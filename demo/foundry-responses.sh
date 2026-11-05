#!/usr/bin/env bash
# Section 8: Azure Foundry Responses API through the gateway as a plain HTTP passthrough (models don't route /responses in 2.2).
#   demo/foundry-responses.sh add | remove
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh; set -a; . ./secrets.yaml; set +a; GW=$(cat .state/gw_id)
HOST=$(echo "$AZURE_OPENAI_ENDPOINT" | sed -E 's#(https://[^/]+).*#\1#')
pid=$(kongctl api get "/v1/ai-gateways/$GW/policies" | jq -r '.data[]|select(.name=="azure-add-key")|.id'); aid=$(kongctl api get "/v1/ai-gateways/$GW/agents" | jq -r '.data[]|select(.name=="foundry-responses")|.id')
case ${1:-add} in
add)
 [ -z "$pid" ] && jq -n '{type:"request-transformer-advanced",name:"azure-add-key",display_name:"Foundry key injection",enabled:true,global:false,config:{add:{headers:["{vault://micron-vault/azure-api-key-header}"]},replace:{headers:["{vault://micron-vault/azure-api-key-header}"]}}}' > .state/fr1.json && kongctl api post "/v1/ai-gateways/$GW/policies" -f .state/fr1.json | jq -c '{policy:.name}'
 pid=$(kongctl api get "/v1/ai-gateways/$GW/policies" | jq -r '.data[]|select(.name=="azure-add-key")|.id')
 jq -n --arg u "$HOST/openai/v1/responses" --arg p "$pid" '{type:"http",name:"foundry-responses",display_name:"Foundry Responses API (HTTP passthrough)",enabled:true,
   access:{auth_strategies:["micron-oidc"],acls:{allow:["Demo-DataScience","Demo-Engineering"]}},
   config:{url:$u,route:{paths:["/foundry-responses"],protocols:["http","https"],strip_path:true},logging:{payloads:false},max_request_body_size:8388608},policies:["azure-add-key"]}' > .state/fr2.json
 if [ -n "$aid" ]; then kongctl api put "/v1/ai-gateways/$GW/agents/$aid" -f .state/fr2.json | jq -c '{updated:.name}'; else kongctl api post "/v1/ai-gateways/$GW/agents" -f .state/fr2.json | jq -c '{created:.name}'; fi;;
remove) [ -n "$aid" ] && kongctl api delete "/v1/ai-gateways/$GW/agents/$aid" >/dev/null && echo "agent removed"; [ -n "$pid" ] && kongctl api delete "/v1/ai-gateways/$GW/policies/$pid" >/dev/null && echo "policy removed" || true;;
esac
