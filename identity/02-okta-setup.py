#!/usr/bin/env python3
"""Idempotent Okta setup for the Micron demo: groups, users A-D, dedicated authorization server
(groups claim, 5-min access tokens) and a PKCE public client. Only creates NEW objects tagged micron.
Output: .state/okta.json (non-secret IDs). Reads secrets.yaml (shell export format)."""
import json, os, re, sys, urllib.request, urllib.error, urllib.parse
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
env = dict(re.findall(r'^(?:export )?([A-Z_0-9]+)=(.*)$', open(f"{ROOT}/secrets.yaml").read(), re.M))
BASE, TOKEN = env["OKTA_DOMAIN"].strip().rstrip("/"), env["OKTA_API_TOKEN"].strip()
PW = env["DEMO_USER_PASSWORD"].strip()
DOMAIN = "kong-sales-engineering.com"

def api(method, path, body=None, ok_404=False):
    req = urllib.request.Request(BASE + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": f"SSWS {TOKEN}", "Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r:
            d = r.read(); return json.loads(d) if d else {}
    except urllib.error.HTTPError as e:
        if ok_404 and e.code == 404: return None
        sys.exit(f"HTTP {e.code} {method} {path}: {e.read().decode()[:400]}")

state = {"groups": {}, "users": {}}
for g in ["Demo-Engineering", "Demo-Finance", "Demo-DataScience"]:
    found = [x for x in api("GET", "/api/v1/groups?q=" + g) if x["profile"]["name"] == g]
    state["groups"][g] = (found[0] if found else api("POST", "/api/v1/groups", {"profile": {"name": g, "description": "micron-demo"}}))["id"]

for nick, name, grp in [("usera", "A", "Demo-Engineering"), ("userb", "B", "Demo-Finance"),
                        ("userc", "C", "Demo-DataScience"), ("userd", "D", "Demo-Engineering")]:
    login = f"micron-{nick}@{DOMAIN}"
    u = api("GET", "/api/v1/users/" + urllib.parse.quote(login), ok_404=True)
    if not u:
        u = api("POST", "/api/v1/users?activate=true", {"profile": {"firstName": "User", "lastName": name, "email": login, "login": login},
                                                       "credentials": {"password": {"value": PW}}})
    state["users"][login] = u["id"]
    api("PUT", f"/api/v1/groups/{state['groups'][grp]}/users/{u['id']}")

AS_NAME = "micron-aigw"
servers = [s for s in api("GET", "/api/v1/authorizationServers") if s["name"] == AS_NAME]
srv = servers[0] if servers else api("POST", "/api/v1/authorizationServers", {"name": AS_NAME, "audiences": ["https://micron.kong-sales-engineering.com"], "description": "micron-demo"})
asid = srv["id"]
if srv.get("audiences") != ["https://micron.kong-sales-engineering.com"]:   # audiences_fix
    srv = api("PUT", f"/api/v1/authorizationServers/{asid}", {"name": srv["name"], "description": srv.get("description", "micron-demo"), "issuerMode": srv.get("issuerMode", "ORG_URL"), "audiences": ["https://micron.kong-sales-engineering.com"]})
asid = srv["id"]; state["issuer"] = srv["issuer"]; state["audience"] = "https://micron.kong-sales-engineering.com"
have = {c["name"] for c in api("GET", f"/api/v1/authorizationServers/{asid}/claims")}
for ctype in ("RESOURCE", "IDENTITY"):
    nm = "groups"
    if ctype == "IDENTITY": nm = "groups"  # same name allowed per claimType
    try_claim = {"name": nm, "status": "ACTIVE", "claimType": ctype, "valueType": "GROUPS", "value": "Demo-.*",
                 "group_filter_type": "REGEX", "conditions": {"scopes": []}}
    existing = [c for c in api("GET", f"/api/v1/authorizationServers/{asid}/claims") if c["name"] == nm and c["claimType"] == ctype]
    if not existing: api("POST", f"/api/v1/authorizationServers/{asid}/claims", try_claim)
for nm, ctype in (("email", "RESOURCE"), ("preferred_username", "RESOURCE")):
    existing = [c for c in api("GET", f"/api/v1/authorizationServers/{asid}/claims") if c["name"] == nm and c["claimType"] == ctype]
    if not existing:
        api("POST", f"/api/v1/authorizationServers/{asid}/claims", {"name": nm, "status": "ACTIVE", "claimType": ctype, "valueType": "EXPRESSION",
            "value": "user.email" if nm == "email" else "user.login", "conditions": {"scopes": []}})
scopes = {s["name"] for s in api("GET", f"/api/v1/authorizationServers/{asid}/scopes")}
if "offline_access" not in scopes:
    api("POST", f"/api/v1/authorizationServers/{asid}/scopes", {"name": "offline_access", "consent": "IMPLICIT", "description": "refresh tokens"})

pols = [p for p in api("GET", f"/api/v1/authorizationServers/{asid}/policies") if p["name"] == "micron-demo"]
pol = pols[0] if pols else api("POST", f"/api/v1/authorizationServers/{asid}/policies",
    {"type": "OAUTH_AUTHORIZATION_POLICY", "name": "micron-demo", "description": "micron-demo", "priority": 1, "conditions": {"clients": {"include": ["ALL_CLIENTS"]}}})
if not api("GET", f"/api/v1/authorizationServers/{asid}/policies/{pol['id']}/rules"):
    api("POST", f"/api/v1/authorizationServers/{asid}/policies/{pol['id']}/rules", {
        "type": "RESOURCE_ACCESS", "name": "short-lived", "priority": 1,
        "conditions": {"people": {"groups": {"include": ["EVERYONE"]}},
                       "grantTypes": {"include": ["authorization_code", "password", "client_credentials", "implicit"]},
                       "scopes": {"include": ["*"]}},
        "actions": {"token": {"accessTokenLifetimeMinutes": 5, "refreshTokenLifetimeMinutes": 0, "refreshTokenWindowMinutes": 10080}}})


# budget attribution claims (verified-token claims that the gateway projects into x-budget-* headers)
g = state["groups"]
def ternary(en, ds, fi, vals):
    return (f'isMemberOfGroup("{g["Demo-Engineering"]}") ? "{vals[0]}" : (isMemberOfGroup("{g["Demo-DataScience"]}") ? "{vals[1]}" : '
            f'(isMemberOfGroup("{g["Demo-Finance"]}") ? "{vals[2]}" : "unassigned"))')
for nm, vals in (("department", ("Product Development", "Product Development", "Finance")), ("team", ("Engineering", "Data Science", "Finance"))):
    if not [c for c in api("GET", f"/api/v1/authorizationServers/{asid}/claims") if c["name"] == nm]:
        api("POST", f"/api/v1/authorizationServers/{asid}/claims", {"name": nm, "status": "ACTIVE", "claimType": "RESOURCE", "valueType": "EXPRESSION",
            "value": ternary(0, 0, 0, vals), "conditions": {"scopes": []}})

REDIRECTS = ["http://127.0.0.1:53180/callback", "http://localhost:53180/callback", "http://localhost:8765/callback", "http://127.0.0.1:8765/callback",
             "https://claude.ai/api/mcp/auth_callback", "https://claude.com/api/mcp/auth_callback"]
LABEL = "Micron AIGW Claude Clients"
apps = [a for a in api("GET", "/api/v1/apps?q=" + urllib.parse.quote("Micron AIGW")) if a["label"] == LABEL]
app = apps[0] if apps else api("POST", "/api/v1/apps", {"name": "oidc_client", "label": LABEL, "signOnMode": "OPENID_CONNECT",
    "credentials": {"oauthClient": {"token_endpoint_auth_method": "none", "pkce_required": True}},
    "settings": {"oauthClient": {"application_type": "native", "grant_types": ["authorization_code", "refresh_token", "password"],
        "redirect_uris": REDIRECTS, "response_types": ["code"],
        "consent_method": "TRUSTED"}}})
# sync redirects
if sorted(app["settings"]["oauthClient"].get("redirect_uris", [])) != sorted(REDIRECTS):
    app["settings"]["oauthClient"]["redirect_uris"] = REDIRECTS; app = api("PUT", f"/api/v1/apps/{app['id']}", app)
state["client_id"] = app["credentials"]["oauthClient"]["client_id"]; state["app_id"] = app["id"]
for gid in state["groups"].values(): api("PUT", f"/api/v1/apps/{app['id']}/groups/{gid}", {})
os.makedirs(f"{ROOT}/.state", exist_ok=True); json.dump(state, open(f"{ROOT}/.state/okta.json", "w"), indent=2)
print(json.dumps({k: v for k, v in state.items() if k not in ("users",)}, indent=2)); print("users:", len(state["users"]))
