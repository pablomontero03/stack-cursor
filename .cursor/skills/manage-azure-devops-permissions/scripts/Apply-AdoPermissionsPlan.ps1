<#
Aplica un plan NO DESTRUCTIVO ya validado por Test-AdoPermissionsPlan.ps1:
crea grupos faltantes, actualiza descripciones, agrega miembros
confirmados y aplica las ACE Git calculadas. Rechaza SIEMPRE cualquier
operacion destructiva (DELETE, delete-security-group,
remove-group-membership) -- para eliminar, usar
Apply-AdoPermissionsDeletePlan.ps1 con su propia aprobacion separada.

Antes de cada escritura, relee en vivo el recurso relevante y compara con
'precondition' (guardado por New-AdoPermissionsPlan.ps1). Si hay drift, esa
operacion puntual se OMITE y se reporta -- nunca sobrescribe un cambio
reciente ajeno.

Uso:
  .\Apply-AdoPermissionsPlan.ps1 -PlanPath '...' -MaxInventoryAgeHours 24
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

# --- Validaciones antes de aplicar (re-verificacion completa, no confiar en que ya se corrio Test-) ---
if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Apply-AdoPermissionsPlan rechazado: no se encontro el plan '$PlanPath'."
}
$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json

if (-not $plan.validated -or $plan.validated -ne $true) {
    throw "Apply-AdoPermissionsPlan rechazado: el plan no esta validated=true. Ejecutar Test-AdoPermissionsPlan.ps1 primero."
}
if ($plan.operationKind -ne 'non-destructive') {
    throw "Apply-AdoPermissionsPlan rechazado: operationKind '$($plan.operationKind)' -- este script solo aplica planes 'non-destructive'."
}

$currentHash = Get-AdoPermissionsPlanCanonicalHash -Plan $plan
if ($currentHash -ne $plan.validationHash) {
    throw "Apply-AdoPermissionsPlan rechazado: el plan cambio despues de validarse (validationHash no coincide). Volver a validar."
}

Assert-AdoPermissionsPlanIsNonDestructive -Plan $plan

if (-not $plan.validationEvidence -or -not $plan.validationEvidence.inventoryGeneratedAtUtc) {
    throw "Apply-AdoPermissionsPlan rechazado: falta validationEvidence en el plan."
}
$effectiveMaxHours = [Math]::Min($MaxInventoryAgeHours, $script:AdoPermissionsAbsoluteMaxInventoryAgeHours)
$evidenceMaxHours = [double]$plan.validationEvidence.maxInventoryAgeHours
if ($evidenceMaxHours -gt $script:AdoPermissionsAbsoluteMaxInventoryAgeHours) {
    throw "Apply-AdoPermissionsPlan rechazado: validationEvidence.maxInventoryAgeHours ($evidenceMaxHours) supera el tope absoluto interno ($($script:AdoPermissionsAbsoluteMaxInventoryAgeHours))."
}
$generatedAt = [DateTime]::Parse([string]$plan.validationEvidence.inventoryGeneratedAtUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
$ageHours = ((Get-Date).ToUniversalTime() - $generatedAt.ToUniversalTime()).TotalHours
if ($ageHours -gt $effectiveMaxHours -or [double]::IsNaN($ageHours) -or [double]::IsInfinity($ageHours)) {
    throw "Apply-AdoPermissionsPlan rechazado: el inventario validado tiene $([Math]::Round($ageHours,2)) hora(s), supera el maximo permitido ($effectiveMaxHours). Volver a exportar, generar y validar un plan nuevo."
}

if (-not (Test-Path -LiteralPath $plan.inventoryPath)) {
    throw "Apply-AdoPermissionsPlan rechazado: el inventario referenciado ('$($plan.inventoryPath)') ya no existe."
}
$currentInventoryRaw = Get-Content -LiteralPath $plan.inventoryPath -Raw -Encoding UTF8
$currentInventoryHash = Get-AdoPermissionsSha256OfText -Text ([string]::new($currentInventoryRaw.ToCharArray()))
if ($currentInventoryHash -ne [string]$plan.inventoryHash) {
    throw "Apply-AdoPermissionsPlan rechazado: el inventario referenciado cambio despues de validar el plan. Volver a generar y validar."
}

Write-Host "Aplicando plan '$PlanPath' (validationHash: $($plan.validationHash))..." -ForegroundColor Cyan
$results = Invoke-AdoPermissionsApplyPhases -Plan $plan -PlanPath $PlanPath

$applied = @($results | Where-Object { $_.status -eq 'applied' }).Count
$alreadyDone = @($results | Where-Object { $_.status -eq 'already-done' }).Count
$skipped = @($results | Where-Object { $_.status -eq 'skipped' }).Count
$failed = @($results | Where-Object { $_.status -eq 'failed' }).Count

Write-Host ""
Write-Host "Resumen: aplicadas=$applied ya-aplicadas=$alreadyDone omitidas=$skipped fallidas=$failed" -ForegroundColor Cyan
if ($plan.deferredAfterCreation -and @($plan.deferredAfterCreation).Count -gt 0) {
    Write-Host "Recordatorio: $(@($plan.deferredAfterCreation).Count) rol(es) de grupo quedaron con miembros/ACE diferidos -- ver 'deferredAfterCreation' en el plan. Volver a exportar el inventario y generar un plan nuevo para completarlos." -ForegroundColor Yellow
}

return $results
