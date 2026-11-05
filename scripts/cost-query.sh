#!/usr/bin/env bash
# Spend from Konnect AI Cost Management. Usage: scripts/cost-query.sh [dimension...]  e.g. person department   (MINUTES=60)
cd "$(dirname "$0")/.."; . scripts/env.sh
export KONNECT_TOKEN="$PAT" AIGW_ID=$(cat .state/gw_id)
bash ai-cost-attribution/demo/query.sh "${@:-tags.person}"
