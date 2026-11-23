<#
GET de solo lectura de una instancia de Release completa (no su
definicion) -- para diagnosticar por que un ambiente quedo en un estado
inesperado (ej. 'rejected' sin desplegar). Gap real encontrado
2026-09-07: ningun script autorizado devolvia el detalle completo de una
instancia, solo su estado normalizado (Ado-RunPolling-Common.ps1) o la
definicion (Get-AdoClassicDefinitionTemplate.ps1, endpoint distinto).

Uso:
  powershell -File .\Get-AdoClassicReleaseInstance.ps1 -ReleaseId 7225 -Project DevOps
#>

param(
    [Parameter(Mandatory)] [int]$ReleaseId,
    [string]$Project = 'DevOps',
    [int]$EnvironmentId,
    [int]$DeployPhaseId,
    [int]$TaskId
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-AdoRest.ps1')

if ($EnvironmentId -and $DeployPhaseId -and $TaskId) {
    $logUri = "$($script:AdoReleaseBaseUrl)/$Project/_apis/release/releases/$ReleaseId/environments/$EnvironmentId/deployPhases/$DeployPhaseId/tasks/$($TaskId)/logs?api-version=$($script:AdoApiVersion)"
    $logResp = Invoke-AdoRest -Method GET -Uri $logUri
    Write-Output $logResp.Body
    return
}

$uri = "$($script:AdoReleaseBaseUrl)/$Project/_apis/release/releases/$($ReleaseId)?api-version=$($script:AdoApiVersion)"
$body = (Invoke-AdoRest -Method GET -Uri $uri).Body
if (-not $body) { throw "Get-AdoClassicReleaseInstance: no se pudo consultar el Release $ReleaseId." }

$environments = @($body.environments | ForEach-Object {
        [PSCustomObject]@{
            id                  = $_.id
            name                = $_.name
            status              = $_.status
            conditions          = @($_.conditions | ForEach-Object { [PSCustomObject]@{ conditionType = $_.conditionType; name = $_.name; result = $_.result } })
            preDeployApprovals  = @($_.preDeployApprovals | ForEach-Object { [PSCustomObject]@{ status = $_.status; isAutomated = $_.isAutomated } })
            deploySteps         = @($_.deploySteps | ForEach-Object { [PSCustomObject]@{ status = $_.status; reason = $_.reason; releaseDeployPhases = @($_.releaseDeployPhases | ForEach-Object { [PSCustomObject]@{ phaseId = $_.id; status = $_.status; deploymentJobs = @($_.deploymentJobs | ForEach-Object { [PSCustomObject]@{ jobId = $_.job.id; job = $_.job.status; tasks = @($_.tasks | ForEach-Object { [PSCustomObject]@{ taskId = $_.id; name = $_.name; status = $_.status; agentName = $_.agentName; logUrl = if ($_.log) { $_.log.url } else { $null } } }) } }) } }) } })
        }
    })

[PSCustomObject]@{
    id           = $body.id
    name         = $body.name
    status       = $body.status
    reason       = $body.reason
    environments = $environments
} | ConvertTo-Json -Depth 12
