<#
Valida un plan generado por New-AzureChangePlan.ps1 y, si pasa todos los
bloqueantes, lo marca validated=true + validationHash (SHA-256 canonico).
Bloqueantes (ver .cursor/rules/azure.mdc):

  - Secretos: escaneo por NOMBRE de propiedad Y por regex sobre el texto
    crudo del archivo (Find-AzureSensitiveJsonProperties /
    Find-AzureSensitiveRawText). Cualquier hallazgo bloquea.
  - Cada operacion tiene los 23 campos obligatorios del esquema.
  - `argv` es un array (nunca un string de shell crudo con `;`/`|`/`&&`).
  - Los inventarios referenciados existen y su hash coincide con el actual
    en disco (deteccion de drift del inventario).
  - Ningun Resource Group completo comparte lote con otra eliminacion.
  - tenantId/subscriptionId de cada operacion coincide con el del plan.

No ejecuta nada contra Azure real -- toda esta validacion es local.

Uso:
  & '.\Test-AzureChangePlan.ps1' -PlanPath plan.json
#>
param([Parameter(Mandatory)] [string]$PlanPath)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Azure-Common.ps1')

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Test-AzureChangePlan rechazado: no existe el plan '$PlanPath'."
}

$rawText = Get-Content -LiteralPath $PlanPath -Raw
$plan = $null
try {
    $plan = $rawText | ConvertFrom-Json
}
catch {
    throw "Test-AzureChangePlan rechazado: el plan '$PlanPath' no es JSON valido."
}

$blockers = [System.Collections.Generic.List[string]]::new()

# --- Secretos ---
$sensitiveProps = @(Find-AzureSensitiveJsonProperties -Object $plan)
foreach ($f in $sensitiveProps) {
    $blockers.Add("Secreto literal detectado en la propiedad '$($f.property)' (ruta $($f.path)). Usar un placeholder `${AZURE_SECRET_NOMBRE} en su lugar.")
}
$rawFindings = @(Find-AzureSensitiveRawText -Text $rawText)
foreach ($p in $rawFindings) {
    $blockers.Add("El texto crudo del plan matchea un patron de secreto sospechoso ($p). Revisar y reemplazar por placeholder.")
}

# --- Forma de cada operacion ---
$requiredOpFields = @(
    'operationId', 'phase', 'action', 'tenantId', 'subscriptionId', 'resourceGroup',
    'resourceId', 'resourceType', 'apiVersion', 'executor', 'argv', 'bodyHash',
    'preconditionHash', 'currentState', 'desiredState', 'dependencies', 'destructive',
    'reversible', 'backupStrategy', 'rollbackStrategy', 'verification', 'retryPolicy',
    'timeoutSeconds', 'expectedFinalState'
)

$allOps = @(@($plan.approvedOperations) + @($plan.pendingDeleteOperations))
if ($allOps.Count -eq 0) {
    $blockers.Add('El plan no tiene ninguna operacion en approvedOperations ni pendingDeleteOperations.')
}

foreach ($op in $allOps) {
    $opId = [string]$op.operationId
    foreach ($f in $requiredOpFields) {
        if (-not ($op.PSObject.Properties.Name -contains $f)) {
            $blockers.Add("Operacion '$opId': falta el campo obligatorio '$f'.")
        }
    }
    if ($op.argv -isnot [System.Array] -and $null -ne $op.argv) {
        $blockers.Add("Operacion '$opId': 'argv' debe ser un array tokenizado, no un string de shell crudo.")
    }
    if ([string]$op.tenantId -ne [string]$plan.tenantId) {
        $blockers.Add("Operacion '$opId': tenantId ('$($op.tenantId)') no coincide con el tenantId del plan ('$($plan.tenantId)').")
    }
    if ([string]$op.subscriptionId -ne [string]$plan.subscriptionId) {
        $blockers.Add("Operacion '$opId': subscriptionId ('$($op.subscriptionId)') no coincide con el subscriptionId del plan ('$($plan.subscriptionId)').")
    }
}

# --- Resource Group completo aislado ---
$rgDeletes = @(@($plan.pendingDeleteOperations) | Where-Object { [string]$_.resourceType -eq 'Microsoft.Resources/resourceGroups' -and [string]$_.action -eq 'delete' })
if ($rgDeletes.Count -gt 0 -and @($plan.pendingDeleteOperations).Count -gt $rgDeletes.Count) {
    $blockers.Add('Eliminar un Resource Group completo debe ser una operacion destructiva aislada -- no puede compartir lote con otras eliminaciones.')
}
if ($rgDeletes.Count -gt 1) {
    $blockers.Add('Mas de un Resource Group en el mismo lote destructivo -- generar un plan separado por cada uno.')
}

# --- Drift de inventario ---
foreach ($inv in @($plan.inventoryHashes)) {
    $invPath = [string]$inv.path
    if (-not (Test-Path -LiteralPath $invPath)) {
        $blockers.Add("El inventario '$invPath' referenciado por el plan ya no existe en disco.")
        continue
    }
    $currentHash = Get-AzureFileSha256 -Path $invPath
    if ($currentHash -ne [string]$inv.hash) {
        $blockers.Add("Drift detectado: el inventario '$invPath' cambio desde que se genero el plan (hash no coincide). Volver a capturar inventario y regenerar el plan.")
    }
}

$evidence = [ordered]@{
    validatedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    blockers        = @($blockers)
    operationCount  = $allOps.Count
    deleteCount     = @($plan.pendingDeleteOperations).Count
}

if ($blockers.Count -gt 0) {
    $plan.validated = $false
    $plan.validationHash = $null
    $plan.validationEvidence = $evidence
    ($plan | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $PlanPath -Encoding utf8
    Write-Host "Test-AzureChangePlan: BLOQUEADO ($($blockers.Count) hallazgo(s))" -ForegroundColor Red
    foreach ($b in $blockers) { Write-Host " - $b" -ForegroundColor Red }
    throw "Test-AzureChangePlan rechazado: el plan tiene $($blockers.Count) bloqueante(s). Ver detalle arriba."
}

$plan.validated = $true
$plan.validationEvidence = $evidence
$hash = Get-AzurePlanCanonicalHash -Plan $plan
$plan.validationHash = $hash

($plan | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $PlanPath -Encoding utf8

[PSCustomObject]@{
    path           = $PlanPath
    validated      = $true
    validationHash = $hash
    operationCount = $allOps.Count
}
