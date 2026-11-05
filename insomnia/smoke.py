#!/usr/bin/env python3
"""Runs requests from micron-demo.insomnia.json the way Insomnia would (substitutes {{ _.var }}) to prove the collection works.
Usage: python3 insomnia/smoke.py [name-substring ...]   (default: a representative sample)"""
import json, re, sys, urllib.request, urllib.error, urllib.parse, pathlib
here = pathlib.Path(__file__).parent
ex = json.load(open(here / "micron-demo.insomnia.json"))["resources"]
env = dict(next(r for r in ex if r["_id"] == "env_base")["data"])
sub = lambda s: re.sub(r"\{\{\s*_\.(\w+)\s*\}\}", lambda m: str(env.get(m.group(1), "")), s)
for _ in range(2): env = {k: sub(v) if isinstance(v, str) else v for k, v in env.items()}
want = sys.argv[1:] or ["Get token: User A", "Get token: User B", "A: Haiku", "B (Finance): Opus", "C on the main route", "Model list: User A", "Model list: User B", "count_tokens", "dated Sonnet", "Unknown model", "No token", "Embedding (User C)", "Embedding as User B", "agent card: Ticket", "Ticketing MCP: no token", "protected-resource", "Ticketing MCP: initialize (User A)", "Fake API key", "Prompt injection", "Automatic model choice: simple", "Expired token (expect", "Notification feed"]
reqs = [r for r in ex if r["_type"] == "request"]
for w in want:
    for r in [x for x in reqs if w.lower() in x["name"].lower()][:1]:
        h = {sub(x["name"]): sub(x["value"]) for x in r["headers"]}
        b = r["body"]; data = None
        if b.get("mimeType") == "application/json": data = sub(b["text"]).encode()
        elif b.get("params"): data = urllib.parse.urlencode({p["name"]: sub(p["value"]) for p in b["params"]}).encode()   # Content-Type must come from the request itself (as in Insomnia), not be added here
        try:
            resp = urllib.request.urlopen(urllib.request.Request(sub(r["url"]), data, h, method=r["method"]), timeout=90); code, body = resp.status, resp.read().decode()
        except urllib.error.HTTPError as e: code, body = e.code, e.read().decode()
        if r.get("afterResponseScript") and "token_" in r["afterResponseScript"] and code == 200:
            tk = json.loads(body)["access_token"]; env["token_" + re.search(r"token_(user\w)", r["afterResponseScript"]).group(1)] = tk
        snippet = re.sub(r"\s+", " ", body)[:110].replace(env.get("demo_password", "~~"), "***")
        print(f"{code}  {r['name'][:62]:62}  {snippet if 'access_token' not in body else '(token issued)'}")
