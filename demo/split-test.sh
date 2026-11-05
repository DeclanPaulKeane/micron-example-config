#!/usr/bin/env bash
# Sends N new sessions (distinct x-claude-code-session-id) and counts provider; then repeats one session 6x to show stickiness.
cd "$(dirname "$0")/.."; . scripts/test-lib.sh; N=${1:-40}; TK=$(tok ${2:-usera}); GWURL=${GWURL:-http://localhost:18000}
call() { curl -s -m 60 $GWURL/anthropic/v1/messages -H "authorization: Bearer $TK" -H "user-agent: claude-cli/demo" -H "x-claude-code-session-id: $1" -H "anthropic-version: 2023-06-01" -H 'content-type: application/json' -d '{"model":"claude-sonnet-split","max_tokens":4,"messages":[{"role":"user","content":"hi"}]}' | jq -r 'if (.id|startswith("msg_bdrk")) then "Bedrock" else "Anthropic" end'; }
echo "$N new sessions:"; for i in $(seq 1 $N); do call "sess-$i-$RANDOM-$$"; done | sort | uniq -c
S="sess-sticky-$RANDOM"; echo "one session x6 (should be a single provider):"; for i in 1 2 3 4 5 6; do call $S; done | sort | uniq -c
