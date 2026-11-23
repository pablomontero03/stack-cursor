<#
Relee en vivo (solo GET) el estado real de cada operacion de un plan ya
aplicado y lo compara contra lo declarado, reportando
aplicado/divergente/error por operationId. Nunca escribe nada. Pensado
para correr despues de Apply-AdoPermissionsPlan.ps1 (o de
Apply-AdoPermissionsDeletePlan.ps1, para confirmar que el recurso ya no
existe).

La logica real vive en Get-AdoPermissionsReadbackResults
(Invoke-AdoPermissionsRest.ps1) para poder probarla con red mockeada.

Uso:
  .\Test-AdoPermissionsReadback.ps1 -PlanPath '...'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PlanPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoPermissionsRest.ps1')

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Test-AdoPermissionsReadback rechazado: no se encontro el plan '$PlanPath'."
}
$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json

$results = Get-AdoPermissionsReadbackResults -Plan $plan

foreach ($r in $results) {
    $color = switch ($r.status) { 'applied' { 'Green' }; 'divergent' { 'Yellow' }; default { 'Red' } }
    Write-Host "[$($r.status)] $($r.operationId) ($($r.operationType)) $($r.detail)" -ForegroundColor $color
}

$divergentCount = @($results | Where-Object { $_.status -ne 'applied' }).Count
Write-Host ""
Write-Host "Readback: $($results.Count) operacion(es), $divergentCount divergente(s)/error(es)." -ForegroundColor Cyan

return $results
