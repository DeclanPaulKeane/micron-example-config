# Insomnia collection: Micron AI Gateway demo

* `build.py` generates `micron-demo.insomnia.json` (collection + environments) and `micron-env.json` (the environment variables alone).
  Both contain the demo-user password and fresh Okta tokens, so they are git-ignored. Re-run `python3 insomnia/build.py` to regenerate.
* Import: Insomnia -> Import -> From File -> `insomnia/micron-demo.insomnia.json`.
* Environments: **Base** (public HTTPS gateway), **Public (HTTPS)**, **Local port-forward** (`scripts/pf.sh`, `http://localhost:18000`). All requests use `{{ _.gw }}`.
* Tokens last 5 minutes: run the requests in folder **00 Get tokens** whenever you get a 401; they store `token_usera|b|c|d` in the environment.
* Folders map to the demo sections (01 SSO ... 08 provider features). Request names say what to expect; descriptions say which `demo/*.sh` toggle to flip first.
* `smoke.py` replays a sample of the requests from the export (proves the file works): `python3 insomnia/smoke.py`.

## Environment variables
| Variable | Meaning |
|---|---|
| `base_url` | https://micron.kong-sales-engineering.com (public gateway) |
| `local_url` | http://localhost:18000 (after `scripts/pf.sh`) |
| `gw` | set by the sub-environment (public or local); used by every request |
| `okta_issuer`, `okta_token_url`, `okta_client_id`, `okta_scope`, `okta_audience` | Okta authorization server and the public PKCE client |
| `email_usera` ... `email_userd` | micron-user[a-d]@kong-sales-engineering.com |
| `demo_password` | password of the four demo users (from `DEMO_USER_PASSWORD` in secrets.yaml) |
| `token_usera` ... `token_userd` | access tokens (5 min); refreshed by the "Get token" requests |
| `expired_token` | an old token for the expired-token test |
| `anthropic_version` | 2023-06-01 |
| `m_opus`, `m_sonnet`, `m_haiku`, `m_auto`, `m_split`, `m_gpt` | model names (`claude-opus-5-5`, `claude-sonnet-5-5`, `claude-haiku-5-5`, `claude-auto`, `claude-sonnet-split`, `gpt-4o`) |
| `session_id` | `x-claude-code-session-id` for the 70/30 sticky-session request |
| `mcp_session`, `foundry_response_id` | set automatically by the MCP initialize and Responses turn-1 requests |
| `ticket_id` | TCK-101 |
