<#
Arma (sin validar) un delete plan Cloudflare SEPARADO del plan de cambios
normal. Todas las operaciones son destructivas (isDestructive=true,
phase='destructive'). Nunca acepta selectores amplios ni operaciones sin un
resourceId concreto -- el lote debe quedar materializado por completo antes
de pedir aprobacion.
#>
param(
    [Parameter(Mandatory)] [string]$AccountId,
    [string[]]$ZoneIds = @(),
    [Parameter(Mandatory)] [string[]]$InventoryPaths,
    [Parameter(Mandatory)] [array]$Operations,
    [string]$BackupPlan = '',
    [string]$RecoveryAnalysis = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cloudflare-Common.ps1')

if (@($Operations).Count -lt 1) {
    throw "Un delete plan debe declarar al menos 1 operacion."
}

foreach ($invPath in $InventoryPaths) {
    if (-not (Test-Path -LiteralPath $invPath -PathType Leaf)) {
        throw "El inventario '$invPath' no existe. Genera uno con Get-CloudflareInventory.ps1 antes de armar el delete plan."
    }
}

$requiredFields = Get-CloudflareRequiredOperationFields
$seenIds = [System.Collections.Generic.HashSet[string]]::new()

foreach ($op in $Operations) {
    foreach ($field in $requiredFields) {
        if (-not ($op.PSObject.Properties.Name -contains $field)) {
            throw "Operacion '$($op.operationId)' no tiene el campo obligatorio '$field'."
        }
    }
    if (-not $seenIds.Add([string]$op.operationId)) {
        throw "operationId duplicado en el delete plan: '$($op.operationId)'."
    }
    if ([bool]$op.isDestructive -ne $true) {
        throw "Operacion '$($op.operationId)': un delete plan exige isDestructive=true en TODAS sus operaciones."
    }
    if ([string]$op.phase -ne 'destructive') {
        throw "Operacion '$($op.operationId)': un delete plan exige phase='destructive' en TODAS sus operaciones."
    }
    if ([string]::IsNullOrWhiteSpace([string]$op.resourceId)) {
        throw "Operacion '$($op.operationId)': falta resourceId concreto -- no se aceptan operaciones sin un ID materializado."
    }
    if ($op.uri -and ([string]$op.uri -match '\*')) {
        throw "Operacion '$($op.operationId)': la uri contiene un selector amplio ('*') -- no se aceptan comodines en un delete plan."
    }
    if ($op.uri -and (-not ([string]$op.uri).TrimEnd('/').EndsWith([string]$op.resourceId))) {
        throw "Operacion '$($op.operationId)': la uri no termina en el resourceId exacto -- posible selector amplio o de coleccion."
    }
    if ($op.executor -in @('terraform', 'wrangler') -and -not ($op.argv -is [array])) {
        throw "Operacion '$($op.operationId)': argv debe ser un array tokenizado cuando executor es '$($op.executor)'."
    }
}

$inventoryHashes = @()
foreach ($invPath in $InventoryPaths) {
    $inventoryHashes += [PSCustomObject]@{ path = $invPath; hash = (Get-CloudflareFileSha256 -Path $invPath) }
}

$createdAtUtc = (Get-Date).ToUniversalTime()
$deletePlan = [ordered]@{
    schemaVersion           = 1
    deletePlanId            = [Guid]::NewGuid().ToString()
    createdAtUtc            = $createdAtUtc.ToString('o')
    expiresAtUtc            = $createdAtUtc.AddHours(24).ToString('o')
    accountId               = $AccountId
    zoneIds                 = @($ZoneIds)
    inventoryHashes         = @($inventoryHashes)
    approvedOperations      = @()
    pendingDeleteOperations = @($Operations)
    backupPlan              = $BackupPlan
    recoveryAnalysis        = $RecoveryAnalysis
    validated               = $false
    validationHash          = $null
    validationEvidence      = $null
    reviewStatus            = 'not-reviewed'
}

Assert-CloudflareDirectoryExists -Path (Get-CloudflareDeletePlansDir)
$fileName = "delete-plan-$($deletePlan.deletePlanId).json"
$filePath = Join-Path (Get-CloudflareDeletePlansDir) $fileName
$deletePlan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $filePath -Encoding utf8

[PSCustomObject]@{ path = $filePath; deletePlanId = $deletePlan.deletePlanId } | ConvertTo-Json
