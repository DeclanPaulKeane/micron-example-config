#!/usr/bin/env python3
"""Okta identities for the two demo agents (service apps) + RFC 8693 token exchange so an agent acts for a user.
Creates apps 'Micron Ticket Triage Agent' / 'Micron Release Notes Agent', an 'agent' claim on the micron-aigw authorization server,
adds the token-exchange grant to the access policy rule, and writes client ids/secrets to secrets.yaml (ENTRA_* names are NOT used; OKTA_AGENT_*)."""
import json, os, re, sys, urllib.request, urllib.error, urllib.parse
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sec = open(f"{ROOT}/secrets.yaml").read()
env = dict(re.findall(r'^(?:export )?([A-Z_0-9]+)=(.*)$', sec, re.M))
BASE, TOKEN = env["OKTA_DOMAIN"].strip().rstrip("/"), env["OKTA_API_TOKEN"].strip()
st = json.load(open(f"{ROOT}/.state/okta.json")); ASID = st["issuer"].rsplit("/", 1)[1]
def api(m, path, body=None):
    req = urllib.request.Request(BASE + path, method=m, data=json.dumps(body).encode() if body is not None else None, headers={"Authorization": f"SSWS {TOKEN}", "Accept": "application/json", "Content-Type": "application/json"})
    try:
        with urllib.request.urlopen(req) as r: d = r.read(); return json.loads(d) if d else {}
    except urllib.error.HTTPError as e: sys.exit(f"HTTP {e.code} {m} {path}: {e.read().decode()[:500]}")
GRANTS = ["client_credentials", "urn:ietf:params:oauth:grant-type:token-exchange"]
agents = {"ticket-triage-agent": ("Micron Ticket Triage Agent", "TRIAGE"), "release-notes-agent": ("Micron Release Notes Agent", "RELEASE")}
ids = {}
for key, (label, tag) in agents.items():
    found = [a for a in api("GET", "/api/v1/apps?q=" + urllib.parse.quote(label)) if a["label"] == label]
    app = found[0] if found else api("POST", "/api/v1/apps", {"name": "oidc_client", "label": label, "signOnMode": "OPENID_CONNECT",
        "credentials": {"oauthClient": {"token_endpoint_auth_method": "client_secret_basic"}},
        "settings": {"oauthClient": {"application_type": "service", "grant_types": GRANTS, "response_types": ["token"]}}})
    cid = app["credentials"]["oauthClient"]["client_id"]; ids[key] = cid
    if not re.search(rf"^(export )?OKTA_AGENT_{tag}_CLIENT_ID=", sec, re.M):
        # secret is only returned at creation (or from the app credentials endpoint)
        csec = app["credentials"]["oauthClient"].get("client_secret")
        if not csec:
            sys.exit(f"no client secret returned for existing app {label}; add OKTA_AGENT_{tag}_CLIENT_ID/SECRET manually")
        with open(f"{ROOT}/secrets.yaml", "a") as f: f.write(f"export OKTA_AGENT_{tag}_CLIENT_ID={cid}\nexport OKTA_AGENT_{tag}_CLIENT_SECRET={csec}\n")
        sec = open(f"{ROOT}/secrets.yaml").read()
    print("agent app", key, cid)
scopes = {x['name'] for x in api('GET', f'/api/v1/authorizationServers/{ASID}/scopes')}
if 'aigw' not in scopes:
    api('POST', f'/api/v1/authorizationServers/{ASID}/scopes', {'name': 'aigw', 'consent': 'IMPLICIT', 'description': 'AI gateway access for agents'})
# claim 'agent' = which agent client is calling (absent for the human client)
claims = api("GET", f"/api/v1/authorizationServers/{ASID}/claims")
expr = f'app.clientId == "{ids["ticket-triage-agent"]}" ? "ticket-triage-agent" : (app.clientId == "{ids["release-notes-agent"]}" ? "release-notes-agent" : "")'
if not [c for c in claims if c["name"] == "agent"]:
    api("POST", f"/api/v1/authorizationServers/{ASID}/claims", {"name": "agent", "status": "ACTIVE", "claimType": "RESOURCE", "valueType": "EXPRESSION", "value": expr, "conditions": {"scopes": []}})
# token exchange grant on the access policy rule
pol = [p for p in api("GET", f"/api/v1/authorizationServers/{ASID}/policies") if p["name"] == "micron-demo"][0]
rule = api("GET", f"/api/v1/authorizationServers/{ASID}/policies/{pol['id']}/rules")[0]
g = rule["conditions"]["grantTypes"]["include"]
if "urn:ietf:params:oauth:grant-type:token-exchange" not in g:
    rule["conditions"]["grantTypes"]["include"] = g + ["urn:ietf:params:oauth:grant-type:token-exchange"]
    api("PUT", f"/api/v1/authorizationServers/{ASID}/policies/{pol['id']}/rules/{rule['id']}", rule)
print("done")
