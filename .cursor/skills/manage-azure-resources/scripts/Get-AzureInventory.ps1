<#
Inventario de solo lectura de una suscripcion/Resource Group, via Azure
Resource Graph (preferido, soporta consultas amplias) con fallback a
`az resource list`. Escribe un snapshot sanitizado bajo .local\azure\inventory\
con su propio hash SHA-256 -- ese hash es lo que New-AzureChangePlan.ps1 y
Test-AzureChangePlan.ps1 referencian como evidencia de inventario.

Uso:
  & '.\Get-AzureInventory.ps1' -SubscriptionId <id> [-ResourceGroup <rg>] [-Query <KQL>]
#>
param(
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$Query,
    [switch]$IncludeLocks,
    [switch]$IncludeActivityLog
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Azure-Common.ps1')

$acct = Get-AzureAccountContext -SubscriptionId $SubscriptionId
if (-not $acct) {
    throw "Get-AzureInventory rechazado: no hay sesion activa de Azure CLI para la suscripcion '$SubscriptionId'. Pedir al usuario que corra 'az login' manualmente."
}

$kql = if ($Query) { $Query } elseif ($ResourceGroup) {
    "Resources | where resourceGroup =~ '$ResourceGroup' | project id, name, type, resourceGroup, location, tags, properties | order by type asc, name asc"
}
else {
    "Resources | project id, name, type, resourceGroup, location, tags | order by type asc, name asc"
}

$graphArgv = @('graph', 'query', '-q', $kql, '--subscriptions', $SubscriptionId, '--first', '1000')
$graphResult = Invoke-AzureCliJson -Argv $graphArgv

$resources = $null
$source = 'resource-graph'
if ($graphResult -and $graphResult.data) {
    $resources = @($graphResult.data)
}
else {
    $source = 'az-resource-list'
    $fallbackArgv = @('resource', 'list', '--subscription', $SubscriptionId)
    if ($ResourceGroup) { $fallbackArgv += @('--resource-group', $ResourceGroup) }
    # No envolver la llamada directo en @(...): @(Invoke-AzureCliJson ...) produce un
    # resultado truncado/mal formado en PowerShell 5.1 cuando la funcion invoca un
    # ejecutable nativo con redireccion adentro (reproducido en vivo 2026-09-03,
    # contra la suscripcion real: devolvia 1 elemento envuelto en {"value":[...]} en
    # vez de los 445 reales). Asignar primero y envolver despues evita el problema.
    $rawFallbackResources = Invoke-AzureCliJson -Argv $fallbackArgv
    $resources = @($rawFallbackResources)
}

$locks = @()
if ($IncludeLocks) {
    $lockArgv = @('lock', 'list', '--subscription', $SubscriptionId)
    if ($ResourceGroup) { $lockArgv += @('--resource-group', $ResourceGroup) }
    # Ver el comentario de mas arriba: no envolver la llamada directo en @(...).
    $rawLocks = Invoke-AzureCliJson -Argv $lockArgv
    $locks = @($rawLocks)
}

$activityLog = @()
if ($IncludeActivityLog) {
    $alArgv = @('monitor', 'activity-log', 'list', '--subscription', $SubscriptionId, '--offset', '24h')
    if ($ResourceGroup) { $alArgv += @('--resource-group', $ResourceGroup) }
    $rawActivityLog = Invoke-AzureCliJson -Argv $alArgv
    $activityLog = @($rawActivityLog)
}

$snapshot = [ordered]@{
    schemaVersion    = 1
    capturedAtUtc    = (Get-Date).ToUniversalTime().ToString('o')
    tenantId         = $acct.tenantId
    subscriptionId   = $acct.subscriptionId
    subscriptionName = $acct.subscriptionName
    resourceGroup    = $ResourceGroup
    source           = $source
    query            = $kql
    resourceCount    = @($resources).Count
    resources        = @($resources)
    locks            = @($locks)
    activityLog      = @($activityLog)
}

Assert-AzureDirectoryExists -Path (Get-AzureInventoryDir)
$fileName = "inv-$($acct.subscriptionId)-$(if ($ResourceGroup) { $ResourceGroup } else { 'all' })-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ')).json"
$path = Join-Path (Get-AzureInventoryDir) $fileName
($snapshot | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $path -Encoding utf8

$hash = Get-AzureFileSha256 -Path $path

[PSCustomObject]@{
    path          = $path
    hash          = $hash
    resourceCount = $snapshot.resourceCount
    source        = $source
}
