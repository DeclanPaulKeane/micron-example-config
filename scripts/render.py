#!/usr/bin/env python3
"""Render a konnect/*.yaml to .state/rendered/: expands __INCLUDE:path__ (indented to the marker) and __AWS_ASSUME_ROLE_ARN__."""
import os, re, sys
root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
env = dict(re.findall(r'^(?:export )?([A-Z_0-9]+)=(.*)$', open(f"{root}/secrets.yaml").read(), re.M))
import json
okta = json.load(open(f"{root}/.state/okta.json"))
src = sys.argv[1]; out = []
for line in open(src).read().split("\n"):
    m = re.match(r"^(\s*)__INCLUDE:(.+)__\s*$", line)
    if m:
        out += [m.group(1) + l.replace("__OKTA_ISSUER__", okta["issuer"]).replace("__OKTA_CLIENT_ID__", okta["client_id"]) if l.strip() else "" for l in open(f"{root}/{m.group(2)}").read().rstrip("\n").split("\n")]
    else:
        out.append(line.replace("__AWS_ASSUME_ROLE_ARN__", env["AWS_ASSUME_ROLE_ARM"].strip()).replace("__OKTA_ISSUER__", okta["issuer"]).replace("__OKTA_CLIENT_ID__", okta["client_id"]))
os.makedirs(f"{root}/.state/rendered", exist_ok=True)
dst = f"{root}/.state/rendered/{os.path.basename(src)}"; open(dst, "w").write("\n".join(out)); print(dst)
