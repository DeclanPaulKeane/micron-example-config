#!/usr/bin/env bash
# MCP through the gateway. Usage: demo/mcp-call.sh <user> <server: ticketing|code-search|hr-records> <list|call> [tool] ['{"json":"args"}']
# Env: TOKEN=<bearer> overrides the user token (used by the agents); GWURL (default https://micron...)
cd "$(dirname "$0")/.."; . scripts/test-lib.sh
GWURL=${GWURL:-https://micron.kong-sales-engineering.com}; U=$1; S=$2; OP=$3; TOOL=${4:-}; ARGS=${5:-{\}}
TK=${TOKEN:-$(tok $U)}; URL=$GWURL/mcp/$S
H=(-H "authorization: Bearer $TK" -H 'content-type: application/json' -H 'accept: application/json, text/event-stream')
init=$(curl -s -m 30 -D .state/mcp.h -o .state/mcp.o -w "%{http_code}" "${H[@]}" $URL -d '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-03-26","capabilities":{},"clientInfo":{"name":"demo","version":"1"}}}')
if [ "$init" != 200 ]; then echo "initialize -> HTTP $init: $(head -c 300 .state/mcp.o)"; exit 1; fi
SID=$(grep -i '^mcp-session-id' .state/mcp.h | awk '{print $2}' | tr -d '\r'); SH=(); [ -n "$SID" ] && SH=(-H "mcp-session-id: $SID")
curl -s -m 20 -o /dev/null "${H[@]}" "${SH[@]}" $URL -d '{"jsonrpc":"2.0","method":"notifications/initialized"}'
if [ "$OP" = list ]; then body='{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; else body=$(jq -nc --arg t "$TOOL" --argjson a "$ARGS" '{jsonrpc:"2.0",id:3,method:"tools/call",params:{name:$t,arguments:$a}}'); fi
curl -s -m 30 -w "\n[HTTP %{http_code}]\n" "${H[@]}" "${SH[@]}" $URL -d "$body" | sed 's/^data: //' | grep -v '^event:' | grep -v '^$' | cut -c1-600
