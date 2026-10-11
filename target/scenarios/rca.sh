#!/bin/bash
# RCA scenario runner (run on the TARGET VM).
#   rca.sh list                      show scenarios
#   rca.sh inject <id>               inject the fault and write ground truth (rca-scenarios) to Elasticsearch
#   rca.sh revert [run_id]           undo the fault (default: most recent run) and record the end time
#   rca.sh run <id> [minutes]        inject, wait (default 10), revert
# Ground truth is stored in the `rca-scenarios` index. The AIOps MCP user (aiops_mcp) cannot read it.
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
set -a; . "$HERE/../.env"; set +a
CATALOG="$HERE/catalog.json"
STATE="$HERE/.state"; mkdir -p "$STATE"
FLAGS="$DEMO_DIR/src/flagd/demo.flagd.json"
now() { date -u +%Y-%m-%dT%H:%M:%SZ; }
es() { # es METHOD PATH JSON
  curl -sS --cacert "$HERE/../certs/ca/ca.crt" -u "rca_internal:${RCA_PASSWORD}" \
    -X "$1" -H 'Content-Type: application/json' "https://${ELK_HOST}:9200$2" -d "$3" >/dev/null
}
cid() { # container id of a compose service
  local id; id=$(docker ps -q --filter "label=com.docker.compose.service=$1" | head -n1)
  [ -n "$id" ] || { echo "no running container for service '$1'" >&2; exit 1; }
  echo "$id"
}
set_flag() { # set_flag NAME VARIANT  (flagd watches the file and reloads)
  local tmp; tmp=$(mktemp)
  jq --arg f "$1" --arg v "$2" '.flags[$f].defaultVariant = $v' "$FLAGS" > "$tmp" && cat "$tmp" > "$FLAGS"; rm -f "$tmp"
}
netem() { # netem add|del SERVICE [delay jitter]
  local c; c=$(cid "$2")
  if [ "$1" = add ]; then
    docker run --rm --net "container:$c" --cap-add NET_ADMIN nicolaka/netshoot \
      tc qdisc add dev eth0 root netem delay "${3}ms" "${4}ms"
  else
    docker run --rm --net "container:$c" --cap-add NET_ADMIN nicolaka/netshoot \
      tc qdisc del dev eth0 root || true
  fi
}
scenario() { jq -e --arg id "$1" '.[] | select(.id==$id)' "$CATALOG"; }

apply() { # apply SCENARIO_JSON  -> start fault
  local t; t=$(jq -r .fault.type <<<"$1")
  case "$t" in
    flag)       set_flag "$(jq -r .fault.flag <<<"$1")" "$(jq -r .fault.variant <<<"$1")" ;;
    stop)       docker stop "$(cid "$(jq -r .fault.service <<<"$1")")" >/dev/null ;;
    netem)      netem add "$(jq -r .fault.service <<<"$1")" "$(jq -r .fault.delay_ms <<<"$1")" "$(jq -r .fault.jitter_ms <<<"$1")" ;;
    cpu_stress) docker run -d --rm --name rca-stress alexeiled/stress-ng --cpu 0 --timeout 3600s >/dev/null ;;
    *) echo "unknown fault type $t" >&2; exit 1 ;;
  esac
}
undo() { # undo SCENARIO_JSON
  local t; t=$(jq -r .fault.type <<<"$1")
  case "$t" in
    flag)       set_flag "$(jq -r .fault.flag <<<"$1")" off ;;
    stop)       docker start "$(docker ps -aq --filter "label=com.docker.compose.service=$(jq -r .fault.service <<<"$1")" | head -n1)" >/dev/null ;;
    netem)      netem del "$(jq -r .fault.service <<<"$1")" ;;
    cpu_stress) docker rm -f rca-stress >/dev/null 2>&1 || true ;;
  esac
}

cmd=${1:-}
case "$cmd" in
  list)
    jq -r '.[] | "\(.id)\t[\(.category)]\t\(.title)\n\t  root cause: \(.expected_root_cause.service) / \(.expected_root_cause.kind)"' "$CATALOG" ;;
  inject)
    id=${2:?scenario id}; sc=$(scenario "$id")
    run_id="$id-$(date -u +%Y%m%dT%H%M%SZ)"; start=$(now)
    apply "$sc"
    echo "$sc" > "$STATE/$run_id.json"; echo "$run_id" > "$STATE/latest"
    es PUT "/rca-scenarios/_doc/$run_id" "$(jq -n --arg r "$run_id" --arg s "$start" --arg env "${ENVIRONMENT:-}" --argjson sc "$sc" \
      '{"@timestamp":$s, run_id:$r, scenario_id:$sc.id, title:$sc.title, category:$sc.category, status:"active",
        injected_at:$s, reverted_at:null, environment:$env, fault:$sc.fault,
        expected_root_cause:$sc.expected_root_cause, expected_impacted:$sc.expected_impacted, expected_signals:$sc.expected_signals}')"
    echo "injected $run_id at $start" ;;
  revert)
    run_id=${2:-$(cat "$STATE/latest")}; sc=$(cat "$STATE/$run_id.json")
    undo "$sc"; end=$(now)
    es POST "/rca-scenarios/_update/$run_id" "$(jq -n --arg e "$end" '{doc:{status:"reverted", reverted_at:$e}}')"
    echo "reverted $run_id at $end" ;;
  run)
    id=${2:?scenario id}; mins=${3:-10}
    "$0" inject "$id"; trap '"$0" revert' EXIT
    echo "holding fault for ${mins} min (Ctrl-C reverts)"; sleep "$((mins*60))" ;;
  *) sed -n 2,8p "$0"; exit 1 ;;
esac
