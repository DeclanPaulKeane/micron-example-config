#!/usr/bin/env bash
# Sends a PDF (or all PDFs in data/pdfs) to the gateway as a Claude Desktop-style attachment (base64 document block).
# Usage: demo/large-file-test.sh <user> <file.pdf|all> [model]      e.g.  demo/large-file-test.sh userb data/large/report-22MB.pdf
cd "$(dirname "$0")/.."; . scripts/test-lib.sh
U=${1:-userb}; F=${2:-all}; M=${3:-claude-sonnet-5-5}; PRE=/anthropic; [ "$U" = userc ] && PRE=/sandbox/anthropic
python3 - "$F" "$M" <<'PY'
import base64,glob,json,sys
f=sys.argv[1]; files=sorted(glob.glob('data/pdfs/*.pdf')) if f=='all' else [f]
c=[{"type":"document","source":{"type":"base64","media_type":"application/pdf","data":base64.b64encode(open(x,'rb').read()).decode()}} for x in files]
c.append({"type":"text","text":"Summarize "+("each document in one sentence." if len(files)>1 else "this document in two sentences.")})
json.dump({"model":sys.argv[2],"max_tokens":300,"messages":[{"role":"user","content":c}]},open('.state/large.json','w'))
PY
SZ=$(ls -l .state/large.json | awk '{printf "%.1f", $5/1e6}')
S=$(date +%s); CODE=$(curl -s -m 280 -o .state/large.out -w "%{http_code}" https://micron.kong-sales-engineering.com$PRE/v1/messages -H "authorization: Bearer $(tok $U)" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' --data-binary @.state/large.json)
printf "%-28s request %6s MB (base64)  HTTP %s  %3ss  " "$(basename $F)" "$SZ" "$CODE" "$(( $(date +%s)-S ))"
jq -r 'if .content then ([.content[]?|select(.type=="text")|.text]|join(" ")|.[0:110]) else (.error.message // .message // "see body")|.[0:200] end' .state/large.out 2>/dev/null || head -c 200 .state/large.out; echo
rm -f .state/large.json
