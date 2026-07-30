// Foundry Agent Service + private Neo4j MCP server over a BYO VNet.
// Subscription scope: creates the resource group and delegates everything else
// to resources.bicep (azd-style, matching the public neo4j-agent-integrations
// microsoft-foundry example this repo is the network-secured variant of).
targetScope = 'subscription'

@minLength(1)
@maxLength(20)
@description('Environment suffix added to all resource names, e.g. "vnet-poc".')
param environmentName string

@description('Azure region for the resource group and all resources. Must support Foundry standard agents with VNet injection.')
param location string

@description('Workload token used in resource names.')
param workloadName string = 'fdy-neo4j'

// --- Foundry ---------------------------------------------------------------

@description('Public network access for the Foundry account endpoint. "Enabled" (default) allows portal/SDK access from the internet while agent egress stays VNet-injected and all backend resources stay private — the POC-friendly variant of foundry-samples template 19. "Disabled" is fully private (requires VPN/Bastion/ExpressRoute to use).')
@allowed([
  'Enabled'
  'Disabled'
])
param foundryPublicNetworkAccess string = 'Enabled'

@description('Foundry chat model deployment name.')
param foundryModelName string = 'gpt-5-mini'

@description('Foundry chat model version.')
param foundryModelVersion string = '2025-08-07'

@description('Foundry chat model SKU.')
param foundryModelSkuName string = 'GlobalStandard'

@description('Foundry chat model capacity (thousands of tokens per minute).')
param foundryModelCapacity string = '120'

@description('Foundry embedding model deployment name (1536-dim to match the public companies demo graph).')
param foundryEmbeddingModelName string = 'text-embedding-3-small'

@description('Foundry embedding model version.')
param foundryEmbeddingModelVersion string = '1'

@description('Foundry embedding model SKU.')
param foundryEmbeddingModelSkuName string = 'GlobalStandard'

@description('Foundry embedding model capacity (thousands of tokens per minute).')
param foundryEmbeddingModelCapacity string = '30'

@description('Entra object ID granted the Foundry User role on the project. azd auto-populates this from the signed-in user. Empty disables the role assignment.')
param principalId string = ''

@description('Type of the principal granted the Foundry User role.')
@allowed([
  'User'
  'ServicePrincipal'
])
param principalType string = 'User'

// --- Neo4j MCP server -------------------------------------------------------

@description('Container image for the Neo4j MCP server.')
param containerImage string = 'mcp/neo4j:latest'

@description('Optional external Neo4j Bolt URI. Leave EMPTY (default) to deploy a private single-node Neo4j Enterprise container inside the VNet and point the MCP server at it. Set it (e.g. bolt://10.x.x.x:7687 for a peered enterprise cluster, or a neo4j+s Aura private-link URI) to use an existing database instead.')
param neo4jUri string = ''

@description('Neo4j database name.')
param neo4jDatabase string = 'neo4j'

@description('Neo4j username. Sets the DB user for the in-VNet Neo4j and the Basic-auth header in the MCP auth connection.')
param neo4jUsername string = 'neo4j'

@description('Neo4j password. Required (no default). deploy.sh generates and stores one in the azd env on first run.')
@secure()
param neo4jPassword string

@description('Run the Neo4j MCP server in read-only mode.')
@allowed([
  'true'
  'false'
])
param readOnly string = 'true'

@description('Container port used by the MCP HTTP transport.')
param mcpPort string = '8000'

@description('Minimum Container Apps replicas.')
param mcpMinReplicas string = '1'

@description('Maximum Container Apps replicas.')
param mcpMaxReplicas string = '3'

@description('Container CPU cores.')
param mcpCpu string = '0.5'

@description('Container memory.')
param mcpMemory string = '1Gi'

@description('HTTP concurrent requests per replica before scale-out.')
param mcpConcurrentRequests string = '20'

@description('Neo4j MCP log format: "json" or "text".')
param neo4jLogFormat string = 'json'

@description('Enable Neo4j MCP telemetry.')
@allowed([
  'true'
  'false'
])
param neo4jTelemetry string = 'true'

@description('Number of nodes sampled for Neo4j schema inference.')
param neo4jSchemaSampleSize string = '100'

@description('CORS allowed origins for the MCP HTTP server. Empty disables CORS.')
param neo4jAllowedOrigins string = ''

var normalizedWorkload = toLower(replace(workloadName, '_', '-'))
var normalizedEnv = toLower(replace(environmentName, '_', '-'))
var baseName = '${normalizedWorkload}-${normalizedEnv}'

var commonTags = {
  workload: normalizedWorkload
  environment: normalizedEnv
  'azd-env-name': environmentName
}

resource rg 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${baseName}'
  location: location
  tags: commonTags
}

module resources './resources.bicep' = {
  name: 'resources-${baseName}'
  scope: rg
  params: {
    location: location
    baseName: baseName
    commonTags: commonTags
    publicNetworkAccess: foundryPublicNetworkAccess
    modelName: foundryModelName
    modelVersion: foundryModelVersion
    modelSkuName: foundryModelSkuName
    modelCapacity: int(foundryModelCapacity)
    embeddingModelName: foundryEmbeddingModelName
    embeddingModelVersion: foundryEmbeddingModelVersion
    embeddingModelSkuName: foundryEmbeddingModelSkuName
    embeddingModelCapacity: int(foundryEmbeddingModelCapacity)
    principalId: principalId
    principalType: principalType
    containerImage: containerImage
    neo4jUri: neo4jUri
    neo4jDatabase: neo4jDatabase
    neo4jUsername: neo4jUsername
    neo4jPassword: neo4jPassword
    readOnly: readOnly
    mcpPort: mcpPort
    mcpMinReplicas: mcpMinReplicas
    mcpMaxReplicas: mcpMaxReplicas
    mcpCpu: mcpCpu
    mcpMemory: mcpMemory
    mcpConcurrentRequests: mcpConcurrentRequests
    neo4jLogFormat: neo4jLogFormat
    neo4jTelemetry: neo4jTelemetry
    neo4jSchemaSampleSize: neo4jSchemaSampleSize
    neo4jAllowedOrigins: neo4jAllowedOrigins
  }
}

output resourceGroupName string = rg.name
output mcpEndpoint string = resources.outputs.mcpEndpoint
output mcpFqdn string = resources.outputs.mcpFqdn
output containerAppName string = resources.outputs.containerAppName
output containerAppsEnvironmentName string = resources.outputs.containerAppsEnvironmentName
output logAnalyticsWorkspaceName string = resources.outputs.logAnalyticsWorkspaceName
output vnetName string = resources.outputs.vnetName
output foundryResourceGroup string = rg.name
output foundryAccountName string = resources.outputs.foundryAccountName
output foundryProjectId string = resources.outputs.foundryProjectId
output foundryProjectName string = resources.outputs.foundryProjectName
output foundryProjectEndpoint string = resources.outputs.foundryProjectEndpoint
output foundryModelDeploymentName string = resources.outputs.foundryModelDeploymentName
output foundryEmbeddingDeploymentName string = resources.outputs.foundryEmbeddingDeploymentName
output mcpConnectionName string = resources.outputs.mcpConnectionName
output neo4jDeployed bool = resources.outputs.neo4jDeployed
output neo4jUri string = resources.outputs.neo4jUri
output neo4jPrivateIp string = resources.outputs.neo4jPrivateIp
output neo4jContainerGroupName string = resources.outputs.neo4jContainerGroupName
output neo4jImportStorageAccount string = resources.outputs.neo4jImportStorageAccount
output neo4jImportShareName string = resources.outputs.neo4jImportShareName
output foundryPublicNetworkAccessOut string = foundryPublicNetworkAccess

// Names the `azure.ai.agents` azd extension expects (kept for parity with the
// public example).
output AZURE_AI_PROJECT_ENDPOINT string = resources.outputs.foundryProjectEndpoint
output AZURE_AI_MODEL_DEPLOYMENT_NAME string = resources.outputs.foundryModelDeploymentName
