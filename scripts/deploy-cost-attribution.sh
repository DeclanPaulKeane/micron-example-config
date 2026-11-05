#!/usr/bin/env bash
# Streaming custom policy ai-cost-attribution (plugin streaming from the control plane) + global policy config.
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh
export KONNECT_TOKEN="$PAT" AIGW_ID=$(cat .state/gw_id)
bash ai-cost-attribution/demo/deploy.sh "$PWD/konnect/cost-attribution-config.json"
