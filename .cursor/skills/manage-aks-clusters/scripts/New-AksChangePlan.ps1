<#
Genera un plan de cambio INMUTABLE (JSON con validationHash SHA-256) para
un lote atomico de operaciones sobre un cluster AKS. No modifica el
cluster -- solo escribe el archivo de plan en .local\aks\plans\. El plan
todavia no queda 'validated'; para eso corre Test-AksChangePlan.ps1 antes
de Apply-AksChangePlan.ps1.

-OperationsJson es un array JSON (string o ruta a archivo .json) con una
entrada por operacion del lote, por ejemplo:
[
  {
    "operationId": "apply-deployment-my-app-desarrollo",
    "kind": "apply",
    "resourceKind": "Deployment",
    "resourceName": "my-app",
    "namespace": "desarrollo",
    "manifestPath": "cluster/deployment-my-app.yaml",
    "requiresBackup": true
  }
]

kind valido: apply | patch | delete | scale | rollout-restart | label |
annotate | cordon | uncordon | drain | other (para cualquier operacion no
cubierta explicitamente -- el plan sigue exigiendo aprobacion igual).

Uso:
  powershell -File .\New-AksChangePlan.ps1 `
    -Context gmon-dev-aks-eastus2-0001 -Namespace desarrollo `
    -SubscriptionId <id> -ResourceGroup <rg> -ClusterName <cluster> `
    -KubeconfigPath "C:\Users\pablo\AppData\Roaming\Lens\kubeconfigs\<archivo>" `
    -Description "..." -OperationsJson .\ops.json `
    -WhatChanges "..." -WhatDoesNotChange "..." -Dependencies "..." `
    -PossibleDowntime "..." -VerificationStrategy "..." -RollbackStrategy "..."

-KubeconfigPath es opcional: si se omite, kubectl usa la resolucion
ambiente ($env:KUBECONFIG -> $env:USERPROFILE\.kube\config). Los
clusteres reales de este proyecto viven en kubeconfigs exportados por
Lens (ver references/kubeconfig-and-contexts.md § Clusteres reales
conocidos) -- casi siempre hace falta pasar esta ruta explicita.
#>

param(
    [Parameter(Mandatory)] [string]$Context,
    [Parameter(Mandatory)] [string]$Namespace,
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [Parameter(Mandatory)] [string]$ResourceGroup,
    [Parameter(Mandatory)] [string]$ClusterName,
    [string]$KubeconfigPath,
    [Parameter(Mandatory)] [string]$Description,
    [Parameter(Mandatory)] [string]$OperationsJson,
    [Parameter(Mandatory)] [string]$WhatChanges,
    [Parameter(Mandatory)] [string]$WhatDoesNotChange,
    [string]$Dependencies = '(ninguna identificada)',
    [string]$PossibleDowntime = '(ninguna esperada)',
    [Parameter(Mandatory)] [string]$VerificationStrategy,
    [Parameter(Mandatory)] [string]$RollbackStrategy,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Aks-Common.ps1')

if (-not $OutDir) { $OutDir = Get-AksPlansDir }
Assert-AksDirectoryExists -Path $OutDir

$opsRaw = if (Test-Path -LiteralPath $OperationsJson -PathType Leaf) {
    Get-Content -LiteralPath $OperationsJson -Raw
}
else {
    $OperationsJson
}

$operations = $null
try {
    $operations = $opsRaw | ConvertFrom-Json
}
catch {
    throw "New-AksChangePlan rechazado: -OperationsJson no es JSON valido. $($_.Exception.Message)"
}
if ($operations -isnot [System.Collections.IEnumerable] -or $operations -is [string]) {
    $operations = @($operations)
}
$operations = @($operations)

if ($operations.Count -eq 0) {
    throw "New-AksChangePlan rechazado: el lote debe tener al menos 1 operacion."
}

$validKinds = @('apply', 'patch', 'delete', 'scale', 'rollout-restart', 'label', 'annotate', 'cordon', 'uncordon', 'drain', 'other')
$seenIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($op in $operations) {
    if ([string]::IsNullOrWhiteSpace([string]$op.operationId)) {
        throw "New-AksChangePlan rechazado: cada operacion requiere 'operationId' unico y no vacio."
    }
    if (-not $seenIds.Add([string]$op.operationId)) {
        throw "New-AksChangePlan rechazado: operationId duplicado '$($op.operationId)'."
    }
    if ($validKinds -notcontains [string]$op.kind) {
        throw "New-AksChangePlan rechazado: la operacion '$($op.operationId)' tiene kind invalido ('$($op.kind)'). Validos: $($validKinds -join ', ')."
    }
    if ([string]::IsNullOrWhiteSpace([string]$op.resourceKind) -or [string]::IsNullOrWhiteSpace([string]$op.resourceName)) {
        throw "New-AksChangePlan rechazado: la operacion '$($op.operationId)' requiere resourceKind y resourceName."
    }
    if ([string]$op.kind -eq 'delete' -and [string]$op.requiresBackup -ne 'True' -and $op.requiresBackup -ne $true) {
        throw "New-AksChangePlan rechazado: la operacion '$($op.operationId)' es una eliminacion (kind='delete') y debe traer requiresBackup=true -- nunca se elimina sin respaldo obligatorio."
    }
}

$plan = [ordered]@{
    schemaVersion       = 1
    createdAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
    cluster             = [ordered]@{
        subscriptionId = $SubscriptionId
        resourceGroup  = $ResourceGroup
        clusterName    = $ClusterName
        context        = $Context
        kubeconfigPath = if ($KubeconfigPath) { (Resolve-Path -LiteralPath $KubeconfigPath).Path } else { $null }
    }
    namespace           = $Namespace
    description         = $Description
    operations          = $operations
    approvedOperations  = $operations
    impact              = [ordered]@{
        whatChanges           = $WhatChanges
        whatDoesNotChange     = $WhatDoesNotChange
        dependencies          = $Dependencies
        possibleDowntime      = $PossibleDowntime
        verificationStrategy  = $VerificationStrategy
        rollbackStrategy      = $RollbackStrategy
    }
    validation          = [ordered]@{
        dryRunPerformed  = $false
        diffPerformed    = $false
        authCanIChecked  = $false
    }
    validated           = $false
    validationHash      = $null
    validationEvidence  = $null
}

$planObj = [PSCustomObject]$plan
$timestamp = (Get-Date).ToString('yyyyMMdd-HHmmss')
$uniqueSuffix = [Guid]::NewGuid().ToString('N').Substring(0, 8)
$safeCluster = ($ClusterName -replace '[^a-zA-Z0-9-]', '-')
# Sufijo unico ademas del timestamp: dos planes para el mismo
# cluster+namespace generados dentro del mismo segundo (real en pruebas
# automatizadas, y posible en uso interactivo rapido) no deben pisarse el
# archivo silenciosamente.
$outPath = Join-Path $OutDir "aks-$safeCluster-$Namespace-$timestamp-$uniqueSuffix.json"

$planObj | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outPath -Encoding utf8

Write-Host "Plan generado (todavia SIN validar): $outPath" -ForegroundColor Cyan
Write-Host "Operaciones incluidas: $($operations.Count)" -ForegroundColor Cyan
Write-Host "Correr Test-AksChangePlan.ps1 antes de Apply-AksChangePlan.ps1." -ForegroundColor Yellow

[PSCustomObject]@{ outPath = $outPath; operationsCount = $operations.Count }
