#!/bin/bash
# Run on the TARGET VM (Ubuntu + Docker + compose plugin + git + jq).
# Clones the OpenTelemetry Demo, wires its collector to the ELK stack, starts demo + Beats.
set -euo pipefail
cd "$(dirname "$0")"
[ -f .env ] || { echo "create target/.env from .env.example first"; exit 1; }
set -a; . ./.env; set +a
for f in certs/ca/ca.crt certs/beat-client/beat-client.crt certs/beat-client/beat-client.key; do
  [ -f "$f" ] || { echo "missing $f - copy the certs dir from the ELK VSI"; exit 1; }
done

if [ ! -d "$DEMO_DIR" ]; then
  git clone --depth 1 --branch "$DEMO_VERSION" https://github.com/open-telemetry/opentelemetry-demo "$DEMO_DIR"
fi
cp otel/otelcol-config-extras.yml "$DEMO_DIR/src/otel-collector/otelcol-config-extras.yml"
cp otel/compose.extras.yaml       "$DEMO_DIR/compose.extras.yaml"

# .env.override is read by the demo's Makefile after .env
cat > "$DEMO_DIR/.env.override" <<EOT
ELK_HOST=$ELK_HOST
APM_SECRET_TOKEN=$APM_SECRET_TOKEN
ELK_CA_FILE=$(pwd)/certs/ca/ca.crt
EOT

docker compose -f compose.beats.yaml up -d
# start-no-o11y = demo without its own Jaeger/Grafana/Prometheus/OpenSearch (ELK replaces them)
make -C "$DEMO_DIR" start-no-o11y
echo "demo UI: http://localhost:8080   load generator: http://localhost:8080/loadgen/"
