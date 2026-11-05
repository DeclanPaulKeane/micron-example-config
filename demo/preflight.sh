#!/usr/bin/env bash
# PRE-DEMO CHECKLIST (automated part). Prints PASS/FAIL per item. Usage: demo/preflight.sh
cd "$(dirname "$0")/.."; . scripts/env.sh; . scripts/test-lib.sh
GWURL=https://micron.kong-sales-engineering.com
ok() { printf "  PASS  %s\n" "$1"; }; bad() { printf "  FAIL  %s\n" "$1"; FAILS=$((FAILS+1)); }; FAILS=0
echo "Certificates / reachability"
exp=$(echo | openssl s_client -connect micron.kong-sales-engineering.com:443 -servername micron.kong-sales-engineering.com 2>/dev/null | openssl x509 -noout -enddate 2>/dev/null | cut -d= -f2)
[ -n "$exp" ] && ok "TLS certificate valid until $exp" || bad "TLS certificate not served"
for h in micron micron-grafana; do c=$(curl -s -o /dev/null -w "%{http_code}" -m 10 https://$h.kong-sales-engineering.com/); [ "$c" != 000 ] && ok "$h.kong-sales-engineering.com reachable (HTTP $c)" || bad "$h unreachable"; done
echo "Tokens / SSO"
for u in usera userb userc userd; do tok $u >/dev/null 2>&1 && ok "Okta sign-in works for $u" || bad "Okta sign-in failed for $u"; done
echo "Gateway"
c=$(curl -s -o /dev/null -w "%{http_code}" -m 20 $GWURL/anthropic/v1/messages -H "authorization: Bearer $(tok usera)" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d '{"model":"claude-haiku-5-5","max_tokens":4,"messages":[{"role":"user","content":"preflight"}]}'); [ "$c" = 200 ] && ok "Anthropic path (Haiku, via gateway)" || bad "Anthropic path HTTP $c"
c=$(curl -s -o /dev/null -w "%{http_code}" -m 30 $GWURL/sandbox/anthropic/v1/messages -H "authorization: Bearer $(tok userc)" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d '{"model":"claude-haiku-5-5","max_tokens":4,"messages":[{"role":"user","content":"preflight"}]}'); [ "$c" = 200 ] && ok "Sandbox route (User C)" || bad "Sandbox route HTTP $c"
echo "Providers"
for m in claude-sonnet-bedrock; do c=$(curl -s -o /dev/null -w "%{http_code}" -m 40 $GWURL/diag/anthropic/v1/messages -H "authorization: Bearer $(tok usera)" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -H 'user-agent: claude-cli/preflight' -d "{\"model\":\"$m\",\"max_tokens\":4,\"messages\":[{\"role\":\"user\",\"content\":\"preflight\"}]}"); [ "$c" = 200 ] && ok "Bedrock reachable" || bad "Bedrock HTTP $c"; done
echo "Security / mocks"
st=$(kubectl -n micron-aigw exec deploy/aidr-proxy -- python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8080/admin/state').read().decode())" 2>/dev/null); echo "$st" | grep -q '"ok"' && ok "CrowdStrike broker mode ok" || bad "CrowdStrike broker: $st"
cs=$(kubectl -n micron-aigw exec deploy/chaos-proxy -- python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8080/admin/state').read().decode())" 2>/dev/null); echo "$cs" | grep -q '"mode": "ok"' && ok "Provider fault injector off" || bad "Fault injector: $cs"
bad_dep=$(kubectl -n micron-aigw get deploy --no-headers | awk '{split($2,a,"/"); if (a[1]!=a[2]) print $1}' | tr '\n' ' '); [ -z "$bad_dep" ] && ok "All deployments have their replicas ready" || bad "deployments not ready: $bad_dep"; ev=$(kubectl -n micron-aigw get pods --no-headers | grep -cE "Evicted|ContainerStatusUnknown|Error"); [ "$ev" = 0 ] || echo "  note  $ev stale evicted pod(s) (harmless; the shared cluster is under memory pressure): kubectl -n micron-aigw delete pod <name>"
echo "Semantic cache (probe: same question twice)"
probe_cache() { Qp="Preflight probe $RANDOM$RANDOM: give me the capital of a random country #$RANDOM, one word"; r=""; for u in usera userd; do curl -s -D .state/pc.h -o /dev/null $GWURL/anthropic/v1/messages -H "authorization: Bearer $(tok $u)" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d "$(jq -n --arg t "$Qp" '{model:"claude-haiku-5-5",max_tokens:60,messages:[{role:"user",content:$t}]}')"; r="$r$(grep -i '^x-cache-status' .state/pc.h | tr -d '\r' | awk '{print $2}')"; done; }
probe_cache; if [ "$r" = "MissHit" ] || [ "$r" = "HitHit" ]; then ok "Semantic cache active ($r)"; else echo "  ..    cache not active ($r): refreshing cache policies"; scripts/kick-cache.sh >/dev/null; sleep 30; probe_cache; [ "$r" = "MissHit" ] || [ "$r" = "HitHit" ] && ok "Semantic cache active after refresh" || bad "Semantic cache inactive ($r)"; fi
echo "Budgets"
rem=$(curl -s -D - -o /dev/null $GWURL/sandbox/anthropic/v1/messages -H "authorization: Bearer $(tok userc)" -H 'anthropic-version: 2023-06-01' -H 'content-type: application/json' -d '{"model":"claude-haiku-5-5","max_tokens":4,"messages":[{"role":"user","content":"x"}]}' | grep -i 'Remaining-day' | awk '{print $2}' | tr -d '\r'); awk -v r="${rem:-0}" 'BEGIN{exit !(r>1.9)}' && ok "User C daily budget fresh (\$$rem of \$2 left)" || bad "User C budget not reset (remaining ${rem:-?})"
echo "Manual items: (1) start the long Claude Code session as User A: clients/claude-code/run.sh usera   (2) open Grafana + Konnect AI Cost Management tabs  (3) Claude Desktop signed in as User B"
[ $FAILS = 0 ] && echo "ALL PREFLIGHT CHECKS PASSED" || echo "$FAILS CHECK(S) FAILED"
