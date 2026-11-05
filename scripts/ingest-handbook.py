#!/usr/bin/env python3
"""Index data/handbook/*.md into the AI RAG Injector's Redis index (collection 'engineering-handbook').
The AI Gateway has no ingest API, so this writes the plugin's own layout: JSON docs under 'kong_rag_injector:' with
$.vector (OpenAI text-embedding-3-small, 1536), $.payload (text) and $.metadata.{source,date,tags,collection}.
Usage: scripts/ingest-handbook.py   (needs kubectl; port-forwards redis temporarily)"""
import glob, json, os, re, subprocess, time, uuid, urllib.request
import redis
ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
env = dict(re.findall(r'^(?:export )?([A-Z_0-9]+)=(.*)$', open(f"{ROOT}/secrets.yaml").read(), re.M))
pf = subprocess.Popen(["kubectl", "-n", "micron-aigw", "port-forward", "svc/redis", "16379:6379"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); time.sleep(3)
try:
    r = redis.Redis(port=16379, password=env["REDIS_PASSWORD"].strip(), decode_responses=True)
    for k in r.scan_iter("kong_rag_injector:*"): r.delete(k)          # idempotent re-index
    n = 0
    for f in sorted(glob.glob(f"{ROOT}/data/handbook/*.md")):
        text = open(f).read(); title = text.splitlines()[0].lstrip("# ").strip()
        chunks = [c.strip() for c in re.split(r"\n\s*\n|\n(?=- )", text) if len(c.strip()) > 40] or [text]
        # keep bullets of a section together: merge consecutive short chunks under the heading
        merged, cur = [], ""
        for c in chunks:
            if len(cur) + len(c) < 700: cur += ("\n" if cur else "") + c
            else: merged.append(cur); cur = c
        if cur: merged.append(cur)
        for c in merged:
            body = json.dumps({"model": "text-embedding-3-small", "input": c}).encode()
            emb = json.load(urllib.request.urlopen(urllib.request.Request("https://api.openai.com/v1/embeddings", body, {"Authorization": "Bearer " + env["OPENAI_KEY"].strip(), "Content-Type": "application/json"})))["data"][0]["embedding"]
            doc = {"vector": emb, "payload": f"[{title}] {c}", "metadata": {"source": os.path.basename(f), "date": int(time.time()), "tags": ["handbook", "engineering"], "collection": "engineering-handbook"}}
            r.execute_command("JSON.SET", f"kong_rag_injector:{uuid.uuid4()}", "$", json.dumps(doc)); n += 1
    print("indexed chunks:", n)
finally:
    pf.terminate()
