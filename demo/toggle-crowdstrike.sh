#!/usr/bin/env bash
# Make CrowdStrike AIDR "unreachable" (or back). Usage: demo/toggle-crowdstrike.sh down|up|slow
M=${1:-down}; [ "$M" = up ] && M=ok
kubectl -n micron-aigw exec deploy/aidr-proxy -- python -c "import urllib.request,json;print(urllib.request.urlopen(urllib.request.Request('http://localhost:8080/admin/mode',json.dumps({'mode':'$M'}).encode())).read().decode())"
