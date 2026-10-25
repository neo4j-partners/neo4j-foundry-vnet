// Microsoft Foundry Basic Agent Setup with VNet injection, a private Neo4j MCP
// server, and an optional private Neo4j Enterprise VM deployment.
targetScope = 'resourceGroup'

param location string
param baseName string
param commonTags object

// Foundry Basic setup
param publicNetworkAccess string
param modelName string
param modelVersion string
param modelSkuName string
param modelCapacity int
param principalId string
param principalType string

// Neo4j and MCP
param containerImage string
param neo4jUri string
param neo4jDatabase string
@secure()
param neo4jAdminPassword string
param neo4jAgentUsername string
@secure()
param neo4jAgentPassword string
param neo4jNodeCount int
param neo4jVmSize string
param neo4jDataDiskSizeGb int
param adminUsername string
param sshPublicKey string
param neo4jVersion string
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

var uniqueSuffix = substring(uniqueString(resourceGroup().id), 0, 4)
var accountName = toLower('aif-${baseName}-${uniqueSuffix}')
var projectName = toLower('proj-${baseName}')
var vnetName = 'vnet-${baseName}'
var projectCapabilityHostName = 'caphostproj'
var deployNeo4j = empty(neo4jUri)

// Four isolated subnets: Foundry injection, private endpoints, internal MCP,
// and Neo4j VMs. The Neo4j subnet has an explicit NAT gateway for bootstrap.
module vnet 'modules-network-secured/vnet.bicep' = {
  name: 'vnet-${baseName}'
  params: {
    location: location
    vnetName: vnetName
    agentSubnetName: 'agent-subnet'
    peSubnetName: 'pe-subnet'
    mcpSubnetName: 'mcp-subnet'
    neo4jSubnetName: 'neo4j-subnet'
  }
}

// Optional bundled Neo4j. Supplying neo4jUri skips Key Vault and all VMs.
module keyVault 'modules/keyvault.bicep' = if (deployNeo4j) {
  name: 'keyvault-${baseName}'
  params: {
    location: location
    baseName: baseName
    commonTags: commonTags
    deployerPrincipalId: principalId
    peSubnetId: vnet.outputs.peSubnetId
    vnetId: vnet.outputs.virtualNetworkId
    neo4jAdminPassword: neo4jAdminPassword
    neo4jAgentPassword: neo4jAgentPassword
  }
}

module neo4jVm 'modules/neo4j-vm.bicep' = if (deployNeo4j) {
  name: 'neo4j-${baseName}'
  params: {
    location: location
    baseName: baseName
    commonTags: commonTags
    neo4jSubnetId: vnet.outputs.neo4jSubnetId
    neo4jSubnetPrefix: vnet.outputs.neo4jSubnetPrefix
    mcpSubnetPrefix: vnet.outputs.mcpSubnetPrefix
    keyVaultUri: keyVault!.outputs.vaultUri
    nodeCount: neo4jNodeCount
    vmSize: neo4jVmSize
    dataDiskSizeGb: neo4jDataDiskSizeGb
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    neo4jVersion: neo4jVersion
  }
}

module keyVaultVmAccess 'modules/keyvault-vm-access.bicep' = if (deployNeo4j) {
  name: 'keyvault-vm-access-${baseName}'
  params: {
    vaultName: keyVault!.outputs.vaultName
    principalIds: neo4jVm!.outputs.vmPrincipalIds
  }
}

var effectiveNeo4jUri = deployNeo4j ? neo4jVm!.outputs.boltUri : neo4jUri

// Internal-only Container Apps environment hosting the official Neo4j MCP
// image. Ingress has no public route; its FQDN resolves only inside the VNet.
module mcpAca 'modules/mcp-aca.bicep' = {
  name: 'mcp-${baseName}'
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

module mcpDns 'modules/mcp-dns.bicep' = {
  name: 'mcp-dns-${baseName}'
  params: {
    baseName: baseName
    commonTags: commonTags
    defaultDomain: mcpAca.outputs.defaultDomain
    staticIp: mcpAca.outputs.containerAppsEnvironmentStaticIp
    vnetId: vnet.outputs.virtualNetworkId
  }
}

// Foundry Basic setup: network injection plus platform-managed agent storage.
// No customer-managed Cosmos DB, Storage account, or AI Search is deployed.
module aiAccount 'modules-network-secured/ai-account-identity.bicep' = {
  name: 'foundry-${baseName}'
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

module foundryPrivateEndpoint 'modules-network-secured/private-endpoint-and-dns.bicep' = {
  name: 'foundry-private-endpoint-${baseName}'
  params: {
    location: location
    aiAccountName: aiAccount.outputs.accountName
    vnetId: vnet.outputs.virtualNetworkId
    peSubnetId: vnet.outputs.peSubnetId
    suffix: uniqueSuffix
    commonTags: commonTags
  }
}

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' = {
  parent: account
  name: projectName
  location: location
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    description: 'Private Microsoft Foundry agent with Neo4j MCP over VNet'
    displayName: 'Neo4j MCP private VNet'
  }
  dependsOn: [
    aiAccount
    foundryPrivateEndpoint
  ]
}

module projectCapabilityHost 'modules-network-secured/add-project-capability-host.bicep' = {
  name: 'capability-host-${baseName}'
  params: {
    accountName: accountName
    projectName: project.name
    projectCapHost: projectCapabilityHostName
  }
}

module foundryExtras 'modules/foundry-extras.bicep' = {
  name: 'foundry-extras-${baseName}'
  params: {
    accountName: accountName
    projectName: project.name
    neo4jMcpEndpoint: mcpAca.outputs.mcpEndpoint
    neo4jUsername: neo4jAgentUsername
    neo4jPassword: neo4jAgentPassword
    principalId: principalId
    principalType: principalType
  }
  dependsOn: [
    mcpDns
    projectCapabilityHost
  ]
}

output mcpEndpoint string = mcpAca.outputs.mcpEndpoint
output mcpFqdn string = mcpAca.outputs.mcpFqdn
output containerAppName string = mcpAca.outputs.containerAppName
output containerAppsEnvironmentName string = mcpAca.outputs.containerAppsEnvironmentName
output logAnalyticsWorkspaceName string = mcpAca.outputs.logAnalyticsWorkspaceName
output vnetName string = vnet.outputs.virtualNetworkName
output foundryAccountName string = aiAccount.outputs.accountName
output foundryProjectId string = project.id
output foundryProjectName string = project.name
output foundryProjectEndpoint string = foundryExtras.outputs.projectEndpoint
output foundryModelDeploymentName string = modelName
output mcpConnectionName string = foundryExtras.outputs.mcpConnectionName
output neo4jDeployed bool = deployNeo4j
output neo4jUri string = effectiveNeo4jUri
output neo4jNodeIps array = deployNeo4j ? neo4jVm!.outputs.nodeIps : []
output neo4jFirstNodeIp string = deployNeo4j ? neo4jVm!.outputs.firstNodeIp : ''
output neo4jFirstNodeVmName string = deployNeo4j ? neo4jVm!.outputs.firstNodeVmName : ''
output keyVaultName string = deployNeo4j ? keyVault!.outputs.vaultName : ''
