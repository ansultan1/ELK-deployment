#!/bin/bash
# Adds the variables needed for remote test targets to an existing .env (never changes existing values).
# Run once, then:  docker compose up -d certs init apm-server logstash filebeat
set -euo pipefail
cd "$(dirname "$0")/.."
[ -f .env ] || { echo "no .env - run 01-generate-env.sh first"; exit 1; }
rnd() { openssl rand -hex 16; }
add() { grep -q "^$1=" .env || { echo "$1=$2" >> .env; echo "added $1"; }; }

add LS_BEATS_BIND 127.0.0.1
add APM_BIND 127.0.0.1
add APM_PASSWORD "$(rnd)"
add APM_SECRET_TOKEN "$(rnd)"
add RCA_PASSWORD "$(rnd)"
add AIOPS_PASSWORD "$(rnd)"
chmod 600 .env
echo "done. To accept a remote target set ES_BIND, LS_BEATS_BIND, APM_BIND to 0.0.0.0 and restrict the ports in the security group."
