#!/usr/bin/env bash
# One-time browser sign-in for all four demo users. Sign out of Okta (or use a private window) between users.
cd "$(dirname "$0")/../.."
for u in ${@:-usera userb userc userd}; do
  echo; echo ">>> Sign in as $u (micron-$u@kong-sales-engineering.com) in the browser that opens"
  MICRON_USER=$u python3 clients/okta_token.py login
done
