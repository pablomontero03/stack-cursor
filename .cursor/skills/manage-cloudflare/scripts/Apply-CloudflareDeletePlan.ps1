<#
UNICO script que ejecuta eliminaciones reales en Cloudflare. -OperationIds
debe coincidir EXACTO (ambas direcciones) con el lote a ejecutar. Respaldo
de solo lectura obligatorio antes de cada DELETE real -- un respaldo fallido
o vacio detiene esa eliminacion antes de tocar nada.
#>
param(
    [Parameter(Mandatory)] [string]$DeletePlanPath,
    [Parameter(Mandatory)] [string[]]$OperationIds
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cloudflare-Common.ps1')

if (-not (Test-Path -LiteralPath $DeletePlanPath -PathType Leaf)) {
    throw "El delete plan '$DeletePlanPath' no existe."
}
$plan = Get-Content -LiteralPath $DeletePlanPath -Raw | ConvertFrom-Json

# --- Preflight comun ---
if ([bool]$plan.validated -ne $true) {
    throw "El delete plan no esta validado (validated != true). Corre Test-CloudflareDeletePlan.ps1 primero."
}
if ([string]::IsNullOrWhiteSpace([string]$plan.validationHash)) {
    throw "El delete plan no tiene validationHash."
}
$recomputedHash = Get-CloudflarePlanCanonicalHash -Plan $plan
if ($recomputedHash -ne [string]$plan.validationHash) {
    throw "El delete plan cambio despues de validarse (validationHash no coincide). Se rechaza la aplicacion -- volve a validar."
}
$accountContext = Get-CloudflareAccountContext -AccountId $plan.accountId
if (-not $accountContext) {
    throw "No se pudo confirmar el contexto de la cuenta Cloudflare '$($plan.accountId)' (token ausente o sin acceso). Se rechaza la aplicacion."
}
foreach ($entry in @($plan.inventoryHashes)) {
    if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf)) {
        throw "El inventario '$($entry.path)' ya no existe (drift). Se rechaza la aplicacion."
    }
    $currentHash = Get-CloudflareFileSha256 -Path $entry.path
    if ($currentHash -ne $entry.hash) {
        throw "El inventario '$($entry.path)' cambio desde la validacion (drift de hash). Se rechaza la aplicacion."
    }
}

$allDeleteOps = @($plan.pendingDeleteOperations)
$allDeleteOpIds = @($allDeleteOps | ForEach-Object { [string]$_.operationId })
$requestedIds = @($OperationIds)

$missing = @($requestedIds | Where-Object { $allDeleteOpIds -notcontains $_ })
if ($missing.Count -gt 0) {
    throw "OperationIds contiene id(s) que no existen en el delete plan: $($missing -join ', ')."
}
$extra = @($allDeleteOpIds | Where-Object { $requestedIds -notcontains $_ })
if ($extra.Count -gt 0) {
    throw "OperationIds no incluye TODAS las operaciones del delete plan -- falta(n): $($extra -join ', '). Un delete plan se ejecuta completo o no se ejecuta; no se permite un subconjunto distinto al aprobado."
}

$operationsToRun = @($allDeleteOps | Where-Object { $requestedIds -contains [string]$_.operationId })
foreach ($op in $operationsToRun) {
    if ([bool]$op.isDestructive -ne $true) {
        throw "Operacion '$($op.operationId)' no tiene isDestructive=true -- esto nunca deberia haber pasado la validacion. Se rechaza toda la aplicacion."
    }
}

Assert-CloudflareDirectoryExists -Path (Get-CloudflareBackupsDir)
$appliedSummary = [System.Collections.Generic.List[string]]::new()

try {
    foreach ($op in $operationsToRun) {
        $started = Start-CloudflareJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allDeleteOpIds -OperationId $op.operationId
        if (-not $started) { continue }

        # Respaldo pre-delete obligatorio.
        $backupUri = if ($op.uri) { $op.uri } else { $null }
        $backup = if ($backupUri) { Invoke-CloudflareApiRequest -Method GET -Uri $backupUri } else { $null }
        if (-not $backup) {
            throw "No se pudo obtener un respaldo de solo lectura del recurso '$($op.resourceType)/$($op.resourceId)' antes de eliminarlo -- se detiene esta eliminacion SIN borrar nada."
        }
        $backupPath = Join-Path (Get-CloudflareBackupsDir) "$($plan.validationHash)-$($op.operationId).json"
        $backup | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $backupPath -Encoding utf8

        $deleteUri = if ($op.uri) { $op.uri } else { $null }
        $response = Invoke-CloudflareApiRequest -Method DELETE -Uri $deleteUri -Body $op.body
        $resultId = "$($op.resourceType)/$($op.resourceId) deleted"

        Complete-CloudflareJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allDeleteOpIds -OperationId $op.operationId -FinalState 'succeeded' -ResultId $resultId
        $appliedSummary.Add("OK: $resultId (respaldo: $backupPath)")
    }
}
catch {
    if ($op) {
        try {
            Complete-CloudflareJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allDeleteOpIds -OperationId $op.operationId -FinalState 'ambiguous' -ResultId "ERROR: $(ConvertTo-CloudflareSanitizedErrorMessage -Message $_.Exception.Message)"
        }
        catch { }
    }
    Write-Host "Eliminaciones aplicadas antes del error:" -ForegroundColor Yellow
    $appliedSummary | ForEach-Object { Write-Host "  $_" }
    throw
}

Write-Host "Delete plan aplicado. Eliminaciones completadas:" -ForegroundColor Green
$appliedSummary | ForEach-Object { Write-Host "  $_" }
[PSCustomObject]@{ applied = @($appliedSummary) } | ConvertTo-Json -Depth 5
