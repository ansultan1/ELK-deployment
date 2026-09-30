#!/bin/bash
# Run once as root on a fresh Ubuntu 22.04/24.04 IBM Cloud VSI.  Usage: sudo ./scripts/00-prepare-host.sh
set -euo pipefail
cd "$(dirname "$0")/.."

[ "$(id -u)" = 0 ] || { echo "run as root"; exit 1; }

echo "== Docker"
if ! command -v docker >/dev/null; then
  curl -fsSL https://get.docker.com | sh
fi
systemctl enable --now docker
# Bounded container logs by default
cat > /etc/docker/daemon.json <<'EOF'
{ "log-driver": "json-file", "log-opts": { "max-size": "50m", "max-file": "5" } }
EOF
systemctl restart docker

echo "== Kernel settings (Elasticsearch requirement)"
echo 'vm.max_map_count=262144' > /etc/sysctl.d/99-elasticsearch.conf
echo 'vm.swappiness=1'        >> /etc/sysctl.d/99-elasticsearch.conf
sysctl --system >/dev/null

echo "== Swap off (ES memory_lock works best without it)"
swapoff -a || true
sed -i '/\sswap\s/ s/^/#/' /etc/fstab

DATA_DIR=$(grep -E '^DATA_DIR=' .env 2>/dev/null | cut -d= -f2 || true)
DATA_DIR=${DATA_DIR:-/data/elk}
echo "== Data directories under $DATA_DIR (mount your IBM block-storage volume here first)"
mkdir -p "$DATA_DIR"/{es,kibana,logstash,backups}
chown -R 1000:0 "$DATA_DIR"
chmod -R g+rwX "$DATA_DIR"

echo "host ready"
