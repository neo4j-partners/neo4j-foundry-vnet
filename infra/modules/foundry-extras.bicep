// Project-scoped MCP authentication connection and optional Foundry User role.
targetScope = 'resourceGroup'

param accountName string
param projectName string

@description('Private Neo4j MCP endpoint URL.')
param neo4jMcpEndpoint string

@description('Least-privilege Neo4j database username.')
param neo4jUsername string

@secure()
@description('Password for the least-privilege Neo4j database user.')
param neo4jPassword string

@description('Entra object ID granted Foundry User at project scope. Empty omits the assignment.')
param principalId string = ''

@allowed([
  'User'
  'ServicePrincipal'
])
param principalType string = 'User'

var foundryUserRoleId = '53ca6127-db72-4b80-b1b0-d745d6d5456d'
var mcpConnectionName = 'neo4j-mcp-auth'

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

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
output mcpConnectionName string = mcpAuthConnection.name
