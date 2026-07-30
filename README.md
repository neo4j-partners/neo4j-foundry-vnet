# Foundry Agent Service + Neo4j MCP over VNet (Enterprise Blueprint)

Network-secured variant of the
[neo4j-agent-integrations `microsoft-foundry` example](https://github.com/neo4j-labs/neo4j-agent-integrations/tree/main/microsoft-foundry):
the official Neo4j MCP server runs on an **internal-only** Azure Container App
that is unreachable from the internet, and a Microsoft Foundry (Azure AI
Foundry) agent reaches it **privately through a customer-managed VNet** using
Standard Agent Setup with virtual network injection.

```
                    ┌──────────────────────────────────────────────┐
   you / portal ───▶│ Foundry account (inbound public*, egress VNet)│
                    │   project · gpt-5-mini · caphost              │
                    └──────────────┬───────────────────────────────┘
                                   │ networkInjections (data proxy)
   VNet 192.168.0.0/16 ────────────┼───────────────────────────────────
   ├─ agent-subnet /24  ◀──────────┘  delegated Microsoft.App/environments
   ├─ pe-subnet    /24  private endpoints: Foundry · Cosmos · Storage · Search
   └─ mcp-subnet   /24  internal ACA env ── neo4j-mcp (mcp/neo4j) ──▶ Neo4j
                        private DNS zone: <env-default-domain> → env static IP
```

\* Inbound public access on the Foundry endpoint is a deliberate POC default
(`FOUNDRY_PUBLIC_NETWORK_ACCESS=Enabled`) so you can use the portal and SDK
without a VPN. Agent **egress** still goes through the VNet, and the MCP
server plus all agent data-plane resources (Cosmos DB, Storage, AI Search)
remain private. Set it to `Disabled` for full end-to-end isolation
(then you need VPN/ExpressRoute/Bastion to reach Foundry at all).

## Why this exists

Enterprises can't expose internal data tools (like a Neo4j MCP server fronting
a corporate knowledge graph) on the public internet. Historically the Foundry
agent data proxy could not resolve private DNS
([MS Q&A 5849073](https://learn.microsoft.com/en-us/answers/questions/5849073/azure-ai-foundry-agent-service-data-proxy-cannot-r),
April 2026 — the then-recommended workaround was a public App Gateway). That
limitation is gone: **private MCP is now officially supported** — see the
[tool support table](https://learn.microsoft.com/azure/foundry/how-to/configure-private-link#agent-tools-with-network-isolation)
("MCP Tool (Private MCP): Supported — through your VNet subnet") and official
sample [`19-private-network-agent-tools`](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/19-private-network-agent-tools),
whose battle-tested Bicep modules are vendored here under
[`infra/modules-network-secured/`](infra/modules-network-secured/).

> **Important:** private MCP only works with the **new Responses-API agents**
> (SDK/CLI or the new Foundry portal) — not agents created in the classic
> portal experience.

## What gets deployed

For azd environment `vnet-poc` (workload token `fdy-neo4j`):

| Resource | Name | Notes |
| --- | --- | --- |
| Resource group | `rg-fdy-neo4j-vnet-poc` | subscription-scoped Bicep creates it |
| VNet | `vnet-fdy-neo4j-vnet-poc` | 192.168.0.0/16, three subnets |
| Foundry account | `aif-fdy-neo4j-vnet-poc-<hash>` | `networkInjections` → agent-subnet (create-time only!) |
| Foundry project | `proj-fdy-neo4j-vnet-poc` | + AAD connections to Cosmos/Storage/Search |
| Model deployments | `gpt-5-mini`, `text-embedding-3-small` | same as the public example |
| Capability host | `caphostproj` | wires agent state to the BYO resources |
| Cosmos DB / Storage / AI Search | `cos-…` / `st…` / `srch-…` | BYO agent state, public access disabled, private endpoints |
| Private DNS zones | `privatelink.{services.ai,openai,cognitiveservices}.azure.com`, `privatelink.search.windows.net`, `privatelink.blob.core.windows.net`, `privatelink.documents.azure.com`, `<aca-default-domain>` | linked to the VNet |
| ACA environment | `cae-fdy-neo4j-vnet-poc` | **internal-only**, workload-profiles, on mcp-subnet |
| Container App | `ca-fdy-neo4j-vnet-poc` | `mcp/neo4j:latest`, HTTP transport :8000, VNet-only ingress |
| Log Analytics | `log-fdy-neo4j-vnet-poc` | ACA logs |

Neo4j itself is the public demo graph (`neo4j+s://demo.neo4jlabs.com:7687`,
db `companies`) for step 1 — the MCP server's outbound traffic to it is
unaffected by the inbound isolation. For production, point `NEO4J_URI` at an
Aura instance with private endpoint or a self-hosted Neo4j in the VNet.

## Deploy

Prereqs: `az` (logged in), `azd`, `uv` (for the test script). Resource
providers `Microsoft.App`, `Microsoft.CognitiveServices`, `Microsoft.Network`,
`Microsoft.Search`, `Microsoft.Storage`, `Microsoft.DocumentDB` registered.

```bash
./deploy.sh          # azd up → ~20-30 min (capability host is slow)
```

Defaults: region `swedencentral`, azd env `vnet-poc`. Override with
`azd env set AZURE_LOCATION <region>` / `azd env new <name>` before running,
or put overrides in `./.env` (same keys as [infra/main.parameters.json](infra/main.parameters.json)).

## Test

```bash
./test-private.sh                        # negative: MCP endpoint NOT publicly reachable
uv run agent/create_and_test_agent.py    # E2E: agent → data proxy → VNet → MCP → Neo4j
```

The E2E script creates a Responses-API agent with an `MCPTool` pointing at the
private endpoint (allowed tools `get-schema` / `read-cypher`), asks a research
question, and prints the MCP calls it observes. It retries up to 3× (the data
proxy occasionally hits a scale unit without proxy support — a known
intermittent issue in Microsoft's own test suite).

**MCP auth:** the Agent Service **rejects sensitive headers passed inline** on
the MCP tool (`Headers that can include sensitive information are not allowed
… Use project_connection_id instead`). The Basic-auth header therefore lives
in a project connection `neo4j-mcp-auth` (`authType: CustomKeys`, its keys are
forwarded to the MCP server as HTTP headers), created by
[infra/modules/foundry-extras.bicep](infra/modules/foundry-extras.bicep) and
referenced by the agent via `project_connection_id`.

### Declarative (no-code) agents in the portal

**Verified working against the private endpoint.** An SDK-created agent shows up
in the new Foundry portal under **Build → Agents** as a `prompt` agent, fully
editable — its YAML carries the MCP tool declaratively:

```yaml
tools:
  - type: mcp
    server_label: neo4j_mcp_private
    server_url: https://ca-…swedencentral.azurecontainerapps.io/mcp   # private
    allowed_tools:
      tool_names: [get-schema, read-cypher]
    require_approval: never
    project_connection_id: neo4j-mcp-auth
```

Chatting in the portal Playground answers from the graph, and the response
footer shows the `mcp_list_tools` / `neo4j_mcp_private` tool chips — the portal
UI drove the private MCP call through the data proxy (public inbound is enabled,
so no VPN needed to reach the portal).

To build one **from scratch in the portal**: **Build → Agents → New agent**,
add the MCP tool exactly as in the
[public example walkthrough](https://github.com/neo4j-labs/neo4j-agent-integrations/blob/main/microsoft-foundry/examples/mcp/README.md),
but set the endpoint to the private URL from `.env.deployed`
(`NEO4J_MCP_ENDPOINT`) and reuse the `neo4j-mcp-auth` connection (or let the
portal create one with the `Authorization: Basic …` header). The tool's
**Connect** step validates server-side through the data proxy, so it succeeds
even though your browser can't reach the private FQDN.

## Enterprise hardening (beyond this POC)

- `azd env set FOUNDRY_PUBLIC_NETWORK_ACCESS Disabled` → Foundry inbound goes
  private too (private endpoint already provisioned); reach it via
  VPN/ExpressRoute/Bastion.
- Private Neo4j: Aura Business Critical / Virtual Dedicated Cloud private
  endpoint, or self-host Neo4j in the VNet.
- Egress control: NAT gateway / Azure Firewall on the subnets; see the
  [firewall allowlist](https://learn.microsoft.com/azure/foundry/how-to/configure-private-link#firewall-allowlisting).
- OAuth in front of MCP: Azure API Management (private) instead of Basic auth.

## Gotchas (learned from the official template)

- **Network injection is create-time only.** You cannot add/change it on an
  existing Foundry account — redeploy instead.
- **Teardown order matters.** Delete the project capability host, then the
  account, then **purge** the soft-deleted account, and wait up to ~20 min
  before reusing the agent subnet — otherwise "Subnet already in use".
  `azd down --force --purge` + patience covers it.
- The agent subnet must be **exclusively** used by one Foundry account.
- Don't use 172.17.0.0/16 anywhere in the VNet (Docker bridge conflict).
- **Re-running `azd provision` after the capability host exists fails** with
  `Connection '…' is in use by the workspace capability host and cannot be
  modified`. This is an idempotency limitation inherited from template 19 (the
  project-connection PUTs are rejected once the caphost owns them). Fresh
  deploys are unaffected; for incremental changes, target the changed module
  (e.g. `az deployment group create`/`az rest` for a single resource) instead
  of a full re-provision.
- Class-A (10.x) VNets are only supported in
  [certain regions](https://github.com/microsoft-foundry/foundry-samples/tree/main/infrastructure/infrastructure-setup-bicep/19-private-network-agent-tools#limitations--known-issues);
  this template uses 192.168.0.0/16 which works everywhere.

## Layout

```
azure.yaml                       azd project
deploy.sh                        azd env seeding + azd up + .env.deployed
test-private.sh                  public-unreachability check
infra/main.bicep                 subscription scope: RG + resources.bicep
infra/resources.bicep            composition (sequencing from template 19)
infra/modules-network-secured/   vendored from foundry-samples template 19
infra/modules/                   this repo's additions:
  mcp-aca.bicep                    internal ACA env + neo4j-mcp app
  mcp-dns.bicep                    private DNS zone for the ACA default domain
  foundry-extras.bicep             embedding model, Foundry User role, endpoint output
agent/create_and_test_agent.py   E2E test (Responses-API agent + MCPTool)
```
