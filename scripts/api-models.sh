#!/usr/bin/env bash
# Models that kongctl's schema can't express (nested balancer config) are managed through the API: claude-auto.
# Built from the live claude-opus model so it inherits ACL, auth and policies.  Idempotent (POST or PUT).
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh; GW=$(cat .state/gw_id)
OPUS=$(kongctl api get "/v1/ai-gateways/$GW/models" | jq -r '.data[]|select(.name=="claude-opus")|.id')
kongctl api get "/v1/ai-gateways/$GW/models/$OPUS" > .state/opus.json
jq '
 del(.id,.created_at,.updated_at)
 | .name="claude-auto" | .display_name="Claude (automatic model choice: Haiku for simple, Opus for complex)"
 | .config.route.model.values=["claude-auto"]
 | .config.balancer={algorithm:"semantic",
     embeddings:{provider:"openai-direct",name:"text-embedding-3-small",config:{type:"openai"}},
     vectordb:{type:"redis",dimensions:1536,distance_metric:"cosine",threshold:0.9,host:"redis.micron-aigw.svc.cluster.local",port:6379,password:"{vault://micron-vault/redis-password}",ssl:false}}
 | .targets[0].semantic_description="Complex, open-ended or multi-step work: system design, architecture, migration plans, deep analysis, hard debugging, trade-off reasoning."
 | .targets += [(.targets[0] | .name="claude-haiku-5-5" | .semantic_description="Simple, short and mechanical tasks: fix a typo, rename, reformat, quick lookup, one-line answers, small edits."
     | .config.input_cost=1 | .config.output_cost=5 | .config.cache_read_cost=0.1 | .config.cache_write_cost=1.25)]
' .state/opus.json > .state/auto.json
AID=$(kongctl api get "/v1/ai-gateways/$GW/models" | jq -r '.data[]|select(.name=="claude-auto")|.id')
if [ -n "$AID" ]; then kongctl api put "/v1/ai-gateways/$GW/models/$AID" -f .state/auto.json | jq -c '{updated:.name}'
else kongctl api post "/v1/ai-gateways/$GW/models" -f .state/auto.json | jq -c '{created:.name}'; fi
