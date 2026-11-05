"""Budget watcher + notification sink (demo).
 - Every 5 s reads the budget counters the AI Rate Limiting Advanced policy keeps in Redis ('<start>:<window>:<id>:fractions', field policy:N).
 - Sends a warning at 80 % and a notice at 100 % once per window and budget (Teams webhook if TEAMS_WEBHOOK_URL is set, else notification feed).
 - Reverts time-limited budget exceptions when they expire (Redis hash micron:exceptions, set by scripts/grant-exception.sh).
 - Watch-only budgets (config 'watch_only'): reports WOULD-BLOCK without blocking, using Konnect AI Cost Management spend.
 - GET /notifications (HTML) | /notifications.json | /budgets | /healthz ; POST /notify (other components)."""
import json, os, threading, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import redis

R = redis.Redis(host=os.environ.get("REDIS_HOST", "redis"), password=os.environ["REDIS_PASSWORD"], decode_responses=True)
CFG = json.load(open("/config/budgets.json"))
TEAMS = os.environ.get("TEAMS_WEBHOOK_URL", "")
PAT, GW = os.environ.get("PAT", ""), os.environ.get("GW_ID", "")
FEED = []   # newest first
def notify(level, text):
    R.lpush("micron:feed", json.dumps({"ts": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()), "level": level, "text": text})); R.ltrim("micron:feed", 0, 199)
    print(level, text, flush=True)
    if TEAMS:
        try: urllib.request.urlopen(urllib.request.Request(TEAMS, json.dumps({"text": f"[{level}] {text}"}).encode(), {"Content-Type": "application/json"}), timeout=5)
        except Exception as e: print("teams error", e, flush=True)

def feed(): return [json.loads(x) for x in R.lrange("micron:feed", 0, 199)]

def usage():
    out = {}
    for k in R.scan_iter("*:fractions"):
        for f, v in R.hgetall(k).items():
            if f.startswith("policy:"): out[(f, k.split(":")[1], k.split(":")[0])] = float(v)
    res = {}
    for (f, win, start), v in out.items(): res[f] = res.get(f, 0) + v
    return res

def konnect(method, path, body=None):
    req = urllib.request.Request("https://us.api.konghq.com" + path, method=method, data=json.dumps(body).encode() if body is not None else None,
                                 headers={"Authorization": "Bearer " + PAT, "Content-Type": "application/json"})
    with urllib.request.urlopen(req, timeout=20) as r: d = r.read(); return json.loads(d) if d else {}

def revert_exceptions():
    for user, raw in R.hgetall("micron:exceptions").items():
        e = json.loads(raw)
        if time.time() < e["expires"]: continue
        try:
            pols = konnect("GET", f"/v1/ai-gateways/{GW}/policies")["data"]; pol = [p for p in pols if p["name"] == "budgets"][0]
            body = {k: v for k, v in pol.items() if k not in ("id", "created_at", "updated_at")}
            lim = body["config"]["policies"][e["index"]]["limits"][0]; lim["limit"] = e["original"]
            konnect("PUT", f"/v1/ai-gateways/{GW}/policies/{pol['id']}", body)
            R.hdel("micron:exceptions", user); notify("info", f"Budget exception for {user} expired; limit restored to ${e['original']}.")
        except Exception as ex: print("revert failed", ex, flush=True)

def watch_only():
    for b in CFG.get("watch_only", []):
        try:
            now = time.gmtime(); frm = time.strftime("%Y-%m-%dT00:00:00Z", now); to = time.strftime("%Y-%m-%dT%H:%M:%SZ", now)
            ep = R.get("micron:epoch")
            if ep and ep > frm: frm = ep      # spend since the last reset (demo epoch)
            q = {"from": frm, "to": to, "dimensions": ["tags." + b["tag"]], "measures": ["events", "reported_cost"],
                 "filters": {"source": {"eq": f"//control-planes/{GW}"}}}
            rows = konnect("POST", "/v1/ai-cost-management/events/query", q)["data"]
            spent = sum(float(r["measures"]["reported_cost"]["value"]) for r in rows if r["dimensions"].get("tags." + b["tag"]) == b["value"])
        except Exception as ex:
            spent = None; print("watch-only query failed", ex, flush=True)
        if spent is None: continue
        b["_spent"] = spent
        if spent >= b["limit"]:
            key = f"micron:wo:{b['name']}:{time.strftime('%Y-%m-%d')}"
            if not R.sismember("micron:notified", key):
                R.sadd("micron:notified", key)
                notify("watch-only", f"WOULD BLOCK (watch-only, not enforced): {b['name']} spent ${spent:.2f} of ${b['limit']:.2f} for today.")

MCP_SERVERS = ["ticketing", "code-search", "hr-records"]
def mcp_tools(server):
    h = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream"}
    def rpc(msg, sid=None):
        hh = dict(h); 
        if sid: hh["mcp-session-id"] = sid
        r = urllib.request.urlopen(urllib.request.Request(f"http://mcp-{server}.micron-aigw.svc.cluster.local/mcp", json.dumps(msg).encode(), hh), timeout=10)
        body = r.read().decode(); sid2 = r.headers.get("mcp-session-id")
        for line in body.splitlines():
            if line.startswith("data:"): body = line[5:].strip(); break
        return sid2, (json.loads(body) if body.strip() else {})
    sid, _ = rpc({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-03-26", "capabilities": {}, "clientInfo": {"name": "ops-watcher", "version": "1"}}})
    rpc({"jsonrpc": "2.0", "method": "notifications/initialized"}, sid)
    _, r = rpc({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, sid)
    return {t["name"]: t.get("description", "") for t in r.get("result", {}).get("tools", [])}

def set_blocked(tools):
    """Rewrite the MCP block list inside the edge-guard policy (the gateway then refuses those tools)."""
    pols = konnect("GET", f"/v1/ai-gateways/{GW}/policies")["data"]; pol = [p for p in pols if p["name"] == "edge-guard"][0]
    body = {k: v for k, v in pol.items() if k not in ("id", "created_at", "updated_at")}
    lua = body["config"]["rewrite"][0]
    a, b = lua.index("-- MCPBLOCK-BEGIN"), lua.index("-- MCPBLOCK-END")
    lines = "".join(f'    ["{t}"] = true,\n' for t in sorted(tools))
    body["config"]["rewrite"][0] = lua[:a] + "-- MCPBLOCK-BEGIN\n" + lines + "    " + lua[b:]
    konnect("PUT", f"/v1/ai-gateways/{GW}/policies/{pol['id']}", body)

def mcp_watch():
    blocked = set(R.smembers("micron:mcp:blocked"))
    for srv in MCP_SERVERS:
        try: tools = mcp_tools(srv)
        except Exception as e: print("mcp watch", srv, e, flush=True); continue
        for name, desc in tools.items():
            h = __import__("hashlib").sha256(desc.encode()).hexdigest()[:16]; key = f"{srv}/{name}"
            base = R.hget("micron:mcp:baseline", key)
            if base is None: R.hset("micron:mcp:baseline", key, h); continue
            if base != h and key not in blocked:
                R.sadd("micron:mcp:blocked", key); blocked.add(key); set_blocked(blocked)
                notify("security", f"MCP tool description CHANGED: {key} (approved hash {base}, now {h}). Tool blocked at the gateway until reviewed. New description: {desc[:140]!r}")
            elif base == h and key in blocked:
                R.srem("micron:mcp:blocked", key); blocked.discard(key); set_blocked(blocked); notify("info", f"MCP tool {key} matches its approved description again; unblocked.")

def loop():
    while True:
        try:
            u = usage()
            for b in CFG["budgets"]:
                used = u.get(f"policy:{b['policy']}", 0); b["_used"] = used
                for pct, lvl in ((80, "warning"), (100, "blocked")):
                    if used >= b["limit"] * pct / 100:
                        key = f"{b['policy']}:{pct}:{R.get('micron:window:' + str(b['policy'])) or ''}:{int(time.time() // b['window'])}"
                        if not R.sismember("micron:notified", key):
                            R.sadd("micron:notified", key)
                            notify(lvl, f"{b['name']}: {pct}% of budget reached (${used:.2f} of ${b['limit']:.2f})." + (" New requests are refused until the window resets or an exception is granted." if pct == 100 else ""))
            revert_exceptions(); watch_only(); mcp_watch()
        except Exception as e: print("loop error", e, flush=True)
        time.sleep(5)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, body, ctype="application/json"):
        self.send_response(code); self.send_header("Content-Type", ctype); self.end_headers(); self.wfile.write(body.encode() if isinstance(body, str) else body)
    def do_GET(self):
        if self.path.startswith("/notifications.json"): return self.send(200, json.dumps(feed()))
        if self.path.startswith("/notifications"):
            rows = "".join(f"<tr><td>{f['ts']}</td><td><b>{f['level']}</b></td><td>{f['text']}</td></tr>" for f in feed())
            return self.send(200, f"<html><meta http-equiv=refresh content=5><body style='font-family:sans-serif'><h2>Budget notifications</h2><table cellpadding=6>{rows}</table></body></html>", "text/html")
        if self.path.startswith("/budgets"): return self.send(200, json.dumps([{k: v for k, v in b.items()} for b in CFG["budgets"]] + CFG.get("watch_only", [])))
        self.send(200, "ok")
    def do_POST(self):
        n = int(self.headers.get("content-length", 0)); b = json.loads(self.rfile.read(n) or b"{}")
        if self.path == "/notify": notify(b.get("level", "info"), b.get("text", ""))
        self.send(200, "{}")

threading.Thread(target=loop, daemon=True).start()
ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
