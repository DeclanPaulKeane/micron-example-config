#!/usr/bin/env bash
# Section 8: Bedrock-native (Converse) route through the gateway, for service tier / Flex. demo/bedrock-native.sh add | remove
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh; GW=$(cat .state/gw_id)
id=$(kongctl api get "/v1/ai-gateways/$GW/models" | jq -r '.data[]|select(.name=="bedrock-native")|.id')
case ${1:-add} in
add) jq -n '{type:"model",name:"bedrock-native",display_name:"Bedrock native (Converse) incl. service tier",enabled:true,formats:[{type:"bedrock"}],capabilities:["generate"],
     access:{auth_strategies:["micron-oidc"],acls:{allow:["Demo-DataScience","Demo-Engineering"]}},
     config:{route:{paths:["/bedrock"],protocols:["http","https"],model:{header_param:"x-bedrock-model",values:["amazon.nova-pro-v1:0"]}},model:{name_header:true},max_request_body_size:8388608},
     targets:[{name:"amazon.nova-pro-v1:0",provider:"bedrock-us-east-1",weight:100,config:{type:"bedrock",region:"us-east-1",input_cost:0.8,output_cost:3.2,service_tier_factor:[{tier:"flex",factor:0.5}]}}]}' > .state/bn.json
     if [ -n "$id" ]; then kongctl api put "/v1/ai-gateways/$GW/models/$id" -f .state/bn.json | jq -c '{updated:.name}'; else kongctl api post "/v1/ai-gateways/$GW/models" -f .state/bn.json 2>&1 | grep -oE '"detail":"[^"]*|"name": ?"[^"]*' | head -2; fi;;
remove) [ -n "$id" ] && kongctl api delete "/v1/ai-gateways/$GW/models/$id" >/dev/null && echo removed;;
esac
