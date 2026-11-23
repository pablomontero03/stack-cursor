<#
Arma (sin validar) un plan de cambio Cloudflare inmutable. No hace ninguna
llamada a la API -- solo ensambla el JSON con la forma correcta y rechaza
inconsistencias estructurales obvias. La validacion real (secretos, forma
completa, drift, eliminacion logica) la hace Test-CloudflareChangePlan.ps1.
#>
param(
    [Parameter(Mandatory)] [string]$AccountId,
    [string[]]$ZoneIds = @(),
    [Parameter(Mandatory)] [string]$Objective,
    [Parameter(Mandatory)] [string[]]$InventoryPaths,
    [array]$Operations = @(),
    [array]$PendingDeleteOperations = @(),
    [string]$RiskAndImpactAnalysis = '',
    [string]$BackupStrategy = '',
    [string]$VerificationPlan = '',
    [string]$RollbackStrategy = '',
    [double]$ExpiresInHours = 24,
    [string]$OwnerTranscriptId = $null
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cloudflare-Common.ps1')

foreach ($invPath in $InventoryPaths) {
    if (-not (Test-Path -LiteralPath $invPath -PathType Leaf)) {
        throw "El inventario '$invPath' no existe. Genera uno con Get-CloudflareInventory.ps1 antes de armar el plan."
    }
}

$requiredFields = Get-CloudflareRequiredOperationFields

function Test-CloudflareOperationShape {
    param($Op, [bool]$ExpectedDestructive)

    foreach ($field in $requiredFields) {
        if (-not ($Op.PSObject.Properties.Name -contains $field)) {
            throw "Operacion '$($Op.operationId)' no tiene el campo obligatorio '$field'."
        }
    }
    if ([bool]$Op.isDestructive -ne $ExpectedDestructive) {
        $arrayName = if ($ExpectedDestructive) { 'PendingDeleteOperations' } else { 'Operations' }
        throw "Operacion '$($Op.operationId)' tiene isDestructive=$($Op.isDestructive) pero vive en -$arrayName (se esperaba isDestructive=$ExpectedDestructive)."
    }
    if ($Op.executor -in @('terraform', 'wrangler') -and -not ($Op.argv -is [array])) {
        throw "Operacion '$($Op.operationId)': argv debe ser un array tokenizado cuando executor es '$($Op.executor)'."
    }
    if ($Op.executor -eq 'cloudflareGraphQL' -and [string]$Op.method -ne 'POST') {
        throw "Operacion '$($Op.operationId)': executor 'cloudflareGraphQL' exige method='POST'."
    }
}

$allOperations = @($Operations) + @($PendingDeleteOperations)
$seenIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($op in $allOperations) {
    if (-not $seenIds.Add([string]$op.operationId)) {
        throw "operationId duplicado en el plan: '$($op.operationId)'."
    }
}

$knownIds = @($allOperations | ForEach-Object { [string]$_.operationId })
foreach ($op in $allOperations) {
    foreach ($depId in @($op.dependencies)) {
        if ($depId -and ($knownIds -notcontains [string]$depId)) {
            throw "Operacion '$($op.operationId)' declara una dependencia '$depId' que no existe en este mismo plan."
        }
    }
}

foreach ($op in $Operations) { Test-CloudflareOperationShape -Op $op -ExpectedDestructive $false }
foreach ($op in $PendingDeleteOperations) { Test-CloudflareOperationShape -Op $op -ExpectedDestructive $true }

$inventoryHashes = @()
foreach ($invPath in $InventoryPaths) {
    $inventoryHashes += [PSCustomObject]@{ path = $invPath; hash = (Get-CloudflareFileSha256 -Path $invPath) }
}

$executorsUsed = @($allOperations | ForEach-Object { [string]$_.executor } | Select-Object -Unique)
$connectionMode = if ($executorsUsed.Count -eq 0) {
    'rest'
}
elseif ($executorsUsed.Count -eq 1) {
    switch ($executorsUsed[0]) {
        'cloudflareRest' { 'rest' }
        'cloudflareGraphQL' { 'rest' }
        'terraform' { 'terraform' }
        'wrangler' { 'wrangler' }
        default { 'rest' }
    }
}
else {
    'mixed'
}

$preStateHash = Get-CloudflarePlanCanonicalHash -Plan ([PSCustomObject]@{ inventoryHashes = $inventoryHashes })

$createdAtUtc = (Get-Date).ToUniversalTime()
$plan = [ordered]@{
    schemaVersion            = 1
    planId                   = [Guid]::NewGuid().ToString()
    createdAtUtc             = $createdAtUtc.ToString('o')
    expiresAtUtc             = $createdAtUtc.AddHours($ExpiresInHours).ToString('o')
    ownerTranscriptId        = $OwnerTranscriptId
    connectionMode           = $connectionMode
    accountId                = $AccountId
    zoneIds                  = @($ZoneIds)
    objective                = $Objective
    inventoryHashes          = @($inventoryHashes)
    preStateHash             = $preStateHash
    approvedOperations       = @($Operations)
    pendingDeleteOperations  = @($PendingDeleteOperations)
    riskAndImpactAnalysis    = $RiskAndImpactAnalysis
    backupStrategy           = $BackupStrategy
    verificationPlan         = $VerificationPlan
    rollbackStrategy         = $RollbackStrategy
    validated                = $false
    validationHash           = $null
    validationEvidence       = $null
    reviewStatus             = 'not-reviewed'
}

Assert-CloudflareDirectoryExists -Path (Get-CloudflarePlansDir)
$fileName = "plan-$($plan.planId).json"
$filePath = Join-Path (Get-CloudflarePlansDir) $fileName
$plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $filePath -Encoding utf8

[PSCustomObject]@{ path = $filePath; planId = $plan.planId } | ConvertTo-Json
