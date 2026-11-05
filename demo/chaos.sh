#!/usr/bin/env bash
# Provider-side faults on the Anthropic path (the shim sits between the gateway and api.anthropic.com).
#   demo/chaos.sh overloaded   Anthropic "overloaded" error (HTTP 500 body overloaded_error: AI Gateway 2.2 can't fail over on a real 529)
#   demo/chaos.sh rate_limit   HTTP 429        demo/chaos.sh server_error   HTTP 500
#   demo/chaos.sh hang         hangs 120 s (gateway times out at 60 s -> 504)
#   demo/chaos.sh drop [N]     provider drops the stream after ~N tokens (default 30): client gets a streamed error, request logged as failure
#   demo/chaos.sh off | state
M=${1:-state}; N=${2:-30}
call() { kubectl -n micron-aigw exec deploy/chaos-proxy -- python -c "import urllib.request;print(urllib.request.urlopen(urllib.request.Request('http://localhost:8080$1',b'$2')).read().decode())"; }
case $M in
 overloaded) call /admin/mode '{"mode":"overloaded","status":500}';;
 rate_limit|server_error|hang) call /admin/mode "{\"mode\":\"$M\"}";;
 drop) call /admin/mode "{\"mode\":\"drop\",\"after_tokens\":$N}";;
 off|ok|reset) call /admin/reset '{}';;
 state) kubectl -n micron-aigw exec deploy/chaos-proxy -- python -c "import urllib.request;print(urllib.request.urlopen('http://localhost:8080/admin/state').read().decode())";;
esac
