<#
UNICO script que ejecuta escrituras NO destructivas reales en Cloudflare.
Requiere un plan validated=true cuyo validationHash coincida con el
contenido actual del archivo. Nunca toca pendingDeleteOperations -- eso es
Apply-CloudflareDeletePlan.ps1, con su propia aprobacion separada.
#>
param(
    [Parameter(Mandatory)] [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cloudflare-Common.ps1')

if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
    throw "El plan '$PlanPath' no existe."
}
$plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json

# --- Preflight comun ---
if ([bool]$plan.validated -ne $true) {
    throw "El plan no esta validado (validated != true). Corre Test-CloudflareChangePlan.ps1 primero."
}
if ([string]::IsNullOrWhiteSpace([string]$plan.validationHash)) {
    throw "El plan no tiene validationHash."
}
$recomputedHash = Get-CloudflarePlanCanonicalHash -Plan $plan
if ($recomputedHash -ne [string]$plan.validationHash) {
    throw "El plan cambio despues de validarse (validationHash no coincide). Se rechaza la aplicacion -- volve a validar."
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

if (@($plan.pendingDeleteOperations).Count -gt 0) {
    Write-Warning "Este plan tiene $(@($plan.pendingDeleteOperations).Count) operacion(es) destructiva(s) declaradas -- este script NUNCA las ejecuta. Usa Apply-CloudflareDeletePlan.ps1 con su propia aprobacion separada."
}

$operations = @($plan.approvedOperations)
foreach ($op in $operations) {
    if ([bool]$op.isDestructive -eq $true) {
        throw "Operacion '$($op.operationId)' esta marcada isDestructive=true dentro de approvedOperations -- esto nunca deberia haber pasado la validacion. Se rechaza toda la aplicacion."
    }
}

$allOperationIds = @($operations | ForEach-Object { [string]$_.operationId })
$appliedSummary = [System.Collections.Generic.List[string]]::new()

try {
    foreach ($op in $operations) {
        $started = Start-CloudflareJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allOperationIds -OperationId $op.operationId
        if (-not $started) { continue }

        $resultId = $null
        switch ([string]$op.executor) {
            'cloudflareRest' {
                $response = Invoke-CloudflareApiRequest -Method $op.method -Uri $op.uri -Body $op.body
                $resultId = "$($op.resourceType)/$($op.resourceId) ($($op.action)) via cloudflareRest"
            }
            'cloudflareGraphQL' {
                $queryText = [string]$op.body.query
                if ($queryText -match '(?i)\bmutation\b') {
                    throw "Operacion '$($op.operationId)': el body GraphQL contiene 'mutation' -- rechazado en tiempo de ejecucion (defensa en profundidad, ya deberia haber sido bloqueado en validacion)."
                }
                $response = Invoke-CloudflareApiRequest -Method 'POST' -Uri $op.uri -Body $op.body
                $resultId = "$($op.resourceType)/$($op.resourceId) ($($op.action)) via cloudflareGraphQL"
            }
            'terraform' {
                & terraform @($op.argv)
                if ($LASTEXITCODE -ne 0) { throw "terraform devolvio codigo de salida $LASTEXITCODE para la operacion '$($op.operationId)'." }
                $resultId = "$($op.resourceType)/$($op.resourceId) ($($op.action)) via terraform"
            }
            'wrangler' {
                & wrangler @($op.argv)
                if ($LASTEXITCODE -ne 0) { throw "wrangler devolvio codigo de salida $LASTEXITCODE para la operacion '$($op.operationId)'." }
                $resultId = "$($op.resourceType)/$($op.resourceId) ($($op.action)) via wrangler"
            }
            default {
                throw "Executor desconocido '$($op.executor)' para la operacion '$($op.operationId)'."
            }
        }

        Complete-CloudflareJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allOperationIds -OperationId $op.operationId -FinalState 'succeeded' -ResultId $resultId
        $appliedSummary.Add("OK: $resultId")
    }
}
catch {
    if ($op) {
        try {
            Complete-CloudflareJournaledOperation -PlanValidationHash $plan.validationHash -AllOperationIds $allOperationIds -OperationId $op.operationId -FinalState 'ambiguous' -ResultId "ERROR: $(ConvertTo-CloudflareSanitizedErrorMessage -Message $_.Exception.Message)"
        }
        catch { }
    }
    Write-Host "Operaciones aplicadas antes del error:" -ForegroundColor Yellow
    $appliedSummary | ForEach-Object { Write-Host "  $_" }
    throw
}

Write-Host "Plan aplicado. Operaciones completadas:" -ForegroundColor Green
$appliedSummary | ForEach-Object { Write-Host "  $_" }
[PSCustomObject]@{ applied = @($appliedSummary) } | ConvertTo-Json -Depth 5
