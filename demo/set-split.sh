#!/usr/bin/env bash
# Change the Anthropic/Bedrock split of 'claude-sonnet-split' live (no client change). Usage: demo/set-split.sh 70   (-> 70/30)  |  50  (-> 50/50)
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh; GW=$(cat .state/gw_id); A=${1:?anthropic weight %}; B=$((100 - A))
MID=$(kongctl api get "/v1/ai-gateways/$GW/models" | jq -r '.data[]|select(.name=="claude-sonnet-split")|.id')
kongctl api get "/v1/ai-gateways/$GW/models/$MID" | jq --argjson a "$A" --argjson b "$B" 'del(.id,.created_at,.updated_at) | .targets |= map(if .provider=="anthropic-primary" then .weight=$a else .weight=$b end)' > .state/split.json
kongctl api put "/v1/ai-gateways/$GW/models/$MID" -f .state/split.json | jq -c '[.targets[]|{provider,weight}]'
