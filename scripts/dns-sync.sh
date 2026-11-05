#!/usr/bin/env bash
# Point micron*.kong-sales-engineering.com at the ingress IP (Cloud DNS zone "sales-engineering"). Idempotent.
set -euo pipefail
Z=sales-engineering; P=sales-engineering-282713
IP=$(kubectl -n micron-aigw get ingress micron-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
[ -n "$IP" ] || { echo "ingress has no IP yet"; exit 1; }
for h in micron micron-grafana micron-agents; do
  n="$h.kong-sales-engineering.com."
  cur=$(gcloud dns record-sets list --zone=$Z --project=$P --name="$n" --type=A --format='value(rrdatas[0])')
  if [ -z "$cur" ]; then gcloud dns record-sets create "$n" --zone=$Z --project=$P --type=A --ttl=60 --rrdatas="$IP" >/dev/null; echo "created $n -> $IP"
  elif [ "$cur" != "$IP" ]; then gcloud dns record-sets update "$n" --zone=$Z --project=$P --type=A --ttl=60 --rrdatas="$IP" >/dev/null; echo "updated $n -> $IP"
  else echo "ok $n"; fi
done
