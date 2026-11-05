# Rebuild the Micron demo from nothing

The `micron-aigw` namespace was deleted on 2026-10-27. Everything needed to recreate it is in this folder.

## What is saved
- `k8s/`, `konnect/`, `mocks/`, `grafana/`, `identity/`, `scripts/`, `demo/`, `clients/`, `insomnia/`, `data/` — the source of truth. `deploy.sh` rebuilds from these.
- `snapshot/2026-10-27/` — what was live at deletion (Deployments, Services, Ingress, ConfigMaps, cert, pod list, DP image `kong/kong-ai-gateway:2.2.0`, the 6 Konnect budgets, the gateway ID). Secret values are NOT in it (names only). Reference only; don't apply it, use `deploy.sh`.
- `secrets.yaml` (git-ignored, holds every credential) and `.state/` (git-ignored: Konnect gateway ID, data-plane certificate, Okta client config, venv). Keep both. Back them up somewhere private; they are not in git.

## What is NOT saved (it lived only in the pods, no volumes)
Redis contents (budget counters, semantic cache, RAG index; the handbook is re-ingested by the deploy), Loki/Tempo/Prometheus history, and the notification feed.

## What was left in place
Konnect control plane `micron-aigw` (org micronpoc), Okta users/groups/apps, Cloud DNS records (micron, micron-grafana, micron-agents). The DNS records point at the old load-balancer IP (8.232.139.209) until `dns-sync.sh` runs.

## Steps
1. `gcloud auth login`, then select the shared cluster context (`gke_sales-engineering-282713_us-east1_aigw2-workshop`).
2. Check `secrets.yaml` is present and the Konnect token in it is still valid.
3. `./deploy.sh` (about 10 minutes; creates the namespace, secrets, pods, ingress, gateway config, budgets, handbook index).
4. `scripts/dns-sync.sh` — the new ingress gets a new IP; this updates the three DNS names.
5. Wait for the Google-managed certificate to turn Active (`kubectl -n micron-aigw get managedcertificate`; commonly 15 to 60 minutes). HTTPS fails until then.
6. `demo/preflight.sh`, then `./reset-demo.sh` for a clean demo state.
7. Sign-ins cached in `~/.cache/micron-aigw/` keep working. If not: `clients/claude-code/login-all.sh`.

## Caveats
- `deploy.sh` was built and run piece by piece against this namespace but has never been run against an empty cluster. Expect to fix a small thing on the first full run. Say so before a customer session and do a dry run first.
- The cluster is shared and was under memory pressure; check pods are Running (`kubectl -n micron-aigw get pods`) after deploy.

## Restored 2026-11-03
Ran the steps above against the empty namespace. New ingress IP 34.120.57.172 (DNS updated); cert went Active in under 30 min.
Fixes made on the way: `deploy.sh` now applies the ingress after its backend Services and waits for the IP before `dns-sync.sh` (it aborted there before); `scripts/kick-cache.sh` only touches `cache-eng` (the only cache policy since the alias fix).
Result: preflight all green; scenario suite 76/78 over HTTPS. The two misses were the 70/30 split checks inside the full run (errors under load late in the suite); run alone, split was 69/31 and one session stuck to a single provider.
Run `demo/run-tests.sh` against the HTTPS hostname (the default), not `GWURL=http://localhost:18000`: MCP/A2A streams time out over the port-forward.
