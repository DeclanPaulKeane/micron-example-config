# Pre-demo checklist

Run `./reset-demo.sh` then `demo/preflight.sh`; every automated line must be PASS. Then the manual items.

| # | Item | How | Automated? |
|---|---|---|---|
| 1 | TLS certificate valid | preflight shows expiry (Google-managed, auto-renews) | yes |
| 2 | Gateway + Grafana reachable over HTTPS | preflight | yes |
| 3 | Okta sign-in works for Users A-D (tokens fresh) | preflight; `MICRON_USER=usera python3 clients/okta_token.py login` for the interactive sessions | yes |
| 4 | Providers reachable | preflight (Anthropic via shim, Bedrock). CrowdStrike: check the broker line | yes |
| 5 | Budgets reset | preflight checks User C's daily budget; reset restarts the data plane | yes |
| 6 | Mocks healthy | preflight (pods Running, fault injector off, CrowdStrike toggle up); agents: `demo/a2a-call.sh usera card-triage` | yes |
| 7 | Foundry provider NOT yet added (live step in section 2) | reset removes it; `kongctl get ai-gateway` / Konnect UI | reset |
| 8 | Group membership restored (User D back in Demo-Engineering) | reset | reset |
| 9 | Long Claude Code session started as User A (section 1) | `cd data/test-repo && ../../clients/claude-code/run.sh usera`, paste the refactor prompt 10-15 min before the slot | manual |
| 10 | Claude Desktop signed in as User B (gateway mode) and the Ticketing connector available for User A | see DEMO-RUNBOOK client setup | manual |
| 11 | Tabs open: Grafana *Micron AI Gateway - Operations*, Konnect AI Gateway + AI Cost Management, notifications feed `https://micron-agents.kong-sales-engineering.com/notifications` | | manual |
| 12 | Laptop clock correct (token validity is 5 min) | | manual |
| 13 | Cluster headroom (shared cluster): `kubectl top nodes` | | manual |
