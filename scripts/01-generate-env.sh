#!/bin/bash
# Creates .env with random secrets. Usage: ./scripts/01-generate-env.sh <VSI_PUBLIC_IP> [hostname]
set -euo pipefail
cd "$(dirname "$0")/.."

[ -f .env ] && { echo ".env exists - refusing to overwrite (delete it to regenerate)"; exit 1; }
VSI_IP=${1:?usage: $0 <vsi-public-ip> [hostname]}
VSI_HOSTNAME=${2:-$(hostname)}
rnd() { openssl rand -hex 16; }

cat > .env <<EOF
STACK_VERSION=8.15.3
VSI_IP=${VSI_IP}
VSI_HOSTNAME=${VSI_HOSTNAME}
DATA_DIR=/data/elk

# Heap: ~50% of container budget, never above 31g. 4g suits a 16 GB VSI.
ES_HEAP=4g
LS_HEAP=1g

# ES + Logstash stay on loopback (use SSH tunnel or security-group rules). Kibana is the public UI.
ES_BIND=127.0.0.1
KIBANA_BIND=0.0.0.0

ELASTIC_PASSWORD=$(rnd)
KIBANA_PASSWORD=$(rnd)
LOGSTASH_PASSWORD=$(rnd)
BEATS_PASSWORD=$(rnd)
LS_HTTP_PASSWORD=$(rnd)
KIBANA_ENC_KEY_1=$(openssl rand -hex 16)
KIBANA_ENC_KEY_2=$(openssl rand -hex 16)
KIBANA_ENC_KEY_3=$(openssl rand -hex 16)
EOF
chmod 600 .env
echo ".env written (mode 600). Back it up somewhere safe - it holds the elastic superuser password."
