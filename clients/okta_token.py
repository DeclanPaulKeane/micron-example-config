#!/usr/bin/env python3
"""Claude Code apiKeyHelper for the Micron AI Gateway demo: prints a valid Okta access token on stdout.

  okta_token.py            print a token (cached; silently refreshed with the refresh token; falls back to login)
  okta_token.py login      interactive browser sign-in (auth code + PKCE, loopback http://127.0.0.1:53180/callback)
  okta_token.py status     show who is signed in and token lifetime
  okta_token.py logout

User profile: env MICRON_USER (usera|userb|userc|userd, default usera) selects the cache file, so several
people can be signed in on one laptop. For automation only: MICRON_PASSWORD_GRANT=1 uses the password grant
(password from DEMO_USER_PASSWORD env or secrets.yaml) instead of a browser.
Config: MICRON_ISSUER / MICRON_CLIENT_ID env, else ../.state/okta.json (written by identity/02-okta-setup.py).
"""
import base64, hashlib, http.server, json, os, re, secrets, sys, threading, time, urllib.parse, urllib.request, urllib.error, webbrowser

HERE = os.path.dirname(os.path.abspath(__file__))
ST = {}
try: ST = json.load(open(os.path.join(HERE, "..", ".state", "okta.json")))
except OSError: pass
ISSUER = os.environ.get("MICRON_ISSUER", ST.get("issuer", ""))
CLIENT = os.environ.get("MICRON_CLIENT_ID", ST.get("client_id", ""))
USER = os.environ.get("MICRON_USER", "usera")
CACHE_DIR = os.path.expanduser("~/.cache/micron-aigw"); os.makedirs(CACHE_DIR, exist_ok=True)
CACHE = os.path.join(CACHE_DIR, f"{USER}.json")
SCOPE = "openid email offline_access"
PORT = 53180

def post(url, data):
    try:
        with urllib.request.urlopen(urllib.request.Request(url, data=urllib.parse.urlencode(data).encode())) as r: return json.load(r)
    except urllib.error.HTTPError as e: return {"error": json.loads(e.read() or b"{}").get("error", str(e.code))}

def save(tok):
    tok["expires_at"] = time.time() + int(tok.get("expires_in", 300))
    json.dump(tok, open(CACHE, "w")); os.chmod(CACHE, 0o600); return tok

def load():
    try: return json.load(open(CACHE))
    except (OSError, ValueError): return None

def claims(jwt):
    p = jwt.split(".")[1]; return json.loads(base64.urlsafe_b64decode(p + "=" * (-len(p) % 4)))

def password_grant():
    pw = os.environ.get("DEMO_USER_PASSWORD")
    if not pw:
        m = re.search(r"^(?:export )?DEMO_USER_PASSWORD=(.*)$", open(os.path.join(HERE, "..", "secrets.yaml")).read(), re.M); pw = m.group(1).strip()
    return post(ISSUER + "/v1/token", {"grant_type": "password", "username": f"micron-{USER}@kong-sales-engineering.com",
                                       "password": pw, "scope": SCOPE, "client_id": CLIENT})

def login():
    if os.environ.get("MICRON_PASSWORD_GRANT"): return save(password_grant())
    verifier = secrets.token_urlsafe(64); state = secrets.token_urlsafe(16)
    challenge = base64.urlsafe_b64encode(hashlib.sha256(verifier.encode()).digest()).rstrip(b"=").decode()
    redirect = f"http://127.0.0.1:{PORT}/callback"; got = {}
    class H(http.server.BaseHTTPRequestHandler):
        def do_GET(self):
            q = urllib.parse.parse_qs(urllib.parse.urlparse(self.path).query); got.update({k: v[0] for k, v in q.items()})
            self.send_response(200); self.send_header("Content-Type", "text/html"); self.end_headers()
            self.wfile.write(b"<h3>Signed in to the Micron AI Gateway demo. You can close this tab.</h3>")
        def log_message(self, *a): pass
    srv = http.server.HTTPServer(("127.0.0.1", PORT), H); t = threading.Thread(target=srv.handle_request); t.start()
    url = ISSUER + "/v1/authorize?" + urllib.parse.urlencode({"client_id": CLIENT, "response_type": "code", "scope": SCOPE, "redirect_uri": redirect,
          "state": state, "code_challenge": challenge, "code_challenge_method": "S256"})
    print("Opening browser to sign in (user: micron-%s@kong-sales-engineering.com)..." % USER, file=sys.stderr); webbrowser.open(url); t.join(300)
    if got.get("state") != state or "code" not in got: sys.exit("login failed: %s" % got)
    return save(post(ISSUER + "/v1/token", {"grant_type": "authorization_code", "code": got["code"], "redirect_uri": redirect,
                                           "client_id": CLIENT, "code_verifier": verifier}))

def token():
    t = load()
    if t and t.get("expires_at", 0) - time.time() > 60: return t
    if t and t.get("refresh_token"):
        n = post(ISSUER + "/v1/token", {"grant_type": "refresh_token", "refresh_token": t["refresh_token"], "client_id": CLIENT, "scope": SCOPE})
        if "access_token" in n:
            n.setdefault("refresh_token", t["refresh_token"]); return save(n)
        if os.environ.get("MICRON_PASSWORD_GRANT"): return login()     # automated tests: just sign in again
        if n.get("error") in ("invalid_grant", "access_denied", "invalid_token"):
            # Okta refused the refresh (user removed from the app/group or sessions revoked). Do NOT pop a browser from
            # inside Claude Code: return a sentinel the gateway turns into a clear "access removed" message.
            return {"access_token": "ACCESS-REMOVED", "expires_at": 0}
    return login()

if __name__ == "__main__":
    cmd = sys.argv[1] if len(sys.argv) > 1 else "token"
    if cmd == "login": login(); cmd = "status"
    if cmd == "logout": 
        try: os.remove(CACHE)
        except OSError: pass
        sys.exit(0)
    if cmd == "status":
        t = load(); c = claims(t["access_token"]) if t else {}
        print(json.dumps({"user": USER, "email": c.get("email"), "groups": c.get("groups"), "seconds_left": int(t["expires_at"] - time.time()) if t else None}))
    else:
        print(token()["access_token"])
