// Stores the Neo4j admin and least-privilege MCP-user passwords. Neo4j VMs
// retrieve them at boot with their system-assigned managed identities.
targetScope = 'resourceGroup'

param location string
param baseName string
param commonTags object

@description('Object ID of the deploying principal. Empty omits the deployer access policy.')
param deployerPrincipalId string = ''

@description('Private endpoint subnet resource ID.')
param peSubnetId string

@description('VNet resource ID used for private DNS linking.')
param vnetId string

@secure()
@description('Neo4j administrator password.')
param neo4jAdminPassword string

@secure()
@description('Password for the read-only database user used by the MCP server.')
param neo4jAgentPassword string

var vaultName = toLower('kv-${take(replace(baseName, '-', ''), 15)}-${substring(uniqueString(resourceGroup().id), 0, 4)}')

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' = {
  name: vaultName
  location: location
  tags: commonTags
  properties: {
    sku: {
      family: 'A'
      name: 'standard'
    }
    tenantId: tenant().tenantId
    enableSoftDelete: true
    softDeleteRetentionInDays: 7
    enableRbacAuthorization: false
    accessPolicies: empty(deployerPrincipalId) ? [] : [
      {
        tenantId: tenant().tenantId
        objectId: deployerPrincipalId
        permissions: {
          secrets: [
            'get'
            'set'
            'list'
            'delete'
            'purge'
          ]
        }
      }
    ]
    // ARM seeds the two secrets during deployment. The post-provision hook
    // disables public access after the private endpoint is ready.
    publicNetworkAccess: 'Enabled'
    networkAcls: {
      defaultAction: 'Allow'
      bypass: 'AzureServices'
    }
  }
}

resource adminSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'neo4j-admin-password'
  properties: {
    value: neo4jAdminPassword
  }
}

resource agentSecret 'Microsoft.KeyVault/vaults/secrets@2023-07-01' = {
  parent: vault
  name: 'neo4j-agent-password'
  properties: {
    value: neo4jAgentPassword
  }
}

resource dnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: 'privatelink.vaultcore.azure.net'
  location: 'global'
  tags: commonTags
}

resource dnsZoneLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: dnsZone
  name: 'link-${baseName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource privateEndpoint 'Microsoft.Network/privateEndpoints@2024-05-01' = {
  name: '${vaultName}-private-endpoint'
  location: location
  tags: commonTags
  properties: {
    subnet: {
      id: peSubnetId
    }
    privateLinkServiceConnections: [
      {
        name: '${vaultName}-connection'
        properties: {
          privateLinkServiceId: vault.id
          groupIds: [
            'vault'
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
    privateDnsZoneConfigs: [
      {
        name: 'vaultcore'
        properties: {
          privateDnsZoneId: dnsZone.id
        }
      }
    ]
  }
  dependsOn: [
    dnsZoneLink
  ]
}

output vaultName string = vault.name
output vaultUri string = vault.properties.vaultUri
