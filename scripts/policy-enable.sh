#!/usr/bin/env bash
# Debug helper: scripts/policy-enable.sh <policy-name> true|false   (temporary API toggle; next scripts/apply.sh restores declared state)
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh; GW=$(cat .state/gw_id)
ID=$(kongctl api get "/v1/ai-gateways/$GW/policies" | jq -r --arg n "$1" '.data[]|select(.name==$n)|.id')
kongctl api get "/v1/ai-gateways/$GW/policies/$ID" | jq --argjson e "$2" 'del(.id,.created_at,.updated_at)|.enabled=$e' > .state/pe.json
kongctl api put "/v1/ai-gateways/$GW/policies/$ID" -f .state/pe.json | jq -c '{name,enabled}'
