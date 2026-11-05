#!/usr/bin/env bash
# Idempotent: Entra groups, users A-D, gateway app registration (public client, PKCE), groups claim.
# Everything is tagged "micron-demo"; identity/99-entra-cleanup.sh removes it.
set -uo pipefail
cd "$(dirname "$0")/.."; set -a; . ./secrets.yaml; set +a
G=https://graph.microsoft.com/v1.0
DOMAIN=kong-sales-engineering.com
: "${DEMO_USER_PASSWORD:=}"
if [ -z "$DEMO_USER_PASSWORD" ]; then
  DEMO_USER_PASSWORD="Mc!$(openssl rand -hex 8)aA1"; printf 'export DEMO_USER_PASSWORD=%s\n' "$DEMO_USER_PASSWORD" >> secrets.yaml
fi
post() { az rest --method post --url "$G/$1" --body "$2" -o json; }

ensure_group() {  # name nick -> id
  local id; id=$(az ad group list --filter "displayName eq '$1'" --query '[0].id' -o tsv)
  [ -z "$id" ] && id=$(az ad group create --display-name "$1" --mail-nickname "$2" --description "micron-demo" --query id -o tsv)
  echo "$id"
}
gid_eng=$(ensure_group Demo-Engineering micron-demo-engineering)  || { echo "FAIL group"; exit 1; }
gid_fin=$(ensure_group Demo-Finance micron-demo-finance)          || { echo "FAIL group"; exit 1; }
gid_ds=$(ensure_group Demo-DataScience micron-demo-datascience)   || { echo "FAIL group"; exit 1; }
echo "groups: eng=$gid_eng fin=$gid_fin ds=$gid_ds"

for u in "usera:User A:$gid_eng" "userb:User B:$gid_fin" "userc:User C:$gid_ds" "userd:User D:$gid_eng"; do
  nick=${u%%:*}; rest=${u#*:}; name=${rest%%:*}; gid=${rest#*:}; upn="micron-$nick@$DOMAIN"
  id=$(az ad user list --filter "userPrincipalName eq '$upn'" --query '[0].id' -o tsv)
  if [ -z "$id" ]; then
    id=$(az ad user create --display-name "Micron Demo $name" --user-principal-name "$upn" --mail-nickname "micron-$nick" \
         --password "$DEMO_USER_PASSWORD" --force-change-password-next-sign-in false --query id -o tsv) || { echo "FAIL user $upn"; exit 1; }
  fi
  az ad group member add --group "$gid" --member-id "$id" 2>/dev/null || true
  echo "user $upn $id"
done
