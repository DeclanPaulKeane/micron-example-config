#!/usr/bin/env bash
# Add/remove an Okta demo user to/from a demo group. Usage: identity/okta-membership.sh add|remove usera Demo-Engineering
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; . ./secrets.yaml; set +a
OP=$1; U=$2; G=$3
UID_=$(jq -r --arg l "micron-$U@kong-sales-engineering.com" '.users[$l]' .state/okta.json); GID=$(jq -r --arg g "$G" '.groups[$g]' .state/okta.json)
M=PUT; [ "$OP" = remove ] && M=DELETE
curl -s -o /dev/null -w "okta $OP $U $G -> %{http_code}\n" -X $M -H "Authorization: SSWS $OKTA_API_TOKEN" "$OKTA_DOMAIN/api/v1/groups/$GID/users/$UID_"
