#!/usr/bin/env bash
# Call an A2A agent through the gateway as a user. Usage: demo/a2a-call.sh <user> <triage|release|card-triage|card-release> ["text"]
cd "$(dirname "$0")/.."; . scripts/test-lib.sh
GWURL=${GWURL:-https://micron.kong-sales-engineering.com}; U=$1; A=$2; TXT=${3:-Please do your job for me}
case $A in triage) P=ticket-triage-agent;; release) P=release-notes-agent;; card-triage) P=ticket-triage-agent;; card-release) P=release-notes-agent;; esac
TK=${TOKEN:-$(tok $U)}
if [[ $A == card-* ]]; then curl -s -m 20 $GWURL/agents/$P/.well-known/agent-card.json -H "authorization: Bearer $TK" | jq '.' 2>/dev/null | head -${LINES_MAX:-40}; exit; fi
curl -s -m 150 $GWURL/agents/$P/ -H "authorization: Bearer $TK" -H 'content-type: application/json' \
  -d "$(jq -nc --arg t "$TXT" '{jsonrpc:"2.0",id:"1",method:"message/send",params:{message:{kind:"message",role:"user",messageId:"m1",parts:[{kind:"text",text:$t}]}}}')" | jq -r 'if type=="object" then (.result.artifacts[0].parts[0].text // (.error.message)) else . end'
