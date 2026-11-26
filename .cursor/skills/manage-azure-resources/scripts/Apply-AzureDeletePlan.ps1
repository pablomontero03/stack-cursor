<#
UNICO script de esta skill que ejecuta eliminaciones reales contra Azure.
Deliberadamente separado de Apply-AzureChangePlan.ps1 -- el hook
azure-delete-authorization.ps1 exige SIEMPRE una tarjeta de aprobacion
propia antes de este script, nunca reutiliza la aprobacion del plan
principal (ver .cursor/rules/azure.mdc § Aprobacion de
eliminaciones).

Exige, en orden, o se rechaza sin borrar nada:
  1. plan.validated == $true y validationHash coincide (sin drift).
  2. tenantId/subscriptionId de la sesion activa coinciden con el plan.
  3. -OperationIds enumera EXACTAMENTE el mismo conjunto de operationIds de
     pendingDeleteOperations que se va a ejecutar -- no se acepta un
     subconjunto distinto al aprobado, ni un id adicional.
  4. Ningun Resource Group completo comparte este lote con otra
     eliminacion (ya lo exige Test-AzureChangePlan.ps1, se revalida aca).

Antes de cada DELETE real, escribe un respaldo de solo lectura sanitizado
del recurso completo (`az resource show`) en .local\azure\backups\ -- un
respaldo fallido o vacio detiene ESA operacion sin borrar nada. Cada
operacion se registra en el journal bajo lock exclusivo; un DELETE
'ambiguous' nunca se reintenta automaticamente.

Uso:
  & '.\Apply-AzureDeletePlan.ps1' -PlanPath plan.json -OperationIds @('delete-...')
#>
param(
    [Parameter(Mandatory)] [string]$PlanPath,
    [Parameter(Mandatory)] [string[]]$OperationIds
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Azure-Common.ps1')

$appliedSoFar = [System.Collections.Generic.List[string]]::new()

function Write-AzureDeleteSummary {
    Write-Host "`n=== Resumen del lote destructivo aplicado en esta ejecucion ===" -ForegroundColor Cyan
    if ($appliedSoFar.Count -eq 0) {
        Write-Host "(nada -- cero eliminaciones realizadas)" -ForegroundColor Yellow
    }
    else {
        foreach ($a in $appliedSoFar) { Write-Host " - $a" -ForegroundColor Red }
    }
    Write-Host "Sin rollback automatico. Correr Test-AzurePostChange.ps1 y revisar Activity Log." -ForegroundColor Yellow
}

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Apply-AzureDeletePlan rechazado: no existe el archivo de plan '$PlanPath'."
}

$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

if ($plan.validated -ne $true) {
    throw "Apply-AzureDeletePlan rechazado: el plan no tiene validated=true."
}
$currentHash = Get-AzurePlanCanonicalHash -Plan $plan
if ($currentHash -ne [string]$plan.validationHash) {
    throw "Apply-AzureDeletePlan rechazado: el contenido del plan cambio despues de la validacion (validationHash no coincide)."
}

$acct = Get-AzureAccountContext -SubscriptionId ([string]$plan.subscriptionId)
if (-not $acct) {
    throw "Apply-AzureDeletePlan rechazado: no hay sesion activa de Azure CLI para la suscripcion '$($plan.subscriptionId)' del plan."
}
if ($acct.tenantId -ne [string]$plan.tenantId) {
    throw "Apply-AzureDeletePlan rechazado: el tenant actual no coincide con el tenant del plan."
}

$allDeleteOps = @($plan.pendingDeleteOperations)
$allDeleteOpIds = @($allDeleteOps | ForEach-Object { [string]$_.operationId })

$requested = @($OperationIds)
$missing = @($requested | Where-Object { $allDeleteOpIds -notcontains $_ })
if ($missing.Count -gt 0) {
    throw "Apply-AzureDeletePlan rechazado: -OperationIds incluye id(s) que no estan en pendingDeleteOperations del plan: $($missing -join ', ')."
}
$extra = @($allDeleteOpIds | Where-Object { $requested -notcontains $_ })
if ($extra.Count -gt 0) {
    throw "Apply-AzureDeletePlan rechazado: el plan tiene eliminacion(es) pendiente(s) no incluida(s) en -OperationIds ($($extra -join ', ')). -OperationIds debe enumerar EXACTAMENTE el lote aprobado, ni mas ni menos."
}

$opsToDelete = @($allDeleteOps | Where-Object { $requested -contains [string]$_.operationId })

$rgDeletes = @($opsToDelete | Where-Object { [string]$_.resourceType -eq 'Microsoft.Resources/resourceGroups' })
if ($rgDeletes.Count -gt 0 -and $opsToDelete.Count -gt $rgDeletes.Count) {
    throw "Apply-AzureDeletePlan rechazado: un Resource Group completo nunca comparte lote con otra eliminacion, ni siquiera aprobado -- generar y aprobar un plan separado."
}

$backupsDir = Get-AzureBackupsDir
Assert-AzureDirectoryExists -Path $backupsDir

foreach ($op in $opsToDelete) {
    $opId = [string]$op.operationId

    $started = Start-AzureJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allDeleteOpIds -OperationId $opId
    if (-not $started) { continue }

    $resultId = $null
    $finalState = 'succeeded'

    try {
        $backupPath = Join-Path $backupsDir "$($plan.validationHash)-$opId.json"
        $backupRaw = & az resource show --ids $op.resourceId --output json 2>&1
        if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]($backupRaw | Out-String))) {
            throw "Respaldo pre-delete fallido o vacio para '$($op.resourceId)' -- se detiene ANTES de borrar nada."
        }
        ($backupRaw | Out-String) | Set-Content -LiteralPath $backupPath -Encoding utf8
        Write-Host "Respaldo escrito: $backupPath" -ForegroundColor DarkGray

        $argv = @($op.argv)
        if ($argv.Count -eq 0) {
            $argv = @('resource', 'delete', '--ids', $op.resourceId)
        }
        $out = & az @argv --output json 2>&1
        if ($LASTEXITCODE -ne 0) { throw "'az $($argv -join ' ')' fallo (exit=$LASTEXITCODE). Salida: $($out | Out-String)" }

        $resultId = "$($op.resourceType)/$($op.resourceId) deleted"
        $appliedSoFar.Add($resultId)
    }
    catch {
        $finalState = 'ambiguous'
        Complete-AzureJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allDeleteOpIds -OperationId $opId -FinalState $finalState -ResultId "ERROR: $($_.Exception.Message)"
        Write-AzureDeleteSummary
        throw "Apply-AzureDeletePlan detenido en la operacion '$opId': $($_.Exception.Message). Ninguna eliminacion posterior del lote se ejecuto. Revisar el estado real (Activity Log) antes de reintentar -- un reintento exige nueva aprobacion destructiva."
    }

    Complete-AzureJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allDeleteOpIds -OperationId $opId -FinalState 'succeeded' -ResultId $resultId
}

Write-AzureDeleteSummary
[PSCustomObject]@{ deleted = @($appliedSoFar); planValidationHash = $plan.validationHash }
