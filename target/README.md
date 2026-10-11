# RCA test target: OpenTelemetry Demo on a VM (Docker Compose)

A ~20-container microservice shop (frontend, cart, checkout, payment, kafka, postgres ...) runs on a
**separate VM** and ships logs, metrics and traces to the ELK VSI. `scenarios/rca.sh` breaks it on
purpose and writes the correct answer to an index your AIOps tool can't see.

```
 TARGET VM (4 vCPU / 16 GB+)                               ELK VSI
 ┌──────────────────────────────────────┐                 ┌─────────────────────────┐
 │ OTel Demo containers                 │  OTLP/HTTPS     │ APM Server :8200  ─┐    │
 │   └ otel-collector ──────────────────┼────────────────►│                    ▼    │
 │ Filebeat  (container logs) ──────────┼─ TLS+client ───►│ Logstash :5044 ► Elasticsearch
 │ Metricbeat (host+docker metrics) ────┼─ HTTPS :9200 ──►│                         │
 │ rca.sh  (inject faults / ground truth)┼─ HTTPS :9200 ──►│ rca-scenarios (hidden)  │
 └──────────────────────────────────────┘                 └─────────────────────────┘
```

## 1. ELK VSI (one time)
```bash
cd ~/elk-lab && git pull
./scripts/10-upgrade-env.sh                  # adds APM/RCA/AIOps secrets to .env (existing values untouched)
# edit .env: ES_BIND=0.0.0.0  LS_BEATS_BIND=0.0.0.0  APM_BIND=0.0.0.0
docker compose up -d certs init              # new certs (logstash, apm-server, beat-client) + roles/users
docker compose up -d --force-recreate logstash filebeat apm-server
```
Security group: allow **9200, 5044, 8200 from the target VM's IP only**.

## 2. Target VM
```bash
sudo apt-get install -y docker.io docker-compose-v2 git jq make   # skip what you have
scp -r ubuntu@<ELK_FIP>:~/elk-lab/certs/{ca,beat-client} target/certs/   # needs sudo on the VSI; copy then chown
cp target/.env.example target/.env     # fill in ELK_HOST, BEATS_PASSWORD, APM_SECRET_TOKEN, RCA_PASSWORD (from VSI .env)
./target/install.sh
```
Demo UI `http://<target>:8080`, load generator `/loadgen/`, feature flags `/feature/`.

## 3. Check data is flowing (Kibana)
| Signal | Where |
|---|---|
| Traces / service map | Observability → APM → Services (`checkout`, `payment` ...) |
| Container logs | Discover → `logs-otel_demo-prod` (field `service.name`) |
| OTLP logs | `logs-apm.app.*` |
| Host + container metrics | `metricbeat-*` filtered by the target's `host.name` |

## 4. Run scenarios
```bash
./target/scenarios/rca.sh list
./target/scenarios/rca.sh run payment-failure-100 10     # inject, hold 10 min, revert
./target/scenarios/rca.sh inject currency-down           # manual control
./target/scenarios/rca.sh revert
```
Ground truth: `GET rca-scenarios/_search` as `elastic` (run id, injected/reverted times, expected root
cause, impacted services, expected signals). Leave 5+ minutes of healthy traffic between scenarios
so the AIOps tool has a clean baseline.

## 5. Point the AIOps MCP at it
Use the read-only `aiops_mcp` user (`AIOPS_PASSWORD` in the VSI `.env`). It can read logs/metrics/traces
and **cannot read `rca-scenarios`**. Do not give the MCP the `elastic` user, or it can read the answers.
Score each run by comparing the tool's conclusion with the `expected_root_cause` document.

## Untested / likely tweaks
Nothing here has been run yet. Most likely to need adjusting:
- Logstash `beats` TLS option names (`ssl_enabled`, `ssl_client_authentication`) depend on the plugin version.
- Docker label field `container.labels.com_docker_compose_service` (used for `service.name` in Logstash).
- `apm_writer` privileges: if APM Server logs a 403, add the index pattern it names.
- Demo 3.1.0 compose/collector layout (`make start-no-o11y`, `compose.extras.yaml`); pinned via `DEMO_VERSION`.
- Container interface name `eth0` in the `netem` scenario.
