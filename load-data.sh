#!/usr/bin/env bash
# Loads the neutral synthetic wind-turbine graph through Azure VM Run Command.
# Neo4j has no public endpoint and no inbound SSH rule.
set -euo pipefail
cd "$(dirname "$0")"

azd_get() {
  local value
  if value="$(azd env get-value "$1" 2>/dev/null)" && [[ "$value" != ERROR:* ]]; then
    printf '%s' "$value"
  fi
}

resource_group="$(azd_get resourceGroupName)"
vm_name="$(azd_get neo4jFirstNodeVmName)"
location="$(azd_get AZURE_LOCATION)"
agent_user="$(azd_get NEO4J_AGENT_USERNAME)"
agent_user="${agent_user:-agent}"

if [ -z "$resource_group" ] || [ -z "$vm_name" ]; then
  echo "No bundled Neo4j VM was found. Run azd up first, or load BYO Neo4j through its own data path." >&2
  exit 1
fi

case "$agent_user" in
  *[!A-Za-z0-9_]*|'') echo "NEO4J_AGENT_USERNAME must match [A-Za-z0-9_]+." >&2; exit 1 ;;
esac

if [ ! -f data/seed.cypher ]; then
  echo "Generating the neutral synthetic dataset..."
  if command -v uv >/dev/null; then uv run data/generate.py; else python3 data/generate.py; fi
fi

# A short-lived staging account lets the private VM download the seed over its
# explicit NAT egress. The storage account and SAS are removed on exit.
staging_account="stload$(openssl rand -hex 7)"
cleanup() {
  az storage account delete --resource-group "$resource_group" --name "$staging_account" --yes --output none 2>/dev/null || true
}
trap cleanup EXIT

echo "Creating short-lived staging storage ${staging_account}..."
az storage account create --resource-group "$resource_group" --name "$staging_account" --location "$location" --sku Standard_LRS --output none
storage_key="$(az storage account keys list --resource-group "$resource_group" --account-name "$staging_account" --query '[0].value' --output tsv)"
az storage container create --account-name "$staging_account" --account-key "$storage_key" --name load --output none
az storage blob upload --account-name "$staging_account" --account-key "$storage_key" --container-name load --name seed.cypher --file data/seed.cypher --overwrite --output none
az storage blob upload --account-name "$staging_account" --account-key "$storage_key" --container-name load --name verify.cypher --file data/verify.cypher --overwrite --output none

expiry="$(date -u -v+3H '+%Y-%m-%dT%H:%MZ' 2>/dev/null || date -u -d '+3 hours' '+%Y-%m-%dT%H:%MZ')"
seed_sas="$(az storage blob generate-sas --account-name "$staging_account" --account-key "$storage_key" --container-name load --name seed.cypher --permissions r --expiry "$expiry" --output tsv)"
verify_sas="$(az storage blob generate-sas --account-name "$staging_account" --account-key "$storage_key" --container-name load --name verify.cypher --permissions r --expiry "$expiry" --output tsv)"
seed_url="https://${staging_account}.blob.core.windows.net/load/seed.cypher?${seed_sas}"
verify_url="https://${staging_account}.blob.core.windows.net/load/verify.cypher?${verify_sas}"

# This fragment is intentionally single-quoted so expansion happens on the VM.
# shellcheck disable=SC2016
credentials='export NEO4J_USERNAME=neo4j; export NEO4J_PASSWORD="$(/opt/kv-secret.sh neo4j-admin-password)"; CS="/opt/neo4j/bin/cypher-shell -a neo4j+ssc://localhost:7687"'

echo "Waiting for Neo4j on ${vm_name}..."
ready=0
for _ in $(seq 1 60); do
  output="$(az vm run-command invoke --resource-group "$resource_group" --name "$vm_name" --command-id RunShellScript --scripts "$credentials; \$CS 'RETURN 1' 2>&1 | tail -1" --query 'value[0].message' --output tsv 2>/dev/null || true)"
  if printf '%s\n' "$output" | grep -q '^1$'; then ready=1; break; fi
  sleep 15
done
[ "$ready" -eq 1 ] || { echo "Neo4j did not become ready. Inspect cloud-init through Azure Run Command." >&2; exit 1; }

echo "Downloading and loading the synthetic graph inside the private VM..."
az vm run-command invoke --resource-group "$resource_group" --name "$vm_name" --command-id RunShellScript --scripts "
set -euo pipefail
curl -fsSL '$seed_url' -o /tmp/seed.cypher
curl -fsSL '$verify_url' -o /tmp/verify.cypher
$credentials
\$CS -f /tmp/seed.cypher
\$CS -f /tmp/verify.cypher
" --query 'value[0].message' --output tsv

echo "Creating read-only Neo4j user '${agent_user}' for the MCP connection..."
az vm run-command invoke --resource-group "$resource_group" --name "$vm_name" --command-id RunShellScript --scripts "
set -euo pipefail
$credentials
AGENT_PASSWORD=\"\$(/opt/kv-secret.sh neo4j-agent-password)\"
\$CS -d system \"CREATE USER ${agent_user} IF NOT EXISTS SET PASSWORD '\$AGENT_PASSWORD' SET PASSWORD CHANGE NOT REQUIRED\"
\$CS -d system \"ALTER USER ${agent_user} SET PASSWORD '\$AGENT_PASSWORD' SET PASSWORD CHANGE NOT REQUIRED\" 2>/dev/null || true
\$CS -d system \"GRANT ROLE reader TO ${agent_user}\"
\$CS -d system --format plain \"SHOW USERS YIELD user, roles WHERE user = '${agent_user}' RETURN user, roles\"
" --query 'value[0].message' --output tsv

echo "Synthetic wind-turbine graph loaded; the MCP connection uses the read-only '${agent_user}' user."
