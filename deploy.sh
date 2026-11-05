#!/usr/bin/env bash
# Deploy everything from scratch (idempotent). Needs secrets.yaml (see secrets.yaml.template) and a working kube context.
set -euo pipefail
cd "$(dirname "$0")"; . scripts/env.sh
kubectl get ns micron-aigw >/dev/null 2>&1 || kubectl create namespace micron-aigw
[ -f .state/venv/bin/python ] || { python3 -m venv .state/venv && .state/venv/bin/pip install -q reportlab imageio imageio-ffmpeg numpy pillow redis requests; }
[ -d data/pdfs ] || .state/venv/bin/python data/generate.py
scripts/load-secrets.sh
python3 identity/02-okta-setup.py >/dev/null; python3 identity/03-okta-agents.py >/dev/null
scripts/load-secrets.sh
# gateway control plane + data-plane certificate
kongctl apply -f konnect/00-gateway.yaml --auto-approve
GW=$(kongctl get ai-gateways -o json | jq -r '.[]|select(.name=="micron-aigw")|.id'); echo "$GW" > .state/gw_id
mkdir -p .state/dp; [ -f .state/dp/tls.crt ] || { openssl req -new -x509 -nodes -newkey rsa:2048 -subj "/CN=kong_clustering" -keyout .state/dp/tls.key -out .state/dp/tls.crt -days 365 2>/dev/null; kongctl api post "/v1/ai-gateways/$GW/data-plane-certificates" title=micron-k8s-dp "cert=$(cat .state/dp/tls.crt)" >/dev/null; }
kubectl -n micron-aigw create secret tls dp-cluster-cert --cert=.state/dp/tls.crt --key=.state/dp/tls.key --dry-run=client -o yaml | kubectl apply -f -
kubectl -n micron-aigw create configmap micron-config --from-literal=GW_ID="$GW" --dry-run=client -o yaml | kubectl apply -f -
for c in "chaos-proxy-app mocks/chaos-proxy/app.py" "mcp-app mocks/mcp/server.py" "budget-watcher-app mocks/budget-watcher/app.py" "log-ingest-app mocks/log-ingest/app.py" "aidr-proxy-app mocks/aidr-proxy/app.py" "agents-app mocks/agents/agent.py"; do set -- $c
  kubectl -n micron-aigw create configmap $1 --from-file=app.py=$2 --dry-run=client -o yaml | sed "s#app.py:#$(basename $2):#" | kubectl apply -f -; done
kubectl -n micron-aigw create configmap budget-watcher-config --from-file=budgets.json=konnect/budgets.json --dry-run=client -o yaml | kubectl apply -f -
python3 grafana/gen.py
# DP endpoints are templated into k8s/40-aigw-dp.yaml at first creation (CP/telemetry hosts of THIS gateway): regenerate if the gateway was recreated
for f in k8s/10-observability.yaml k8s/20-redis.yaml k8s/40-aigw-dp.yaml k8s/50-chaos-proxy.yaml k8s/60-mcp-mocks.yaml k8s/70-budget-watcher.yaml k8s/80-log-ingest.yaml k8s/85-aidr-proxy.yaml k8s/90-dashboards.json k8s/95-agents.yaml; do kubectl apply -f $f; done
kubectl apply -f k8s/30-ingress.yaml   # after its backend Services exist, or the GCE controller stalls on "could not find service"
# a fresh GCE ingress takes a few minutes to get its IP
for i in $(seq 1 60); do [ -n "$(kubectl -n micron-aigw get ingress micron-ingress -o jsonpath='{.status.loadBalancer.ingress[0].ip}')" ] && break; sleep 10; done
scripts/dns-sync.sh
scripts/bootstrap-vault.sh
scripts/apply.sh
scripts/api-models.sh; scripts/api-openai-models.sh
scripts/deploy-cost-attribution.sh; scripts/native-budgets.sh
.state/venv/bin/python scripts/ingest-handbook.py
scripts/pf.sh
echo "Deployed. Next: ./reset-demo.sh && demo/preflight.sh"
