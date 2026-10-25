#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")"

command -v azd >/dev/null || {
  echo "Install azd: https://learn.microsoft.com/azure/developer/azure-developer-cli/install-azd" >&2
  exit 1
}

# This wrapper is optional; `azd up` directly follows the same hooks.
azd up "$@"

cat <<'EOF'

Next steps:
  ./load-data.sh
  ./test-private.sh
  uv run agent/create_and_test_agent.py

The Foundry endpoint is private by default. Run the agent test from a machine
with VNet connectivity, or set FOUNDRY_PUBLIC_NETWORK_ACCESS=Enabled before a
fresh deployment for an evaluation environment.
EOF
