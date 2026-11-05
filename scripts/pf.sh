#!/usr/bin/env bash
# (Re)start local port-forwards: gateway 18000, chaos proxy 28080, mcp-ticketing 28081. Idempotent.
cd "$(dirname "$0")/.."
pkill -f "micron-aigw port-forward" 2>/dev/null; sleep 1
kubectl -n micron-aigw port-forward svc/aigw-dp 18000:80 >/dev/null 2>&1 &
kubectl -n micron-aigw port-forward svc/chaos-proxy 28080:80 >/dev/null 2>&1 &
kubectl -n micron-aigw port-forward svc/mcp-ticketing 28081:80 >/dev/null 2>&1 &
kubectl -n micron-aigw port-forward svc/budget-watcher 18082:80 >/dev/null 2>&1 &
for i in $(seq 1 30); do c=$(curl -s -o /dev/null -w "%{http_code}" -m 3 localhost:18000/anthropic/v1/models); [ "$c" != 000 ] && break; sleep 2; done
echo "port-forwards up (gateway probe: $c)"
