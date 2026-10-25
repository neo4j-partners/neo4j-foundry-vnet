#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

command -v az >/dev/null || { echo "Azure CLI (az) is required." >&2; exit 1; }
command -v azd >/dev/null || { echo "Azure Developer CLI (azd) is required." >&2; exit 1; }

cloud_name="$(az cloud show --query name --output tsv 2>/dev/null || true)"
[ "$cloud_name" = "AzureCloud" ] || {
  echo "This template currently supports AzureCloud only; active cloud: ${cloud_name:-unknown}." >&2
  exit 1
}

required_providers=(
  Microsoft.App
  Microsoft.CognitiveServices
  Microsoft.Compute
  Microsoft.ContainerService
  Microsoft.KeyVault
  Microsoft.Network
  Microsoft.OperationalInsights
)
for provider in "${required_providers[@]}"; do
  state="$(az provider show --namespace "$provider" --query registrationState --output tsv 2>/dev/null || true)"
  if [ "$state" != "Registered" ]; then
    echo "Registering required Azure resource provider ${provider}..."
    az provider register --namespace "$provider" --wait --output none
  fi
done

azd_get() {
  local value
  if value="$(azd env get-value "$1" 2>/dev/null)" && [[ "$value" != ERROR:* ]]; then
    printf '%s' "$value"
  fi
}

# Import optional non-secret local overrides.
if [ -f .env ]; then
  while IFS='=' read -r key value; do
    key="$(printf '%s' "$key" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    value="$(printf '%s' "${value:-}" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [ -z "$key" ] || [[ "$key" == \#* ]] || [ -z "$value" ] || azd env set "$key" "$value" >/dev/null
  done < .env
fi

# Downloading and running Neo4j Enterprise requires explicit acceptance of the
# Neo4j commercial license. BYO Neo4j deployments skip this acknowledgement.
configured_uri="${NEO4J_URI:-$(azd_get NEO4J_URI)}"
license_acceptance="${NEO4J_ACCEPT_LICENSE_AGREEMENT:-$(azd_get NEO4J_ACCEPT_LICENSE_AGREEMENT)}"
if [ -z "$configured_uri" ] && [ "$license_acceptance" != "yes" ]; then
  echo "The bundled database uses Neo4j Enterprise for evaluation."
  echo "Review: https://neo4j.com/licensing/"
  if [ -t 0 ]; then
    read -r -p "Accept the Neo4j license terms for this deployment? [y/N] " answer
    case "$answer" in
      y|Y|yes|YES) azd env set NEO4J_ACCEPT_LICENSE_AGREEMENT yes >/dev/null ;;
      *) echo "License not accepted. Set NEO4J_URI to use an existing private Neo4j deployment." >&2; exit 1 ;;
    esac
  else
    echo "Set NEO4J_ACCEPT_LICENSE_AGREEMENT=yes for non-interactive deployment, or set NEO4J_URI." >&2
    exit 1
  fi
fi

if [ -z "${NEO4J_AGENT_PASSWORD:-$(azd_get NEO4J_AGENT_PASSWORD)}" ]; then
  azd env set NEO4J_AGENT_PASSWORD "$(openssl rand -hex 24)" >/dev/null
  echo "Generated the read-only Neo4j MCP-user password in the local azd environment."
fi

if [ -z "$configured_uri" ]; then
  if [ -z "${NEO4J_ADMIN_PASSWORD:-$(azd_get NEO4J_ADMIN_PASSWORD)}" ]; then
    azd env set NEO4J_ADMIN_PASSWORD "$(openssl rand -hex 24)" >/dev/null
    echo "Generated the Neo4j administrator password in the local azd environment."
  fi

  if [ -z "${NEO4J_VM_SSH_PUBLIC_KEY:-$(azd_get NEO4J_VM_SSH_PUBLIC_KEY)}" ]; then
    key_path=".azure/neo4j-admin-ed25519"
    mkdir -p .azure
    if [ ! -f "$key_path.pub" ]; then
      ssh-keygen -q -t ed25519 -N '' -C 'neo4j-azd-template' -f "$key_path"
    fi
    azd env set NEO4J_VM_SSH_PUBLIC_KEY "$(<"$key_path.pub")" >/dev/null
    echo "Generated a local VM administration key under .azure/ (no SSH endpoint is exposed)."
  fi
fi

if [ -z "${AZURE_PRINCIPAL_ID:-$(azd_get AZURE_PRINCIPAL_ID)}" ]; then
  principal_id="$(az ad signed-in-user show --query id -o tsv 2>/dev/null || true)"
  [ -z "$principal_id" ] || azd env set AZURE_PRINCIPAL_ID "$principal_id" >/dev/null
fi

if [ -z "${AZURE_TENANT_ID:-$(azd_get AZURE_TENANT_ID)}" ]; then
  tenant_id="$(az account show --query tenantId -o tsv 2>/dev/null || true)"
  [ -z "$tenant_id" ] || azd env set AZURE_TENANT_ID "$tenant_id" >/dev/null
fi
