<#
Muestra un resumen de dry-run de un plan ya generado (validado o no). Este
script es EXCLUSIVAMENTE de solo lectura: no acepta -Apply, no llama a
Invoke-AdoRest para escribir nada, no crea ni modifica ningun recurso de
Azure DevOps bajo ninguna circunstancia ni combinacion de parametros.

La aplicacion real vive en un script separado, Apply-AdoClassicPlan.ps1,
precisamente para no depender de interpretar variantes de un switch
-Apply (abreviaciones de PowerShell, -Apply:$true, etc.) en un mismo
script que tambien hace dry-run: el hook de seguridad
(ado-security-gate.ps1) puede pedir permiso simplemente por el NOMBRE del
script que se va a ejecutar.

Uso:
  powershell -File .\Invoke-AdoClassicPlan.ps1 -PlanPath '...\aks-x-y-....json'
#>

param(
    [Parameter(Mandatory)] [string]$PlanPath
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Invoke-AdoClassicPlan: no existe el archivo de plan '$PlanPath'."
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

Write-Host "=== DRY-RUN (no se realiza ningun cambio) ===" -ForegroundColor Cyan
Write-Host "Familia: $($plan.family)"
Write-Host "Build a crear:   $($plan.names.build)"
Write-Host "Release a crear: $($plan.names.release)"
if ($plan.family -eq 'aks') {
    Write-Host "Variable Group a crear: $($plan.variableGroup.name)"
}
else {
    Write-Host "Library compartida a referenciar (no se crea): $($plan.sharedLibrary.name)"
}
Write-Host "CD trigger: $($plan.release.cdTriggerEnabled)"
Write-Host "validated: $($plan.validated)"
Write-Host ""
Write-Host "Nada fue creado, modificado ni ejecutado. Este script nunca aplica: para aplicar de verdad (tras aprobacion explicita del usuario) se usa Apply-AdoClassicPlan.ps1, un script separado." -ForegroundColor Yellow
exit 0
