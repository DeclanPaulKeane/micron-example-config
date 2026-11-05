#!/usr/bin/env bash
# Load secrets.yaml (shell export format) into k8s Secret micron-secrets in namespace micron-aigw.
# Only non-empty keys are loaded. Values are never printed.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp); trap 'rm -f $tmp' EXIT
set -a; . ./secrets.yaml; set +a
grep -oE '^(export )?[A-Z_0-9]+=' secrets.yaml | sed 's/export //; s/=$//' | sort -u | while read -r k; do
  v="${!k:-}"; [ -n "$v" ] && printf '%s=%s\n' "$k" "$v" >> "$tmp"
done
kubectl -n micron-aigw create secret generic micron-secrets --from-env-file="$tmp" --dry-run=client -o yaml | kubectl apply -f - >/dev/null
echo "micron-secrets: $(wc -l < "$tmp" | tr -d ' ') keys loaded"
