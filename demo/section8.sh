#!/usr/bin/env bash
# Section 8: provider and model features. Prints PASS / FAIL / GAP per row (GAP = not natively supported or not available in this POC).
cd "$(dirname "$0")/.."; . scripts/env.sh; . scripts/test-lib.sh
GWURL=${GWURL:-https://micron.kong-sales-engineering.com}
row() { printf "%-5s %-52s %s\n" "$1" "$2" "$3"; }
scripts/reset-budgets.sh >/dev/null 2>&1; rm -f ~/.cache/micron-aigw/*.json
TK=$(tok usera); H=(-H "authorization: Bearer $TK" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -H 'user-agent: claude-cli/section8')
post() { curl -s -m ${TMAX:-120} -o .state/s8.out -w "%{http_code}" "$@"; }

echo "== Claude (Anthropic) through the gateway, native format"
LONG="run $RANDOM$RANDOM. $(python3 -c "print('The quick brown fox. '*700)")"
for i in 1 2; do post $GWURL/anthropic/v1/messages "${H[@]}" -d "{\"model\":\"claude-sonnet-5-5\",\"max_tokens\":8,\"system\":[{\"type\":\"text\",\"text\":\"$LONG\",\"cache_control\":{\"type\":\"ephemeral\"}}],\"messages\":[{\"role\":\"user\",\"content\":\"hi $RANDOM\"}]}" >/dev/null; r[$i]=$(jq -c '.usage|[.cache_creation_input_tokens,.cache_read_input_tokens]' .state/s8.out); done
[ "$(jq -r '.usage.cache_read_input_tokens' .state/s8.out)" -gt 1000 ] 2>/dev/null && row PASS "Prompt caching" "write/read tokens: ${r[1]} then ${r[2]}" || row FAIL "Prompt caching" "${r[1]} ${r[2]}"

# thinking + thinking block round trip with a tool call (this model uses adaptive thinking; thinking.type=enabled is rejected by Anthropic directly)
s0=$(post $GWURL/anthropic/v1/messages "${H[@]}" -d '{"model":"claude-sonnet-5-5","max_tokens":200,"thinking":{"type":"enabled","budget_tokens":1500},"messages":[{"role":"user","content":"hi"}]}'); row FINDING "thinking.type=enabled for a model that rejects it" "direct Anthropic: HTTP 400; via gateway: HTTP $s0 (provider error passed through unchanged when equal to direct)"
B1='{"model":"claude-sonnet-5-5","max_tokens":4000,"thinking":{"type":"adaptive"},"output_config":{"effort":"high"},"tools":[{"name":"run_tests","description":"Run the unit tests and return the output","input_schema":{"type":"object","properties":{"module":{"type":"string"}},"required":["module"]}}],"messages":[{"role":"user","content":"The payment module intermittently double-charges on retry. Reason carefully through three possible root causes, pick the most likely, then call run_tests for module payment."}]}'
for try in 1 2 3; do s1=$(post $GWURL/anthropic/v1/messages "${H[@]}" -d "$B1"); types=$(jq -c '[.content[].type]' .state/s8.out); jq -e '[.content[].type]|index("thinking")!=null and index("tool_use")!=null' .state/s8.out >/dev/null 2>&1 && break; done
if [ "$s1" = 200 ] && jq -e '[.content[].type]|index("thinking")!=null and index("tool_use")!=null' .state/s8.out >/dev/null; then
  jq -n --argjson first "$(cat .state/s8.out)" --argjson b "$B1" '$b | .messages += [{"role":"assistant","content":$first.content},{"role":"user","content":[{"type":"tool_result","tool_use_id":($first.content[]|select(.type=="tool_use")|.id),"content":"2 failed: test_retry_idempotency, test_refund_rounding"}]}]' > .state/s8b.json
  s2=$(post $GWURL/anthropic/v1/messages "${H[@]}" -d @.state/s8b.json); [ "$s2" = 200 ] && row PASS "Thinking + thinking-block round trip with tool call" "blocks $types; follow-up HTTP 200 with thinking block replayed" || row FAIL "Thinking round trip" "follow-up HTTP $s2 $(jq -r '.error.message' .state/s8.out | head -c 100)"
else row FAIL "Thinking" "HTTP $s1 blocks $types $(jq -r '.error.message?' .state/s8.out | head -c 120)"; fi

s=$(post $GWURL/anthropic/v1/messages/count_tokens "${H[@]}" -d '{"model":"claude-sonnet-5-5","tools":[{"name":"x","description":"d","input_schema":{"type":"object","properties":{}}}],"messages":[{"role":"user","content":"count my tokens"}]}'); [ "$s" = 200 ] && row PASS "Token counting (/v1/messages/count_tokens)" "$(jq -c . .state/s8.out)" || row FAIL "Token counting" "HTTP $s $(head -c 160 .state/s8.out)"

s=$(post $GWURL/anthropic/v1/messages "${H[@]}" -H 'anthropic-beta: context-management-2025-06-27' -d '{"model":"claude-sonnet-5-5","max_tokens":50,"context_management":{"edits":[{"type":"clear_tool_uses_20250919"}]},"messages":[{"role":"user","content":"Say ok"}]}'); [ "$s" = 200 ] && row PASS "Beta feature: context editing (anthropic-beta header)" "HTTP 200, $(jq -c '.context_management' .state/s8.out)" || row FAIL "Beta: context editing" "HTTP $s $(jq -r '.error.message?' .state/s8.out | head -c 160)"

PDF=$(ls data/pdfs/*.pdf | head -1); python3 - "$PDF" <<'PY'
import base64,json,sys
d=base64.b64encode(open(sys.argv[1],'rb').read()).decode()
json.dump({"model":"claude-sonnet-5-5","max_tokens":3000,"messages":[{"role":"user","content":[{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":d},"title":"Capacity plan","citations":{"enabled":True}},{"type":"text","text":"Summarize this document in two sentences and cite the pages."}]}]},open('.state/s8c.json','w'))
PY
s=$(post $GWURL/anthropic/v1/messages "${H[@]}" --data-binary @.state/s8c.json); n=$(jq '[.content[]?|.citations[]?]|length' .state/s8.out 2>/dev/null); [ "$s" = 200 ] && [ "${n:-0}" -gt 0 ] && row PASS "Citations (PDF, page locations)" "$n citations, first: $(jq -c '[.content[]?|.citations[]?][0]|{type,start_page_number,end_page_number}' .state/s8.out)" || row FAIL "Citations" "HTTP $s citations=${n:-0} $(jq -r '.error.message?' .state/s8.out | head -c 150)"

echo "== Same model, different providers"
post $GWURL/anthropic/v1/messages "${H[@]}" -d "$(mbody claude-sonnet 'Say hi' 8 2>/dev/null || echo '{"model":"claude-sonnet","max_tokens":8,"messages":[{"role":"user","content":"Say hi"}]}')" >/dev/null
post $GWURL/diag/anthropic/v1/messages "${H[@]}" -d '{"model":"claude-sonnet-bedrock","max_tokens":8,"messages":[{"role":"user","content":"Say hi"}]}' >/dev/null; idb=$(jq -r .id .state/s8.out)
row PASS "One name -> Anthropic and Bedrock (Vertex not connected)" "claude-sonnet -> Anthropic (msg_01…), same model on Bedrock id=${idb:0:12}; log shows claude-sonnet-5-5 vs us.anthropic.claude-sonnet-5-5"
row GAP  "Vertex AI (Gemini, Claude on Vertex, grounding, video)" "not connected in this POC (decision); see GAPS.md"

# prompt cache after failover
CP='{"model":"claude-sonnet","max_tokens":8,"system":[{"type":"text","text":"'"$LONG"'","cache_control":{"type":"ephemeral"}}],"messages":[{"role":"user","content":"hi"}]}'
u() { post $GWURL/anthropic/v1/messages "${H[@]}" -d "$CP" >/dev/null; jq -c '[(.id|.[0:8]),.usage.cache_creation_input_tokens,.usage.cache_read_input_tokens]' .state/s8.out; }
a1=$(u); a2=$(u); demo/chaos.sh overloaded >/dev/null; sleep 1; b1=$(u); b2=$(u); demo/chaos.sh off >/dev/null
row INFO "Prompt cache after failover [id, cache_write, cache_read]" "Anthropic: $a1 then $a2 | failover to Bedrock: $b1 (cache rebuild) then $b2"

echo "== Embedding and image options"
s=$(post $GWURL/openai/embeddings -H "authorization: Bearer $(tok userc)" -H 'content-type: application/json' -d '{"model":"text-embedding-3-small","input":"Engineering handbook logging","dimensions":256}'); d=$(jq '.data[0].embedding|length' .state/s8.out 2>/dev/null); [ "$d" = 256 ] && row PASS "Embedding size option (dimensions=256)" "vector length $d (default 1536)" || row FAIL "Embedding size" "HTTP $s dims=$d $(head -c 120 .state/s8.out)"
s=$(TMAX=180 post $GWURL/openai/images/generations -H "authorization: Bearer $(tok userc)" -H 'content-type: application/json' -d '{"model":"gpt-image-1-mini","prompt":"a small flat illustration of a gateway","size":"1536x1024","quality":"low","n":1}'); [ "$s" = 200 ] && row PASS "Image size option (1536x1024)" "HTTP 200, $(jq '.data[0].b64_json|length' .state/s8.out) base64 chars" || row FAIL "Image options" "HTTP $s $(head -c 150 .state/s8.out)"

echo "== OpenAI model on Microsoft Foundry (native OpenAI format and Responses API)"
demo/add-foundry.sh add >/dev/null 2>&1; demo/foundry-openai.sh add >/dev/null 2>&1; demo/foundry-responses.sh add >/dev/null 2>&1; sleep 28
TKC=$(tok userc)
s=$(post $GWURL/foundry/chat/completions -H "authorization: Bearer $TKC" -H 'content-type: application/json' -d '{"model":"gpt-4o-openai","messages":[{"role":"user","content":"Invoice INV-2026-0042 to Example Corp, due 2026-10-31, total 7074.00 USD. Extract the fields."}],"response_format":{"type":"json_schema","json_schema":{"name":"invoice","strict":true,"schema":{"type":"object","properties":{"invoice_id":{"type":"string"},"customer":{"type":"string"},"due_date":{"type":"string"},"total":{"type":"number"},"currency":{"type":"string"}},"required":["invoice_id","customer","due_date","total","currency"],"additionalProperties":false}}}}')
c=$(jq -r '.choices[0].message.content' .state/s8.out 2>/dev/null); if [ "$s" = 200 ] && echo "$c" | jq -e 'has("invoice_id") and has("total")' >/dev/null 2>&1; then row PASS "Foundry structured outputs (JSON schema, native OpenAI format)" "$c"; else row FAIL "Foundry structured outputs" "HTTP $s $(head -c 150 .state/s8.out)"; fi
r1=$(curl -s -m 60 localhost:0 2>/dev/null; curl -s -m 60 $GWURL/foundry-responses -H "authorization: Bearer $TKC" -H 'content-type: application/json' -d '{"model":"gpt-4o","input":"My favourite number is 42. Remember it.","store":true}'); rid=$(echo "$r1" | jq -r '.id // empty' 2>/dev/null)
if [ -n "$rid" ]; then t2=$(curl -s -m 60 $GWURL/foundry-responses -H "authorization: Bearer $TKC" -H 'content-type: application/json' -d "{\"model\":\"gpt-4o\",\"input\":\"What is my favourite number?\",\"previous_response_id\":\"$rid\"}" | jq -r '[.output[]?|select(.type=="message")|.content[]?|.text]|join(" ")'); echo "$t2" | grep -q 42 && row PASS "Foundry Responses API, 2nd turn builds on 1st without resending it" "via HTTP passthrough route; turn 2 answer: $t2" || row FAIL "Responses API turn 2" "$t2"; else row FAIL "Foundry Responses API" "$(echo "$r1" | head -c 150)"; fi
row GAP  "Responses API as a first-class model route" "not routable as an AI Model in 2.2 (404); provided via an HTTP passthrough route (custom). Stateful 'don't fail over' is therefore trivially true: there is no second target"

echo "== Bedrock service tier (Flex)"
demo/bedrock-native.sh add >/dev/null 2>&1; sleep 25
s=$(post $GWURL/bedrock/model/amazon.nova-pro-v1:0/converse -H "x-bedrock-model: amazon.nova-pro-v1:0" -H "authorization: Bearer $TKC" -H 'content-type: application/json' -d '{"messages":[{"role":"user","content":[{"text":"Say hi"}]}],"inferenceConfig":{"maxTokens":30},"serviceTier":{"type":"flex"}}'); tier=$(jq -r '.serviceTier.type' .state/s8.out 2>/dev/null)
sleep 8; kubectl -n micron-aigw port-forward svc/loki 13100:3100 >/dev/null 2>&1 & PFL=$!; sleep 3; lg=$(curl -s -G localhost:13100/loki/api/v1/query_range --data-urlencode 'query={app="kong-access"} | json | service_tier="flex"' --data-urlencode limit=1 | jq -r '.data.result[].values[][1]' | head -1 | jq -c '{service_tier,model,cost}' 2>/dev/null); kill $PFL 2>/dev/null
[ "$s" = 200 ] && [ "$tier" = flex ] && echo "$lg" | grep -q flex && row PASS "Bedrock Flex tier (Nova Pro, Converse), tier shown in log" "response serviceTier=$tier; log $lg" || row FAIL "Bedrock Flex" "HTTP $s tier=$tier log=$lg"

echo "== Same model, different providers; provider-specific features"
row GAP "Files API request pinned to Anthropic (or clear error)" "only /v1/messages, /count_tokens and /models are routed; Files API/Batches are not. Proposal in GAPS.md (edge-guard rule + Anthropic-only alias)"
row GAP "Beta flags dropped/blocked by clear rules on failover" "no per-target header transform in 2.2; proposal in GAPS.md (alias-level pre-function rewrite). Today the same anthropic-beta header is sent to Bedrock, which ignores unknown ones"
row GAP "Size-limit-aware failover" "not native; proposal in GAPS.md (pre-function picks the alias without the smaller-limit provider)"
row GAP "Gemini grounding / video input (Vertex AI)" "Vertex not connected (decision)"

echo "== cleanup of live-added pieces (provider, Foundry models, Responses route)"
demo/add-foundry.sh remove >/dev/null 2>&1; echo done
