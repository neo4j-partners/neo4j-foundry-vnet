#!/usr/bin/env bash
# Negative test: the MCP endpoint must NOT be reachable from the public
# internet. Public DNS must not resolve the internal ACA FQDN (the zone only
# exists as a private DNS zone linked to the VNet), and any direct connection
# attempt must fail.
set -uo pipefail

cd "$(dirname "$0")"

if [ -f .env.deployed ]; then
  # shellcheck disable=SC1091
  . ./.env.deployed
fi

FQDN="${MCP_FQDN:-}"
ENDPOINT="${NEO4J_MCP_ENDPOINT:-}"
if [ -z "$FQDN" ] || [ -z "$ENDPOINT" ]; then
  echo "Missing MCP_FQDN / NEO4J_MCP_ENDPOINT — run ./deploy.sh first." >&2
  exit 1
fi

echo "Checking that ${FQDN} is NOT publicly resolvable/reachable..."

fail=0

if dig +short "$FQDN" @1.1.1.1 | grep -q .; then
  echo "✗ PUBLIC DNS RESOLVES ${FQDN} — endpoint may be public!"
  fail=1
else
  echo "✓ Public DNS does not resolve the MCP FQDN."
fi

if curl -sS --max-time 10 -o /dev/null "$ENDPOINT" 2>/dev/null; then
  echo "✗ HTTP request to ${ENDPOINT} SUCCEEDED from this machine — endpoint is public!"
  fail=1
else
  echo "✓ Direct HTTP request from this machine fails (as expected)."
fi

if [ "$fail" -eq 0 ]; then
  echo
  echo "✓ PRIVATE: the Neo4j MCP endpoint is only reachable from inside the VNet."
else
  echo
  echo "✗ The endpoint appears publicly reachable — check ingress/internal-only settings." >&2
  exit 1
fi
