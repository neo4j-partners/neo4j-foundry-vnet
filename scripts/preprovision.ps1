$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')

function Get-AzdValue([string]$Name) {
  $value = azd env get-value $Name 2>$null
  if ($LASTEXITCODE -eq 0 -and $value -notlike 'ERROR:*') { return $value }
  return ''
}

if (-not (Get-Command az -ErrorAction SilentlyContinue)) { throw 'Azure CLI (az) is required.' }
if (-not (Get-Command azd -ErrorAction SilentlyContinue)) { throw 'Azure Developer CLI (azd) is required.' }

$cloudName = az cloud show --query name --output tsv 2>$null
if ($LASTEXITCODE -ne 0 -or $cloudName.Trim() -ne 'AzureCloud') {
  throw "This template currently supports AzureCloud only; active cloud: $cloudName."
}

$requiredProviders = @(
  'Microsoft.App'
  'Microsoft.CognitiveServices'
  'Microsoft.Compute'
  'Microsoft.ContainerService'
  'Microsoft.KeyVault'
  'Microsoft.Network'
  'Microsoft.OperationalInsights'
)
foreach ($provider in $requiredProviders) {
  $state = az provider show --namespace $provider --query registrationState --output tsv 2>$null
  if ($state -ne 'Registered') {
    Write-Host "Registering required Azure resource provider $provider..."
    az provider register --namespace $provider --wait --output none
    if ($LASTEXITCODE -ne 0) { throw "Failed to register Azure resource provider $provider." }
  }
}

$configuredUri = if ($env:NEO4J_URI) { $env:NEO4J_URI } else { Get-AzdValue 'NEO4J_URI' }
$licenseAcceptance = if ($env:NEO4J_ACCEPT_LICENSE_AGREEMENT) { $env:NEO4J_ACCEPT_LICENSE_AGREEMENT } else { Get-AzdValue 'NEO4J_ACCEPT_LICENSE_AGREEMENT' }
if ([string]::IsNullOrWhiteSpace($configuredUri) -and $licenseAcceptance -ne 'yes') {
  Write-Host 'The bundled database uses Neo4j Enterprise for evaluation.'
  Write-Host 'Review: https://neo4j.com/licensing/'
  $answer = Read-Host 'Accept the Neo4j license terms for this deployment? [y/N]'
  if ($answer -notmatch '^(y|yes)$') { throw 'License not accepted. Set NEO4J_URI to use an existing private Neo4j deployment.' }
  azd env set NEO4J_ACCEPT_LICENSE_AGREEMENT yes | Out-Null
}

$agentPassword = if ($env:NEO4J_AGENT_PASSWORD) { $env:NEO4J_AGENT_PASSWORD } else { Get-AzdValue 'NEO4J_AGENT_PASSWORD' }
if ([string]::IsNullOrWhiteSpace($agentPassword)) {
  $password = -join ((1..48) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
  azd env set NEO4J_AGENT_PASSWORD $password | Out-Null
}
if ([string]::IsNullOrWhiteSpace($configuredUri)) {
  $adminPassword = if ($env:NEO4J_ADMIN_PASSWORD) { $env:NEO4J_ADMIN_PASSWORD } else { Get-AzdValue 'NEO4J_ADMIN_PASSWORD' }
  if ([string]::IsNullOrWhiteSpace($adminPassword)) {
    $password = -join ((1..48) | ForEach-Object { '{0:x}' -f (Get-Random -Maximum 16) })
    azd env set NEO4J_ADMIN_PASSWORD $password | Out-Null
  }
  $sshPublicKey = if ($env:NEO4J_VM_SSH_PUBLIC_KEY) { $env:NEO4J_VM_SSH_PUBLIC_KEY } else { Get-AzdValue 'NEO4J_VM_SSH_PUBLIC_KEY' }
  if ([string]::IsNullOrWhiteSpace($sshPublicKey)) {
    $keyPath = Join-Path '.azure' 'neo4j-admin-ed25519'
    New-Item -ItemType Directory -Force '.azure' | Out-Null
    if (-not (Test-Path "$keyPath.pub")) { ssh-keygen -q -t ed25519 -N '' -C neo4j-azd-template -f $keyPath }
    azd env set NEO4J_VM_SSH_PUBLIC_KEY (Get-Content "$keyPath.pub" -Raw).Trim() | Out-Null
  }
}
$principalId = if ($env:AZURE_PRINCIPAL_ID) { $env:AZURE_PRINCIPAL_ID } else { Get-AzdValue 'AZURE_PRINCIPAL_ID' }
if ([string]::IsNullOrWhiteSpace($principalId)) {
  $principalId = az ad signed-in-user show --query id -o tsv 2>$null
  if ($principalId) { azd env set AZURE_PRINCIPAL_ID $principalId | Out-Null }
}
$tenantId = if ($env:AZURE_TENANT_ID) { $env:AZURE_TENANT_ID } else { Get-AzdValue 'AZURE_TENANT_ID' }
if ([string]::IsNullOrWhiteSpace($tenantId)) {
  $tenantId = az account show --query tenantId -o tsv 2>$null
  if ($tenantId) { azd env set AZURE_TENANT_ID $tenantId | Out-Null }
}
