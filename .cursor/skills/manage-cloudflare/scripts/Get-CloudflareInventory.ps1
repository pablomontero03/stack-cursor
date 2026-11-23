<#
Inventario sanitizado de solo lectura: cuenta, zonas y (opcionalmente)
registros DNS de las zonas indicadas. Escribe un JSON bajo
.local\cloudflare\inventory\ con nombre timestamp+guid y devuelve la ruta +
hash del archivo escrito, listo para -InventoryPaths de
New-CloudflareChangePlan.ps1 / New-CloudflareDeletePlan.ps1.
#>
param(
    [Parameter(Mandatory)] [string]$AccountId,
    [string[]]$ZoneIds = @()
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cloudflare-Common.ps1')

$readScript = Join-Path $PSScriptRoot 'Invoke-CloudflareRead.ps1'

$account = & $readScript -Method GET -Uri "$(Get-CloudflareApiBaseUri)/accounts/$AccountId"
$zones = & $readScript -Method GET -Uri "$(Get-CloudflareApiBaseUri)/zones?account.id=$AccountId"

$zoneDetails = [System.Collections.Generic.List[object]]::new()
foreach ($zoneId in $ZoneIds) {
    $zoneInfo = & $readScript -Method GET -Uri "$(Get-CloudflareApiBaseUri)/zones/$zoneId"
    $dnsRecords = & $readScript -Method GET -Uri "$(Get-CloudflareApiBaseUri)/zones/$zoneId/dns_records"
    $zoneDetails.Add([PSCustomObject]@{
        zoneId     = $zoneId
        zone       = $zoneInfo.result
        dnsRecords = $dnsRecords.result
    })
}

$inventory = [PSCustomObject]@{
    schemaVersion  = 1
    capturedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    accountId      = $AccountId
    account        = $account.result
    zonesForAccount = $zones.result
    requestedZones = @($zoneDetails)
}

Assert-CloudflareDirectoryExists -Path (Get-CloudflareInventoryDir)
$fileName = "inventory-$((Get-Date).ToUniversalTime().ToString('yyyyMMddTHHmmssZ'))-$([Guid]::NewGuid().ToString('N').Substring(0,8)).json"
$filePath = Join-Path (Get-CloudflareInventoryDir) $fileName
$inventory | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $filePath -Encoding utf8

$hash = Get-CloudflareFileSha256 -Path $filePath

[PSCustomObject]@{
    path = $filePath
    hash = $hash
} | ConvertTo-Json
