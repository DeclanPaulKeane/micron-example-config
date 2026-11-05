#!/usr/bin/env bash
# Prints the exact Claude Desktop (gateway / third-party inference) and Claude Code settings for the Micron demo.
cd "$(dirname "$0")/.."; ISS=$(jq -r .issuer .state/okta.json); CID=$(jq -r .client_id .state/okta.json)
cat <<TXT
CLAUDE DESKTOP: Settings -> Developer/Gateway (third-party inference)
  Gateway base URL ......... https://micron.kong-sales-engineering.com/anthropic        (User C: .../sandbox/anthropic)
  Credential kind .......... Identity provider sign-in (OIDC)
  Sign-in flow ............. browser
  Issuer URL (BASE url) .... $ISS
  Client ID ................ $CID
  Bearer token ............. Access token
  Scopes ................... openid email        (Append offline_access: ON)
  Redirect host / port ..... localhost / 8765
  Sign in as ............... micron-usera|userb|userc|userd@kong-sales-engineering.com  (password: DEMO_USER_PASSWORD in secrets.yaml)
                             NOT your konghq.com account: it is not in a Demo-* group. Use a private window if Okta auto-signs you in as someone else.

DO NOT USE: issuer .../oauth2/default or client ID 0oa15aypn34JXisbp698 (workshop 'Claude Integration App').
  Tokens from those fail with "Wrong identity-provider settings" (before the check existed: 401 invalid signature).

CLAUDE CODE: clients/claude-code/run.sh <user>   (settings generated automatically)
TXT
