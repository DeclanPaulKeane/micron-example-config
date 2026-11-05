"""Chaos proxy (overloaded: pass {"status":503} because AI Gateway 2.2 cannot fail over on 529; real Anthropic overload is 529).
Chaos proxy in front of Anthropic. Mode ok = transparent streaming passthrough to api.anthropic.com.
Fault modes (set via POST /admin/mode {"mode": ..., "after_tokens": 1000, "count": N, "model": optional}):
  ok | overloaded (529 Anthropic overloaded_error) | rate_limit (429) | server_error (500/502/503) | hang (120 s) | drop (kill stream after N output tokens)
Faults apply only to /v1/messages. Optional "count" limits how many requests are faulted; "model" limits to one model.
State is in memory; POST /admin/reset restores ok. GET /admin/state shows mode + counters."""
import asyncio, json, os, time
import aiohttp
from aiohttp import web

UPSTREAM = os.environ.get("UPSTREAM", "https://api.anthropic.com")
state = {"mode": "ok", "overload_status": 529, "after_tokens": 1000, "count": None, "model": None, "hits": 0, "faulted": 0}
HOP = {"host", "content-length", "transfer-encoding", "connection", "keep-alive", "accept-encoding"}

def err(status, typ, msg):
    return web.json_response({"type": "error", "error": {"type": typ, "message": msg}}, status=status)

async def admin(req):
    if req.path == "/admin/reset":
        state.update(mode="ok", count=None, model=None, hits=0, faulted=0)
    elif req.path == "/admin/mode":
        body = await req.json(); state.update(mode=body.get("mode", "ok"), overload_status=body.get("status", 529), after_tokens=body.get("after_tokens", 1000),
                                              count=body.get("count"), model=body.get("model"), hits=0, faulted=0)
    return web.json_response(state)

async def proxy(req):
    body = await req.read()
    print(req.method, req.path_qs, flush=True)
    is_msg = req.path.endswith("/v1/messages") and req.method == "POST"
    model = None
    if is_msg:
        try: model = json.loads(body).get("model")
        except ValueError: pass
    mode = state["mode"]
    active = is_msg and mode != "ok" and (state["model"] in (None, model)) and (state["count"] is None or state["faulted"] < state["count"])
    if active and mode != "drop":
        state["faulted"] += 1
        if mode == "overloaded": return err(state["overload_status"], "overloaded_error", "Overloaded")
        if mode == "rate_limit":
            r = err(429, "rate_limit_error", "Number of request tokens has exceeded your per-minute rate limit"); r.headers["retry-after"] = "5"; return r
        if mode == "server_error": return err(500, "api_error", "Internal server error")
        if mode == "hang": await asyncio.sleep(120); return err(504, "api_error", "upstream timeout")
    if active: state["faulted"] += 1
    headers = {k: v for k, v in req.headers.items() if k.lower() not in HOP}
    SEAL = b'\n\nevent: error\ndata: {"type":"error","error":{"type":"api_error","message":"Upstream provider connection dropped mid-stream"}}\n\n'
    async with aiohttp.ClientSession(timeout=aiohttp.ClientTimeout(total=None)) as s:
        async with s.request(req.method, UPSTREAM + req.path_qs, data=body, headers=headers) as up:
            resp = web.StreamResponse(status=up.status, headers={k: v for k, v in up.headers.items() if k.lower() not in HOP | {"content-encoding"}})
            await resp.prepare(req)
            out_chars = 0; started = False
            try:
                async for chunk in up.content.iter_any():
                    await resp.write(chunk); started = True
                    if active and mode == "drop":
                        out_chars += chunk.count(b"content_block_delta") * 10      # ~10 tokens per streamed delta (text, thinking or tool input)
                        if out_chars >= state["after_tokens"]:
                            await resp.write(SEAL); await resp.write_eof(); return resp   # simulated provider drop, sealed with a streamed error
            except (aiohttp.ClientPayloadError, aiohttp.ClientConnectionError, asyncio.TimeoutError):
                if started: await resp.write(SEAL)                                  # REAL upstream drop mid-stream: seal it the same way
            await resp.write_eof(); return resp

app = web.Application(client_max_size=1024**3)
app.router.add_route("*", "/admin/{x:.*}", admin)
app.router.add_route("*", "/{p:.*}", proxy)
web.run_app(app, port=8080, print=None)
