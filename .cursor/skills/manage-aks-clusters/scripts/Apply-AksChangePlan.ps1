<#
UNICO script de esta skill que puede ejecutar una escritura real contra un
cluster AKS. Separado deliberadamente de cualquier dry-run para que
aks-security-gate.ps1 pueda pedir permiso explicito por el NOMBRE de este
script. Exige, en orden, o se rechaza sin tocar el cluster:

  1. El plan existe y validated == $true (escrito por Test-AksChangePlan.ps1).
  2. validationHash coincide con el contenido actual del plan.
  3. El contexto actual (kubectl config current-context) coincide con
     plan.cluster.context -- si cambio desde que se genero el plan, se
     rechaza (nunca aplicar a un cluster distinto del planeado).
  4. Confirmacion explicita del usuario ya obtenida FUERA de este script
     (el hook de Claude Code pide esa confirmacion por el NOMBRE de este
     script).

Cada operacion 'delete' escribe SIEMPRE un respaldo de solo lectura
sanitizado en .local\aks\backups\ antes del delete real -- un respaldo
fallido o vacio detiene esa operacion antes de borrar nada. Cada
operacion se registra en el journal de .local\aks\executions\ bajo lock
exclusivo de archivo -- una operacion ya 'succeeded' nunca se reintenta
automaticamente. Ninguna fase hace rollback automatico: si una falla, el
script se detiene y reporta exactamente que se aplico hasta ahi.

Uso:
  powershell -File .\Apply-AksChangePlan.ps1 -PlanPath <plan.json>
#>

param(
    [Parameter(Mandatory)] [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Aks-Common.ps1')

$appliedSoFar = [System.Collections.Generic.List[string]]::new()

function Write-AppliedSummary {
    Write-Host "`n=== Resumen de lo aplicado en esta ejecucion ===" -ForegroundColor Cyan
    if ($appliedSoFar.Count -eq 0) {
        Write-Host "(nada -- cero escrituras realizadas)" -ForegroundColor Yellow
    }
    else {
        foreach ($a in $appliedSoFar) { Write-Host " - $a" -ForegroundColor Green }
    }
    Write-Host "Ninguna operacion hace rollback automatico. Correr Test-AksPostChange.ps1 para el readback." -ForegroundColor Yellow
}

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Apply-AksChangePlan rechazado: no existe el archivo de plan '$PlanPath'."
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

if ($plan.validated -ne $true) {
    throw "Apply-AksChangePlan rechazado: el plan no tiene validated=true. Ejecutar Test-AksChangePlan.ps1 primero y resolver los bloqueantes."
}
if ([string]::IsNullOrWhiteSpace([string]$plan.validationHash)) {
    throw "Apply-AksChangePlan rechazado: el plan no tiene validationHash."
}

$currentHash = Get-AksPlanCanonicalHash -Plan $plan
if ($currentHash -ne $plan.validationHash) {
    throw "Apply-AksChangePlan rechazado: el contenido del plan cambio despues de la validacion (validationHash no coincide). Volver a correr Test-AksChangePlan.ps1 sobre la version actual antes de aplicar."
}

$planContext = [string]$plan.cluster.context
$planKubeconfigPath = [string]$plan.cluster.kubeconfigPath
if ($planKubeconfigPath -and -not (Test-Path -LiteralPath $planKubeconfigPath)) {
    throw "Apply-AksChangePlan rechazado: el plan referencia el kubeconfig '$planKubeconfigPath', que ya no existe en esta maquina."
}

$currentContextArgs = @('config', 'current-context')
if ($planKubeconfigPath) { $currentContextArgs += @('--kubeconfig', $planKubeconfigPath) }
$actualContext = $null
try { $actualContext = (& kubectl @currentContextArgs) 2>$null } catch { $actualContext = $null }
if ($actualContext -ne $planContext) {
    throw "Apply-AksChangePlan rechazado: el contexto actual ('$actualContext'$(if ($planKubeconfigPath) { " en '$planKubeconfigPath'" })) no coincide con el contexto del plan ('$planContext'). El contexto pudo haber cambiado desde que se genero el plan -- nunca se aplica a un cluster distinto del planeado."
}

$connArgs = Get-AksKubectlConnectionArgs -Context $planContext -KubeconfigPath $planKubeconfigPath

$namespace = [string]$plan.namespace
$allOperationIds = @(@($plan.approvedOperations) | ForEach-Object { [string]$_.operationId })
$backupsDir = Get-AksBackupsDir
Assert-AksDirectoryExists -Path $backupsDir

foreach ($op in @($plan.approvedOperations)) {
    $opId = [string]$op.operationId
    $kind = [string]$op.kind
    $resourceKind = [string]$op.resourceKind
    $resourceName = [string]$op.resourceName
    $opNamespace = if ($op.namespace) { [string]$op.namespace } else { $namespace }

    $started = Start-AksJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allOperationIds -OperationId $opId
    if (-not $started) { continue }

    $resultId = $null
    $finalState = 'succeeded'

    try {
        if ($kind -eq 'delete') {
            $backupPath = Join-Path $backupsDir "$($plan.validationHash)-$opId.yaml"
            $backupYaml = & kubectl get $resourceKind $resourceName -n $opNamespace @connArgs -o yaml 2>&1
            if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]($backupYaml | Out-String))) {
                throw "Respaldo pre-delete fallido o vacio para '$resourceKind/$resourceName' en namespace '$opNamespace' -- se detiene ANTES de borrar nada."
            }
            ($backupYaml | Out-String) | Set-Content -LiteralPath $backupPath -Encoding utf8
            Write-Host "Respaldo escrito: $backupPath" -ForegroundColor DarkGray

            $propagation = if ($op.propagationPolicy) { [string]$op.propagationPolicy } else { 'Background' }
            & kubectl delete $resourceKind $resourceName -n $opNamespace @connArgs "--cascade=$propagation" 2>&1 | Write-Host
            if ($LASTEXITCODE -ne 0) { throw "kubectl delete fallo para '$resourceKind/$resourceName' (exit=$LASTEXITCODE)." }
            $resultId = "$resourceKind/$resourceName@$opNamespace deleted"
        }
        elseif ($kind -eq 'apply') {
            if ([string]::IsNullOrWhiteSpace([string]$op.manifestPath) -or -not (Test-Path -LiteralPath $op.manifestPath)) {
                throw "Operacion 'apply' ($opId) no tiene manifestPath valido."
            }
            & kubectl apply -f $op.manifestPath -n $opNamespace @connArgs 2>&1 | Write-Host
            if ($LASTEXITCODE -ne 0) { throw "kubectl apply fallo para '$($op.manifestPath)' (exit=$LASTEXITCODE)." }
            $resultId = "$resourceKind/$resourceName@$opNamespace applied"
        }
        elseif ($kind -eq 'scale') {
            if (-not $op.replicas) { throw "Operacion 'scale' ($opId) no tiene 'replicas'." }
            & kubectl scale $resourceKind $resourceName -n $opNamespace @connArgs "--replicas=$($op.replicas)" 2>&1 | Write-Host
            if ($LASTEXITCODE -ne 0) { throw "kubectl scale fallo (exit=$LASTEXITCODE)." }
            $resultId = "$resourceKind/$resourceName@$opNamespace scaled to $($op.replicas)"
        }
        elseif ($kind -eq 'rollout-restart') {
            & kubectl rollout restart "$resourceKind/$resourceName" -n $opNamespace @connArgs 2>&1 | Write-Host
            if ($LASTEXITCODE -ne 0) { throw "kubectl rollout restart fallo (exit=$LASTEXITCODE)." }
            $resultId = "$resourceKind/$resourceName@$opNamespace restarted"
        }
        elseif ($kind -in @('patch', 'label', 'annotate', 'cordon', 'uncordon', 'drain', 'other')) {
            if ([string]::IsNullOrWhiteSpace([string]$op.rawArgs)) {
                throw "Operacion '$kind' ($opId) requiere 'rawArgs' (array de argumentos kubectl exactos ya revisados en el plan)."
            }
            $rawArgsArray = @($op.rawArgs)
            & kubectl @rawArgsArray @connArgs 2>&1 | Write-Host
            if ($LASTEXITCODE -ne 0) { throw "kubectl $kind fallo (exit=$LASTEXITCODE)." }
            $resultId = "$resourceKind/$resourceName@$opNamespace ($kind) aplicado"
        }
        else {
            throw "kind de operacion no soportado: '$kind'."
        }

        $appliedSoFar.Add($resultId)
    }
    catch {
        $finalState = 'ambiguous'
        Complete-AksJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allOperationIds -OperationId $opId -FinalState $finalState -ResultId "ERROR: $($_.Exception.Message)"
        Write-AppliedSummary
        throw "Apply-AksChangePlan detenido en la operacion '$opId': $($_.Exception.Message). Ninguna operacion posterior del lote se ejecuto. Sin rollback automatico -- revisar el estado real del cluster antes de reintentar (un reintento exige nueva aprobacion)."
    }

    Complete-AksJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allOperationIds -OperationId $opId -FinalState 'succeeded' -ResultId $resultId
}

Write-AppliedSummary
[PSCustomObject]@{ applied = @($appliedSoFar); planValidationHash = $plan.validationHash }
