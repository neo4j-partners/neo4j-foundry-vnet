// Foundry account private endpoint and the three required private DNS zones.
// Adapted from the official 11-private-network-basic-vnet sample.
targetScope = 'resourceGroup'

param location string
param aiAccountName string
param vnetId string
param peSubnetId string
param suffix string
param commonTags object

resource aiAccount 'Microsoft.CognitiveServices/accounts@2025-04-01-preview' existing = {
  name: aiAccountName
}

var dnsZoneNames = [
  'privatelink.services.ai.azure.com'
  'privatelink.openai.azure.com'
  'privatelink.cognitiveservices.azure.com'
]

resource dnsZones 'Microsoft.Network/privateDnsZones@2024-06-01' = [for zoneName in dnsZoneNames: {
  name: zoneName
  location: 'global'
  tags: commonTags
}]

resource dnsLinks 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = [for (zoneName, index) in dnsZoneNames: {
  parent: dnsZones[index]
  name: 'link-${suffix}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}]

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${aiAccountName}-private-endpoint'
  location: location
  tags: commonTags
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${aiAccountName}-connection'
        properties: {
          privateLinkServiceId: aiAccount.id
          groupIds: [
            'account'
          ]
        }
      }
    ]
  }
}

resource privateEndpointDns 'Microsoft.Network/privateEndpoints/privateDnsZoneGroups@2024-05-01' = {
  parent: privateEndpoint
  name: 'default'
  properties: {
    privateDnsZoneConfigs: [for (zoneName, index) in dnsZoneNames: {
      name: 'zone-${index}'
      properties: {
        privateDnsZoneId: dnsZones[index].id
      }
    }]
  }
  dependsOn: [
    dnsLinks
  ]
}

output privateEndpointId string = privateEndpoint.id
