<#
Imprime (solo lectura, sin red) un resumen legible de los environments de
un body de Release ya descargado por
Get-AdoClassicDefinitionTemplate.ps1 -Kind Release: id, name, Variable
Groups, workflowTasks, conditions, y opcionalmente el detalle de
preDeployApprovals (approver, isAutomated, approvalOptions -- son datos
de identidad de la organizacion, nunca un secreto). Reemplaza los
one-liners de PowerShell -Command improvisados para esta misma tarea --
reusar este script en vez de armar uno nuevo cada vez, para que quede
cubierto por un wildcard fijo de permisos.

Uso:
  powershell -File .\Show-AdoReleaseEnvironments.ps1 -JsonPath 'C:\...\raw-release-366-....json'
  powershell -File .\Show-AdoReleaseEnvironments.ps1 -JsonPath '...' -ShowApprovals
  powershell -File .\Show-AdoReleaseEnvironments.ps1 -JsonPath '...' -EnvironmentName Produccion -ShowApprovals
#>

param(
    [Parameter(Mandatory)] [string]$JsonPath,
    [string]$EnvironmentName,
    [switch]$ShowApprovals
)

$ErrorActionPreference = 'Stop'

if (-not (Test-Path -LiteralPath $JsonPath -PathType Leaf)) {
    throw "No existe el archivo: $JsonPath"
}

$r = Get-Content -LiteralPath $JsonPath -Raw -Encoding UTF8 | ConvertFrom-Json

Write-Output "name=$($r.name) id=$($r.id) revision=$($r.revision)"

$envs = $r.environments
if ($EnvironmentName) { $envs = $envs | Where-Object { $_.name -eq $EnvironmentName } }

foreach ($e in $envs) {
    $enableAccessToken = $e.deployPhases[0].deploymentInput.enableAccessToken
    Write-Output "--- env id=$($e.id) name=$($e.name) variableGroups=$($e.variableGroups -join ',') enableAccessToken=$enableAccessToken"
    foreach ($t in $e.deployPhases[0].workflowTasks) { Write-Output "    workflowTask: $($t.name) enabled=$($t.enabled)" }
    Write-Output '    conditions:'
    $e.conditions | ForEach-Object { Write-Output "      $($_.name)/$($_.conditionType)/$($_.value)" }
    if ($ShowApprovals) {
        Write-Output '    preDeployApprovals:'
        Write-Output ("      isAutomated=" + ($e.preDeployApprovals.approvals | ForEach-Object { $_.isAutomated } | Select-Object -First 1))
        $e.preDeployApprovals.approvals | ForEach-Object {
            $approverName = if ($_.approver) { $_.approver.displayName } else { '(sin approver)' }
            Write-Output "      rank=$($_.rank) isAutomated=$($_.isAutomated) approver='$approverName'"
        }
        Write-Output "      approvalOptions: $($e.preDeployApprovals.approvalOptions | ConvertTo-Json -Compress)"
    }
}
