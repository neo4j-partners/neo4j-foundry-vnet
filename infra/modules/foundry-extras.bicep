// Additions on top of the vendored template-19 modules:
// - text-embedding deployment (matches the neo4j-agent-integrations example so the
//   same demo-graph vector workflows keep working)
// - Foundry User role assignment at PROJECT scope for the deploying principal so
//   `az login` is all the auth the agent scripts need
// - project endpoint output (the vendored ai-project-identity module doesn't expose it)
param accountName string
param projectName string

param embeddingModelName string
param embeddingModelVersion string
param embeddingModelSkuName string
param embeddingModelCapacity int

@description('Private Neo4j MCP endpoint URL, stored in the MCP auth project connection.')
param neo4jMcpEndpoint string

@description('Neo4j username for the MCP Basic-auth header.')
param neo4jUsername string

@description('Neo4j password for the MCP Basic-auth header.')
@secure()
param neo4jPassword string

@description('Entra object ID granted the Foundry User role on the project. Empty disables the role assignment.')
param principalId string = ''
@allowed([
  'User'
  'ServicePrincipal'
])
param principalType string = 'User'

// Foundry User — least-privilege built-in role to create/run agents via the
// project endpoint. Assigned at project scope, matching the base example.
var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

// ARM does not allow two deployments under one account to provision in parallel;
// the caller sequences this module after the chat-model deployment via dependsOn.
#disable-next-line BCP081
resource embeddingDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: account
  name: embeddingModelName
  sku: {
    name: embeddingModelSkuName
    capacity: embeddingModelCapacity
  }
  properties: {
    model: {
      format: 'OpenAI'
      name: embeddingModelName
      version: embeddingModelVersion
    }
  }
}

// MCP auth project connection. The Agent Service rejects sensitive headers
// (like Authorization) passed inline on the MCP tool — they must come from a
// project connection referenced via `project_connection_id`. The keys in a
// CustomKeys connection are forwarded to the MCP server as HTTP headers.
var mcpConnectionName = 'neo4j-mcp-auth'

resource mcpAuthConnection 'Microsoft.CognitiveServices/accounts/projects/connections@2025-04-01-preview' = {
  parent: project
  name: mcpConnectionName
  properties: {
    category: 'CustomKeys'
    target: neo4jMcpEndpoint
    authType: 'CustomKeys'
    isSharedToAll: false
    credentials: {
      keys: {
        Authorization: 'Basic ${base64('${neo4jUsername}:${neo4jPassword}')}'
      }
    }
    metadata: {}
  }
}

resource deployerRoleAssignment 'Microsoft.Authorization/roleAssignments@2022-04-01' = if (!empty(principalId)) {
  scope: project
  name: guid(project.id, principalId, foundryUserRoleId)
  properties: {
    roleDefinitionId: subscriptionResourceId('Microsoft.Authorization/roleDefinitions', foundryUserRoleId)
    principalId: principalId
    principalType: principalType
  }
}

output projectEndpoint string = project.properties.endpoints['AI Foundry API']
output embeddingDeploymentName string = embeddingDeployment.name
output mcpConnectionName string = mcpAuthConnection.name
