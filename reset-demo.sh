#!/usr/bin/env bash
# Return the environment to its PRE-DEMO state: budgets, group membership, cache, routing weights, mock/fault state, live-added providers.
# Usage: ./reset-demo.sh [--quick]   (--quick skips the data-plane restart; budgets may then take a minute to clear)
set -uo pipefail
cd "$(dirname "$0")"; . scripts/env.sh
step() { printf '\n== %s\n' "$*"; }
step "Okta: restore demo group membership (A,D Engineering; B Finance; C Data Science) + clear revoked sessions"
for u in "usera Demo-Engineering" "userd Demo-Engineering" "userb Demo-Finance" "userc Demo-DataScience"; do identity/okta-membership.sh add $u; done
rm -f ~/.cache/micron-aigw/*.json
step "Gateway config -> declared state (removes deny-list entries, exceptions, edits to weights/limits, model lists)"
python3 - <<'PY'
import re
p="konnect/lua/edge-guard.lua"; s=open(p).read()
s=re.sub(r"(-- DENYLIST-BEGIN\n).*?(  -- DENYLIST-END)", r"\1\2", s, flags=re.S)
s=re.sub(r"(-- MCPBLOCK-BEGIN\n).*?(    -- MCPBLOCK-END)", r"\1\2", s, flags=re.S)
open(p,"w").write(s)
PY
scripts/apply.sh 2>&1 | grep -E '✓|✗|rror' | cut -c1-160
step "Live-added Foundry provider/model removed"; demo/add-foundry.sh remove 2>&1 | tail -3
step "Auto-choice model (API-managed) and 70/30 split"; scripts/api-models.sh | tail -1; demo/set-split.sh 70 | tail -1
step "Faults off (provider chaos, CrowdStrike toggle, MCP tool descriptions)"
demo/chaos.sh off | tail -1; demo/toggle-crowdstrike.sh up | tail -1; demo/poison-tool.sh reset | tail -1
step "Budgets (Redis counters) + exceptions + notifications + cache"
scripts/reset-budgets.sh
set -a; . ./secrets.yaml; set +a
R() { kubectl -n micron-aigw exec deploy/redis -- redis-cli -a "$REDIS_PASSWORD" --no-auth-warning "$@"; }
R del micron:exceptions micron:mcp:blocked >/dev/null
for k in $(R --scan --pattern 'semantic_cache:*'); do R del "$k" >/dev/null; done
step "Cached answers flushed; MCP baseline kept"
kubectl -n micron-aigw rollout restart deploy/budget-watcher >/dev/null; kubectl -n micron-aigw rollout status deploy/budget-watcher --timeout=120s >/dev/null
R set micron:epoch "$(date -u +%Y-%m-%dT%H:%M:%SZ)" >/dev/null; R del micron:notified micron:feed >/dev/null   # after the restart so the old pod cannot re-add entries
if [ "${1:-}" != "--quick" ]; then
  step "Data plane restart (clears per-pod budget state)"; kubectl -n micron-aigw rollout restart deploy/aigw-dp >/dev/null; kubectl -n micron-aigw rollout status deploy/aigw-dp --timeout=300s | tail -1
fi
scripts/pf.sh
step "Refresh semantic-cache instances (they can sit inactive after heavy traffic/restarts)"; scripts/kick-cache.sh; sleep 25; scripts/flush-cache.sh
step "DONE. Run demo/preflight.sh next."
