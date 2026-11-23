<#
Aplica un plan de eliminacion ya validado por Test-AdoPermissionsDeletePlan.ps1.
Rechaza cualquier plan con mas de una operacion o con operationKind
distinto de 'destructive'. Respaldo de solo lectura SIEMPRE obligatorio
antes del DELETE real -- si falla, no se elimina nada.

Aprobar esta eliminacion NUNCA autoriza recrear el recurso -- son 2
aprobaciones independientes.

Uso:
  .\Apply-AdoPermissionsDeletePlan.ps1 -PlanPath '...' -MaxInventoryAgeHours 24
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PlanPath,

    [ValidateRange(0.01, 24)]
    [double]$MaxInventoryAgeHours = 24
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoPermissionsRest.ps1')

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Apply-AdoPermissionsDeletePlan rechazado: no se encontro el plan '$PlanPath'."
}
$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $plan.validated -or $plan.validated -ne $true) {
    throw "Apply-AdoPermissionsDeletePlan rechazado: el plan no esta validated=true. Ejecutar Test-AdoPermissionsDeletePlan.ps1 primero."
}
if ($plan.operationKind -ne 'destructive') {
    throw "Apply-AdoPermissionsDeletePlan rechazado: operationKind '$($plan.operationKind)' -- este script solo aplica planes 'destructive'."
}
if ($plan.backupRequired -ne $true) {
    throw "Apply-AdoPermissionsDeletePlan rechazado: el plan no exige backupRequired=true."
}

$approvedOps = @()
if ($null -ne $plan.approvedOperations) { $approvedOps = @($plan.approvedOperations) }
if ($approvedOps.Count -ne 1) {
    throw "Apply-AdoPermissionsDeletePlan rechazado: el plan tiene $($approvedOps.Count) operacion(es) -- debe tener EXACTAMENTE una."
}
if ([string]$approvedOps[0].method -ne 'DELETE') {
    throw "Apply-AdoPermissionsDeletePlan rechazado: la operacion aprobada no es DELETE."
}
if (-not ($script:AdoPermissionsDestructiveOperationTypes -contains [string]$approvedOps[0].operationType)) {
    throw "Apply-AdoPermissionsDeletePlan rechazado: operationType '$($approvedOps[0].operationType)' no es un tipo de eliminacion permitido."
}

$currentHash = Get-AdoPermissionsPlanCanonicalHash -Plan $plan
if ($currentHash -ne $plan.validationHash) {
    throw "Apply-AdoPermissionsDeletePlan rechazado: el plan cambio despues de validarse (validationHash no coincide). Volver a validar."
}

if (-not $plan.validationEvidence -or -not $plan.validationEvidence.maxInventoryAgeHours) {
    throw "Apply-AdoPermissionsDeletePlan rechazado: falta validationEvidence en el plan."
}
$effectiveMaxHours = [Math]::Min($MaxInventoryAgeHours, $script:AdoPermissionsAbsoluteMaxInventoryAgeHours)
if ([double]$plan.validationEvidence.maxInventoryAgeHours -gt $script:AdoPermissionsAbsoluteMaxInventoryAgeHours) {
    throw "Apply-AdoPermissionsDeletePlan rechazado: validationEvidence.maxInventoryAgeHours supera el tope absoluto interno."
}
$generatedAt = [DateTime]::Parse([string]$plan.generatedAtUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
$ageHours = ((Get-Date).ToUniversalTime() - $generatedAt.ToUniversalTime()).TotalHours
if ($ageHours -gt $effectiveMaxHours -or [double]::IsNaN($ageHours) -or [double]::IsInfinity($ageHours)) {
    throw "Apply-AdoPermissionsDeletePlan rechazado: el plan tiene $([Math]::Round($ageHours,2)) hora(s), supera el maximo permitido ($effectiveMaxHours). Volver a generar y validar."
}

Write-Host "Aplicando plan de eliminacion '$PlanPath' -- recurso: $($plan.resourceSummary)" -ForegroundColor Yellow
Write-Host "validationHash: $($plan.validationHash)" -ForegroundColor Yellow

$result = Invoke-AdoPermissionsDeleteApplyPhase -Plan $plan -PlanPath $PlanPath

Write-Host ""
Write-Host "Eliminacion aplicada. Respaldo: $($result.backupPath)" -ForegroundColor Green
Write-Host "Esta aprobacion NO autoriza recrear el recurso -- eso exige su propia aprobacion separada." -ForegroundColor Yellow

return $result
