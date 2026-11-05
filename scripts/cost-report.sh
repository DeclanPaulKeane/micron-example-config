#!/usr/bin/env bash
# Cost report for the demo period. Usage: scripts/cost-report.sh [HOURS=24]
# Tables: by department, team, person, agent, model, provider -- with cached tokens. (Failed/interrupted requests: see Grafana, section 6.)
cd "$(dirname "$0")/.."; . scripts/env.sh; H=${1:-24}
FROM=$(date -u -v-"${H}"H +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "$H hours ago" +%Y-%m-%dT%H:%M:%SZ); NOW=$(date -u +%Y-%m-%dT%H:%M:%SZ)
for dim in tags.department tags.team tags.person tags.agent model provider; do
  echo; echo "=== cost by ${dim#tags.} (last ${H}h) ==="
  jq -n --arg f "$FROM" --arg t "$NOW" --arg d "$dim" --arg src "//control-planes/$(cat .state/gw_id)" \
   '{from:$f,to:$t,dimensions:[$d],measures:["events","reported_cost","input_tokens","input_cache_read_tokens","input_cache_write_tokens","output_tokens"],filters:{source:{eq:$src}}}' > .state/q.json
  kongctl api post /v1/ai-cost-management/events/query -f .state/q.json | jq -r --arg d "$dim" \
   '(["name","requests","cost_usd","input_tok","cache_read","cache_write","output_tok"]|@tsv), (.data[]|[.dimensions[$d], .measures.events, (.measures.reported_cost.value|tonumber*10000|round/10000), .measures.input_tokens, .measures.input_cache_read_tokens, .measures.input_cache_write_tokens, .measures.output_tokens]|@tsv)' | column -t -s $'\t'
done
