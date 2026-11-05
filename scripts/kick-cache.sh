#!/usr/bin/env bash
# After a data-plane restart the semantic-cache instances can stay inactive until the next config push (observed on 2.2).
# This pushes a harmless change (cache_ttl 3600 <-> 3601) to the cache policies so the instances are re-initialised.
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh; GW=$(cat .state/gw_id)
for n in cache-eng; do   # one cache policy since the model-alias fix
  ID=$(kongctl api get "/v1/ai-gateways/$GW/policies" | jq -r --arg n "$n" '.data[]|select(.name==$n)|.id')
  kongctl api get "/v1/ai-gateways/$GW/policies/$ID" | jq 'del(.id,.created_at,.updated_at)|.config.cache_ttl=(if .config.cache_ttl==3600 then 3601 else 3600 end)' > .state/ck.json
  kongctl api put "/v1/ai-gateways/$GW/policies/$ID" -f .state/ck.json >/dev/null
done; echo "cache policies refreshed"
