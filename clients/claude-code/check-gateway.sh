#!/usr/bin/env bash
# Prove a demo user's Claude Code traffic goes through the Kong gateway.  Usage: clients/claude-code/check-gateway.sh usera
cd "$(dirname "$0")/../.."; U=${1:-usera}; export MICRON_USER=$U
PRE=${MICRON_ROUTE:-/anthropic}; [ -z "${MICRON_ROUTE:-}" ] && [ "$U" = userc ] && PRE=/sandbox/anthropic
GW=https://micron.kong-sales-engineering.com$PRE
T=$(python3 clients/okta_token.py) || { echo "Not signed in: MICRON_USER=$U python3 clients/okta_token.py login"; exit 1; }
BODY='{"model":"claude-haiku-5-5","max_tokens":16,"messages":[{"role":"user","content":"Say hi"}]}'
echo "== $U via $GW"; python3 clients/okta_token.py status
echo "== gateway response headers (look for Via kong, X-Kong-Request-Id)"
curl -sS -D - -o /dev/null -X POST "$GW/v1/messages" -H "Authorization: Bearer $T" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d "$BODY" | grep -i -E "^HTTP|^via|x-kong-request-id|x-kong-proxy-latency|x-kong-upstream"
echo "== same token straight at Anthropic (must be refused: proves the gateway is the only way in)"
curl -sS -o /dev/null -w "HTTP %{http_code}\n" -X POST https://api.anthropic.com/v1/messages -H "Authorization: Bearer $T" -H "anthropic-version: 2023-06-01" -H "content-type: application/json" -d "$BODY"
