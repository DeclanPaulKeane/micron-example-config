"""Security-check broker between Kong's ai-custom-guardrail policy and CrowdStrike AIDR.
POST /check?route=engineering|sandbox   body {"text": "...", "user": "...", "request_id": "..."}
  -> {"blocked": bool, "check": "crowdstrike-aidr:<detector>", "message": "..."}   (HTTP 503 when the service is 'down' or unreachable)
Admin: POST /admin/mode {"mode": "ok|down|slow"}  (down = pretend CrowdStrike is unreachable; slow = hang past the gateway timeout)  GET /admin/state
Every decision is logged to Loki (app=kong-security) with the check that made it; unavailable events on the sandbox route are logged as FLAGGED."""
import json, os, re, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
AIDR = os.environ["AIDR_URL"].rstrip("/") + "/v1/guard_chat_completions"; KEY = os.environ["AIDR_KEY"]
LOKI = "http://loki:3100/loki/api/v1/push"; state = {"mode": "ok"}

def loki(labels, line):
    try:
        urllib.request.urlopen(urllib.request.Request(LOKI, json.dumps({"streams": [{"stream": labels, "values": [[str(time.time_ns()), json.dumps(line)]]}]}).encode(), {"Content-Type": "application/json"}), timeout=3)
    except Exception as e: print("loki push failed", e, flush=True)

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def send(self, code, obj): b = json.dumps(obj).encode(); self.send_response(code); self.send_header("Content-Type", "application/json"); self.send_header("Content-Length", str(len(b))); self.end_headers(); self.wfile.write(b)
    def do_GET(self): self.send(200, state)
    def do_POST(self):
        n = int(self.headers.get("content-length", 0)); body = json.loads(self.rfile.read(n) or b"{}")
        if self.path.startswith("/admin/mode"): state["mode"] = body.get("mode", "ok"); return self.send(200, state)
        route = "sandbox" if str(body.get("path", "")).startswith("/sandbox") else "engineering"   # route decided from the request path sent by the gateway
        base = {"user": body.get("user"), "request_id": body.get("request_id"), "route": route}
        if state["mode"] == "down":
            loki({"app": "kong-security", "route": route, "decision": "unavailable"}, {**base, "check": "crowdstrike-aidr", "decision": "unavailable", "detail": "CrowdStrike AIDR unreachable (toggle)",
                 "flagged": route == "sandbox", "action": "fail-open (allowed, FLAGGED)" if route == "sandbox" else "fail-closed (refused)"})
            if route == "sandbox": return self.send(200, {"blocked": False, "check": "crowdstrike-aidr", "flagged": True, "message": "allowed: security service unavailable, sandbox route fails open (flagged)"})
            return self.send(503, {"error": "AIDR unreachable"})
        if state["mode"] == "slow": time.sleep(30)
        text = body.get("text", "")
        # Claude Code injects <system-reminder> blocks (user email, env, memory, git status) into the user message: not user-authored, so not inspected
        text = re.sub(r"<system-reminder>.*?</system-reminder>", "", text, flags=re.S).strip() or "(no user-authored text)"
        if len(text) > 30000: text = text[:15000] + "\n...[truncated by broker for inspection]...\n" + text[-15000:]   # truncate: keep head+tail
        try:
            req = urllib.request.Request(AIDR, json.dumps({"guard_input": {"messages": [{"role": "user", "content": text}]}, "event_type": "input"}).encode(), {"Authorization": "Bearer " + KEY, "Content-Type": "application/json"})
            r = json.load(urllib.request.urlopen(req, timeout=8)); res = r.get("result", {})
        except Exception as e:
            loki({"app": "kong-security", "route": route, "decision": "unavailable"}, {**base, "check": "crowdstrike-aidr", "decision": "unavailable", "detail": str(e)[:200], "flagged": route == "sandbox"})
            if route == "sandbox": return self.send(200, {"blocked": False, "check": "crowdstrike-aidr", "flagged": True, "message": "allowed: security service error, sandbox route fails open (flagged)"})
            return self.send(503, {"error": str(e)[:200]})
        blocked = bool(res.get("blocked")); summary = r.get("summary", "")
        det = ""
        for d, v in (res.get("detectors") or {}).items():
            if isinstance(v, dict) and v.get("detected"): det = d; break
        check = "crowdstrike-aidr:" + (det or ("malicious_prompt" if "Malicious" in summary else "secret_and_key_entity" if "Secret" in summary else "confidential_and_pii_entity" if "PII" in summary else "policy"))
        msg = f"Blocked by security check CrowdStrike AIDR: {summary.strip()}" if blocked else "allowed"
        loki({"app": "kong-security", "route": route, "decision": "blocked" if blocked else "allowed"}, {**base, "check": check if blocked else "crowdstrike-aidr", "decision": "blocked" if blocked else "allowed", "verdict": summary, "chars": len(text)})
        self.send(200, {"blocked": blocked, "check": check, "message": msg})
ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
