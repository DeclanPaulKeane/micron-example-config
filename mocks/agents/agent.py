"""A2A demo agents (synthetic). AGENT=triage|release.  Speaks A2A (JSON-RPC 2.0 over HTTP): agent card at /.well-known/agent-card.json,
methods message/send and tasks/get.  Identity: the agent has its OWN Okta client (service app); for every request it exchanges the caller's
user token (RFC 8693) so everything it does at the gateway is "<user> via <agent>".  The agent never holds MCP or model credentials."""
import base64, hashlib, json, os, time, urllib.parse, urllib.request, urllib.error, uuid
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

KIND = os.environ["AGENT"]
CID, CSEC = os.environ["CLIENT_ID"], os.environ["CLIENT_SECRET"]
ISSUER, AUD = os.environ["ISSUER"], os.environ["AUDIENCE"]
GW = os.environ.get("GW_URL", "http://aigw-dp.micron-aigw.svc.cluster.local")
PUBLIC = os.environ["PUBLIC_URL"]
MODEL = os.environ.get("MODEL", "claude-haiku-5-5")
CARDS = {
  "triage": {"name": "Ticket Triage Agent", "id": "ticket-triage-agent", "description": "Reads open support tickets through the Ticketing MCP server, ranks them and proposes owners. Acts on behalf of the calling user.",
             "skills": [{"id": "triage-tickets", "name": "Triage tickets", "description": "Read open tickets and propose priority and owner for each.", "tags": ["tickets", "triage"], "examples": ["Triage the open tickets"]}]},
  "release": {"name": "Release Notes Agent", "id": "release-notes-agent", "description": "Searches the code repository through the Code search MCP server and drafts release notes. Acts on behalf of the calling user.",
              "skills": [{"id": "draft-release-notes", "name": "Draft release notes", "description": "Summarise merged pull requests since the last release.", "tags": ["release", "notes"], "examples": ["Draft release notes since v1.4"]}]},
}[KIND]
CARD = {"protocolVersion": "0.3.0", "name": CARDS["name"], "description": CARDS["description"], "url": PUBLIC, "preferredTransport": "JSONRPC", "version": "1.0.0",
        "provider": {"organization": "Micron AI Gateway demo (synthetic)", "url": "https://micron.kong-sales-engineering.com"},
        "capabilities": {"streaming": False, "pushNotifications": False, "stateTransitionHistory": False},
        "defaultInputModes": ["text/plain"], "defaultOutputModes": ["text/plain"], "skills": CARDS["skills"],
        "securitySchemes": {"oidc": {"type": "openIdConnect", "openIdConnectUrl": ISSUER + "/.well-known/openid-configuration"}}, "security": [{"oidc": ["openid"]}],
        "x-agent-identity": {"okta_client_id": CID, "agent_claim": CARDS["id"]}}
TASKS = {}; XCACHE = {}

def jpost(url, data, headers=None, form=False, timeout=60):
    body = urllib.parse.urlencode(data).encode() if form else json.dumps(data).encode()
    h = {"Content-Type": "application/x-www-form-urlencoded" if form else "application/json", **(headers or {})}
    try:
        with urllib.request.urlopen(urllib.request.Request(url, body, h), timeout=timeout) as r: return r.status, dict(r.headers), r.read().decode()
    except urllib.error.HTTPError as e: return e.code, dict(e.headers), e.read().decode()

def exchange(user_token):
    """RFC 8693 token exchange: user token -> token for 'user via this agent' (Okta custom authorization server)."""
    k = hashlib.sha256(user_token.encode()).hexdigest()
    if k in XCACHE and XCACHE[k][1] > time.time() + 20: return XCACHE[k][0]
    basic = base64.b64encode(f"{CID}:{CSEC}".encode()).decode()
    st, _, b = jpost(ISSUER + "/v1/token", {"grant_type": "urn:ietf:params:oauth:grant-type:token-exchange", "subject_token": user_token, "subject_token_type": "urn:ietf:params:oauth:token-type:access_token",
        "requested_token_type": "urn:ietf:params:oauth:token-type:access_token", "audience": AUD, "scope": "aigw"}, {"Authorization": "Basic " + basic}, form=True)
    j = json.loads(b)
    if "access_token" not in j: raise RuntimeError(f"token exchange failed: {b[:200]}")
    XCACHE[k] = (j["access_token"], time.time() + int(j.get("expires_in", 300))); return j["access_token"]

class MCP:
    def __init__(self, server, token): self.url = f"{GW}/mcp/{server}"; self.h = {"Authorization": "Bearer " + token, "Accept": "application/json, text/event-stream"}; self.sid = None
    def rpc(self, method, params=None, id=1, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}; 
        if not notify: msg["id"] = id
        if params is not None: msg["params"] = params
        h = dict(self.h); 
        if self.sid: h["mcp-session-id"] = self.sid
        st, hd, b = jpost(self.url, msg, h)
        if not self.sid: self.sid = {k.lower(): v for k, v in hd.items()}.get("mcp-session-id")
        if notify or not b.strip(): return {}
        for line in b.splitlines():
            if line.startswith("data:"): b = line[5:].strip(); break
        try: return json.loads(b)
        except ValueError: return {"error": {"message": f"HTTP {st}: {b[:200]}"}}
    def call(self, tool, args):
        self.rpc("initialize", {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": CARDS["id"], "version": "1"}}); self.rpc("notifications/initialized", notify=True)
        return self.rpc("tools/call", {"name": tool, "arguments": args}, id=2)

def tool_text(r):
    if "error" in r: return None, r["error"].get("message", str(r["error"]))
    return "".join(c.get("text", "") for c in r.get("result", {}).get("content", [])), None

def llm(token, system, prompt):
    st, _, b = jpost(f"{GW}/anthropic/v1/messages", {"model": MODEL, "max_tokens": 500, "system": system, "messages": [{"role": "user", "content": prompt}]},
                     {"Authorization": "Bearer " + token, "anthropic-version": "2023-06-01", "User-Agent": CARDS["id"]})
    j = json.loads(b)
    if st != 200: return f"[model call refused: {j.get('error', {}).get('message', b[:200])}]"
    return "".join(x.get("text", "") for x in j.get("content", []) if x.get("type") == "text")

def run(user_token, text):
    t = exchange(user_token); log = []
    if KIND == "triage":
        out, err = tool_text(MCP("ticketing", t).call("list_tickets", {"status": "open"})); log.append(("ticketing/list_tickets", "allowed" if out else "DENIED: " + str(err)))
        sal, serr = tool_text(MCP("hr-records", t).call("get_employee_salary", {"employee_id": "E1"}))
        log.append(("hr-records/get_employee_salary", "allowed (UNEXPECTED)" if sal else "DENIED by gateway: " + str(serr)))
        summary = llm(t, "You are a ticket triage assistant. Be concise.", f"Rank these open tickets by urgency and suggest an owning team for each (one line each):\n{out}")
        body = f"Triage result:\n{summary}\n\nTool calls:\n" + "\n".join(f"- {a}: {b}" for a, b in log)
    else:
        prs, e1 = tool_text(MCP("code-search", t).call("list_merged_prs", {"since": "v1.4"})); ch, e2 = tool_text(MCP("code-search", t).call("search_code", {"query": "CHANGELOG"}))
        log += [("code-search/list_merged_prs", "allowed" if prs else "DENIED: " + str(e1)), ("code-search/search_code", "allowed" if ch else "DENIED: " + str(e2))]
        notes = llm(t, "You write short, friendly release notes.", f"Draft release notes (markdown, 5 lines max) from these merged PRs and changelog:\nPRs: {prs}\nChangelog: {ch}")
        body = f"Release notes draft:\n{notes}\n\nTool calls:\n" + "\n".join(f"- {a}: {b}" for a, b in log)
    return body

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj):
        b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self):
        if self.path.startswith("/.well-known/agent-card.json") or self.path.startswith("/.well-known/agent.json"): return self.send(200, CARD)
        self.send(200, {"ok": True, "agent": CARDS["id"]})
    def do_POST(self):
        n = int(self.headers.get("content-length", 0)); req = json.loads(self.rfile.read(n) or b"{}"); rid = req.get("id")
        auth = self.headers.get("Authorization", "")
        if req.get("method") == "tasks/get":
            t = TASKS.get(req.get("params", {}).get("id")); return self.send(200, {"jsonrpc": "2.0", "id": rid, "result": t} if t else {"jsonrpc": "2.0", "id": rid, "error": {"code": -32001, "message": "Task not found"}})
        if req.get("method") not in ("message/send", "message/stream"): return self.send(200, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "Method not found"}})
        if not auth.lower().startswith("bearer "): return self.send(401, {"jsonrpc": "2.0", "id": rid, "error": {"code": -32000, "message": "Bearer token required"}})
        parts = req.get("params", {}).get("message", {}).get("parts", []); text = " ".join(p.get("text", "") for p in parts if p.get("kind") == "text")
        tid = str(uuid.uuid4()); ctx = req.get("params", {}).get("message", {}).get("contextId") or str(uuid.uuid4())
        try: out = run(auth[7:], text); state = "completed"
        except Exception as e: out = f"Agent error: {e}"; state = "failed"
        task = {"kind": "task", "id": tid, "contextId": ctx, "status": {"state": state, "timestamp": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())},
                "artifacts": [{"artifactId": str(uuid.uuid4()), "name": "result", "parts": [{"kind": "text", "text": out}]}], "history": []}
        TASKS[tid] = task; self.send(200, {"jsonrpc": "2.0", "id": rid, "result": task})
ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
