#!/bin/bash
# One-shot bootstrap: service passwords, least-privilege roles/users, ILM, snapshots. Idempotent.
set -euo pipefail

ES=https://es01:9200
CA=/certs/ca/ca.crt

api() { # api METHOD PATH [JSON]  (no --fail-with-body: the ES image's curl is too old)
  local out code
  out=$(curl -sS -w '\n%{http_code}' --cacert "$CA" -u "elastic:${ELASTIC_PASSWORD}" \
    -X "$1" -H 'Content-Type: application/json' "$ES$2" ${3:+-d "$3"}) || return 1
  code=${out##*$'\n'}
  echo "${out%$'\n'*}"
  [[ "$code" =~ ^2 ]] || { echo "HTTP $code from $1 $2" >&2; return 1; }
}

echo "== built-in user passwords"
api POST /_security/user/kibana_system/_password "{\"password\":\"${KIBANA_PASSWORD}\"}"

echo "== roles"
api PUT /_security/role/logstash_writer '{
  "cluster": ["monitor", "manage_index_templates"],
  "indices": [{
    "names": ["logs-*-*"],
    "privileges": ["auto_configure", "create_doc", "create_index", "view_index_metadata"]
  }]
}'

api PUT /_security/role/beats_writer '{
  "cluster": ["monitor", "manage_ilm", "read_ilm", "manage_index_templates", "manage_pipeline"],
  "indices": [{
    "names": ["filebeat-*", "metricbeat-*", "heartbeat-*", "logs-*", "metrics-*", "synthetics-*"],
    "privileges": ["auto_configure", "create_doc", "create_index", "view_index_metadata"]
  }]
}'

echo "== users"
api PUT /_security/user/logstash_internal "{
  \"password\": \"${LOGSTASH_PASSWORD}\", \"roles\": [\"logstash_writer\"],
  \"full_name\": \"Logstash writer\"
}"
# beats_writer also gets the built-in monitoring roles so Metricbeat xpack modules can
# collect ES/Kibana/Logstash stats and write .monitoring-*-mb.
api PUT /_security/user/beats_internal "{
  \"password\": \"${BEATS_PASSWORD}\",
  \"roles\": [\"beats_writer\", \"remote_monitoring_collector\", \"remote_monitoring_agent\"],
  \"full_name\": \"Beats writer\"
}"

echo "== ILM: 30-day log lifecycle"
api PUT /_ilm/policy/logs-30d '{
  "policy": { "phases": {
    "hot":    { "actions": { "rollover": { "max_age": "1d", "max_primary_shard_size": "30gb" } } },
    "warm":   { "min_age": "3d", "actions": { "forcemerge": { "max_num_segments": 1 }, "shrink": { "number_of_shards": 1 } } },
    "delete": { "min_age": "30d", "actions": { "delete": {} } }
  } }
}'
# logs-*-* data streams include the "logs@custom" component template automatically.
api PUT /_component_template/logs@custom '{
  "template": { "settings": {
    "index.lifecycle.name": "logs-30d",
    "index.number_of_replicas": 0
  } }
}'

echo "== snapshots: local repo + nightly SLM (swap for IBM COS / S3 in real prod)"
api PUT /_snapshot/local_backup '{
  "type": "fs", "settings": { "location": "/usr/share/elasticsearch/backups" }
}'
api PUT /_slm/policy/nightly '{
  "schedule": "0 30 1 * * ?",
  "name": "<nightly-{now/d}>",
  "repository": "local_backup",
  "config": { "indices": ["*"], "include_global_state": true },
  "retention": { "expire_after": "14d", "min_count": 3, "max_count": 14 }
}'

echo "init done"
