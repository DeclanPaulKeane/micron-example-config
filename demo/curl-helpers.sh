# source me from the repo root: . demo/curl-helpers.sh   (used by DEMO-SCRIPT.md)
export GW=https://micron.kong-sales-engineering.com
tok() { MICRON_USER=$1 MICRON_PASSWORD_GRANT=1 python3 clients/okta_token.py; }
# ask <user> <model> "<prompt>" [route] [extra curl args...]   prints the routing headers, then the answer or the error
ask() {
  local u=$1 m=$2 p=$3 r=${4:-/anthropic}; shift 4 2>/dev/null || shift $#
  curl -s -D /tmp/h -o /tmp/b "$GW$r/v1/messages" -H "authorization: Bearer $(tok $u)" \
    -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' "$@" \
    -d "$(jq -nc --arg m "$m" --arg p "$p" '{model:$m,max_tokens:300,messages:[{role:"user",content:$p}]}')"
  grep -iE '^(HTTP/|x-kong-llm-model|x-cache-status|x-kong-proxy-latency)' /tmp/h | tr -d '\r'
  jq -r 'if .error then "ERROR: "+.error.message else "id: \(.id)\n\([.content[]|select(.type=="text")|.text]|join(" "))" end' /tmp/b | cut -c1-500; echo
}
CC=(-H 'user-agent: claude-cli/demo')   # identifies as Claude Code: skips the semantic cache, so every call really reaches a provider
