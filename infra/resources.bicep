// Resource-group composition for the network-secured Foundry + Neo4j MCP POC.
// Module sequencing follows the official foundry-samples template
// 19-private-network-agent-tools (vendored under ./modules-network-secured):
//   vnet -> account (network-injected) -> dependencies -> private endpoints/DNS
//   -> project -> RBAC -> capability host -> post-caphost container RBAC.
// Additions: mcp-aca (internal ACA env + Neo4j MCP + private DNS zone) and
// foundry-extras (embedding model, Foundry User role, project endpoint output).
targetScope = 'resourceGroup'

param location string
param baseName string
param commonTags object

// Foundry
param publicNetworkAccess string
param modelName string
param modelVersion string
param modelSkuName string
param modelCapacity int
param embeddingModelName string
param embeddingModelVersion string
param embeddingModelSkuName string
param embeddingModelCapacity int
param principalId string
param principalType string

// Neo4j MCP container app
param containerImage string
param neo4jUri string
param neo4jDatabase string
param neo4jUsername string
@secure()
param neo4jPassword string
param readOnly string
param mcpPort string
param mcpMinReplicas string
param mcpMaxReplicas string
param mcpCpu string
param mcpMemory string
param mcpConcurrentRequests string
param neo4jLogFormat string
param neo4jTelemetry string
param neo4jSchemaSampleSize string
param neo4jAllowedOrigins string

// Deterministic 4-char suffix keeps globally-unique names (Foundry custom
// subdomain, storage, cosmos, search) stable across re-deploys of the same RG.
var uniqueSuffix = substring(uniqueString(resourceGroup().id), 0, 4)

var accountName = toLower('aif-${baseName}-${uniqueSuffix}')
var projectName = toLower('proj-${baseName}')
var vnetName = 'vnet-${baseName}'
var cosmosDBName = toLower('cos-${baseName}-${uniqueSuffix}')
var aiSearchName = toLower('srch-${baseName}-${uniqueSuffix}')
// Storage: lowercase alphanumeric, max 24 chars.
var azureStorageName = toLower(take('st${replace(baseName, '-', '')}', 20))
var azureStorageNameUnique = '${azureStorageName}${uniqueSuffix}'

var projectCapHost = 'caphostproj'

// --- Network: VNet + agent/pe/mcp subnets (agent + mcp delegated to Microsoft.App/environments)
module vnet 'modules-network-secured/network-agent-vnet.bicep' = {
  name: 'vnet-${baseName}-deployment'
  params: {
    location: location
    vnetName: vnetName
    useExistingVnet: false
    agentSubnetName: 'agent-subnet'
    peSubnetName: 'pe-subnet'
    mcpSubnetName: 'mcp-subnet'
    neo4jSubnetName: 'neo4j-subnet'
  }
}

// --- Private Neo4j Enterprise (single node, ACI) on the neo4j-subnet.
// Deployed only when no external neo4jUri is supplied. Provide neo4jUri (e.g. a
// customer's existing Neo4j Enterprise cluster reached over a peered VNet /
// private endpoint, or an Aura private-link URI) to skip this and point the MCP
// server at that database instead.
var deployNeo4j = empty(neo4jUri)

module neo4jAci 'modules/neo4j-aci.bicep' = if (deployNeo4j) {
  name: 'neo4j-aci-${baseName}-deployment'
  params: {
    location: location
    baseName: baseName
    commonTags: commonTags
    neo4jSubnetId: vnet.outputs.neo4jSubnetId
    neo4jUsername: neo4jUsername
    neo4jPassword: neo4jPassword
  }
}

var effectiveNeo4jUri = deployNeo4j ? neo4jAci!.outputs.boltUri : neo4jUri

// --- Foundry account with VNet injection (create-time only!) + chat model
module aiAccount 'modules-network-secured/ai-account-identity.bicep' = {
  name: 'account-${baseName}-deployment'
  params: {
    accountName: accountName
    location: location
    modelName: modelName
    modelFormat: 'OpenAI'
    modelVersion: modelVersion
    modelSkuName: modelSkuName
    modelCapacity: modelCapacity
    agentSubnetId: vnet.outputs.agentSubnetId
    networkInjection: 'true'
    publicNetworkAccess: publicNetworkAccess
  }
}

// --- Standard-agent dependencies (BYO data plane): Cosmos DB, AI Search, Storage
module aiDependencies 'modules-network-secured/standard-dependent-resources.bicep' = {
  name: 'dependencies-${baseName}-deployment'
  params: {
    location: location
    azureStorageName: azureStorageNameUnique
    aiSearchName: aiSearchName
    cosmosDBName: cosmosDBName
    existingAiSearchResourceId: ''
    aiSearchExists: false
    existingAzureStorageAccountResourceId: ''
    azureStorageExists: false
    existingCosmosDBResourceId: ''
    cosmosDBExists: false
  }
}

// --- Private endpoints + private DNS zones for Foundry, Search, Storage, Cosmos
module privateEndpointAndDNS 'modules-network-secured/private-endpoint-and-dns.bicep' = {
  name: 'private-endpoint-${baseName}-deployment'
  params: {
    aiAccountName: aiAccount.outputs.accountName
    aiSearchName: aiDependencies.outputs.aiSearchName
    storageName: aiDependencies.outputs.azureStorageName
    cosmosDBName: aiDependencies.outputs.cosmosDBName
    vnetName: vnet.outputs.virtualNetworkName
    peSubnetName: vnet.outputs.peSubnetName
    suffix: uniqueSuffix
    vnetResourceGroupName: vnet.outputs.virtualNetworkResourceGroup
    vnetSubscriptionId: vnet.outputs.virtualNetworkSubscriptionId
  }
}

// --- Foundry project + AAD connections to the three dependencies
module aiProject 'modules-network-secured/ai-project-identity.bicep' = {
  name: 'project-${baseName}-deployment'
  params: {
    projectName: projectName
    projectDescription: 'Foundry + Neo4j MCP over VNet (private MCP blueprint)'
    displayName: 'Foundry + Neo4j (VNet)'
    location: location
    aiSearchName: aiDependencies.outputs.aiSearchName
    aiSearchServiceResourceGroupName: aiDependencies.outputs.aiSearchServiceResourceGroupName
    aiSearchServiceSubscriptionId: aiDependencies.outputs.aiSearchServiceSubscriptionId
    cosmosDBName: aiDependencies.outputs.cosmosDBName
    cosmosDBSubscriptionId: aiDependencies.outputs.cosmosDBSubscriptionId
    cosmosDBResourceGroupName: aiDependencies.outputs.cosmosDBResourceGroupName
    azureStorageName: aiDependencies.outputs.azureStorageName
    azureStorageSubscriptionId: aiDependencies.outputs.azureStorageSubscriptionId
    azureStorageResourceGroupName: aiDependencies.outputs.azureStorageResourceGroupName
    accountName: aiAccount.outputs.accountName
  }
  dependsOn: [
    privateEndpointAndDNS
  ]
}

module formatProjectWorkspaceId 'modules-network-secured/format-project-workspace-id.bicep' = {
  name: 'format-workspace-id-${baseName}-deployment'
  params: {
    projectWorkspaceId: aiProject.outputs.projectWorkspaceId
  }
}

// --- RBAC for the project managed identity (required BEFORE the caphost)
module storageAccountRoleAssignment 'modules-network-secured/azure-storage-account-role-assignment.bicep' = {
  name: 'storage-ra-${baseName}-deployment'
  params: {
    azureStorageName: aiDependencies.outputs.azureStorageName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

module cosmosAccountRoleAssignments 'modules-network-secured/cosmosdb-account-role-assignment.bicep' = {
  name: 'cosmos-account-ra-${baseName}-deployment'
  params: {
    cosmosDBName: aiDependencies.outputs.cosmosDBName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

module aiSearchRoleAssignments 'modules-network-secured/ai-search-role-assignments.bicep' = {
  name: 'ai-search-ra-${baseName}-deployment'
  params: {
    aiSearchName: aiDependencies.outputs.aiSearchName
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
}

// --- Capability host: wires the project's agent runtime to the BYO resources
module addProjectCapabilityHost 'modules-network-secured/add-project-capability-host.bicep' = {
  name: 'caphost-${baseName}-deployment'
  params: {
    accountName: aiAccount.outputs.accountName
    projectName: aiProject.outputs.projectName
    cosmosDBConnection: aiProject.outputs.cosmosDBConnection
    azureStorageConnection: aiProject.outputs.azureStorageConnection
    aiSearchConnection: aiProject.outputs.aiSearchConnection
    projectCapHost: projectCapHost
  }
  dependsOn: [
    cosmosAccountRoleAssignments
    storageAccountRoleAssignment
    aiSearchRoleAssignments
  ]
}

// --- Container-level RBAC (required AFTER the caphost creates the containers)
module storageContainersRoleAssignment 'modules-network-secured/blob-storage-container-role-assignments.bicep' = {
  name: 'storage-containers-ra-${baseName}-deployment'
  params: {
    aiProjectPrincipalId: aiProject.outputs.projectPrincipalId
    storageName: aiDependencies.outputs.azureStorageName
    workspaceId: formatProjectWorkspaceId.outputs.projectWorkspaceIdGuid
  }
  dependsOn: [
    addProjectCapabilityHost
    storageAccountRoleAssignment
  ]
}

module cosmosContainerRoleAssignments 'modules-network-secured/cosmos-container-role-assignments.bicep' = {
  name: 'cosmos-containers-ra-${baseName}-deployment'
  params: {
    cosmosAccountName: aiDependencies.outputs.cosmosDBName
    projectWorkspaceId: formatProjectWorkspaceId.outputs.projectWorkspaceIdGuid
    projectPrincipalId: aiProject.outputs.projectPrincipalId
  }
  dependsOn: [
    addProjectCapabilityHost
    storageContainersRoleAssignment
  ]
}

// --- Embedding model + Foundry User role + project endpoint
module foundryExtras 'modules/foundry-extras.bicep' = {
  name: 'foundry-extras-${baseName}-deployment'
  params: {
    accountName: aiAccount.outputs.accountName
    projectName: aiProject.outputs.projectName
    neo4jMcpEndpoint: mcpAca.outputs.mcpEndpoint
    neo4jUsername: neo4jUsername
    neo4jPassword: neo4jPassword
    embeddingModelName: embeddingModelName
    embeddingModelVersion: embeddingModelVersion
    embeddingModelSkuName: embeddingModelSkuName
    embeddingModelCapacity: embeddingModelCapacity
    principalId: principalId
    principalType: principalType
  }
  // Serialization vs the chat-model deployment is implicit: this module's
  // accountName/projectName params reference aiAccount/aiProject outputs.
}

// --- Private Neo4j MCP server on the MCP subnet
module mcpAca 'modules/mcp-aca.bicep' = {
  name: 'mcp-aca-${baseName}-deployment'
  params: {
    location: location
    baseName: baseName
    commonTags: commonTags
    mcpSubnetId: vnet.outputs.mcpSubnetId
    containerImage: containerImage
    neo4jUri: effectiveNeo4jUri
    neo4jDatabase: neo4jDatabase
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

// Private DNS zone for the internal ACA environment (runtime-named, so a
// separate module).
module mcpDns 'modules/mcp-dns.bicep' = {
  name: 'mcp-dns-${baseName}-deployment'
  params: {
    baseName: baseName
    commonTags: commonTags
    defaultDomain: mcpAca.outputs.defaultDomain
    staticIp: mcpAca.outputs.containerAppsEnvironmentStaticIp
    vnetId: vnet.outputs.virtualNetworkId
  }
}

output mcpEndpoint string = mcpAca.outputs.mcpEndpoint
output mcpFqdn string = mcpAca.outputs.mcpFqdn
output containerAppName string = mcpAca.outputs.containerAppName
output containerAppsEnvironmentName string = mcpAca.outputs.containerAppsEnvironmentName
output logAnalyticsWorkspaceName string = mcpAca.outputs.logAnalyticsWorkspaceName
output vnetName string = vnet.outputs.virtualNetworkName
output agentSubnetId string = vnet.outputs.agentSubnetId
output mcpSubnetId string = vnet.outputs.mcpSubnetId
output foundryAccountName string = aiAccount.outputs.accountName
output foundryProjectId string = aiProject.outputs.projectId
output foundryProjectName string = aiProject.outputs.projectName
output foundryProjectEndpoint string = foundryExtras.outputs.projectEndpoint
output foundryModelDeploymentName string = modelName
output foundryEmbeddingDeploymentName string = foundryExtras.outputs.embeddingDeploymentName
output mcpConnectionName string = foundryExtras.outputs.mcpConnectionName
output cosmosDBName string = aiDependencies.outputs.cosmosDBName
output aiSearchName string = aiDependencies.outputs.aiSearchName
output azureStorageName string = aiDependencies.outputs.azureStorageName

// Private Neo4j (empty when an external neo4jUri override was supplied)
output neo4jDeployed bool = deployNeo4j
output neo4jUri string = effectiveNeo4jUri
output neo4jPrivateIp string = deployNeo4j ? neo4jAci!.outputs.privateIp : ''
output neo4jContainerGroupName string = deployNeo4j ? neo4jAci!.outputs.containerGroupName : ''
output neo4jImportStorageAccount string = deployNeo4j ? neo4jAci!.outputs.storageAccountName : ''
output neo4jImportShareName string = deployNeo4j ? neo4jAci!.outputs.importShareName : ''
