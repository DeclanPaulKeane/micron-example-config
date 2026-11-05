#!/usr/bin/env bash
# Delete cached semantic-cache answers (not the RAG index, not budgets).
cd "$(dirname "$0")/.."; set -a; . ./secrets.yaml; set +a
kubectl -n micron-aigw exec deploy/redis -- sh -c "redis-cli -a '$REDIS_PASSWORD' --no-auth-warning --scan --pattern 'semantic_cache:*' | while read k; do redis-cli -a '$REDIS_PASSWORD' --no-auth-warning del \"\$k\" >/dev/null; done; echo flushed"
