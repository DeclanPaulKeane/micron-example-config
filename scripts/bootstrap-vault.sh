#!/usr/bin/env bash
# Create the Konnect config store + vault "micron-vault" and seed it from secrets.yaml / .state/okta.json. Idempotent.
# Every config references secrets as {vault://micron-vault/<key>}; values are never written to YAML.
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh
V=micron-vault
GW=$(kongctl get ai-gateways -o json | jq -r '.[]|select(.name=="micron-aigw")|.id')
vault_json=$(kongctl api get "/v1/ai-gateways/$GW/vaults")
STORE=$(echo "$vault_json" | jq -r --arg n $V '.data[]|select(.name==$n)|.config.config_store_id')
if [ -z "$STORE" ]; then
  STORE=$(kongctl api get "/v1/ai-gateways/$GW/config-stores" | jq -r --arg n $V '.data[]|select(.name==$n)|.id')
  [ -z "$STORE" ] && STORE=$(kongctl api post "/v1/ai-gateways/$GW/config-stores" name=$V | jq -r .id)
  kongctl api post "/v1/ai-gateways/$GW/vaults" name=$V type=konnect "config:={\"config_store_id\":\"$STORE\"}" >/dev/null
  echo "vault created"
fi
existing=$(kongctl api get "/v1/ai-gateways/$GW/config-stores/$STORE/secrets" | jq -r '.data[].key')
seed() { # key value
  [ -z "$2" ] && { echo "skip $1 (empty)"; return; }
  if echo "$existing" | grep -qx "$1"; then kongctl api put "/v1/ai-gateways/$GW/config-stores/$STORE/secrets/$1" value="$2" >/dev/null; echo "updated $1"
  else kongctl api post "/v1/ai-gateways/$GW/config-stores/$STORE/secrets" key="$1" value="$2" >/dev/null; echo "created $1"; fi
}
ISS=$(jq -r .issuer .state/okta.json); CID=$(jq -r .client_id .state/okta.json)
seed anthropic-api-key "$ANTHROPIC_API_KEY"
seed anthropic-api-key-header "x-api-key:$ANTHROPIC_API_KEY"
seed okta-issuer "$ISS/.well-known/openid-configuration"
seed okta-client-id "$CID"
seed okta-client-secret "not-used-public-client"
seed oidc-cache-tokens-salt "$OIDC_CACHE_TOKENS_SALT"
seed aws-access-key-id "$AWS_ACCESS_KEY_ID"
seed aws-secret-access-key "$AWS_SECRET_ACCESS_KEY"
seed aws-assume-role-arn "$AWS_ASSUME_ROLE_ARM"
seed openai-api-key "$OPENAI_KEY"
seed openai-bearer "Bearer $OPENAI_KEY"
seed azure-api-key "$AZURE_KEY"
seed azure-api-key-header "api-key:$AZURE_KEY"
seed crowdstrike-api-key "$CROWDSTRIKE_API_KEY"
seed redis-password "$REDIS_PASSWORD"
