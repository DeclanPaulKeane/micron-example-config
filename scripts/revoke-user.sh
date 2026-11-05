#!/usr/bin/env bash
# URGENT access removal for a demo user. Usage: scripts/revoke-user.sh userd Demo-Engineering   (undo: scripts/restore-user.sh userd Demo-Engineering)
#  1. Okta: remove from group (normal path; takes effect at the user's next token refresh, <= 5 min)
#  2. Okta: end sessions + revoke OAuth tokens for the user (refresh tokens die immediately)
#  3. Gateway: add the user to the edge-guard deny list so an unexpired access token stops working in seconds
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; . ./secrets.yaml; set +a
U=$1; G=$2; EMAIL="micron-$U@kong-sales-engineering.com"
identity/okta-membership.sh remove "$U" "$G"
UID_=$(jq -r --arg l "$EMAIL" '.users[$l]' .state/okta.json)
curl -s -o /dev/null -w "okta revoke sessions+tokens -> %{http_code}\n" -X DELETE -H "Authorization: SSWS $OKTA_API_TOKEN" "$OKTA_DOMAIN/api/v1/users/$UID_/sessions?oauthTokens=true"
python3 - "$EMAIL" add <<'PY'
import sys,re
email,op=sys.argv[1:3]; p="konnect/lua/edge-guard.lua"; s=open(p).read()
s=s.replace(f'  ["{email}"] = true,\n',"")
if op=="add": s=s.replace("  -- DENYLIST-BEGIN\n",f'  -- DENYLIST-BEGIN\n  ["{email}"] = true,\n')
open(p,"w").write(s)
PY
scripts/apply.sh konnect/10-gateway.yaml 2>&1 | grep -E '✓|✗' || true
echo "revoked $EMAIL (gateway deny list active in ~10 s)"
