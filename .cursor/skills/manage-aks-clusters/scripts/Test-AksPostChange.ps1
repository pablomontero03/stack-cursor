<#
Readback de solo lectura despues de aplicar un plan: get, rollout status
(cuando corresponde), eventos recientes, estado de pods y logs
sanitizados de los recursos afectados por el plan. No modifica nada.

Uso:
  powershell -File .\Test-AksPostChange.ps1 -PlanPath <plan.json>
#>

param(
    [Parameter(Mandatory)] [string]$PlanPath,
    [int]$LogLines = 50
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Aks-Common.ps1')

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Test-AksPostChange rechazado: no existe el archivo de plan '$PlanPath'."
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$context = [string]$plan.cluster.context
$namespace = [string]$plan.namespace
$connArgs = Get-AksKubectlConnectionArgs -Context $context -KubeconfigPath ([string]$plan.cluster.kubeconfigPath)

$report = [ordered]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    context        = $context
    namespace      = $namespace
    resources      = @()
}

foreach ($op in @($plan.approvedOperations)) {
    if ([string]$op.kind -eq 'delete') {
        # No hay readback de estado para un recurso ya eliminado -- se
        # confirma la ausencia en su lugar.
        $stillExists = & kubectl get $op.resourceKind $op.resourceName -n $op.namespace @connArgs 2>&1
        $report.resources += [PSCustomObject]@{
            operationId  = $op.operationId
            resourceKind = $op.resourceKind
            resourceName = $op.resourceName
            deleted      = ($LASTEXITCODE -ne 0)
            note         = if ($LASTEXITCODE -eq 0) { 'ADVERTENCIA: el recurso todavia existe.' } else { 'Confirmado: ya no existe.' }
        }
        continue
    }

    $opNamespace = if ($op.namespace) { [string]$op.namespace } else { $namespace }
    $getOutput = & kubectl get $op.resourceKind $op.resourceName -n $opNamespace @connArgs -o wide 2>&1

    $rolloutStatus = $null
    if ($op.resourceKind -in @('Deployment', 'StatefulSet', 'DaemonSet', 'deployment', 'statefulset', 'daemonset')) {
        $rolloutStatus = & kubectl rollout status "$($op.resourceKind)/$($op.resourceName)" -n $opNamespace @connArgs --timeout=30s 2>&1 | Out-String
    }

    $events = & kubectl get events -n $opNamespace @connArgs --field-selector "involvedObject.name=$($op.resourceName)" --sort-by='.lastTimestamp' 2>&1 | Out-String

    $report.resources += [PSCustomObject]@{
        operationId    = $op.operationId
        resourceKind   = $op.resourceKind
        resourceName   = $op.resourceName
        namespace      = $opNamespace
        get            = ($getOutput | Out-String).Trim()
        rolloutStatus  = if ($rolloutStatus) { $rolloutStatus.Trim() } else { $null }
        recentEvents   = $events.Trim()
    }
}

$report | ConvertTo-Json -Depth 10
