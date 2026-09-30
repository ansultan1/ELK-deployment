# ELK Stack on an IBM Cloud VSI — production-style deployment, monitoring, API testing

Elasticsearch + Logstash + Kibana 8.x (plus Filebeat / Metricbeat / Heartbeat) on one IBM Cloud VSI with Docker Compose, TLS, authentication, least-privilege service accounts, ILM retention and snapshots. A sample app with a traffic generator gives you real data to monitor.

> **Status:** the compose file and shell scripts were syntax-checked, but the stack has **not been run end to end**. Run it on the VSI and use `scripts/02-test-apis.sh` as the acceptance test. Section 9 lists what is most likely to need a tweak.

## 1. Architecture

```
                      Internet
                         │  :5601 (https, allow-listed IPs only)
                 ┌───────▼────────────── IBM Cloud VSI (Ubuntu 24.04) ──────────────────────┐
                 │                                                                          │
                 │  Kibana ──https──► Elasticsearch (single node, TLS, RBAC)  ◄── Metricbeat│
                 │                        ▲     ▲                              (host, docker│
                 │                        │     └── Heartbeat (uptime checks)   + ELK self-│
                 │  sample-app ─stdout─► Docker json logs                          monitoring)│
                 │                        │                                               │
                 │                    Filebeat ──:5044──► Logstash (parse, enrich, route) │
                 │                                          │ persistent queue            │
                 │                                          └──► logs-<dataset>-prod      │
                 │  /data/elk (block-storage volume): es/ kibana/ logstash/ backups/       │
                 └──────────────────────────────────────────────────────────────────────────┘
```

| Signal | Collected by | Lands in | Viewed in Kibana |
|---|---|---|---|
| App / container logs | Filebeat → Logstash | `logs-app-prod`, `logs-docker-prod` (data streams, ILM 30d) | Discover, Observability → Logs |
| Host + container metrics | Metricbeat | `metricbeat-*` | Observability → Infrastructure |
| ELK self-health | Metricbeat xpack modules | `.monitoring-*-mb` | Stack Monitoring |
| Availability / latency | Heartbeat | `heartbeat-*` | Observability → Synthetics / Uptime |

### Production-readiness: what is and isn't covered
**Done:** TLS on ES HTTP/transport and Kibana; auth everywhere; separate least-privilege users for Logstash and Beats (no `elastic` superuser in pipelines); ES and Logstash bound to loopback; `memory_lock`, heap sizing, `vm.max_map_count`, swap off; Logstash persistent queue; data streams + ILM retention; nightly snapshots with retention; bounded Docker logs; `restart: unless-stopped`; secrets generated randomly, `.env` mode 600 and git-ignored.

**Not done (be aware):** this is a **single node**, so no high availability (cluster status stays *yellow* for Beats indices because they want replicas). Snapshots go to the same VM's disk by default — switch to IBM Cloud Object Storage (section 8). The Kibana certificate is from a private CA (browser warning) — put a real certificate / reverse proxy in front for real use. Filebeat→Logstash is plain TCP on the internal Docker network.

## 2. Prerequisites on IBM Cloud

1. **VSI:** Ubuntu 24.04, profile `bx2-4x16` minimum (4 vCPU / 16 GB). `bx2-8x32` is better if you'll send real volume. Attach a **block-storage volume** (100 GB+, 5–10 IOPS/GB tier or better), format it and mount it at `/data`.
   ```bash
   sudo mkfs.ext4 /dev/vdb && sudo mkdir -p /data && sudo mount /dev/vdb /data
   echo "$(blkid -s UUID -o export /dev/vdb | grep ^UUID) /data ext4 defaults,nofail 0 2" | sudo tee -a /etc/fstab   # confirm device name with lsblk first
   ```
2. **Floating IP** attached to the VSI (you need it for the TLS certs and to reach Kibana).
3. **Security group** inbound rules — keep it tight:

   | Port | Source | Purpose |
   |---|---|---|
   | 22/tcp | your office/home IP | SSH |
   | 5601/tcp | your IP(s) | Kibana UI + Kibana API |
   | 9200/tcp | *(nothing)* | ES stays on loopback; reach it via SSH tunnel (below), or add your IP here **and** set `ES_BIND=0.0.0.0` |

   Outbound: allow 443 (image pulls).
4. Copy this directory to the VSI (`scp -r elk-lab ubuntu@<FIP>:~/`).

## 3. Deploy

```bash
cd ~/elk-lab
sudo ./scripts/00-prepare-host.sh              # docker, sysctl, swap off, /data/elk dirs
./scripts/01-generate-env.sh <FLOATING_IP>     # writes .env with random secrets
docker compose up -d --build
docker compose ps                              # wait until es01 and kibana are healthy (2–4 min first time)
```

Startup order (enforced by `depends_on`): `certs` → `es01` → `init` (passwords, roles, users, ILM, snapshot repo) → `kibana`, `logstash`, `metricbeat`, `heartbeat` → `filebeat`.

Log in: `https://<FLOATING_IP>:5601`, user `elastic`, password from `grep ELASTIC_PASSWORD .env`. Accept the private-CA warning, or import `certs/ca/ca.crt`.

Then:
```bash
./scripts/03-kibana-setup.sh     # data views + "app error spike" alert rule
./scripts/02-test-apis.sh        # API test suite (section 5)
```

Reach Elasticsearch from your laptop without opening port 9200:
```bash
ssh -L 9200:localhost:9200 ubuntu@<FLOATING_IP>
curl --cacert ca.crt -u elastic:<pw> https://localhost:9200     # copy certs/ca/ca.crt from the VSI first
```

## 4. Monitoring — what to look at

The `sample-app` (Flask, JSON logs) and `traffic` containers hit `/`, `/order` (10% payment-declined 402s), `/slow` and `/error` (500s) continuously. Give it a minute, then:

**Logs** — *Discover* → data view **App logs**
- `log.level: "ERROR"` — the 500s
- `app.status >= 500 and app.route: "/error"`
- `app.duration_ms > 500` — slow requests
- Visualize: *Lens* → `count()` by `app.status` over time; `p95(app.duration_ms)` by `app.route`.

**Host and containers** — *Observability → Infrastructure → Inventory*: CPU, memory, disk and network of the VSI and each container. Kill the app (`docker stop sample-app`) and watch the metrics and logs stop.

**Health of the ELK stack itself** — *Stack Management → Stack Monitoring* (*Observability → Stack Monitoring* in newer versions): ES indexing/search rate, JVM heap, shard/disk state; Logstash pipeline throughput and queue; Kibana response times.

**Availability** — *Observability → Synthetics* (or Uptime): up/down and latency for app `/health`, ES, Kibana, Logstash port. Try `docker stop sample-app` — `Sample app /health` goes down within ~10s.

**Alerting** — `03-kibana-setup.sh` creates rule *App error spike* (>5 `ERROR` logs in 5 min). Matches are written to index `alerts-app-errors`; check with `GET alerts-app-errors/_search`. Replace the index connector with Email/Slack/PagerDuty/Webhook under *Stack Management → Connectors*.

**Monitoring your own application:** point any container's stdout at the same path — Filebeat already collects all containers. For JSON logs, your fields appear under `app.*` automatically. Non-JSON logs arrive in `message`; add `grok` filters in `logstash/pipeline/main.conf` (and `docker compose restart logstash`). For host-installed apps, add a `filestream` input to `filebeat/filebeat.yml` and mount the log path. To ship from *other* servers, run Filebeat/Metricbeat there pointed at this Logstash (:5044 — requires opening the port and adding TLS) or Elasticsearch.

## 5. API testing

`./scripts/02-test-apis.sh` runs ~30 checks and prints PASS/FAIL. It covers:

| Component | Endpoint(s) | Checks |
|---|---|---|
| Elasticsearch :9200 | `_cluster/health`, index create/delete, `_doc` CRUD, `_bulk`, `_search`, aggregations, `_update`, ILM & snapshot config | auth enforced, CRUD round trip, search/agg correctness, least-privilege user is denied admin APIs |
| Logstash :9600 / :8080 | `/`, `/_node/stats/pipelines`, `/_node/stats/jvm`, HTTP input | node up, pipeline `main` loaded, POST an event → it is searchable in `logs-test-prod` (proves Logstash→ES) |
| Kibana :5601 | `/api/status`, `/api/data_views`, `/api/alerting/rules/_find`, saved objects | service available, APIs respond with auth |
| End-to-end | `logs-app-prod`, `metricbeat-*`, `heartbeat-*` counts | whole pipeline is flowing |

Manual examples (run on the VSI, after `set -a; . ./.env; set +a`):

```bash
CA=certs/ca/ca.crt
# Elasticsearch
curl --cacert $CA -u elastic:$ELASTIC_PASSWORD https://localhost:9200/_cluster/health?pretty
curl --cacert $CA -u elastic:$ELASTIC_PASSWORD https://localhost:9200/logs-app-prod/_search?pretty \
  -H 'Content-Type: application/json' -d '{"size":3,"query":{"match":{"log.level":"ERROR"}},"sort":[{"@timestamp":"desc"}]}'
curl --cacert $CA -u elastic:$ELASTIC_PASSWORD 'https://localhost:9200/_cat/indices?v&s=store.size:desc'
curl --cacert $CA -u elastic:$ELASTIC_PASSWORD 'https://localhost:9200/_data_stream?pretty'

# Logstash
curl -s localhost:9600/_node/stats/pipelines?pretty | head -40
curl -u ingest:$LS_HTTP_PASSWORD -XPOST localhost:8080 -H 'Content-Type: application/json' -d '{"msg":"manual test","level":"INFO"}'

# Kibana
curl --cacert $CA -u elastic:$ELASTIC_PASSWORD https://localhost:5601/api/status | head -c 300
curl --cacert $CA -u elastic:$ELASTIC_PASSWORD -H 'kbn-xsrf: true' https://localhost:5601/api/alerting/rules/_find
```
For API-key auth instead of passwords: `POST _security/api_key` and send `-H "Authorization: ApiKey <encoded>"`.

Load testing ES: `docker run --rm --network elk_default elastic/rally` or simply loop `_bulk` calls; watch *Stack Monitoring* while doing so.

## 6. Day-2 operations

```bash
docker compose ps; docker compose logs -f logstash          # status / logs
docker compose restart logstash                              # apply pipeline change
curl ... _cluster/allocation/explain?pretty                  # why is a shard unassigned
curl ... _cat/allocation?v                                   # disk usage (ES stops allocating at 85%, read-only at 95%)
curl ... _slm/policy/nightly?pretty                          # snapshot status
```
- **Retention:** `logs-30d` ILM policy (`setup/init.sh`): rollover daily, delete at 30d. Change and re-run `docker compose run --rm init`.
- **Restore test** (do this once, a backup you haven't restored isn't a backup): `POST _snapshot/local_backup/<snap>/_restore`.
- **Upgrade:** snapshot → bump `STACK_VERSION` in `.env` → `docker compose pull && docker compose up -d` (upgrade one minor version at a time; read the release notes; Kibana/Beats must not be newer than ES).
- **Rotate a password:** `POST _security/user/<name>/_password`, update `.env`, `docker compose up -d`.
- **Disk:** alert on the VSI filesystem in Infrastructure view; expand the IBM block volume online and `resize2fs`.

## 7. Sizing guide

| Daily ingest | VSI | ES heap | Notes |
|---|---|---|---|
| < 5 GB/day | bx2-4x16 | 4g | this lab's defaults |
| 5–30 GB/day | bx2-8x32 | 8–12g | IOPS-heavy block volume |
| more / need HA | 3+ VSIs | ≤ 50% RAM, ≤ 31g | move to multi-node (below) |

## 8. Going further

- **HA:** three master-eligible data nodes (`es01..es03`, `discovery.seed_hosts`, `cluster.initial_master_nodes`, drop `discovery.type=single-node`), put them on separate VSIs across IBM zones, add a dedicated Logstash tier behind a load balancer, add `es02/es03` to `certs.sh`, and use replicas ≥ 1.
- **Snapshots to IBM Cloud Object Storage:** create a COS bucket + HMAC credentials, add `s3.client.default.access_key/secret_key` to the ES keystore, then `PUT _snapshot/cos {"type":"s3","settings":{"bucket":"...","endpoint":"s3.<region>.cloud-object-storage.appdomain.cloud","path_style_access":true}}` and point the SLM policy at it.
- **TLS front door:** nginx/Caddy or an IBM Cloud Application Load Balancer with a real certificate in front of Kibana; bind Kibana to loopback.
- **Logstash TLS / more inputs:** add `ssl_enabled`/cert settings to the beats input and `output.logstash.ssl` in Filebeat before accepting external shippers.
- **Auth:** SSO (SAML/OIDC) needs a paid license tier; otherwise create per-person users/roles in *Stack Management → Security*.
- **IBM Cloud Monitoring/Logging** are the managed alternatives if you don't want to operate ELK.

## 9. Troubleshooting (and likely first-run tweaks)

| Symptom | Fix |
|---|---|
| `es01` exits: `max virtual memory areas ... too low` | `sudo sysctl -w vm.max_map_count=262144` (prepare script does it) |
| `es01` permission denied on `/usr/share/elasticsearch/data` | `sudo chown -R 1000:0 /data/elk && sudo chmod -R g+rwX /data/elk` |
| `es01` `memory_lock` / ulimit error | confirm Docker honors `ulimits`; as a last resort remove `bootstrap.memory_lock` |
| Kibana "server is not ready" for minutes | normal on first boot (saved-object migration); `docker compose logs kibana` |
| Kibana can't log in / 401 loop | `init` failed — `docker compose logs init`; re-run `docker compose run --rm init` |
| No data in `logs-app-prod` | `docker compose logs filebeat logstash`; check `curl localhost:9600/_node/stats/pipelines` event counts |
| Logstash ES output error about `ssl_certificate_authorities` | older Logstash plugin: use `cacert => "..."` instead (stack ≥ 8.12 uses the `ssl_*` names) |
| Stack Monitoring shows Kibana or Logstash missing | check `docker compose logs metricbeat`; the `beats_internal` user's access to Kibana stats API is the first suspect (grant it `monitoring_user` / `kibana_admin` roles in `setup/init.sh`) |
| Alert rule creation fails in `03-kibana-setup.sh` | rule-type/connector payloads vary slightly by minor version; create it once in the UI, then `GET /api/alerting/rule/<id>` to see the exact shape |
| Cluster is yellow | expected on one node (Beats indices request replicas). Set `number_of_replicas: 0` on those indices or add nodes |

## 10. Layout

```
docker-compose.yml        the stack
setup/certs.sh            private CA + node certs (idempotent)
setup/init.sh             passwords, roles, users, ILM, snapshot repo + SLM
kibana/kibana.yml         logstash/logstash.yml + pipeline/main.conf
filebeat/ metricbeat/ heartbeat/   shipper configs
app/                      sample monitored service
scripts/00..03            host prep, secret generation, API tests, Kibana objects
```
Teardown: `docker compose down` (keeps data) · `docker compose down -v && sudo rm -rf /data/elk/* certs` (wipes everything).
