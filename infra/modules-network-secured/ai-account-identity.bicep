param accountName string
param location string
param modelName string
param modelFormat string
param modelVersion string
param modelSkuName string
param modelCapacity int
param agentSubnetId string
param networkInjection string = 'true'

// Deviation from upstream template 19: publicNetworkAccess is a parameter.
// 'Enabled' keeps the Foundry endpoint reachable from the internet (portal /
// SDK testing without VPN) while agent egress still goes through the injected
// VNet and all backend resources stay private — the documented "public inbound"
// variant of template 19. 'Disabled' is the fully-private enterprise mode.
@allowed([
  'Enabled'
  'Disabled'
])
param publicNetworkAccess string = 'Disabled'

#disable-next-line BCP036
resource account 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' = {
  name: accountName
  location: location
  sku: {
    name: 'S0'
  }
  kind: 'AIServices'
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    allowProjectManagement: true
    customSubDomainName: accountName
    networkAcls: {
      defaultAction: publicNetworkAccess == 'Enabled' ? 'Allow' : 'Deny'
      virtualNetworkRules: []
      ipRules: []
      bypass: 'AzureServices'
    }
    publicNetworkAccess: publicNetworkAccess
    networkInjections: ((networkInjection == 'true')
      ? [
          {
            scenario: 'agent'
            subnetArmId: agentSubnetId
            useMicrosoftManagedNetwork: false
          }
        ]
      : null)
    disableLocalAuth: true
  }
}

#disable-next-line BCP081
resource modelDeployment 'Microsoft.CognitiveServices/accounts/deployments@2025-04-01-preview' = {
  parent: account
  name: modelName
  sku: {
    capacity: modelCapacity
    name: modelSkuName
  }
  properties: {
    model: {
      name: modelName
      format: modelFormat
      version: modelVersion
    }
  }
}

output accountName string = account.name
output accountID string = account.id
output accountTarget string = account.properties.endpoint
output accountPrincipalId string = account.identity.principalId
