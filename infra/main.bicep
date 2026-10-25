// Neo4j MCP + Microsoft Foundry Basic Agent Setup with VNet injection.
// Subscription scope lets azd create a self-contained resource group.
targetScope = 'subscription'

@minLength(1)
@maxLength(16)
@description('Environment suffix used in resource names.')
param environmentName string

@description('Azure region. It must support Foundry Basic Agent Setup with VNet injection and the selected model.')
@allowed([
  'westus'
  'eastus'
  'eastus2'
  'japaneast'
  'francecentral'
  'spaincentral'
  'uaenorth'
  'southcentralus'
  'italynorth'
  'germanywestcentral'
  'brazilsouth'
  'southafricanorth'
  'australiaeast'
  'swedencentral'
  'canadaeast'
  'canadacentral'
  'westeurope'
  'westus3'
  'uksouth'
  'southindia'
  'koreacentral'
  'polandcentral'
  'switzerlandnorth'
  'norwayeast'
])
param location string

@minLength(2)
@maxLength(16)
@description('Workload token used in resource names.')
param workloadName string = 'neo4j-mcp'

@allowed([
  'Disabled'
  'Enabled'
])
@description('Foundry inbound public access. Disabled is the secure default and requires private network access to use the project endpoint. Agent egress remains VNet-injected in either mode.')
param foundryPublicNetworkAccess string = 'Disabled'

@description('Foundry chat model deployment and model name.')
param foundryModelName string = 'gpt-5.5'

@description('Foundry chat model version.')
param foundryModelVersion string = '2026-04-24'

@description('Foundry chat model deployment SKU.')
param foundryModelSkuName string = 'GlobalStandard'

@minValue(1)
@description('Foundry model capacity in thousands of tokens per minute.')
param foundryModelCapacity int = 30

@description('Entra object ID granted Foundry User at project scope. Empty omits the role assignment.')
param principalId string = ''

@allowed([
  'User'
  'ServicePrincipal'
])
param principalType string = 'User'

@description('Official Neo4j MCP container image. Pin a released version for reproducible deployments.')
param containerImage string = 'neo4j/mcp:v1.5.3@sha256:fb2b7b486ecabdfb2792f1ac7eac401365cd836d83230edc9bcaa99bbf1bf727'

@description('Existing private Neo4j URI. Empty deploys Neo4j Enterprise on private Azure VMs; a value skips the bundled database.')
param neo4jUri string = ''

@description('Neo4j database name.')
param neo4jDatabase string = 'neo4j'

@secure()
@description('Neo4j administrator password for the bundled deployment.')
param neo4jAdminPassword string = ''

@description('Least-privilege Neo4j user used by the MCP server.')
param neo4jAgentUsername string = 'agent'

@secure()
@description('Password for the least-privilege Neo4j MCP user.')
// The preprovision hook generates this value. The empty Bicep default keeps
// azd from prompting before that hook has had a chance to populate the
// environment, as recommended by the azd custom-hook guidance.
param neo4jAgentPassword string = ''

@minValue(1)
@maxValue(7)
@description('Bundled Neo4j Enterprise primary count. One minimizes evaluation cost; three is the smallest fault-tolerant cluster.')
param neo4jNodeCount int = 1

@description('VM size for each bundled Neo4j node.')
param neo4jVmSize string = 'Standard_D4s_v5'

@minValue(64)
@description('Premium SSD data disk size for each Neo4j node, in GiB.')
param neo4jDataDiskSizeGb int = 256

@description('Linux VM administrator name. The template creates no public IP or SSH rule.')
param adminUsername string = 'azureuser'

@description('SSH public key required by the Linux VM image. The template creates no SSH endpoint.')
param sshPublicKey string = ''

@description('Neo4j Enterprise version.')
param neo4jVersion string = '2026.07.1'

@allowed([
  'true'
  'false'
])
@description('Run the Neo4j MCP server in read-only mode.')
param readOnly string = 'true'

param mcpPort string = '8000'
param mcpMinReplicas string = '1'
param mcpMaxReplicas string = '3'
param mcpCpu string = '0.5'
param mcpMemory string = '1Gi'
param mcpConcurrentRequests string = '20'
param neo4jLogFormat string = 'json'
param neo4jTelemetry string = 'true'
param neo4jSchemaSampleSize string = '100'
param neo4jAllowedOrigins string = ''

var normalizedWorkload = toLower(replace(workloadName, '_', '-'))
var normalizedEnvironment = toLower(replace(environmentName, '_', '-'))
var baseName = '${normalizedWorkload}-${normalizedEnvironment}'
var commonTags = {
  workload: normalizedWorkload
  environment: normalizedEnvironment
  'azd-env-name': environmentName
  'template-name': 'neo4j-foundry-vnet'
}

resource resourceGroup 'Microsoft.Resources/resourceGroups@2024-03-01' = {
  name: 'rg-${baseName}'
  location: location
  tags: commonTags
}

module resources './resources.bicep' = {
  name: 'resources-${baseName}'
  scope: resourceGroup
  params: {
    location: location
    baseName: baseName
    commonTags: commonTags
    publicNetworkAccess: foundryPublicNetworkAccess
    modelName: foundryModelName
    modelVersion: foundryModelVersion
    modelSkuName: foundryModelSkuName
    modelCapacity: foundryModelCapacity
    principalId: principalId
    principalType: principalType
    containerImage: containerImage
    neo4jUri: neo4jUri
    neo4jDatabase: neo4jDatabase
    neo4jAdminPassword: neo4jAdminPassword
    neo4jAgentUsername: neo4jAgentUsername
    neo4jAgentPassword: neo4jAgentPassword
    neo4jNodeCount: neo4jNodeCount
    neo4jVmSize: neo4jVmSize
    neo4jDataDiskSizeGb: neo4jDataDiskSizeGb
    adminUsername: adminUsername
    sshPublicKey: sshPublicKey
    neo4jVersion: neo4jVersion
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

output resourceGroupName string = resourceGroup.name
output mcpEndpoint string = resources.outputs.mcpEndpoint
output mcpFqdn string = resources.outputs.mcpFqdn
output containerAppName string = resources.outputs.containerAppName
output containerAppsEnvironmentName string = resources.outputs.containerAppsEnvironmentName
output logAnalyticsWorkspaceName string = resources.outputs.logAnalyticsWorkspaceName
output vnetName string = resources.outputs.vnetName
output foundryResourceGroup string = resourceGroup.name
output foundryAccountName string = resources.outputs.foundryAccountName
output foundryProjectId string = resources.outputs.foundryProjectId
output foundryProjectName string = resources.outputs.foundryProjectName
output foundryProjectEndpoint string = resources.outputs.foundryProjectEndpoint
output foundryModelDeploymentName string = resources.outputs.foundryModelDeploymentName
output mcpConnectionName string = resources.outputs.mcpConnectionName
output neo4jDeployed bool = resources.outputs.neo4jDeployed
output neo4jUri string = resources.outputs.neo4jUri
output neo4jNodeIps array = resources.outputs.neo4jNodeIps
output neo4jFirstNodeIp string = resources.outputs.neo4jFirstNodeIp
output neo4jFirstNodeVmName string = resources.outputs.neo4jFirstNodeVmName
output keyVaultName string = resources.outputs.keyVaultName
output foundryPublicNetworkAccessOut string = foundryPublicNetworkAccess

output AZURE_AI_PROJECT_ENDPOINT string = resources.outputs.foundryProjectEndpoint
output AZURE_AI_MODEL_DEPLOYMENT_NAME string = resources.outputs.foundryModelDeploymentName
