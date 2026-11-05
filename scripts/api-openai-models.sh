#!/usr/bin/env bash
# Embedding + image models (OpenAI format, path /openai) for Data Science and Engineering. Idempotent (POST or PUT).
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh; GW=$(cat .state/gw_id)
mk() { # name capability target-model values-json cost-json
  jq -n --arg n "$1" --arg c "$2" --arg tm "$3" --argjson cfg "$4" '{type:"model",name:$n,display_name:$n,enabled:true,formats:[{type:"openai"}],capabilities:[$c],
    access:{auth_strategies:["micron-oidc"],acls:{allow:["Demo-DataScience","Demo-Engineering"]}},
    config:{route:{paths:["/openai"],protocols:["http","https"],model:{body_param:"model",values:[$n]}},model:{name_header:true},max_request_body_size:8388608},
    targets:[{name:$tm,provider:"openai-direct",weight:100,config:({type:"openai"}+$cfg)}]}' > .state/m4.json
  id=$(kongctl api get "/v1/ai-gateways/$GW/models" | jq -r --arg n "$1" '.data[]|select(.name==$n)|.id')
  if [ -n "$id" ]; then kongctl api put "/v1/ai-gateways/$GW/models/$id" -f .state/m4.json | jq -c '{updated:.name}'; else kongctl api post "/v1/ai-gateways/$GW/models" -f .state/m4.json | jq -c '{created:.name}'; fi
}
mk text-embedding-3-small embeddings text-embedding-3-small '{"input_cost":0.02}'
mk gpt-image-1-mini image gpt-image-1-mini '{}'
