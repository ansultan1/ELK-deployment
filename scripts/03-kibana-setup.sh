#!/bin/bash
# Creates data views and an alert rule through the Kibana API. Idempotent-ish (skips on 409).
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a
KB=https://localhost:5601
kb() { curl -sS --cacert ./certs/ca/ca.crt -u "elastic:$ELASTIC_PASSWORD" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' "$@"; echo; }

echo "== data views"
kb -XPOST $KB/api/data_views/data_view -d '{"data_view":{"id":"app-logs","name":"App logs","title":"logs-app-*","timeFieldName":"@timestamp"}}'
kb -XPOST $KB/api/data_views/data_view -d '{"data_view":{"id":"all-logs","name":"All logs","title":"logs-*","timeFieldName":"@timestamp"}}'

echo "== connector: write alerts into an index (swap for email/Slack/PagerDuty in real use)"
kb -XPOST $KB/api/actions/connector/app-errors-index -d '{"name":"app-errors-index","connector_type_id":".index","config":{"index":"alerts-app-errors","refresh":true}}'

echo "== rule: >5 ERROR logs from sample-app in 5 minutes"
kb -XPOST $KB/api/alerting/rule/app-error-spike -d '{
  "name": "App error spike",
  "rule_type_id": ".es-query",
  "consumer": "alerts",
  "schedule": { "interval": "1m" },
  "params": {
    "searchType": "esQuery",
    "index": ["logs-app-prod"],
    "timeField": "@timestamp",
    "esQuery": "{\"query\":{\"match\":{\"log.level\":\"ERROR\"}}}",
    "size": 10,
    "threshold": [5],
    "thresholdComparator": ">",
    "timeWindowSize": 5,
    "timeWindowUnit": "m"
  },
  "actions": [{
    "group": "query matched",
    "id": "app-errors-index",
    "params": { "documents": [{ "rule": "{{rule.name}}", "matches": "{{context.hits.length}}", "at": "{{date}}" }] }
  }]
}'
