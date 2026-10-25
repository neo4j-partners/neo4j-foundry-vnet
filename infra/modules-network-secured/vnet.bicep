/*
Virtual Network Module
This module deploys the core network infrastructure with security controls:

1. Address Space:
   - VNet CIDR: 172.16.0.0/16 OR 192.168.0.0/16
   - Agents Subnet: 172.16.0.0/24 OR 192.168.0.0/24 (reserved for Azure AI Foundry)
   - Private Endpoint Subnet: 172.16.1.0/24 OR 192.168.1.0/24
   - MCP Subnet: 172.16.2.0/24 OR 192.168.2.0/24 (for user Container Apps)

2. Security Features:
   - Network isolation
   - Subnet delegation
   - Private endpoint subnet
*/

@description('Azure region for the deployment')
param location string

@description('The name of the virtual network')
param vnetName string = 'agents-vnet-test'

@description('The name of Agents Subnet')
param agentSubnetName string = 'agent-subnet'

@description('The name of Hub subnet')
param peSubnetName string = 'pe-subnet'

@description('The name of MCP subnet for user-deployed Container Apps')
param mcpSubnetName string = 'mcp-subnet'

@description('The name of the Neo4j subnet used by private Neo4j VMs')
param neo4jSubnetName string = 'neo4j-subnet'

@description('Address space for the VNet')
param vnetAddressPrefix string = ''

@description('Address prefix for the agent subnet')
param agentSubnetPrefix string = ''

@description('Address prefix for the private endpoint subnet')
param peSubnetPrefix string = ''

@description('Address prefix for the MCP subnet')
param mcpSubnetPrefix string = ''

@description('Address prefix for the Neo4j subnet')
param neo4jSubnetPrefix string = ''

var defaultVnetAddressPrefix = '192.168.0.0/16'
var vnetAddress = empty(vnetAddressPrefix) ? defaultVnetAddressPrefix : vnetAddressPrefix
var agentSubnet = empty(agentSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 0) : agentSubnetPrefix
var peSubnet = empty(peSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 1) : peSubnetPrefix
var mcpSubnet = empty(mcpSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 2) : mcpSubnetPrefix
var neo4jSubnet = empty(neo4jSubnetPrefix) ? cidrSubnet(vnetAddress, 24, 3) : neo4jSubnetPrefix

// Neo4j VMs have no public IP. Explicit NAT supplies outbound access for OS
// packages and the Neo4j distribution while keeping inbound access private.
resource natPublicIp 'Microsoft.Network/publicIPAddresses@2024-05-01' = {
  name: 'pip-${vnetName}-nat'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    publicIPAllocationMethod: 'Static'
  }
}

resource natGateway 'Microsoft.Network/natGateways@2024-05-01' = {
  name: 'nat-${vnetName}'
  location: location
  sku: {
    name: 'Standard'
  }
  properties: {
    idleTimeoutInMinutes: 10
    publicIpAddresses: [
      {
        id: natPublicIp.id
      }
    ]
  }
}

resource virtualNetwork 'Microsoft.Network/virtualNetworks@2024-05-01' = {
  name: vnetName
  location: location
  properties: {
    addressSpace: {
      addressPrefixes: [
        vnetAddress
      ]
    }
    subnets: [
      {
        name: agentSubnetName
        properties: {
          addressPrefix: agentSubnet
          delegations: [
            {
              name: 'Microsoft.app/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        name: peSubnetName
        properties: {
          addressPrefix: peSubnet
        }
      }
      {
        name: mcpSubnetName
        properties: {
          addressPrefix: mcpSubnet
          delegations: [
            {
              name: 'Microsoft.App/environments'
              properties: {
                serviceName: 'Microsoft.App/environments'
              }
            }
          ]
        }
      }
      {
        // Plain subnet for the private Neo4j VM deployment.
        name: neo4jSubnetName
        properties: {
          addressPrefix: neo4jSubnet
          natGateway: {
            id: natGateway.id
          }
        }
      }
    ]
  }
}
// Output variables
output peSubnetName string = peSubnetName
output agentSubnetName string = agentSubnetName
output mcpSubnetName string = mcpSubnetName
output neo4jSubnetName string = neo4jSubnetName
output neo4jSubnetPrefix string = neo4jSubnet
output mcpSubnetPrefix string = mcpSubnet
output agentSubnetId string = '${virtualNetwork.id}/subnets/${agentSubnetName}'
output peSubnetId string = '${virtualNetwork.id}/subnets/${peSubnetName}'
output mcpSubnetId string = '${virtualNetwork.id}/subnets/${mcpSubnetName}'
output neo4jSubnetId string = '${virtualNetwork.id}/subnets/${neo4jSubnetName}'
output virtualNetworkName string = virtualNetwork.name
output virtualNetworkId string = virtualNetwork.id
output virtualNetworkResourceGroup string = resourceGroup().name
output virtualNetworkSubscriptionId string = subscription().subscriptionId
