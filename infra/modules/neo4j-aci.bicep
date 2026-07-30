// Private Neo4j Enterprise (single node) on Azure Container Instances, injected
// into the delegated neo4j-subnet. Private IP only — no public IP, no ingress.
// The MCP server (in the internal ACA env on the same VNet) reaches it over
// private Bolt. An Azure Files share is mounted at /import so the synthetic
// seed can be loaded from inside the VNet (see load-data.sh) without ever
// exposing the database.
//
// This is a POC-grade single node with an EVAL license and plaintext in-VNet
// Bolt. Production hardening (3+ primary cluster, Bolt TLS, Key Vault secrets,
// read-only least-privilege user) is called out in the README.
targetScope = 'resourceGroup'

param location string
param baseName string
param commonTags object

@description('Resource ID of the neo4j-subnet (delegated to Microsoft.ContainerInstance/containerGroups).')
param neo4jSubnetId string

@description('Neo4j Enterprise container image.')
param neo4jImage string = 'neo4j:2025.10.1-enterprise'

@description('Neo4j username.')
param neo4jUsername string = 'neo4j'

@description('Neo4j password.')
@secure()
param neo4jPassword string

@description('Container CPU cores.')
param cpuCores int = 2

@description('Container memory in GB.')
param memoryGb int = 4

// Dedicated Standard_LRS storage account for the /import file share. Kept
// separate from the Foundry BYO storage (which is locked down and key-less).
var storageName = toLower(take('stn4j${replace(baseName, '-', '')}', 24))
var importShareName = 'neo4j-import'
var containerGroupName = 'aci-neo4j-${baseName}'

resource storage 'Microsoft.Storage/storageAccounts@2023-05-01' = {
  name: storageName
  location: location
  tags: commonTags
  sku: {
    name: 'Standard_LRS'
  }
  kind: 'StorageV2'
  properties: {
    minimumTlsVersion: 'TLS1_2'
    allowBlobPublicAccess: false
  }
}

resource fileService 'Microsoft.Storage/storageAccounts/fileServices@2023-05-01' = {
  parent: storage
  name: 'default'
}

resource importShare 'Microsoft.Storage/storageAccounts/fileServices/shares@2023-05-01' = {
  parent: fileService
  name: importShareName
  properties: {
    shareQuota: 5
  }
}

resource neo4j 'Microsoft.ContainerInstance/containerGroups@2023-05-01' = {
  name: containerGroupName
  location: location
  tags: commonTags
  properties: {
    osType: 'Linux'
    restartPolicy: 'OnFailure'
    subnetIds: [
      {
        id: neo4jSubnetId
      }
    ]
    // Private IP inside the VNet — no public exposure.
    ipAddress: {
      type: 'Private'
      ports: [
        { protocol: 'TCP', port: 7687 }
        { protocol: 'TCP', port: 7474 }
      ]
    }
    volumes: [
      {
        name: 'import'
        azureFile: {
          shareName: importShareName
          storageAccountName: storage.name
          storageAccountKey: storage.listKeys().keys[0].value
        }
      }
    ]
    containers: [
      {
        name: 'neo4j'
        properties: {
          image: neo4jImage
          ports: [
            { protocol: 'TCP', port: 7687 }
            { protocol: 'TCP', port: 7474 }
          ]
          resources: {
            requests: {
              cpu: cpuCores
              memoryInGB: memoryGb
            }
          }
          volumeMounts: [
            {
              name: 'import'
              mountPath: '/import'
            }
          ]
          environmentVariables: [
            { name: 'NEO4J_ACCEPT_LICENSE_AGREEMENT', value: 'eval' }
            { name: 'NEO4J_AUTH', secureValue: '${neo4jUsername}/${neo4jPassword}' }
            { name: 'NEO4J_server_memory_heap_initial__size', value: '1G' }
            { name: 'NEO4J_server_memory_heap_max__size', value: '1G' }
            { name: 'NEO4J_server_memory_pagecache_size', value: '1G' }
            // APOC core ships with Enterprise; enable it for richer demo queries.
            { name: 'NEO4J_PLUGINS', value: '["apoc"]' }
          ]
        }
      }
    ]
  }
}

output containerGroupName string = neo4j.name
output privateIp string = neo4j.properties.ipAddress.ip
output boltUri string = 'bolt://${neo4j.properties.ipAddress.ip}:7687'
output storageAccountName string = storage.name
output importShareName string = importShareName
