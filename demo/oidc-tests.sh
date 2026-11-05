#!/usr/bin/env bash
# OIDC enforcement matrix: every protected surface x every kind of bad credential. Anything but 401/403 on a bad credential is a FAIL.
cd "$(dirname "$0")/.."; . scripts/env.sh; . scripts/test-lib.sh
G=https://micron.kong-sales-engineering.com; PASS=0; FAIL=0; ROWS=""
b64() { python3 -c "import sys,base64,json;print(base64.urlsafe_b64encode(sys.stdin.buffer.read()).rstrip(b'=').decode())"; }
GOOD=$(tok usera); H=${GOOD%%.*}; P=$(echo "$GOOD" | cut -d. -f2); SIG=${GOOD##*.}
TAMPER="$H.$P.${SIG:0:${#SIG}-6}AAAAAA"                                   # valid header/payload, broken signature
FORGED_P=$(printf '{"iss":"x","aud":"https://micron.kong-sales-engineering.com","exp":4102444800,"sub":"evil","email":"micron-usera@kong-sales-engineering.com","groups":["Demo-Engineering"],"department":"Product Development","team":"Engineering"}' | b64)
UNSIGNED="$(printf '{"alg":"none","typ":"JWT"}' | b64).$FORGED_P."          # alg=none with forged Engineering claims
# re-use a real token's header with forged payload: signature cannot match
FORGED_SIG="$H.$FORGED_P.$SIG"
EXPIRED=$(cat .state/expiring-token.txt)
WORKSHOP="$H.$(printf '{"iss":"https://integrator-1741022.okta.com/oauth2/default","aud":"api://default","exp":4102444800,"sub":"x"}' | b64).$SIG"   # token from the workshop authorization server
declare -a NAMES=("no token" "garbage" "tampered signature" "alg=none forged Engineering" "forged payload, real header+sig" "expired token" "workshop issuer")
declare -a TOKS=("" "not-a-jwt" "$TAMPER" "$UNSIGNED" "$FORGED_SIG" "$EXPIRED" "$WORKSHOP")
req() { # surface-name method url [body]   token in $T
  local m=$2 u=$3 body=$4 hdr=(); [ -n "$T" ] && hdr=(-H "authorization: Bearer $T")
  if [ -n "$body" ]; then curl -s -m 25 -o /tmp/o.out -w "%{http_code}" -X $m "$u" "${hdr[@]}" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -H 'accept: application/json, text/event-stream' -d "$body"
  else curl -s -m 25 -o /tmp/o.out -w "%{http_code}" -X $m "$u" "${hdr[@]}" -H 'anthropic-version: 2023-06-01'; fi; }
SURF=("POST inference /anthropic/v1/messages" "GET model-list /anthropic/v1/models" "POST count_tokens /anthropic/v1/messages/count_tokens" "POST embeddings /openai/embeddings" "POST mcp-ticketing /mcp/ticketing" "POST a2a-agent /agents/ticket-triage-agent/")
bodyfor() { case $1 in inference) echo '{"model":"claude-haiku-5-5","max_tokens":4,"messages":[{"role":"user","content":"hi"}]}';; count_tokens) echo '{"model":"claude-haiku-5-5","messages":[{"role":"user","content":"hi"}]}';; embeddings) echo '{"model":"text-embedding-3-small","input":"x"}';; mcp-ticketing) echo '{"jsonrpc":"2.0","id":1,"method":"tools/list"}';; a2a-agent) echo '{"jsonrpc":"2.0","id":"1","method":"message/send","params":{"message":{"kind":"message","role":"user","messageId":"m","parts":[{"kind":"text","text":"x"}]}}}';; esac; }
printf "%-16s" "surface"; for n in "${NAMES[@]}"; do printf "%-9s" "$(echo $n | cut -c1-8)"; done; printf "valid\n"
for s in "${SURF[@]}"; do set -- $s; m=$1; name=$2; path=$3; line=$(printf "%-16s" $name); bad=0
  for i in "${!TOKS[@]}"; do T="${TOKS[$i]}"; c=$(req "$name" $m "$G$path" "$(bodyfor $name)"); line+=$(printf "%-9s" $c); case $c in 401|403) ;; *) bad=1; ROWS+="| $name | ${NAMES[$i]} | **FAIL** | HTTP $c $(head -c 100 /tmp/o.out | tr '|\n' '/ ') |"$'\n';; esac; done
  T=$(tok usera); v=$(req "$name" $m "$G$path" "$(bodyfor $name)"); line+=$(printf "%-9s" $v)
  echo "$line"
  if [ $bad = 0 ]; then ROWS+="| $name | all 7 bad credentials refused (401/403) | **PASS** | valid token -> HTTP $v |"$'\n'; PASS=$((PASS+1)); else FAIL=$((FAIL+1)); fi
done
echo; echo "surfaces fully protected: $PASS, with a hole: $FAIL"
{ echo "## OIDC enforcement matrix (\`demo/oidc-tests.sh\`)"; echo; echo "Bad credentials tried on every protected surface: none, garbage, tampered signature, alg=none with forged Engineering claims, forged payload with a real header+signature, expired token. A valid User A token is the control."; echo; echo "| Surface | Case | Result | Evidence |"; echo "|---|---|---|---|"; printf "%s" "$ROWS"; } > .state/oidc-report.md
