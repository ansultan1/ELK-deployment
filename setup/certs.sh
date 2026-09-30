#!/bin/bash
# Generates a private CA + PEM certs for es01 and kibana. Idempotent.
set -euo pipefail
cd /usr/share/elasticsearch
OUT=/certs

if [ ! -f "$OUT/ca/ca.crt" ]; then
  bin/elasticsearch-certutil ca --silent --pem -out "$OUT/ca.zip"
  unzip -q -o "$OUT/ca.zip" -d "$OUT"
fi

if [ ! -f "$OUT/es01/es01.crt" ]; then
  cat > "$OUT/instances.yml" <<EOF
instances:
  - name: es01
    dns: [es01, localhost]
    ip: [127.0.0.1, ${VSI_IP}]
  - name: kibana
    dns: [kibana, localhost]
    ip: [127.0.0.1, ${VSI_IP}]
EOF
  bin/elasticsearch-certutil cert --silent --pem -out "$OUT/certs.zip" \
    --in "$OUT/instances.yml" --ca-cert "$OUT/ca/ca.crt" --ca-key "$OUT/ca/ca.key"
  unzip -q -o "$OUT/certs.zip" -d "$OUT"
fi

# Containers run as uid 1000 / gid 0: keys group-readable, public certs world-readable.
chown -R 0:0 "$OUT"
find "$OUT" -type d -exec chmod 755 {} \;
find "$OUT" -type f -exec chmod 640 {} \;
find "$OUT" -name '*.crt' -exec chmod 644 {} \;
chmod 600 "$OUT/ca/ca.key"
echo "certs ready"
