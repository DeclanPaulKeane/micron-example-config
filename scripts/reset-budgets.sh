#!/usr/bin/env bash
# Zero all budget counters (rate-limit keys look like <epoch>:<window_seconds>:<id>) without touching cache/RAG data in Redis.
set -euo pipefail
cd "$(dirname "$0")/.."; set -a; . ./secrets.yaml; set +a
kubectl -n micron-aigw exec deploy/redis -- sh -c "redis-cli -a '$REDIS_PASSWORD' --no-auth-warning --scan --pattern '[0-9]*:[0-9]*:*' | xargs -r redis-cli -a '$REDIS_PASSWORD' --no-auth-warning del" | sed 's/^/budget counters deleted: /'
