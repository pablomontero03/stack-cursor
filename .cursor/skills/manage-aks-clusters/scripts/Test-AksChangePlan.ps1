<#
Valida de forma independiente un plan generado por New-AksChangePlan.ps1:
sin secretos/kubeconfigs embebidos, impacto/rollback/verificacion
completos, respaldo declarado para toda eliminacion, y evidencia de
inventario fresco. Si pasa, escribe validated=true + validationHash +
validationEvidence de vuelta al MISMO archivo de plan (nunca crea un
plan nuevo). No modifica el cluster.

Uso:
  powershell -File .\Test-AksChangePlan.ps1 -PlanPath <plan.json> -InventoryPath <inventory.json> [-MaxInventoryAgeHours 24]
#>

param(
    [Parameter(Mandatory)] [string]$PlanPath,
    [Parameter(Mandatory)] [string]$InventoryPath,
    [int]$MaxInventoryAgeHours = 24,
    [switch]$DryRunPerformed,
    [switch]$DiffPerformed,
    [switch]$AuthCanIChecked
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Aks-Common.ps1')
. (Join-Path (Get-AksProjectRoot) '.kiro\hooks\aks\aks-secret-scan-lib.ps1')

$blockers = [System.Collections.Generic.List[string]]::new()

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Test-AksChangePlan rechazado: no existe el archivo de plan '$PlanPath'."
}
if (-not (Test-Path -LiteralPath $InventoryPath)) {
    throw "Test-AksChangePlan rechazado: no existe el archivo de inventario '$InventoryPath'."
}

$planRaw = Get-Content -LiteralPath $PlanPath -Raw
$plan = $null
try { $plan = $planRaw | ConvertFrom-Json }
catch { throw "Test-AksChangePlan rechazado: JSON invalido en '$PlanPath'. $($_.Exception.Message)" }

# --- Secretos / kubeconfigs embebidos ---
$sensitiveProps = Find-AksSensitiveJsonProperties -Node $plan
if ($sensitiveProps.Count -gt 0) {
    $blockers.Add("El plan contiene valores no permitidos en propiedades sensibles: $($sensitiveProps -join ', ').")
}
$rawHits = Find-AksRawTextSecretPatterns -RawText $planRaw
if ($rawHits.Count -gt 0) {
    $blockers.Add("El plan parece contener un secreto o kubeconfig embebido: $($rawHits -join ', ').")
}

# --- Estructura minima ---
if (-not $plan.cluster -or -not $plan.cluster.context -or -not $plan.cluster.clusterName) {
    $blockers.Add("El plan no identifica cluster.context / cluster.clusterName completos.")
}
if ([string]::IsNullOrWhiteSpace([string]$plan.namespace)) {
    $blockers.Add("El plan no identifica un namespace.")
}
if (-not $plan.operations -or @($plan.operations).Count -eq 0) {
    $blockers.Add("El plan no tiene ninguna operacion.")
}
if (-not $plan.impact -or [string]::IsNullOrWhiteSpace([string]$plan.impact.whatChanges) -or [string]::IsNullOrWhiteSpace([string]$plan.impact.whatDoesNotChange) `
        -or [string]::IsNullOrWhiteSpace([string]$plan.impact.verificationStrategy) -or [string]::IsNullOrWhiteSpace([string]$plan.impact.rollbackStrategy)) {
    $blockers.Add("El plan no tiene 'impact' completo (whatChanges/whatDoesNotChange/verificationStrategy/rollbackStrategy).")
}

# --- Cada operacion de eliminacion trae respaldo obligatorio ---
foreach ($op in @($plan.operations)) {
    if ([string]$op.kind -eq 'delete') {
        $requiresBackup = ($op.requiresBackup -eq $true) -or ([string]$op.requiresBackup -eq 'True')
        if (-not $requiresBackup) {
            $blockers.Add("La operacion '$($op.operationId)' es una eliminacion sin requiresBackup=true.")
        }
    }
    if ([string]::IsNullOrWhiteSpace([string]$op.operationId) -or [string]::IsNullOrWhiteSpace([string]$op.resourceKind) -or [string]::IsNullOrWhiteSpace([string]$op.resourceName)) {
        $blockers.Add("Una operacion del plan tiene forma invalida (falta operationId/resourceKind/resourceName).")
    }
}

# --- approvedOperations debe coincidir EXACTO con operations (mismo lote atomico) ---
$opIds = @(@($plan.operations) | ForEach-Object { [string]$_.operationId } | Sort-Object)
$approvedIds = @(@($plan.approvedOperations) | ForEach-Object { [string]$_.operationId } | Sort-Object)
if (($opIds -join ',') -ne ($approvedIds -join ',')) {
    $blockers.Add("plan.approvedOperations no coincide exactamente con plan.operations -- el lote aprobado debe ser el lote completo declarado, sin agregar ni quitar operaciones.")
}

# --- Evidencia de inventario ---
$inventoryRaw = Get-Content -LiteralPath $InventoryPath -Raw
$inventoryParsed = $null
try { $inventoryParsed = $inventoryRaw | ConvertFrom-Json } catch { $blockers.Add("El inventario referenciado ('$InventoryPath') no es JSON valido.") }

$inventoryGeneratedAtUtc = $null
if ($inventoryParsed -and $inventoryParsed.generatedAtUtc) {
    $inventoryGeneratedAtUtc = [datetime]$inventoryParsed.generatedAtUtc
    $ageHours = ((Get-Date).ToUniversalTime() - $inventoryGeneratedAtUtc.ToUniversalTime()).TotalHours
    if ($ageHours -gt $MaxInventoryAgeHours) {
        $blockers.Add("El inventario tiene $([math]::Round($ageHours,1))h de antiguedad, mas que el maximo permitido ($MaxInventoryAgeHours h). Regenerar con Get-AksInventory.ps1.")
    }
    if ($inventoryParsed.context -and $inventoryParsed.context -ne [string]$plan.cluster.context) {
        $blockers.Add("El inventario fue generado para el contexto '$($inventoryParsed.context)', pero el plan es para '$($plan.cluster.context)'.")
    }
    # El mismo nombre de contexto puede existir en mas de un kubeconfig
    # real de este proyecto (confirmado: 'gmon-prod-aks-eastus2-0001/2/3'
    # aparecen en 2 archivos Lens distintos) -- el nombre de contexto solo
    # no alcanza para identificar el cluster de forma unica, tambien se
    # compara el kubeconfig de origen cuando ambos lo declaran.
    $inventoryKubeconfig = [string]$inventoryParsed.kubeconfigPath
    $planKubeconfig = [string]$plan.cluster.kubeconfigPath
    if ($inventoryKubeconfig -and $planKubeconfig -and $inventoryKubeconfig -ne $planKubeconfig) {
        $blockers.Add("El inventario se genero con el kubeconfig '$inventoryKubeconfig', pero el plan referencia '$planKubeconfig' -- aunque el contexto se llame igual, pueden ser clusteres distintos.")
    }
}
else {
    $blockers.Add("El inventario referenciado no tiene 'generatedAtUtc' -- no se puede evaluar su antiguedad.")
}

$inventoryHashBytes = [System.Security.Cryptography.SHA256]::Create().ComputeHash([Text.Encoding]::UTF8.GetBytes($inventoryRaw))
$inventoryHash = -join ($inventoryHashBytes | ForEach-Object { $_.ToString('x2') })

# --- Reporte ---
if ($blockers.Count -gt 0) {
    Write-Host "BLOQUEANTES ($($blockers.Count)):" -ForegroundColor Red
    foreach ($b in $blockers) { Write-Host "- $b" -ForegroundColor Red }
    [PSCustomObject]@{ validated = $false; blockers = @($blockers) }
    exit 1
}

$plan.validation.dryRunPerformed = [bool]$DryRunPerformed
$plan.validation.diffPerformed = [bool]$DiffPerformed
$plan.validation.authCanIChecked = [bool]$AuthCanIChecked

$validatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
$plan.validationEvidence = [PSCustomObject]@{
    inventoryPath            = (Resolve-Path -LiteralPath $InventoryPath).Path
    inventoryGeneratedAtUtc  = if ($inventoryGeneratedAtUtc) { $inventoryGeneratedAtUtc.ToString('o') } else { $null }
    inventoryHash            = $inventoryHash
    validatedAtUtc           = $validatedAtUtc
    maxInventoryAgeHours     = $MaxInventoryAgeHours
}
$plan.validated = $true
$plan.validationHash = Get-AksPlanCanonicalHash -Plan $plan

$plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $PlanPath -Encoding utf8

Write-Host "Plan validado OK. validationHash=$($plan.validationHash)" -ForegroundColor Green
if (-not $DryRunPerformed -and -not $DiffPerformed) {
    Write-Host "ADVERTENCIA: el plan quedo validado sin -DryRunPerformed ni -DiffPerformed. Recomendado (no bloqueante) correr kubectl diff/--dry-run=server antes de pedir aprobacion." -ForegroundColor Yellow
}

[PSCustomObject]@{ validated = $true; validationHash = $plan.validationHash; blockers = @() }
