# Micron AI Gateway: follow-up session demo script (30 min)

Three blocks of 10 minutes: **(1) model routing and failover**, **(2) agents, MCP governance, caching and RAG**, **(3) roadmap and next steps** (talk track only).
Everything below runs from this folder against `https://micron.kong-sales-engineering.com`. Each step is **Tell → Show → Tell**. Expected output is what the gateway returned in rehearsal on 2026-11-04.

## Before the session (15 min ahead)
```bash
gcloud auth login                 # the fault/tool-change switches use kubectl; credentials expire overnight
./reset-demo.sh                   # clean state (~3 min)
demo/preflight.sh                 # must end with ALL PREFLIGHT CHECKS PASSED
. demo/curl-helpers.sh            # defines: ask <user> <model> "<prompt>" [route] [curl args], tok <user>, CC (Claude Code header)
```
Open tabs: Konnect → AI Gateway *Micron AI Gateway* (Models, Agents, MCP servers) and AI Cost Management; Grafana *Operations* (`https://micron-grafana.kong-sales-engineering.com`); the notifications feed (`https://micron-agents.kong-sales-engineering.com/notifications`).
Optional Claude Code window (User A): `cd data/test-repo && ../../clients/claude-code/run.sh usera`.

> `ask` prints the response headers that matter (`x-kong-llm-model` = **which provider and model really answered**, `x-cache-status`, `x-kong-proxy-latency`), then the answer or the gateway error. Errors always carry a gateway request ID, traceable in Grafana.
> `"${CC[@]}"` adds `user-agent: claude-cli/…`: the gateway treats the call as Claude Code, which **bypasses the semantic cache**. Use it in block 1, or a cached answer hides the routing.

---
## 1. Model routing and failover (10 min)

### 1.1 One endpoint, models by group (1 min)
**Tell:** clients point at one URL with their Okta sign-in. The gateway reads the group from the token and decides which models the caller may use; the request body's `model` string picks the route.
```bash
curl -s $GW/anthropic/v1/models -H "authorization: Bearer $(tok usera)" | jq -c '[.data[].id]'   # Engineering
curl -s $GW/anthropic/v1/models -H "authorization: Bearer $(tok userb)" | jq -c '[.data[].id]'   # Finance
ask userb claude-opus-5-5 "Say hi"
```
Expect: A sees `opus, sonnet, haiku`; B sees `sonnet, haiku`; B asking for Opus gets **403 "Model not allowed: your group (Demo-Finance) cannot use 'claude-opus-5-5' … (gateway request ID: …)"**.

### 1.2 Priority routing: Anthropic first, Bedrock as standby (1 min)
**Tell:** `claude-sonnet` is one model with two targets, Anthropic direct (primary) and Amazon Bedrock (standby). Show it in Konnect → Models → `claude-sonnet`.
```bash
ask usera claude-sonnet "Say hi" /anthropic "${CC[@]}"
```
Expect: `x-kong-llm-model: anthropic/claude-sonnet-5-5`, id `msg_01…`.

### 1.3 Automatic failover (3 min) *(needs kubectl)*
**Tell:** we put a fault injector between the gateway and Anthropic so we can make Anthropic fail on demand.
```bash
demo/chaos.sh overloaded                                   # Anthropic now returns "overloaded" errors
ask usera claude-sonnet "Say hi" /anthropic "${CC[@]}"      # failover model
ask usera claude-haiku-5-5 "Say hi" /anthropic "${CC[@]}"   # Haiku has no standby, on purpose
demo/chaos.sh off
```
Expect: Sonnet still **200**, now `x-kong-llm-model: bedrock/us.anthropic.claude-sonnet-5-5`, id `msg_bdrk_…`. The client did nothing; the response is still Anthropic format. Haiku returns **500 "Overloaded (gateway request ID: …)"**, showing what happens without a standby.
**Claude Code version:** with the fault on, keep prompting in User A's Claude Code; it carries on and Grafana *Provider mix* shows traffic moving to Bedrock.
**Tell (be upfront):** a real Anthropic overload is HTTP **529**. Failing over on 529 needs gateway runtime **2.3**; on 2.2 (this POC) 429/500/502 fail over and 503/504 did not. That's why the injector sends a 500 with Anthropic's overloaded body.

### 1.4 Load balancing with sticky sessions, changed live (3 min)
**Tell:** `claude-sonnet-split` spreads new sessions across Anthropic and Bedrock 70/30. A Claude Code session stays on one provider, keyed on the session header Claude Code already sends, so its prompt cache stays warm.
```bash
GWURL=$GW demo/split-test.sh 20          # 20 new sessions, then one session repeated 6 times
demo/set-split.sh 50                     # live change through the Konnect API, no client change
sleep 20; GWURL=$GW demo/split-test.sh 20
demo/set-split.sh 70                     # put it back
```
Expect: roughly 14/6, then roughly 10/10 (the split is statistical); the repeated session lands on **one** provider every time (rehearsal: 69/31 over 100 sessions, 6/6 sticky).

### 1.5 Automatic model choice (2 min)
**Tell:** `claude-auto` lets the gateway choose a model by comparing the prompt with a description of each model: cheap model for simple work, strongest model for hard work.
```bash
ask usera claude-auto "Fix the typo in this sentence: Teh cat sat." /anthropic "${CC[@]}"
ask usera claude-auto "Design a migration plan to move a 40-service monolith to Kubernetes with zero downtime, covering data, rollout and rollback." /anthropic "${CC[@]}"
```
Expect: first `x-kong-llm-model: anthropic/claude-haiku-5-5`, second `anthropic/claude-opus-5-5`.
**Tell (wrap):** priority, failover, weighted and semantic routing are all native, declared config. The only custom piece is the fault injector we used to cause the failures.

---
## 2. Agents, MCP governance, caching and RAG (10 min)

### 2.1 MCP servers and tools governed by group (3 min)
**Tell:** three internal MCP servers (Ticketing, Code Search, HR Records) are published only through the gateway. Access to a server is set by group; access to each tool is enforced per call, and every denial is clear and traceable.
```bash
demo/mcp-call.sh usera ticketing list                                              # Engineering (output trimmed to 600 chars)
demo/mcp-call.sh userb ticketing list                                              # Finance
demo/mcp-call.sh usera ticketing call list_tickets '{}'
demo/mcp-call.sh usera hr-records call get_employee_salary '{"employee_id":"E100"}'
```
Expect: A sees the ticketing tools; B gets an **empty tool list** (the server is invisible to Finance); `list_tickets` returns tickets (TCK-101 …); salary returns **"Tool denied: micron-usera@… may not call 'get_employee_salary' on MCP server 'hr-records' … (gateway request ID: …)"**.
*(`mcp-call.sh` is three curls: `initialize`, `notifications/initialized`, then `tools/list` or `tools/call`, all to `$GW/mcp/<server>` with the user's Okta token.)*
**Claude Desktop version:** Settings → Connectors → add `https://micron.kong-sales-engineering.com/mcp/ticketing` (client ID from `clients/desktop-settings.sh`). *Not rehearsed in the Desktop app; use the terminal version unless tested.*

### 2.2 Tool description changes are blocked (2 min) *(needs kubectl)*
**Tell:** a common MCP attack is a tool whose description changes after approval to carry hidden instructions. The gateway keeps a fingerprint of each approved description.
```bash
demo/poison-tool.sh poison        # the server now advertises a get_ticket description with a hidden instruction
sleep 45
demo/mcp-call.sh usera ticketing call get_ticket '{"ticket_id":"TCK-101"}'
demo/poison-tool.sh reset
```
Expect: the notifications feed shows **"MCP tool description CHANGED: ticketing/get_ticket"**; the call returns **"Tool blocked: its description changed since it was approved"**. After reset it unblocks on its own.
**Tell (be upfront):** detection and blocking here are custom (a watcher plus a gateway block list), not a native 2.2 feature.

### 2.3 Agents: identity, access control, lifecycle (3 min)
**Tell:** two A2A agents (Ticket Triage, Release Notes) are registered in Konnect (show AI Gateway → Agents / MCP servers: the registry). Each has its **own Okta identity** and its own **$5/day budget**. When an agent acts for a user it exchanges tokens (RFC 8693), so every downstream call is "user **via** agent" and limited to what that user may do.
```bash
LINES_MAX=12 demo/a2a-call.sh usera card-triage                 # agent card, served through the gateway
demo/a2a-call.sh usera triage "Triage the open tickets"
demo/a2a-call.sh userb triage "Triage the open tickets"         # Finance may not use this agent
scripts/cost-report.sh 2                                         # cost by department, team, person, agent
```
Expect: the card (name, URL behind the gateway, JSON-RPC); A gets ranked tickets with owners, plus **"hr-records/get_employee_salary: DENIED … micron-usera@… via ticket-triage-agent may not call …"**, showing both identities on one call; B gets **"You cannot consume this service (gateway request ID: …)"**; the cost report has a per-agent table.
**Lifecycle talk track:** register (Konnect agents/MCP registry) → identity (Okta service app) → permissions (group ACLs on the agent route, tool ACLs on its calls) → budget (per-agent limit, warning at 80%) → cost and audit (per-agent tags in AI Cost Management, request ID on every call) → retire (remove the registry entry and the Okta app; not scripted here).
**Tell (be upfront):** in 2.2 agents are registered as HTTP agents; there is no first-class A2A policy engine yet. Okta's delegation form of token exchange (`act` claim) was denied, so we used the impersonation form.

### 2.4 Semantic cache and RAG (2 min)
**Tell:** Engineering's questions are answered from the Engineering handbook (RAG) and cached by meaning, so a colleague asking the same thing gets an instant answer at no model cost. Other teams can't see the handbook or the cache.
```bash
ask usera claude-haiku-5-5 "What does the Engineering handbook say about logging?"    # User A, Engineering
ask userd claude-haiku-5-5 "What does the Engineering handbook say about logging?"    # User D, Engineering
ask userb claude-haiku-5-5 "What does the Engineering handbook say about logging?"    # User B, Finance
```
Expect: A gets `x-cache-status: Miss` and a handbook-grounded answer (structured JSON logs to stdout, required fields `ts/level/service/trace_id/msg`, 30-day hot retention …); D gets `x-cache-status: Hit` with the same answer, no `x-kong-llm-model` (no model called); B gets **403 "Access denied: the Engineering handbook is a knowledge source restricted to the Engineering group …"**.
If A already shows `Hit`, run `scripts/flush-cache.sh` first (needs kubectl).
**Tell (be upfront):** cache and RAG are native policies, but the RAG injector has no ingestion API on AI Gateway, so we load documents with a script; RAG and cache are skipped for Claude Code traffic and attachments (the injector rejects multi-block messages). Cache scope is per team by design, not per person.

---
## 3. Roadmap and next steps (10 min, talk track)
**Do not commit dates in the room.** Fill the `[confirm]` items with product before the call; anything not confirmed is "we'll come back to you".

### 3.1 Cost management
| Topic | Where the POC is today | Ask product |
|---|---|---|
| Provider-level pricing | Prices are entered per model target (input/output/cache costs) in config; no automatic price feed. Budgets use these numbers. | [confirm] provider price catalogue / auto-update, and timing |
| Billing reconciliation | Gateway cost is computed from token usage × configured price (`scripts/cost-report.sh`, AI Cost Management). Not reconciled against Anthropic/AWS invoices. | [confirm] invoice reconciliation on the roadmap; until then, an export to compare with invoices monthly |
| Budgets | Enforced budgets = AI Rate Limiting Advanced (GA). Konnect AI Cost Management budgets are watch-only; the 80% warnings and exceptions here are custom. | [confirm] native alerts/notifications and enforcement from AI Cost Management |
| Failover cost | A request that moves provider pays a prompt-cache write again on the new provider. | n/a, design note |

### 3.2 AI Gateway, agent and MCP capabilities
| Seen today | Status in 2.2 | Ask product |
|---|---|---|
| Failover on real Anthropic overload (529) | Needs runtime **2.3** | [confirm] 2.3 GA date for Konnect AI Gateway |
| Mid-stream provider drop reported as an error | Custom shim (Anthropic path only) | [confirm] native SSE error + failure logging |
| A2A agents | Registered as HTTP agents; no A2A-aware policies | [confirm] first-class A2A type and policies |
| Agent identity | Okta token exchange (impersonation) | [confirm] Entra Agent ID / OBO support |
| MCP tool ACLs | Server-level native; per-tool ACLs custom (`default_tool_acls` exists, not verified) | [confirm] per-tool ACLs GA |
| Tool description change detection | Custom | [confirm] native tool pinning / change detection |
| RAG ingestion | No ingestion API; scripted | [confirm] ingestion API |
| CrowdStrike AIDR | Plugin not accepted as an AI Gateway policy; HTTP guardrail adapter used | [confirm] AIDR as a native AI Gateway policy |

### 3.3 "Coming Soon" items
List each "Coming Soon" item Micron asked about with the date product confirms. **[fill before the call: no dates are recorded in this repo]**

### 3.4 Open questions and POC next steps
- Identity: move from Okta to Micron's Entra ID (needs an Entra admin to create 4 test users; gateway side only changes issuer, client ID, audience).
- Not yet exercised with real clients: Claude Desktop sign-in and MCP connector OAuth; a 30+ min Claude Code session (verify before relying on it).
- Vertex AI / Gemini: out of scope so far; confirm whether Micron wants it in the POC.
- Notifications: Teams/email webhook not connected (feed page only); needs a Micron webhook URL.
- Agree success criteria and dates for the next POC phase; full gap list and draft answers in `GAPS.md`.

---
## Recovery during the session
| Symptom | Fix |
|---|---|
| `kubectl` errors / "Reauthentication failed" | `gcloud auth login` |
| Everything 401 | `rm ~/.cache/micron-aigw/*.json`, then re-run the step (`tok` signs in again) |
| A fault is stuck on | `demo/chaos.sh off`; `demo/poison-tool.sh reset` |
| Failover step shows `x-cache-status: Hit` | you dropped `"${CC[@]}"`; add it back |
| Anything else | `./reset-demo.sh` (3 min) |
