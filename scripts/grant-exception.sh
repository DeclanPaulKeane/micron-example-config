#!/usr/bin/env bash
# Time-limited budget exception. Usage: scripts/grant-exception.sh userc 1 24     (+$1 for 24 hours on User C's daily budget)
# Raises the limit of the matching budget block in the 'budgets' policy; budget-watcher reverts it when the hours are up.
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh
U=$1; DELTA=$2; HOURS=$3; GW=$(cat .state/gw_id)
EMAIL="micron-$U@kong-sales-engineering.com"
PID=$(kongctl api get "/v1/ai-gateways/$GW/policies" | jq -r '.data[]|select(.name=="budgets")|.id')
kongctl api get "/v1/ai-gateways/$GW/policies/$PID" > .state/pol.json
IDX=$(jq --arg e "$EMAIL" '[.config.policies[]|(.match[0].values|index($e))]|map(. != null)|index(true)' .state/pol.json)
[ "$IDX" != null ] || { echo "no budget block for $EMAIL"; exit 1; }
ORIG=$(jq ".config.policies[$IDX].limits[0].limit" .state/pol.json)
jq "del(.id,.created_at,.updated_at) | .config.policies[$IDX].limits[0].limit += $DELTA" .state/pol.json > .state/pol2.json
kongctl api put "/v1/ai-gateways/$GW/policies/$PID" -f .state/pol2.json | jq -c '{limit_now: .config.policies['$IDX'].limits[0].limit}'
EXP=$(python3 -c "import time;print(int(time.time()+$HOURS*3600))")
set -a; . ./secrets.yaml; set +a
kubectl -n micron-aigw exec deploy/redis -- redis-cli -a "$REDIS_PASSWORD" --no-auth-warning hset micron:exceptions "$EMAIL" "{\"index\":$IDX,\"original\":$ORIG,\"expires\":$EXP}" >/dev/null
kubectl -n micron-aigw exec deploy/redis -- redis-cli -a "$REDIS_PASSWORD" --no-auth-warning --scan --pattern 'micron:notified' >/dev/null
echo "exception granted: $EMAIL limit \$$ORIG -> \$$(python3 -c "print($ORIG+$DELTA)") for ${HOURS}h (propagates in ~15 s)"
