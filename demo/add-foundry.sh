#!/usr/bin/env bash
# LIVE DEMO STEP (section 2): add Microsoft Foundry (Azure OpenAI) and publish gpt-4o to Demo-DataScience ONLY.
#   demo/add-foundry.sh add      -> provider + model + model-list entry for Data Science
#   demo/add-foundry.sh remove   -> undo (used by reset-demo.sh)
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh; GW=$(cat .state/gw_id)
HOST=$(echo "$AZURE_OPENAI_ENDPOINT" | sed -E 's#https://([^./]+)\..*#\1#'); DEPLOY=${FOUNDRY_GPT_DEPLOYMENT:-gpt-4o}
idof() { kongctl api get "/v1/ai-gateways/$GW/$1" | jq -r --arg n "$2" '.data[]|select(.name==$n)|.id'; }
LISTPOL=$(idof policies models-list-datascience)
case ${1:-add} in
add)
  jq -n --arg inst "$HOST" '{type:"azure",name:"azure-foundry",display_name:"Microsoft Foundry (Azure OpenAI)",config:{instance:$inst,auth:{type:"basic",headers:[{name:"api-key",value:"{vault://micron-vault/azure-api-key}"}]}}}' > .state/f1.json
  pid=$(idof model-providers azure-foundry); [ -z "$pid" ] && kongctl api post "/v1/ai-gateways/$GW/model-providers" -f .state/f1.json | jq -c '{provider:.name}'
  jq -n --arg d "$DEPLOY" '{type:"model",name:"gpt-4o-foundry",display_name:"GPT-4o (Microsoft Foundry)",enabled:true,formats:[{type:"anthropic"}],capabilities:["generate"],
    access:{auth_strategies:["micron-oidc"],acls:{allow:["Demo-DataScience"]}},
    config:{route:{paths:["/sandbox/anthropic"],protocols:["http","https"],model:{body_param:"model",values:["gpt-4o"]}},model:{name_header:true},max_request_body_size:8388608},
    targets:[{name:$d,provider:"azure-foundry",weight:100,config:{type:"azure",deployment_id:$d,api_version:"2024-10-21",input_cost:2.5,output_cost:10}}]}' > .state/f2.json
  mid=$(idof models gpt-4o-foundry); if [ -n "$mid" ]; then kongctl api put "/v1/ai-gateways/$GW/models/$mid" -f .state/f2.json | jq -c '{model:.name}'; else kongctl api post "/v1/ai-gateways/$GW/models" -f .state/f2.json | jq -c '{model:.name}'; fi
  kongctl api get "/v1/ai-gateways/$GW/policies/$LISTPOL" | jq 'del(.id,.created_at,.updated_at) | .config.body |= (fromjson | .data += [{"type":"model","id":"gpt-4o","display_name":"GPT-4o (Microsoft Foundry)","created_at":"2026-06-29T00:00:00Z"}] | .last_id="gpt-4o" | tojson)' > .state/f3.json
  kongctl api put "/v1/ai-gateways/$GW/policies/$LISTPOL" -f .state/f3.json | jq -c '{datascience_model_list: (.config.body|fromjson|[.data[].id])}';;
remove)
  demo/foundry-responses.sh remove >/dev/null 2>&1 || true; demo/foundry-openai.sh remove >/dev/null 2>&1 || true
  mid=$(idof models gpt-4o-foundry); [ -n "$mid" ] && kongctl api delete "/v1/ai-gateways/$GW/models/$mid" >/dev/null && echo "model removed"
  pid=$(idof model-providers azure-foundry); [ -n "$pid" ] && kongctl api delete "/v1/ai-gateways/$GW/model-providers/$pid" >/dev/null && echo "provider removed"
  scripts/apply.sh >/dev/null 2>&1 && echo "model list restored from config";;
esac
