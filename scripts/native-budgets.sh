#!/usr/bin/env bash
# Konnect AI Cost Management budgets (dashboard utilisation). Enforcement is done by the 'budgets' policy; the Data Science
# budget exists ONLY here, i.e. it is the "watch-only" budget (tracked and shown, never blocks).
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh
have=$(kongctl api get /v1/ai-cost-management/budgets | jq -r '.data[].name')
mk() { # name tagfield value usd interval anchor mode
  echo "$have" | grep -qx "$1" && { echo "exists: $1"; return; }
  jq -n --arg n "$1" --arg f "tags.$2" --arg v "$3" --arg usd "$4" --arg i "$5" --arg a "$6" --arg m "$7" \
   '{effect:"limit",name:$n,labels:{mode:$m,customer:"micron"},limit:{unit:"USD",value:$usd},scope:{filters:[{op:"eq",field:$f,value:$v}]},window:{type:"fixed",interval:$i,anchor:$a}}' > .state/nb.json
  kongctl api post /v1/ai-cost-management/budgets -f .state/nb.json | jq -c '{created:.name}'
}
D="2026-10-24T00:00:00+00:00[UTC]"; M="2026-10-01T00:00:00+00:00[UTC]"
mk "Product Development - monthly" department "Product Development" 2000 P1M "$M" enforced
mk "Finance - monthly" department Finance 500 P1M "$M" enforced
mk "User C - daily" person micron-userc@kong-sales-engineering.com 2 P1D "$D" enforced
mk "Ticket Triage Agent - daily" agent ticket-triage-agent 5 P1D "$D" enforced
mk "Release Notes Agent - daily" agent release-notes-agent 5 P1D "$D" enforced
mk "Data Science team - daily (watch-only)" team "Data Science" 1 P1D "$D" watch-only
