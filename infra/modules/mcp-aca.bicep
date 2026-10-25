// Private Neo4j MCP server: internal-only Azure Container Apps environment on the
// dedicated MCP subnet, plus the private DNS zone that lets the VNet (and the
// Foundry Agent Service data proxy injected into the agent subnet) resolve the
// app's FQDN. Container/app settings are ported from the public example
// (neo4j-agent-integrations/microsoft-foundry/infra/infra/app.bicep); the delta
// is the VNet integration, internal ingress, and private DNS.
targetScope = 'resourceGroup'

param location string
param baseName string
param commonTags object

@description('Resource ID of the MCP subnet (delegated to Microsoft.App/environments).')
param mcpSubnetId string

@description('Container image for the Neo4j MCP server.')
param containerImage string

param neo4jUri string
param neo4jDatabase string

@allowed([
  'true'
  'false'
])
param readOnly string
param mcpPort string
param mcpMinReplicas string
param mcpMaxReplicas string
param mcpCpu string
param mcpMemory string
param mcpConcurrentRequests string
param neo4jLogFormat string
@allowed([
  'true'
  'false'
])
param neo4jTelemetry string
param neo4jSchemaSampleSize string
param neo4jAllowedOrigins string

var logAnalyticsName = 'log-${baseName}'
var containerAppsEnvironmentName = 'cae-${baseName}'
var containerAppName = 'ca-${baseName}'

resource logAnalytics 'Microsoft.OperationalInsights/workspaces@2023-09-01' = {
  name: logAnalyticsName
  location: location
  tags: commonTags
  properties: {
    sku: {
      name: 'PerGB2018'
    }
    retentionInDays: 30
  }
}

// Internal-only environment: no public endpoint at all. The env gets a static
// IP inside the MCP subnet. A /24 subnet requires the workload-profiles
// (v2) environment type; the Consumption profile keeps billing serverless.
resource containerAppsEnvironment 'Microsoft.App/managedEnvironments@2024-03-01' = {
  name: containerAppsEnvironmentName
  location: location
  tags: commonTags
  properties: {
    appLogsConfiguration: {
      destination: 'log-analytics'
      logAnalyticsConfiguration: {
        customerId: logAnalytics.properties.customerId
        sharedKey: logAnalytics.listKeys().primarySharedKey
      }
    }
    vnetConfiguration: {
      infrastructureSubnetId: mcpSubnetId
      internal: true
    }
    workloadProfiles: [
      {
        name: 'Consumption'
        workloadProfileType: 'Consumption'
      }
    ]
  }
}

resource mcpContainerApp 'Microsoft.App/containerApps@2024-03-01' = {
  name: containerAppName
  location: location
  tags: commonTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    managedEnvironmentId: containerAppsEnvironment.id
    workloadProfileName: 'Consumption'
    configuration: {
      activeRevisionsMode: 'Single'
      ingress: {
        // "external" within an internal-only environment means: reachable from
        // the whole VNet (via the env's static IP), still no public exposure.
        external: true
        targetPort: int(mcpPort)
        transport: 'http'
        allowInsecure: false
      }
    }
    template: {
      containers: [
        {
          name: 'neo4j-mcp'
          image: containerImage
          env: [
            { name: 'NEO4J_URI', value: neo4jUri }
            { name: 'NEO4J_DATABASE', value: neo4jDatabase }
            { name: 'NEO4J_TRANSPORT_MODE', value: 'http' }
            { name: 'NEO4J_MCP_HTTP_HOST', value: '0.0.0.0' }
            { name: 'NEO4J_MCP_HTTP_PORT', value: mcpPort }
            { name: 'NEO4J_READ_ONLY', value: readOnly }
            { name: 'NEO4J_LOG_FORMAT', value: neo4jLogFormat }
            { name: 'NEO4J_TELEMETRY', value: neo4jTelemetry }
            { name: 'NEO4J_SCHEMA_SAMPLE_SIZE', value: neo4jSchemaSampleSize }
            { name: 'NEO4J_MCP_HTTP_ALLOWED_ORIGINS', value: neo4jAllowedOrigins }
          ]
          resources: {
            cpu: json(mcpCpu)
            memory: mcpMemory
          }
        }
      ]
      scale: {
        minReplicas: int(mcpMinReplicas)
        maxReplicas: int(mcpMaxReplicas)
        rules: [
          {
            name: 'http-scale'
            http: {
              metadata: {
                concurrentRequests: mcpConcurrentRequests
              }
            }
          }
        ]
      }
    }
  }
}

// Private DNS (zone named after the env's runtime defaultDomain) lives in
// modules/mcp-dns.bicep — resource names can't be runtime values here, but
// they can be module parameters.
output defaultDomain string = containerAppsEnvironment.properties.defaultDomain
output mcpEndpoint string = 'https://${mcpContainerApp.properties.configuration.ingress.fqdn}/mcp'
output mcpFqdn string = mcpContainerApp.properties.configuration.ingress.fqdn
output containerAppName string = mcpContainerApp.name
output containerAppsEnvironmentName string = containerAppsEnvironment.name
output containerAppsEnvironmentStaticIp string = containerAppsEnvironment.properties.staticIp
output logAnalyticsWorkspaceName string = logAnalytics.name
