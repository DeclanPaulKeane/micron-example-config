#!/usr/bin/env bash
# Start Claude Code against the Micron gateway as a demo user, with an isolated config dir (never touches ~/.claude).
# Usage: clients/claude-code/run.sh usera [claude args...]     (sign in first: MICRON_USER=usera python3 clients/okta_token.py login)
set -euo pipefail
R="$(cd "$(dirname "$0")/../.." && pwd)"; U=${1:-usera}; shift || true
D="$R/.state/claude-$U"; mkdir -p "$D"
PRE=${MICRON_ROUTE:-/anthropic}; [ -z "${MICRON_ROUTE:-}" ] && [ "$U" = userc ] && PRE=/sandbox/anthropic;   # per-team route
sed "s#__REPO__#$R#g; s#/anthropic\"#$PRE\"#" "$R/clients/claude-code/settings.json" > "$D/settings.json"
export MICRON_USER=$U CLAUDE_CONFIG_DIR="$D"
unset ANTHROPIC_API_KEY ANTHROPIC_AUTH_TOKEN
exec claude --settings "$D/settings.json" "$@"
