<#
Wrapper CLI de solo lectura para monitorear un Build o Release clasico ya
iniciado: consulta inmediatamente y luego cada -IntervalSeconds hasta un
estado terminal o -TimeoutMinutes. Nunca escribe nada -- son GETs, forman
parte del plan aprobado y no requieren aprobacion adicional (ver
.cursor/rules/azure-devops.mdc).

Usado tambien por orchestrate-application-pipeline-cycle para el
monitoreo activo de Build/Release exigido por
INPUT.execution.status_poll_interval_seconds.

Uso:
  powershell -File .\Wait-AdoClassicRun.ps1 -Kind Build -Id 12345 -Project DevOps -IntervalSeconds 120 -TimeoutMinutes 60
  powershell -File .\Wait-AdoClassicRun.ps1 -Kind Release -Id 6789 -Project DevOps -EnvironmentName Desarrollo -IntervalSeconds 120 -TimeoutMinutes 60
#>

param(
    [Parameter(Mandatory)] [ValidateSet('Build', 'Release')] [string]$Kind,
    [Parameter(Mandatory)] [int]$Id,
    [Parameter(Mandatory)] [string]$Project,
    [string]$EnvironmentName,
    [int]$IntervalSeconds = 120,
    [int]$TimeoutMinutes = 60
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')
. (Join-Path $scriptRoot 'Ado-RunPolling-Common.ps1')

$result = Wait-AdoClassicRun -Kind $Kind -Id $Id -Project $Project -EnvironmentName $EnvironmentName -IntervalSeconds $IntervalSeconds -TimeoutMinutes $TimeoutMinutes

$result | ConvertTo-Json -Depth 10
