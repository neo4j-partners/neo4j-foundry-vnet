// Basic Agent Setup capability host. Platform-managed agent data resources are
// used, so no Cosmos DB, Storage, or AI Search connections are supplied.
targetScope = 'resourceGroup'

param projectName string
param accountName string
param projectCapHost string = 'caphostproj'

resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: accountName
}

resource project 'Microsoft.CognitiveServices/accounts/projects@2025-04-01-preview' existing = {
  parent: account
  name: projectName
}

resource capabilityHost 'Microsoft.CognitiveServices/accounts/projects/capabilityHosts@2025-04-01-preview' = {
  parent: project
  name: projectCapHost
  properties: {
    #disable-next-line BCP037
    capabilityHostKind: 'Agents'
  }
}

output capabilityHostName string = capabilityHost.name
