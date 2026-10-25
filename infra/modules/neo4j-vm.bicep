// Private Neo4j Enterprise VM deployment with optional multi-primary cluster.
// No public IP or inbound SSH is created. Management uses Azure Run Command.
targetScope = 'resourceGroup'

param location string
param baseName string
param commonTags object

@description('Neo4j subnet resource ID.')
param neo4jSubnetId string

@description('Neo4j subnet address prefix, used for static IPs and NSG scope.')
param neo4jSubnetPrefix string

@description('MCP subnet address prefix. Only this subnet can reach Bolt.')
param mcpSubnetPrefix string

@description('Key Vault URI used by VM managed identities to fetch passwords.')
param keyVaultUri string

@minValue(1)
@maxValue(7)
@description('Neo4j primary count. Use 1 for evaluation and 3 or more for a fault-tolerant Enterprise cluster.')
param nodeCount int = 1

@description('Azure VM size for each Neo4j node.')
param vmSize string = 'Standard_D4s_v5'

@minValue(64)
@description('Premium SSD data disk size for each node, in GiB.')
param dataDiskSizeGb int = 256

@description('VM administrator name. SSH is not exposed by the NSG.')
param adminUsername string = 'azureuser'

@description('SSH public key required by the Linux VM image. No public SSH endpoint is created.')
param sshPublicKey string

@description('Neo4j Enterprise version downloaded from dist.neo4j.org.')
param neo4jVersion string = '2026.07.1'

var nodeIps = [for i in range(0, nodeCount): cidrHost(neo4jSubnetPrefix, i + 4)]
var endpoints = join(map(nodeIps, ip => '${ip}:6000'), ',')

// No secret value is embedded in customData. /opt/kv-secret.sh obtains an
// Entra token from IMDS and reads Key Vault over its private endpoint.
var cloudInitTemplate = '''#cloud-config
package_update: true
packages:
  - java-21-openjdk
  - java-21-openjdk-devel
  - wget
  - lz4
  - parted
  - xfsprogs
write_files:
  - path: /etc/sysctl.d/99-neo4j.conf
    permissions: '0644'
    content: |
      vm.swappiness=1
      vm.max_map_count=262144
      fs.file-max=200000
  - path: /etc/security/limits.d/99-neo4j.conf
    permissions: '0644'
    content: |
      neo4j soft nofile 40000
      neo4j hard nofile 60000
  - path: /opt/kv-secret.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -uo pipefail
      NAME="$1"
      for i in $(seq 1 60); do
        TOKEN=$(curl -s -H Metadata:true "http://169.254.169.254/metadata/identity/oauth2/token?api-version=2018-02-01&resource=https%3A%2F%2Fvault.azure.net" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("access_token",""))' 2>/dev/null)
        if [ -n "$TOKEN" ]; then
          VALUE=$(curl -s -H "Authorization: Bearer $TOKEN" "__VAULT_URI__secrets/${NAME}?api-version=7.4" | python3 -c 'import json,sys;print(json.load(sys.stdin).get("value",""))' 2>/dev/null)
          if [ -n "$VALUE" ]; then printf '%s' "$VALUE"; exit 0; fi
        fi
        sleep 10
      done
      echo "Unable to read Key Vault secret ${NAME}" >&2
      exit 1
  - path: /opt/setup-disk.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      DEV=/dev/disk/azure/scsi1/lun0
      for i in $(seq 1 30); do [ -e "$DEV" ] && break; sleep 2; done
      PART="${DEV}-part1"
      if [ ! -e "$PART" ]; then
        parted "$DEV" --script mklabel gpt mkpart primary xfs 0% 100%
        sleep 3
        mkfs.xfs "$PART"
      fi
      mkdir -p /data/neo4j
      UUID=$(blkid -s UUID -o value "$PART")
      grep -q "$UUID" /etc/fstab || echo "UUID=$UUID /data/neo4j xfs defaults,noatime 0 2" >> /etc/fstab
      mount -a
      mkdir -p /data/neo4j/data /data/neo4j/transactions /data/neo4j/backups /data/neo4j/certificates/bolt
  - path: /opt/render-neo4j-conf.sh
    permissions: '0755'
    content: |
      #!/bin/bash
      set -euo pipefail
      cat > /opt/neo4j/conf/neo4j.conf <<'CONF'
      server.default_listen_address=0.0.0.0
      server.default_advertised_address=__THIS_IP__
      server.directories.data=/data/neo4j/data
      server.directories.transaction.logs.root=/data/neo4j/transactions
      server.directories.import=/opt/neo4j/import
      dbms.security.allow_csv_import_from_file_urls=true
      dbms.security.procedures.allowlist=apoc.*
      dbms.security.procedures.unrestricted=apoc.meta.*
      dbms.cluster.discovery.resolver_type=LIST
      dbms.cluster.endpoints=__ENDPOINTS__
      dbms.cluster.minimum_initial_system_primaries_count=__NODES__
      initial.dbms.default_primaries_count=__NODES__
      server.cluster.listen_address=:6000
      server.cluster.advertised_address=__THIS_IP__:6000
      server.cluster.raft.listen_address=:7000
      server.cluster.raft.advertised_address=__THIS_IP__:7000
      server.routing.listen_address=:7688
      server.routing.advertised_address=__THIS_IP__:7688
      server.http.enabled=false
      server.https.enabled=false
      server.bolt.enabled=true
      server.bolt.listen_address=:7687
      server.bolt.advertised_address=__THIS_IP__:7687
      server.bolt.tls_level=REQUIRED
      dbms.ssl.policy.bolt.enabled=true
      dbms.ssl.policy.bolt.base_directory=/data/neo4j/certificates/bolt
      dbms.ssl.policy.bolt.private_key=private.key
      dbms.ssl.policy.bolt.public_certificate=public.crt
      dbms.ssl.policy.bolt.client_auth=NONE
      server.memory.heap.initial_size=2g
      server.memory.heap.max_size=2g
      server.memory.pagecache.size=2g
      server.config.strict_validation.enabled=false
      CONF
  - path: /etc/systemd/system/neo4j-backup.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Neo4j online backup
      [Service]
      Type=oneshot
      User=neo4j
      ExecStart=/bin/bash -lc '/opt/neo4j/bin/neo4j-admin database backup --to-path=/data/neo4j/backups neo4j system'
  - path: /etc/systemd/system/neo4j.service
    permissions: '0644'
    content: |
      [Unit]
      Description=Neo4j graph database
      After=network-online.target
      Wants=network-online.target
      RequiresMountsFor=/data/neo4j
      [Service]
      Type=simple
      User=neo4j
      Group=neo4j
      Environment=HOME=/opt/neo4j
      Environment=NEO4J_ACCEPT_LICENSE_AGREEMENT=yes
      ExecStart=/bin/bash -lc 'export JAVA_HOME=$(dirname $(dirname $(readlink -f $(command -v java)))); exec /opt/neo4j/bin/neo4j console'
      Restart=on-failure
      RestartSec=10
      LimitNOFILE=60000
      TimeoutStopSec=120
      [Install]
      WantedBy=multi-user.target
  - path: /etc/systemd/system/neo4j-backup.timer
    permissions: '0644'
    content: |
      [Unit]
      Description=Daily Neo4j backup
      [Timer]
      OnCalendar=*-*-* 03:00:00
      Persistent=true
      [Install]
      WantedBy=timers.target
runcmd:
  - sysctl --system || true
  - echo never > /sys/kernel/mm/transparent_hugepage/enabled || true
  - JH=$(ls -d /usr/lib/jvm/java-21-openjdk* | head -1); alternatives --install /usr/bin/java java $JH/bin/java 2100 || true; alternatives --set java $JH/bin/java || true
  - for p in 7687 7688 5000 6000 7000 6362; do firewall-cmd --permanent --add-port=${p}/tcp || true; done
  - firewall-cmd --reload || true
  - /opt/setup-disk.sh
  - cd /tmp && wget -q https://dist.neo4j.org/neo4j-enterprise-__VERSION__-unix.tar.gz
  - EXPECTED_SHA256=$(wget -qO- https://dist.neo4j.org/neo4j-enterprise-__VERSION__-unix.tar.gz.sha256) && echo "$EXPECTED_SHA256  /tmp/neo4j-enterprise-__VERSION__-unix.tar.gz" | sha256sum --check --strict
  - tar -xzf /tmp/neo4j-enterprise-__VERSION__-unix.tar.gz -C /opt
  - mv /opt/neo4j-enterprise-__VERSION__ /opt/neo4j
  - id neo4j >/dev/null 2>&1 || useradd --system --home /opt/neo4j --shell /bin/bash neo4j
  - cp /opt/neo4j/labs/apoc-*-core.jar /opt/neo4j/plugins/ 2>/dev/null || true
  - /opt/render-neo4j-conf.sh
  - openssl req -x509 -newkey rsa:2048 -nodes -keyout /data/neo4j/certificates/bolt/private.key -out /data/neo4j/certificates/bolt/public.crt -days 825 -subj "/CN=__THIS_IP__" -addext "subjectAltName=IP:__THIS_IP__"
  - JH=$(ls -d /usr/lib/jvm/java-21-openjdk* | head -1); JAVA_HOME=$JH /opt/neo4j/bin/neo4j-admin server license --accept-commercial
  - JH=$(ls -d /usr/lib/jvm/java-21-openjdk* | head -1); PW="$(/opt/kv-secret.sh neo4j-admin-password)" && JAVA_HOME=$JH /opt/neo4j/bin/neo4j-admin dbms set-initial-password "$PW"
  - chown -R neo4j:neo4j /opt/neo4j /data/neo4j
  - systemctl daemon-reload
  - systemctl enable --now neo4j.service
  - systemctl enable --now neo4j-backup.timer || true
'''

resource nsg 'Microsoft.Network/networkSecurityGroups@2024-05-01' = {
  name: 'nsg-${baseName}'
  location: location
  tags: commonTags
  properties: {
    securityRules: [
      {
        name: 'AllowBoltFromMcpSubnet'
        properties: {
          priority: 1000
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: mcpSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: neo4jSubnetPrefix
          destinationPortRanges: [
            '7687'
            '7688'
          ]
        }
      }
      {
        name: 'AllowClusterIntraSubnet'
        properties: {
          priority: 1100
          direction: 'Inbound'
          access: 'Allow'
          protocol: 'Tcp'
          sourceAddressPrefix: neo4jSubnetPrefix
          sourcePortRange: '*'
          destinationAddressPrefix: neo4jSubnetPrefix
          destinationPortRanges: [
            '5000'
            '6000'
            '7000'
            '7688'
            '6362'
          ]
        }
      }
      {
        name: 'DenyAllInbound'
        properties: {
          priority: 4096
          direction: 'Inbound'
          access: 'Deny'
          protocol: '*'
          sourceAddressPrefix: '*'
          sourcePortRange: '*'
          destinationAddressPrefix: '*'
          destinationPortRange: '*'
        }
      }
    ]
  }
}

resource nics 'Microsoft.Network/networkInterfaces@2024-05-01' = [for i in range(0, nodeCount): {
  name: 'nic-${baseName}-${i}'
  location: location
  tags: commonTags
  properties: {
    networkSecurityGroup: {
      id: nsg.id
    }
    ipConfigurations: [
      {
        name: 'ipconfig1'
        properties: {
          privateIPAllocationMethod: 'Static'
          privateIPAddress: nodeIps[i]
          subnet: {
            id: neo4jSubnetId
          }
        }
      }
    ]
  }
}]

resource vms 'Microsoft.Compute/virtualMachines@2024-07-01' = [for i in range(0, nodeCount): {
  name: 'vm-${baseName}-${i}'
  location: location
  tags: commonTags
  identity: {
    type: 'SystemAssigned'
  }
  properties: {
    hardwareProfile: {
      vmSize: vmSize
    }
    securityProfile: {
      securityType: 'TrustedLaunch'
      uefiSettings: {
        secureBootEnabled: true
        vTpmEnabled: true
      }
    }
    osProfile: {
      computerName: 'neo4j-${i}'
      adminUsername: adminUsername
      linuxConfiguration: {
        disablePasswordAuthentication: true
        ssh: {
          publicKeys: [
            {
              path: '/home/${adminUsername}/.ssh/authorized_keys'
              keyData: sshPublicKey
            }
          ]
        }
      }
      customData: base64(replace(replace(replace(replace(replace(cloudInitTemplate, '__THIS_IP__', nodeIps[i]), '__ENDPOINTS__', endpoints), '__NODES__', string(nodeCount)), '__VERSION__', neo4jVersion), '__VAULT_URI__', keyVaultUri))
    }
    storageProfile: {
      imageReference: {
        publisher: 'RedHat'
        offer: 'RHEL'
        sku: '96-gen2'
        version: 'latest'
      }
      osDisk: {
        createOption: 'FromImage'
        diskSizeGB: 128
        managedDisk: {
          storageAccountType: 'Premium_LRS'
        }
      }
      dataDisks: [
        {
          lun: 0
          createOption: 'Empty'
          diskSizeGB: dataDiskSizeGb
          managedDisk: {
            storageAccountType: 'Premium_LRS'
          }
        }
      ]
    }
    networkProfile: {
      networkInterfaces: [
        {
          id: nics[i].id
        }
      ]
    }
  }
}]

output nodeIps array = nodeIps
output boltUri string = 'neo4j+ssc://${nodeIps[0]}:7687'
output firstNodeIp string = nodeIps[0]
output firstNodeVmName string = 'vm-${baseName}-0'
output vmPrincipalIds array = [for i in range(0, nodeCount): vms[i].identity.principalId]
