<#
PREPARA y MUESTRA un plan de rollback a partir de un respaldo ya escrito
en .local\aks\backups\ o de un revision anterior de un rollout -- nunca lo
ejecuta. Ejecutar el rollback (kubectl apply del respaldo, o kubectl
rollout undo) exige volver a pasar por New-AksChangePlan.ps1 ->
Test-AksChangePlan.ps1 -> Apply-AksChangePlan.ps1 con una aprobacion NUEVA
y separada de la del cambio original -- este script solo arma esa
propuesta para que el usuario la revise.

Uso:
  powershell -File .\Invoke-AksRollback.ps1 -PlanPath <plan-del-cambio-original.json>
#>

param(
    [Parameter(Mandatory)] [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Aks-Common.ps1')

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Invoke-AksRollback rechazado: no existe el archivo de plan '$PlanPath'."
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
$backupsDir = Get-AksBackupsDir

$proposals = [System.Collections.Generic.List[object]]::new()

foreach ($op in @($plan.approvedOperations)) {
    $backupPath = Join-Path $backupsDir "$($plan.validationHash)-$($op.operationId).yaml"

    if ([string]$op.kind -eq 'delete' -and (Test-Path -LiteralPath $backupPath)) {
        $proposals.Add([PSCustomObject]@{
            operationId      = $op.operationId
            originalKind     = 'delete'
            rollbackStrategy = 'kubectl apply del respaldo pre-delete (recrea el recurso tal como estaba)'
            backupPath       = $backupPath
            nextStep         = 'Generar un New-AksChangePlan.ps1 nuevo con kind=apply y manifestPath apuntando a este respaldo, validarlo y pedir una aprobacion NUEVA para aplicarlo.'
        })
    }
    elseif ([string]$op.kind -in @('apply', 'patch', 'scale', 'label', 'annotate')) {
        $proposals.Add([PSCustomObject]@{
            operationId      = $op.operationId
            originalKind     = [string]$op.kind
            rollbackStrategy = 'kubectl rollout undo (si el recurso soporta rollout) o reaplicar la revision anterior conocida'
            backupPath       = if (Test-Path -LiteralPath $backupPath) { $backupPath } else { $null }
            nextStep         = 'Confirmar la revision objetivo (kubectl rollout history) y generar un New-AksChangePlan.ps1 nuevo con kind=rollout-restart o el manifiesto de la revision anterior; requiere aprobacion NUEVA.'
        })
    }
    elseif ([string]$op.kind -eq 'rollout-restart') {
        $proposals.Add([PSCustomObject]@{
            operationId      = $op.operationId
            originalKind     = 'rollout-restart'
            rollbackStrategy = 'Un restart no cambia el manifiesto -- no hay "deshacer" mas alla de otro restart si el problema fue transitorio. Revisar si hace falta revertir una revision distinta.'
            backupPath       = $null
            nextStep         = 'Diagnosticar con aks-diagnoser antes de proponer un rollback -- un restart no es reversible en el sentido tradicional.'
        })
    }
    else {
        $proposals.Add([PSCustomObject]@{
            operationId      = $op.operationId
            originalKind     = [string]$op.kind
            rollbackStrategy = 'No hay estrategia automatica para este kind -- revisar manualmente.'
            backupPath       = if (Test-Path -LiteralPath $backupPath) { $backupPath } else { $null }
            nextStep         = 'Definir la estrategia con el usuario antes de generar un plan de rollback.'
        })
    }
}

Write-Host "=== Propuesta de rollback (NADA se ejecuto) ===" -ForegroundColor Cyan
Write-Host "Cada item exige una aprobacion NUEVA y separada de la del cambio original, siguiendo otra vez New-AksChangePlan -> Test-AksChangePlan -> Apply-AksChangePlan." -ForegroundColor Yellow

$proposals | ConvertTo-Json -Depth 10
