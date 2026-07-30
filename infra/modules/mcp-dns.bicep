// Private DNS for the internal Container Apps environment: a zone named after
// the env's default domain with a wildcard A record pointing at the env's
// static IP, linked to the VNet. This is what lets the Foundry agent data
// proxy (injected into the agent subnet) resolve the private MCP FQDN — the
// missing piece behind MS Q&A issue 5849073 before private MCP support.
// Separate module because a resource name can't be a runtime value in the
// declaring template, but it CAN be a module parameter.
targetScope = 'resourceGroup'

param baseName string
param commonTags object

@description('The internal ACA environment default domain, e.g. <name>.<region>.azurecontainerapps.io.')
param defaultDomain string

@description('The internal ACA environment static IP inside the MCP subnet.')
param staticIp string

@description('Resource ID of the VNet to link the zone to.')
param vnetId string

resource mcpDnsZone 'Microsoft.Network/privateDnsZones@2024-06-01' = {
  name: defaultDomain
  location: 'global'
  tags: commonTags
}

resource mcpDnsZoneVnetLink 'Microsoft.Network/privateDnsZones/virtualNetworkLinks@2024-06-01' = {
  parent: mcpDnsZone
  name: 'link-${baseName}'
  location: 'global'
  properties: {
    registrationEnabled: false
    virtualNetwork: {
      id: vnetId
    }
  }
}

resource mcpDnsWildcard 'Microsoft.Network/privateDnsZones/A@2024-06-01' = {
  parent: mcpDnsZone
  name: '*'
  properties: {
    ttl: 300
    aRecords: [
      {
        ipv4Address: staticIp
      }
    ]
  }
}

output dnsZoneName string = mcpDnsZone.name
