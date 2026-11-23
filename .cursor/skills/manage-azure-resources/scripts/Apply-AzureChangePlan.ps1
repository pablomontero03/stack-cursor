<#
UNICO script de esta skill que ejecuta escrituras reales no destructivas
(create/update/action) contra Azure. Separado deliberadamente de cualquier
what-if para que el hook de este dominio pueda pedir permiso explicito por
el NOMBRE de este script (o reutilizar, dentro de la ventana de 24h, la
aprobacion visible ya dada en ExitPlanMode -- ver
.kiro/hooks/azure/azure-plan-authorization.ps1). NUNCA ejecuta
`pendingDeleteOperations` -- eso es exclusivamente Apply-AzureDeletePlan.ps1.

Exige, en orden, o se rechaza sin tocar Azure:
  1. plan.validated == $true (escrito por Test-AzureChangePlan.ps1).
  2. validationHash coincide con el contenido actual del plan (sin drift).
  3. tenantId/subscriptionId de la sesion activa de az coinciden con los
     del plan -- si cambiaron desde que se genero, se rechaza.
  4. Ningun inventario referenciado cambio desde la validacion.

Cada operacion se ejecuta unicamente via el executor declarado
(azureCli/armDeployment/armRest) usando `argv` tokenizado -- nunca se
interpola un string de shell. Cada operacion se registra en el journal de
.local\azure\executions\ bajo lock exclusivo; una operacion ya 'succeeded'
nunca se reintenta automaticamente. Sin rollback automatico: si una
operacion falla, el script se detiene y reporta exactamente que se aplico
hasta ahi (ver Invoke-AzureRollback -- no existe, un rollback siempre es un
plan nuevo con su propia aprobacion).

Uso:
  & '.\Apply-AzureChangePlan.ps1' -PlanPath plan.json
#>
param([Parameter(Mandatory)] [string]$PlanPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Azure-Common.ps1')

$appliedSoFar = [System.Collections.Generic.List[string]]::new()

function Write-AzureAppliedSummary {
    Write-Host "`n=== Resumen de lo aplicado en esta ejecucion (fase no destructiva) ===" -ForegroundColor Cyan
    if ($appliedSoFar.Count -eq 0) {
        Write-Host "(nada -- cero escrituras realizadas)" -ForegroundColor Yellow
    }
    else {
        foreach ($a in $appliedSoFar) { Write-Host " - $a" -ForegroundColor Green }
    }
    Write-Host "Ninguna operacion hace rollback automatico. Correr Test-AzurePostChange.ps1 para el readback." -ForegroundColor Yellow
}

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Apply-AzureChangePlan rechazado: no existe el archivo de plan '$PlanPath'."
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

if ($plan.validated -ne $true) {
    throw "Apply-AzureChangePlan rechazado: el plan no tiene validated=true. Ejecutar Test-AzureChangePlan.ps1 primero y resolver los bloqueantes."
}
if ([string]::IsNullOrWhiteSpace([string]$plan.validationHash)) {
    throw "Apply-AzureChangePlan rechazado: el plan no tiene validationHash."
}

$currentHash = Get-AzurePlanCanonicalHash -Plan $plan
if ($currentHash -ne $plan.validationHash) {
    throw "Apply-AzureChangePlan rechazado: el contenido del plan cambio despues de la validacion (validationHash no coincide). Volver a correr Test-AzureChangePlan.ps1 sobre la version actual antes de aplicar."
}

$acct = Get-AzureAccountContext -SubscriptionId ([string]$plan.subscriptionId)
if (-not $acct) {
    throw "Apply-AzureChangePlan rechazado: no hay sesion activa de Azure CLI para la suscripcion '$($plan.subscriptionId)' del plan."
}
if ($acct.tenantId -ne [string]$plan.tenantId) {
    throw "Apply-AzureChangePlan rechazado: el tenant actual ('$($acct.tenantId)') no coincide con el tenant del plan ('$($plan.tenantId)'). La sesion pudo haber cambiado desde que se genero el plan -- nunca se aplica a un tenant distinto del planeado."
}

foreach ($inv in @($plan.inventoryHashes)) {
    $invPath = [string]$inv.path
    if (-not (Test-Path -LiteralPath $invPath)) {
        throw "Apply-AzureChangePlan rechazado: el inventario '$invPath' referenciado por el plan ya no existe en disco (drift)."
    }
    $invHash = Get-AzureFileSha256 -Path $invPath
    if ($invHash -ne [string]$inv.hash) {
        throw "Apply-AzureChangePlan rechazado: drift detectado en el inventario '$invPath' desde la validacion del plan."
    }
}

if (@($plan.pendingDeleteOperations).Count -gt 0) {
    Write-Host "Nota: el plan tiene $(@($plan.pendingDeleteOperations).Count) eliminacion(es) pendiente(s) -- este script NUNCA las ejecuta. Usar Apply-AzureDeletePlan.ps1 con su propia aprobacion separada." -ForegroundColor Yellow
}

$allOperationIds = @(@($plan.approvedOperations) | ForEach-Object { [string]$_.operationId })

foreach ($op in @($plan.approvedOperations)) {
    $opId = [string]$op.operationId
    if ([bool]$op.destructive) {
        throw "Apply-AzureChangePlan rechazado: la operacion '$opId' esta marcada destructive=true dentro de approvedOperations -- eso nunca deberia haber pasado la validacion. Deteniendose sin ejecutar nada mas."
    }

    $started = Start-AzureJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allOperationIds -OperationId $opId
    if (-not $started) { continue }

    $resultId = $null
    $finalState = 'succeeded'

    try {
        $executor = [string]$op.executor
        $argv = @($op.argv)

        switch ($executor) {
            'azureCli' {
                if ($argv.Count -eq 0) { throw "Operacion '$opId': executor azureCli requiere 'argv' no vacio." }
                $out = & az @argv --output json 2>&1
                if ($LASTEXITCODE -ne 0) { throw "'az $($argv -join ' ')' fallo (exit=$LASTEXITCODE). Salida: $($out | Out-String)" }
                $resultId = "$($op.resourceType)/$($op.resourceId) ($($op.action)) via azureCli"
            }
            'armDeployment' {
                if ($argv.Count -eq 0) { throw "Operacion '$opId': executor armDeployment requiere 'argv' (ej. deployment,group,create,...) no vacio." }
                $out = & az @argv --output json 2>&1
                if ($LASTEXITCODE -ne 0) { throw "'az $($argv -join ' ')' fallo (exit=$LASTEXITCODE). Salida: $($out | Out-String)" }
                $resultId = "$($op.resourceType)/$($op.resourceId) ($($op.action)) via armDeployment"
            }
            'armRest' {
                if ($argv.Count -eq 0) { throw "Operacion '$opId': executor armRest requiere 'argv' (az rest ...) no vacio." }
                if ($argv[0] -ne 'rest') { throw "Operacion '$opId': executor armRest exige que argv[0] sea 'rest'." }
                $out = & az @argv --output json 2>&1
                if ($LASTEXITCODE -ne 0) { throw "'az $($argv -join ' ')' fallo (exit=$LASTEXITCODE). Salida: $($out | Out-String)" }
                $resultId = "$($op.resourceType)/$($op.resourceId) ($($op.action)) via armRest"
            }
            default {
                throw "Operacion '$opId': executor no soportado '$executor' (esperado azureCli|armDeployment|armRest)."
            }
        }

        $appliedSoFar.Add($resultId)
    }
    catch {
        $finalState = 'ambiguous'
        Complete-AzureJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allOperationIds -OperationId $opId -FinalState $finalState -ResultId "ERROR: $($_.Exception.Message)"
        Write-AzureAppliedSummary
        throw "Apply-AzureChangePlan detenido en la operacion '$opId': $($_.Exception.Message). Ninguna operacion posterior del lote se ejecuto. Sin rollback automatico -- hacer readback del estado real antes de decidir (un reintento exige nueva aprobacion, ver New-AzureRollbackPlan.ps1 para un rollback deliberado)."
    }

    Complete-AzureJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allOperationIds -OperationId $opId -FinalState 'succeeded' -ResultId $resultId
}

Write-AzureAppliedSummary
[PSCustomObject]@{ applied = @($appliedSoFar); planValidationHash = $plan.validationHash }
