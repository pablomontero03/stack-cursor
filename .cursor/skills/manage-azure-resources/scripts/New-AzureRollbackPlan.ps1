<#
Prepara y MUESTRA (nunca ejecuta) una propuesta de rollback para un plan ya
aplicado. Un rollback tambien puede producir impacto real, asi que nunca es
automatico: este script solo genera un plan NUEVO (via New-AzureChangePlan.ps1
internamente) con las operaciones inversas sugeridas -- ese plan nuevo
necesita su propio Test-AzureChangePlan.ps1 y su propia aprobacion antes de
poder aplicarse con Apply-AzureChangePlan.ps1 / Apply-AzureDeletePlan.ps1,
exactamente igual que cualquier otro plan.

No toda operacion tiene un inverso seguro (ej. una 'action' como reiniciar
una VM no tiene rollback real) -- esas quedan marcadas 'noAutomaticInverse'
y deben resolverse a mano.

Uso:
  & '.\New-AzureRollbackPlan.ps1' -OriginalPlanPath plan.json -OutPath rollback-plan.json
#>
param(
    [Parameter(Mandatory)] [string]$OriginalPlanPath,
    [Parameter(Mandatory)] [string]$OutPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Azure-Common.ps1')

if (-not (Test-Path -LiteralPath $OriginalPlanPath)) {
    throw "New-AzureRollbackPlan rechazado: no existe el plan original '$OriginalPlanPath'."
}
$originalPlan = Get-Content -LiteralPath $OriginalPlanPath -Raw | ConvertFrom-Json

$inverseOps = [System.Collections.Generic.List[object]]::new()
$noInverse = [System.Collections.Generic.List[string]]::new()

foreach ($op in @($originalPlan.approvedOperations)) {
    $action = [string]$op.action
    $opId = [string]$op.operationId

    if ($action -eq 'create') {
        $inverseOps.Add([ordered]@{
            operationId       = "rollback-delete-$opId"
            phase             = 'destructive'
            action            = 'delete'
            tenantId          = $op.tenantId
            subscriptionId    = $op.subscriptionId
            resourceGroup     = $op.resourceGroup
            resourceId        = $op.resourceId
            resourceType      = $op.resourceType
            apiVersion        = $op.apiVersion
            executor          = 'azureCli'
            argv              = @('resource', 'delete', '--ids', $op.resourceId)
            bodyHash          = $null
            preconditionHash  = $null
            currentState      = $op.desiredState
            desiredState      = @{}
            dependencies      = @()
            destructive       = $true
            reversible        = $false
            backupStrategy    = 'Respaldo automatico de Apply-AzureDeletePlan.ps1 antes del delete.'
            rollbackStrategy  = 'N/A -- este ES el rollback.'
            verification      = @("az resource show --ids $($op.resourceId) (debe fallar/no existir)")
            retryPolicy       = @{ maxAttempts = 1; retryableCodes = @(); delaySeconds = 0 }
            timeoutSeconds    = 600
            expectedFinalState = "Recurso $($op.resourceId) eliminado (vuelve al estado previo a $($originalPlan.planId))"
        })
    }
    elseif ($action -eq 'update') {
        $restoreOp = [ordered]@{
            operationId       = "rollback-restore-$opId"
            phase             = 'nonDestructive'
            action            = 'update'
            tenantId          = $op.tenantId
            subscriptionId    = $op.subscriptionId
            resourceGroup     = $op.resourceGroup
            resourceId        = $op.resourceId
            resourceType      = $op.resourceType
            apiVersion        = $op.apiVersion
            executor          = $op.executor
            argv              = @('__PENDIENTE__: completar argv real de update antes de validar -- New-AzureRollbackPlan no puede inferir el comando exacto de restauracion.')
            bodyHash          = $null
            preconditionHash  = $null
            currentState      = $op.desiredState
            desiredState      = $op.currentState
            dependencies      = @()
            destructive       = $false
            reversible        = $true
            backupStrategy    = 'N/A -- restaura al currentState capturado en el plan original.'
            rollbackStrategy  = 'N/A -- este ES el rollback.'
            verification      = $op.verification
            retryPolicy       = @{ maxAttempts = 1; retryableCodes = @(); delaySeconds = 0 }
            timeoutSeconds    = $op.timeoutSeconds
            expectedFinalState = "Recurso $($op.resourceId) restaurado a su estado previo a $($originalPlan.planId)"
        }
        $inverseOps.Add($restoreOp)
    }
    else {
        $noInverse.Add("$opId (action='$action') no tiene inverso automatico seguro -- resolver manualmente.")
    }
}

$outDir = Split-Path -Parent $OutPath
Assert-AzureDirectoryExists -Path $outDir

$rollbackDraft = [ordered]@{
    schemaVersion           = 1
    planId                  = [Guid]::NewGuid().ToString()
    createdAtUtc            = (Get-Date).ToUniversalTime().ToString('o')
    ownerTranscriptId       = $null
    tenantId                = $originalPlan.tenantId
    subscriptionId          = $originalPlan.subscriptionId
    rollbackOfPlanId        = $originalPlan.planId
    inventoryHashes         = @()
    approvedOperations      = @($inverseOps | Where-Object { -not [bool]$_.destructive })
    pendingDeleteOperations = @($inverseOps | Where-Object { [bool]$_.destructive })
    impactAndCostAnalysis   = 'Plan de rollback -- requiere inventario fresco antes de Test-AzureChangePlan.ps1 (inventoryHashes vacio a proposito).'
    validated               = $false
    validationHash          = $null
    validationEvidence      = $null
    reviewStatus            = 'not-reviewed'
    noAutomaticInverse      = @($noInverse)
}

($rollbackDraft | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $OutPath -Encoding utf8

Write-Host "Borrador de rollback escrito en '$OutPath'. ESTO NO SE APLICA SOLO." -ForegroundColor Yellow
Write-Host "Antes de aplicar: capturar inventario fresco (Get-AzureInventory.ps1), completar cualquier argv '__PENDIENTE__', correr Test-AzureChangePlan.ps1, y pedir una aprobacion NUEVA y separada de la del plan original." -ForegroundColor Yellow
if ($noInverse.Count -gt 0) {
    Write-Host "Operaciones sin inverso automatico:" -ForegroundColor Red
    foreach ($n in $noInverse) { Write-Host " - $n" -ForegroundColor Red }
}

[PSCustomObject]@{
    path               = $OutPath
    inverseOperations  = $inverseOps.Count
    noAutomaticInverse = @($noInverse)
}
