// Adds secret-read access for the Neo4j VM managed identities after those
// identities exist.
targetScope = 'resourceGroup'

param vaultName string

@description('Object IDs of the VM system-assigned managed identities.')
param principalIds array

resource vault 'Microsoft.KeyVault/vaults@2023-07-01' existing = {
  name: vaultName
}

resource policies 'Microsoft.KeyVault/vaults/accessPolicies@2023-07-01' = {
  parent: vault
  name: 'add'
  properties: {
    accessPolicies: [for principalId in principalIds: {
      tenantId: tenant().tenantId
      objectId: principalId
      permissions: {
        secrets: [
          'get'
        ]
      }
    }]
  }
}
