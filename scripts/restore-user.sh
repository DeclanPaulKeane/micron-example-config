#!/usr/bin/env bash
# Undo scripts/revoke-user.sh. Usage: scripts/restore-user.sh userd Demo-Engineering
set -euo pipefail
cd "$(dirname "$0")/.."
U=$1; G=$2; EMAIL="micron-$U@kong-sales-engineering.com"
identity/okta-membership.sh add "$U" "$G"
python3 - "$EMAIL" <<'PY'
import sys; email=sys.argv[1]; p="konnect/lua/edge-guard.lua"; s=open(p).read()
open(p,"w").write(s.replace(f'  ["{email}"] = true,\n',""))
PY
scripts/apply.sh konnect/10-gateway.yaml 2>&1 | grep -E '✓|✗' || true
echo "restored $EMAIL"
