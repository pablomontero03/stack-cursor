<#
Azure Monitor Metrics de solo lectura para un recurso, para correlacionar
utilizacion con costo (ver references/utilization-correlation.md). Usa
`az monitor metrics list` (via Invoke-AzureCliJson del dominio general),
argv tokenizado.

Uso:
  & '.\Get-AzureResourceMetrics.ps1' -ResourceId /subscriptions/.../resourceGroups/rg1/providers/Microsoft.Compute/virtualMachines/vm1 -MetricNames 'Percentage CPU' -StartTime (Get-Date).AddDays(-7) -EndTime (Get-Date) -Interval PT1H -Aggregation Average
#>
param(
    [Parameter(Mandatory)] [string]$ResourceId,
    [Parameter(Mandatory)] [string[]]$MetricNames,
    [datetime]$StartTime = (Get-Date).AddDays(-7),
    [datetime]$EndTime = (Get-Date),
    [string]$Interval = 'PT1H',
    [ValidateSet('Average', 'Total', 'Maximum', 'Minimum', 'Count')] [string]$Aggregation = 'Average'
)

$ErrorActionPreference = 'Stop'
$azureCommonPath = Join-Path $PSScriptRoot '..\..\manage-azure-resources\scripts\Azure-Common.ps1'
. $azureCommonPath

if ($ResourceId -notmatch '(?i)^/subscriptions/69dc43ec-5f24-4203-9239-a8d0f8506d44/') {
    throw "Get-AzureResourceMetrics rechazado: el resourceId no pertenece a la suscripcion FinOps autorizada (69dc43ec-5f24-4203-9239-a8d0f8506d44)."
}

$argv = @(
    'monitor', 'metrics', 'list',
    '--resource', $ResourceId,
    '--metric', ($MetricNames -join ','),
    '--start-time', $StartTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'),
    '--end-time', $EndTime.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ'),
    '--interval', $Interval,
    '--aggregation', $Aggregation
)

$raw = Invoke-AzureCliJson -Argv $argv
$queriedAtUtc = (Get-Date).ToUniversalTime().ToString('o')

if ($null -eq $raw) {
    [PSCustomObject]@{
        ok           = $false
        resourceId   = $ResourceId
        metricNames  = $MetricNames
        note         = 'La consulta de metricas fallo o el recurso no expone estas metricas en Azure Monitor. No asumir que esta ocioso sin este dato -- marcar utilizacion como no disponible.'
        queriedAtUtc = $queriedAtUtc
    } | ConvertTo-Json -Depth 10
    return
}

$series = @($raw.value | ForEach-Object {
    [PSCustomObject]@{
        name       = [string]$_.name.value
        unit       = [string]$_.unit
        timeseries = @($_.timeseries | ForEach-Object {
            @($_.data | Where-Object { $null -ne $_.$Aggregation } | ForEach-Object {
                [PSCustomObject]@{ timeStamp = $_.timeStamp; value = $_.$Aggregation }
            })
        })
    }
})

[PSCustomObject]@{
    ok           = $true
    resourceId   = $ResourceId
    startTime    = $StartTime.ToUniversalTime().ToString('o')
    endTime      = $EndTime.ToUniversalTime().ToString('o')
    interval     = $Interval
    aggregation  = $Aggregation
    metrics      = $series
    queriedAtUtc = $queriedAtUtc
} | ConvertTo-Json -Depth 15
