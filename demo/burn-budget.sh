#!/usr/bin/env bash
# Burn User C's $2/day quickly with big-input Sonnet calls (~$0.5 each). Usage: demo/burn-budget.sh [user=userc] [model=claude-sonnet-5-5] [max-calls=12]
cd "$(dirname "$0")/.."; . scripts/test-lib.sh
GWURL=${GWURL:-https://micron.kong-sales-engineering.com}
U=${1:-userc}; PRE=/anthropic; [ "$U" = userc ] && PRE=/sandbox/anthropic; M=${2:-claude-sonnet-5-5}; N=${3:-12}
python3 - "$M" <<'PY'
import json,sys,random
random.seed(1); words=[''.join(random.choice('abcdefghijklmnop') for _ in range(5)) for _ in range(4000)]
text=' '.join(random.choice(words) for _ in range(30000))   # ~100k tokens
json.dump({"model":sys.argv[1],"max_tokens":1,"messages":[{"role":"user","content":text+"\n\nReply with: ok"}]},open('.state/burn.json','w'))
PY
for i in $(seq 1 $N); do
  TK=$(tok $U)
  R=$(curl -s -m 120 -D .state/burn.h -o .state/burn.out -w "%{http_code}" $GWURL$PRE/v1/messages -H "authorization: Bearer $TK" -H "anthropic-version: 2023-06-01" -H 'content-type: application/json' --data-binary @.state/burn.json)
  REM=$(grep -i 'X-AI-RateLimit-Remaining-day' .state/burn.h | tr -d '\r' | awk '{print $2}')
  echo "call $i -> HTTP $R   day-budget remaining: ${REM:-n/a}"
  [ "$R" != 200 ] && { head -c 400 .state/burn.out; echo; break; }
done
