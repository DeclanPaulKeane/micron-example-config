#!/usr/bin/env bash
# Section 8 helper: OpenAI-format (native) route to the Foundry deployment so structured outputs / Responses API can be shown.
#   demo/foundry-openai.sh add | remove      (needs demo/add-foundry.sh add for the provider)
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh; GW=$(cat .state/gw_id); DEPLOY=${FOUNDRY_GPT_DEPLOYMENT:-gpt-4o}
id=$(kongctl api get "/v1/ai-gateways/$GW/models" | jq -r '.data[]|select(.name=="gpt-4o-openai")|.id')
case ${1:-add} in
add) jq -n --arg d "$DEPLOY" '{type:"model",name:"gpt-4o-openai",display_name:"GPT-4o via Foundry (OpenAI-native format)",enabled:true,formats:[{type:"openai"}],capabilities:["generate"],
      access:{auth_strategies:["micron-oidc"],acls:{allow:["Demo-DataScience","Demo-Engineering"]}},
      config:{route:{paths:["/foundry"],protocols:["http","https"],model:{body_param:"model",values:["gpt-4o-openai"]}},model:{name_header:true},max_request_body_size:8388608},
      targets:[{name:$d,provider:"azure-foundry",weight:100,config:{type:"azure",deployment_id:$d,api_version:"2024-10-21",input_cost:2.5,output_cost:10}}]}' > .state/fo.json
     if [ -n "$id" ]; then kongctl api put "/v1/ai-gateways/$GW/models/$id" -f .state/fo.json | jq -c '{updated:.name}'; else kongctl api post "/v1/ai-gateways/$GW/models" -f .state/fo.json | jq -c '{created:.name}'; fi;;
remove) [ -n "$id" ] && kongctl api delete "/v1/ai-gateways/$GW/models/$id" >/dev/null && echo removed;;
esac
