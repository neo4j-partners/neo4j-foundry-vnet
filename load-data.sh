#!/usr/bin/env bash
# Load the synthetic wind-turbine digital-twin graph into the private Neo4j.
#
# The database has no public endpoint, so we never connect to it from here.
# Instead we upload the generated seed.cypher to the Azure Files share that is
# mounted at /import inside the Neo4j container, then run cypher-shell *inside*
# the container (against localhost) via `az container exec`. Nothing about the
# database is exposed to the internet at any point.
set -euo pipefail
cd "$(dirname "$0")"

command -v az >/dev/null || { echo "Missing az CLI." >&2; exit 1; }

azd_get() {
  local out
  if out="$(azd env get-value "$1" 2>/dev/null)" && [[ "$out" != ERROR:* ]]; then
    printf '%s' "$out"
  fi
}

RG="$(azd_get resourceGroupName)"
CG="$(azd_get neo4jContainerGroupName)"
SA="$(azd_get neo4jImportStorageAccount)"
SHARE="$(azd_get neo4jImportShareName)"
NEO4J_USER="$(azd_get NEO4J_USERNAME)"; NEO4J_USER="${NEO4J_USER:-neo4j}"
NEO4J_PW="$(azd_get NEO4J_PASSWORD)"

if [ -z "$CG" ]; then
  echo "No in-VNet Neo4j deployed (neo4jContainerGroupName empty). If you set an" >&2
  echo "external NEO4J_URI, load your data through your own path instead." >&2
  exit 1
fi
[ -n "$RG" ] && [ -n "$SA" ] && [ -n "$SHARE" ] && [ -n "$NEO4J_PW" ] || {
  echo "Missing deploy outputs. Run ./deploy.sh first." >&2; exit 1; }

# 1. (Re)generate the synthetic seed if needed.
if [ ! -f data/seed.cypher ]; then
  echo "Generating data/seed.cypher..."
  if command -v uv >/dev/null; then uv run data/generate.py; else python3 data/generate.py; fi
fi

# 2. Upload the seed (and a small verify query) to the private import share.
#    This is the storage data-plane, not the database — Neo4j stays private.
echo "Uploading seed.cypher to //${SA}/${SHARE}..."
KEY="$(az storage account keys list -g "$RG" -n "$SA" --query '[0].value' -o tsv)"
az storage file upload \
  --account-name "$SA" --account-key "$KEY" \
  --share-name "$SHARE" --source data/seed.cypher --path seed.cypher -o none
az storage file upload \
  --account-name "$SA" --account-key "$KEY" \
  --share-name "$SHARE" --source data/verify.cypher --path verify.cypher -o none

# 3. Wait for Neo4j to accept connections (inside the container).
echo "Waiting for Neo4j to be ready..."
ready=0
for i in $(seq 1 40); do
  if az container exec -g "$RG" -n "$CG" --container-name neo4j \
       --exec-command "cypher-shell -u $NEO4J_USER -p $NEO4J_PW 'RETURN 1'" >/dev/null 2>&1; then
    ready=1; echo "  ready."; break
  fi
  sleep 5
done
[ "$ready" -eq 1 ] || { echo "Neo4j did not become ready in time." >&2; exit 1; }

# 4. Load the seed from inside the container (localhost — never exposed).
echo "Loading the graph (this can take a minute)..."
az container exec -g "$RG" -n "$CG" --container-name neo4j \
  --exec-command "cypher-shell -u $NEO4J_USER -p $NEO4J_PW -f /import/seed.cypher"

# 5. Report the resulting counts. Run the query from an uploaded file — passing
#    an inline Cypher string with spaces through `az container exec` is mangled
#    by argument splitting, so a `-f` file is the reliable way.
echo ""
echo "Node counts:"
az container exec -g "$RG" -n "$CG" --container-name neo4j \
  --exec-command "cypher-shell -u $NEO4J_USER -p $NEO4J_PW -f /import/verify.cypher"

echo ""
echo "Done. The synthetic wind-turbine digital twin is loaded in the private Neo4j."
