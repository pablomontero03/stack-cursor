<#
NUNCA aplica nada. Prepara y MUESTRA una propuesta de plan inverso a partir
de un plan ya aplicado -- cada operacion completada se invierte a candidato
(update -> revertir a currentState previo; create -> delete; delete ->
recreate usando currentState como desiredState). Lo que no se puede inferir
automaticamente queda marcado __PENDIENTE__. Aplicar ese rollback exige un
flujo completo nuevo (New-*Plan -> Test-*Plan -> Apply-*Plan) con su propia
aprobacion, separada de la del cambio original.
#>
param(
    [Parameter(Mandatory)] [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cloudflare-Common.ps1')

if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
    throw "El plan '$PlanPath' no existe."
}
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

$rollbackOperations = [System.Collections.Generic.List[object]]::new()

foreach ($op in @($plan.approvedOperations)) {
    $inverseAction = switch ([string]$op.action) {
        'create' { 'delete' }
        'update' { 'update' }
        'action' { 'action' }
        default { 'update' }
    }
    $inverseBody = if ([string]$op.action -eq 'update' -and $op.currentState) { $op.currentState } else { [PSCustomObject]@{ __PENDIENTE__ = $true } }
    $inverseArgv = if ($op.executor -in @('terraform', 'wrangler')) { @('__PENDIENTE__') } else { @() }

    $rollbackOperations.Add([PSCustomObject]@{
        operationId       = (New-CloudflareOperationId -Action $inverseAction -ResourceType $op.resourceType -ResourceName "$($op.resourceName)-rollback")
        phase             = 'nonDestructive'
        action            = $inverseAction
        accountId         = $op.accountId
        zoneId            = $op.zoneId
        resourceType      = $op.resourceType
        resourceId        = $op.resourceId
        resourceName      = $op.resourceName
        executor          = $op.executor
        method            = if ($inverseAction -eq 'delete') { 'DELETE' } else { $op.method }
        uri               = $op.uri
        argv              = $inverseArgv
        body              = $inverseBody
        bodyHash          = $null
        preconditionHash  = '__PENDIENTE__'
        currentState      = $op.desiredState
        desiredState      = $inverseBody
        dependencies      = @()
        isDestructive     = $false
        reversible        = $true
        backupStrategy    = 'Ver respaldo original del plan aplicado.'
        rollbackStrategy  = 'N/A (esto ya es el rollback).'
        verification      = @()
        retryPolicy       = [PSCustomObject]@{ maxAttempts = 1; retryableCodes = @(); delaySeconds = 0 }
        timeoutSeconds    = 600
        expectedFinalState = "Estado revertido a como estaba antes de aplicar '$($plan.planId)'."
        expectedReadback  = '__PENDIENTE__'
    })
}

Write-Host "Propuesta de rollback para el plan '$($plan.planId)' -- NO se aplico nada. Operaciones candidatas:" -ForegroundColor Cyan
[PSCustomObject]@{
    sourcePlanId        = [string]$plan.planId
    proposedOperations  = @($rollbackOperations)
    note                = 'Revisar cada campo marcado __PENDIENTE__ antes de generar un plan real con New-CloudflareChangePlan.ps1. Este script nunca valida ni aplica.'
} | ConvertTo-Json -Depth 20
