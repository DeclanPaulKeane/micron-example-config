#!/usr/bin/env bash
# Apply the Konnect declarative config. Usage: scripts/apply.sh [file...]   (default: konnect/10-gateway.yaml)
# __AWS_ASSUME_ROLE_ARN__ is substituted into a temp copy under .state/ (never written back to the repo).
set -euo pipefail
cd "$(dirname "$0")/.."; . scripts/env.sh; mkdir -p .state/rendered
files=("$@"); [ ${#files[@]} -eq 0 ] && files=(konnect/10-gateway.yaml)
for f in "${files[@]}"; do
  out=$(python3 scripts/render.py "$f")
  kongctl apply -f "$out" --auto-approve
done
