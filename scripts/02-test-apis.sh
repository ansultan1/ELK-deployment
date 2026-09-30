#!/bin/bash
# Smoke-tests the Elasticsearch, Logstash and Kibana APIs. Run on the VSI from the project dir.
set -uo pipefail
cd "$(dirname "$0")/.."
set -a; . ./.env; set +a

CA=./certs/ca/ca.crt
ES=https://localhost:9200
KB=https://localhost:5601
LS=http://localhost:9600
PASS=0; FAIL=0

es() { curl -sS --cacert $CA -u "elastic:$ELASTIC_PASSWORD" -H 'Content-Type: application/json' "$@"; }
kb() { curl -sS --cacert $CA -u "elastic:$ELASTIC_PASSWORD" -H 'kbn-xsrf: true' -H 'Content-Type: application/json' "$@"; }
check() { # check "name" "actual" "expected-substring"
  if [[ "$2" == *"$3"* ]]; then echo "  PASS  $1"; PASS=$((PASS+1)); else echo "  FAIL  $1  -> $2" | head -c 400; echo; FAIL=$((FAIL+1)); fi
}

echo "== Elasticsearch"
check "auth required (no creds -> 401)" "$(curl -sS --cacert $CA $ES)" "missing authentication"
check "cluster health"       "$(es $ES/_cluster/health)" '"status":"'
check "node info"            "$(es $ES/_nodes/_local/stats/jvm,os?filter_path=nodes.*.name)" '"name"'
es -XDELETE $ES/api-test >/dev/null
check "create index"         "$(es -XPUT $ES/api-test -d '{"settings":{"number_of_replicas":0},"mappings":{"properties":{"title":{"type":"text"},"n":{"type":"integer"}}}}')" '"acknowledged":true'
check "index document"       "$(es -XPUT "$ES/api-test/_doc/1?refresh=true" -d '{"title":"hello elk","n":1}')" '"result":"created"'
check "bulk"                 "$(es -XPOST "$ES/_bulk?refresh=true" --data-binary $'{"index":{"_index":"api-test"}}\n{"title":"second doc","n":2}\n{"index":{"_index":"api-test"}}\n{"title":"third doc","n":3}\n')" '"errors":false'
check "get document"         "$(es $ES/api-test/_doc/1)" '"found":true'
check "search (match)"       "$(es $ES/api-test/_search -d '{"query":{"match":{"title":"hello"}}}')" '"value":1'
check "aggregation (sum)"    "$(es $ES/api-test/_search -d '{"size":0,"aggs":{"s":{"sum":{"field":"n"}}}}')" '"value":6.0'
check "update document"      "$(es -XPOST "$ES/api-test/_update/1?refresh=true" -d '{"doc":{"n":10}}')" '"result":"updated"'
check "delete document"      "$(es -XDELETE "$ES/api-test/_doc/1")" '"result":"deleted"'
check "delete index"         "$(es -XDELETE $ES/api-test)" '"acknowledged":true'
check "ILM policy present"   "$(es $ES/_ilm/policy/logs-30d)" 'logs-30d'
check "snapshot repo present" "$(es $ES/_snapshot/local_backup)" 'local_backup'
check "least-priv user can't read cluster settings" \
  "$(curl -sS --cacert $CA -u logstash_internal:$LOGSTASH_PASSWORD $ES/_cluster/settings)" 'security_exception'

echo "== Logstash"
check "node API"             "$(curl -sS $LS/)" '"status"'
check "pipeline stats"       "$(curl -sS $LS/_node/stats/pipelines)" '"main"'
check "JVM stats"            "$(curl -sS $LS/_node/stats/jvm)" '"heap_used_percent"'
MARK="apitest-$(date +%s)"
check "http input accepts event" \
  "$(curl -sS -o /dev/null -w '%{http_code}' -u ingest:$LS_HTTP_PASSWORD -XPOST localhost:8080 -H 'Content-Type: application/json' -d "{\"msg\":\"$MARK\",\"level\":\"INFO\"}")" '200'
echo "  ...waiting for event to reach Elasticsearch"; sleep 8
check "event searchable in logs-test-prod" \
  "$(es "$ES/logs-test-prod/_search" -d "{\"query\":{\"match_phrase\":{\"message\":\"$MARK\"}}}")" '"value":1'

echo "== Kibana"
check "status"               "$(kb $KB/api/status)" '"level":"available"'
check "list data views"      "$(kb $KB/api/data_views)" '"data_view"'
check "list alerting rules"  "$(kb "$KB/api/alerting/rules/_find?per_page=1")" '"total"'
check "saved objects find"   "$(kb "$KB/api/saved_objects/_find?type=index-pattern&per_page=1")" '"total"'

echo "== Pipeline end-to-end (app -> filebeat -> logstash -> ES)"
check "sample-app logs indexed" "$(es "$ES/logs-app-prod/_count")" '"count"'
check "metricbeat data present" "$(es "$ES/metricbeat-*/_count")" '"count"'
check "heartbeat data present"  "$(es "$ES/heartbeat-*/_count")" '"count"'

echo; echo "passed=$PASS failed=$FAIL"; [ $FAIL -eq 0 ]
