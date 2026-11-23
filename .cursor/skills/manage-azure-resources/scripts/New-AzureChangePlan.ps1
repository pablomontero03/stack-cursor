<#
Genera un plan de cambio Azure inmutable (sin validar -- eso lo hace
Test-AzureChangePlan.ps1). Cada operacion sigue EXACTAMENTE el esquema de
"## Esquema del plan Azure" de INSTRUCCIONES-AUTOMATIZACION-AZURE.md. No
almacena comandos de shell arbitrarios: `argv` es siempre un array
tokenizado.

Uso:
  $ops = @(
    [ordered]@{
      operationId = 'create-storageaccounts-stexample'
      phase = 'nonDestructive'; action = 'create'
      tenantId = $tenantId; subscriptionId = $subId; resourceGroup = 'rg1'
      resourceId = '/subscriptions/.../resourceGroups/rg1/providers/Microsoft.Storage/storageAccounts/stexample'
      resourceType = 'Microsoft.Storage/storageAccounts'; apiVersion = '2023-01-01'
      executor = 'azureCli'; argv = @('storage','account','create','-n','stexample','-g','rg1')
      bodyHash = $null; preconditionHash = $invHash
      currentState = @{}; desiredState = @{ sku = 'Standard_LRS' }
      dependencies = @(); destructive = $false; reversible = $true
      backupStrategy = 'N/A -- recurso nuevo'; rollbackStrategy = 'Eliminar el recurso creado (plan de rollback aparte)'
      verification = @('az storage account show -n stexample -g rg1')
      retryPolicy = @{ maxAttempts = 1; retryableCodes = @(); delaySeconds = 0 }
      timeoutSeconds = 600; expectedFinalState = 'Storage account stexample existe con sku Standard_LRS'
    }
  )
  & '.\New-AzureChangePlan.ps1' -TenantId $tenantId -SubscriptionId $subId -Operations $ops -InventoryPaths @($invPath) -OutPath plan.json
#>
param(
    [Parameter(Mandatory)] [string]$TenantId,
    [Parameter(Mandatory)] [string]$SubscriptionId,
    [array]$Operations = @(),
    [array]$PendingDeleteOperations = @(),
    [Parameter(Mandatory)] [string[]]$InventoryPaths,
    [Parameter(Mandatory)] [string]$OutPath,
    [string]$OwnerTranscriptId,
    [string]$ImpactAndCostAnalysis = ''
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Azure-Common.ps1')

foreach ($inv in $InventoryPaths) {
    if (-not (Test-Path -LiteralPath $inv)) {
        throw "New-AzureChangePlan rechazado: no existe el inventario '$inv'. Correr Get-AzureInventory.ps1 primero."
    }
}

$requiredOpFields = @(
    'operationId', 'phase', 'action', 'tenantId', 'subscriptionId', 'resourceGroup',
    'resourceId', 'resourceType', 'apiVersion', 'executor', 'argv', 'bodyHash',
    'preconditionHash', 'currentState', 'desiredState', 'dependencies', 'destructive',
    'reversible', 'backupStrategy', 'rollbackStrategy', 'verification', 'retryPolicy',
    'timeoutSeconds', 'expectedFinalState'
)

function Assert-AzureOperationShape {
    param($Op, [string]$Kind)
    foreach ($f in $requiredOpFields) {
        if (-not ($Op.PSObject.Properties.Name -contains $f) -and -not ($Op -is [hashtable] -and $Op.Contains($f)) -and -not ($Op -is [System.Collections.Specialized.OrderedDictionary] -and $Op.Contains($f))) {
            throw "New-AzureChangePlan rechazado: la operacion $Kind le falta el campo obligatorio '$f'. El esquema del plan no se simplifica."
        }
    }
}

$allOpIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($op in $Operations) {
    Assert-AzureOperationShape -Op $op -Kind 'no destructiva'
    $opId = [string]$op.operationId
    if (-not $allOpIds.Add($opId)) { throw "New-AzureChangePlan rechazado: operationId duplicado '$opId'." }
    if ([bool]$op.destructive) { throw "New-AzureChangePlan rechazado: la operacion '$opId' esta marcada destructive=true pero fue pasada en -Operations (no destructivas). Usar -PendingDeleteOperations." }
}
foreach ($op in $PendingDeleteOperations) {
    Assert-AzureOperationShape -Op $op -Kind 'destructiva (pendingDelete)'
    $opId = [string]$op.operationId
    if (-not $allOpIds.Add($opId)) { throw "New-AzureChangePlan rechazado: operationId duplicado '$opId'." }
    if (-not [bool]$op.destructive) { throw "New-AzureChangePlan rechazado: la operacion '$opId' esta en -PendingDeleteOperations pero no tiene destructive=true." }
}

# Eliminar un Resource Group completo siempre queda aislado: si aparece,
# ninguna otra eliminacion puede compartir el mismo lote.
$rgDeletes = @($PendingDeleteOperations | Where-Object { [string]$_.resourceType -eq 'Microsoft.Resources/resourceGroups' -and [string]$_.action -eq 'delete' })
if ($rgDeletes.Count -gt 0 -and $PendingDeleteOperations.Count -gt $rgDeletes.Count) {
    throw "New-AzureChangePlan rechazado: eliminar un Resource Group completo debe ser una operacion destructiva aislada -- no se puede combinar con otras eliminaciones en el mismo plan."
}
if ($rgDeletes.Count -gt 1) {
    throw "New-AzureChangePlan rechazado: no se permite mas de un Resource Group en el mismo lote destructivo -- generar un plan separado por cada uno."
}

$inventoryHashes = @($InventoryPaths | ForEach-Object {
    [PSCustomObject]@{ path = $_; hash = (Get-AzureFileSha256 -Path $_) }
})

$plan = [ordered]@{
    schemaVersion            = 1
    planId                   = [Guid]::NewGuid().ToString()
    createdAtUtc             = (Get-Date).ToUniversalTime().ToString('o')
    ownerTranscriptId        = $OwnerTranscriptId
    tenantId                 = $TenantId
    subscriptionId           = $SubscriptionId
    inventoryHashes          = $inventoryHashes
    approvedOperations       = @($Operations)
    pendingDeleteOperations  = @($PendingDeleteOperations)
    impactAndCostAnalysis    = $ImpactAndCostAnalysis
    validated                = $false
    validationHash           = $null
    validationEvidence       = $null
    reviewStatus             = 'not-reviewed'
}

Assert-AzureDirectoryExists -Path (Split-Path -Parent $OutPath)
($plan | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $OutPath -Encoding utf8

[PSCustomObject]@{
    path                   = $OutPath
    planId                 = $plan.planId
    operationCount         = $Operations.Count
    pendingDeleteCount     = $PendingDeleteOperations.Count
}
