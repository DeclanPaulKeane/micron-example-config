"""Receives Kong http-log batches (JSON array or object per request), flattens the useful fields and pushes them to Loki.
Labels: app=kong-access, gateway=micron-aigw, status_class, error_source. Everything else is in the JSON line (query with | json)."""
import json, time, urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
LOKI = "http://loki:3100/loki/api/v1/push"

def g(d, *path, default=None):
    for p in path:
        if not isinstance(d, dict) or p not in d: return default
        d = d[p]
    return d

def flatten(e):
    h = g(e, "request", "headers", default={}) or {}
    ai = g(e, "ai", default={}) or {}
    prox = ai.get("proxy", ai) if isinstance(ai, dict) else {}
    meta = g(prox, "meta", default={}) or {}; usage = g(prox, "usage", default={}) or {}
    st = g(e, "response", "status", default=0)
    failed_stream = bool(e.get("micron_stream_failed"))
    if failed_stream and st < 400: st = 599          # interrupted stream: a FAILURE even though HTTP 200 had already been sent
    src = "none"
    if st >= 400:
        src = "provider" if failed_stream else "provider" if (meta.get("provider_name") and (g(e, "latencies", "proxy", default=0) or 0) > 0 and not g(e, "response", "headers", "x-micron-error-source")) else "gateway"
    return {
        "ts": e.get("started_at"), "request_id": g(e, "request", "id") or h.get("x-kong-request-id"), "status": st, "method": g(e, "request", "method"),
        "path": g(e, "request", "uri"), "route": g(e, "route", "name"), "user": h.get("x-budget-user") or h.get("x-micron-caller"), "dept": h.get("x-budget-dept"), "team": h.get("x-budget-team"),
        "agent": h.get("x-budget-agent"), "client_ua": h.get("user-agent"), "provider": meta.get("provider_name"), "model": meta.get("request_model"),
        "response_model": meta.get("response_model"), "llm_latency_ms": meta.get("llm_latency"), "prompt_tokens": usage.get("prompt_tokens"),
        "completion_tokens": usage.get("completion_tokens"), "total_tokens": usage.get("total_tokens"), "cost": usage.get("cost"),
        "cache_read_tokens": usage.get("cache_read_tokens"), "kong_latency_ms": g(e, "latencies", "kong"), "proxy_latency_ms": g(e, "latencies", "proxy"),
        "request_latency_ms": g(e, "latencies", "request"), "cache_status": g(prox, "cache", "cache_status"), "rag_injected": g(prox, "rag-inject", "injected"), "rag_chunks": len(g(prox, "rag-inject", "chunk_ids", default=[]) or []),
        "service_tier": e.get("micron_service_tier"),
        "error_source": src, "stream_failed": failed_stream, "stream_est_tokens": e.get("micron_stream_est_tokens"), "security_check": e.get("micron_security_check"), "size_bytes": g(e, "request", "size"), "ai_raw": ai,
    }

class H(BaseHTTPRequestHandler):
    def log_message(self, *a): pass
    def do_POST(self):
        n = int(self.headers.get("content-length", 0)); body = json.loads(self.rfile.read(n) or b"[]")
        events = body if isinstance(body, list) else [body]
        streams = {}
        for e in events:
            f = flatten(e); st = f["status"] or 0
            labels = (("app", "kong-access"), ("gateway", "micron-aigw"), ("status_class", f"{st // 100}xx"), ("error_source", f["error_source"]), ("security_check", f["security_check"] or "none"))
            ts = str(int((f["ts"] or time.time() * 1000) * 1_000_000)) if (f["ts"] or 0) > 1e12 else str(time.time_ns())
            streams.setdefault(labels, []).append([ts, json.dumps(f, default=str)])
        payload = {"streams": [{"stream": dict(k), "values": v} for k, v in streams.items()]}
        try: urllib.request.urlopen(urllib.request.Request(LOKI, json.dumps(payload).encode(), {"Content-Type": "application/json"}), timeout=5)
        except Exception as ex: print("loki push failed", ex, flush=True)
        print("ingested", len(events), flush=True); self.send_response(200); self.end_headers()
ThreadingHTTPServer(("0.0.0.0", 8080), H).serve_forever()
