# source me: loads secrets.yaml and exports kongctl auth
cd "$(dirname "${BASH_SOURCE[0]}")/.." || return
set -a; . ./secrets.yaml >/dev/null 2>&1; set +a
export KONGCTL_DEFAULT_KONNECT_PAT="$PAT" KONGCTL_DEFAULT_KONNECT_REGION="${KONNECT_REGION:-us}"
