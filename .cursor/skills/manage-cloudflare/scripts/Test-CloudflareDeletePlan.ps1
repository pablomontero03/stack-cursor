<#
Valida (nunca aplica) un delete plan Cloudflare. Ademas de los bloqueantes
de forma/secretos/drift comunes, exige que TODAS las operaciones sean
isDestructive=true con phase='destructive', y que el inventario referenciado
sea reciente (-MaxInventoryAgeHours).
#>
param(
    [Parameter(Mandatory)] [string]$DeletePlanPath,
    [double]$MaxInventoryAgeHours = 24
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cloudflare-Common.ps1')

if (-not (Test-Path -LiteralPath $DeletePlanPath -PathType Leaf)) {
    throw "El delete plan '$DeletePlanPath' no existe."
}

$rawText = Get-Content -LiteralPath $DeletePlanPath -Raw
$plan = $rawText | ConvertFrom-Json

$blockers = [System.Collections.Generic.List[string]]::new()

$jsonFindings = Find-CloudflareSensitiveJsonProperties -Object $plan
foreach ($finding in $jsonFindings) {
    $blockers.Add("Posible secreto en '$($finding.path)' (propiedad '$($finding.property)').")
}
$rawFindings = Find-CloudflareSensitiveRawText -Text $rawText
foreach ($pattern in $rawFindings) {
    $blockers.Add("El texto crudo del delete plan coincide con un patron de secreto conocido ($pattern).")
}

$requiredFields = Get-CloudflareRequiredOperationFields
$operations = @($plan.pendingDeleteOperations)

if ($operations.Count -lt 1) {
    $blockers.Add('El delete plan no contiene ninguna operacion.')
}
if (@($plan.approvedOperations).Count -gt 0) {
    $blockers.Add('Un delete plan nunca debe tener approvedOperations no vacio.')
}

foreach ($op in $operations) {
    foreach ($field in $requiredFields) {
        if (-not ($op.PSObject.Properties.Name -contains $field)) {
            $blockers.Add("Operacion '$($op.operationId)' no tiene el campo obligatorio '$field'.")
        }
    }
    if ([bool]$op.isDestructive -ne $true) {
        $blockers.Add("Operacion '$($op.operationId)': isDestructive debe ser true.")
    }
    if ([string]$op.phase -ne 'destructive') {
        $blockers.Add("Operacion '$($op.operationId)': phase debe ser 'destructive'.")
    }
    if ([string]::IsNullOrWhiteSpace([string]$op.resourceId)) {
        $blockers.Add("Operacion '$($op.operationId)': falta resourceId concreto.")
    }
    if ([string]$op.accountId -ne [string]$plan.accountId) {
        $blockers.Add("Operacion '$($op.operationId)': accountId no coincide con el del plan.")
    }
}

foreach ($entry in @($plan.inventoryHashes)) {
    if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf)) {
        $blockers.Add("El inventario '$($entry.path)' referenciado por el delete plan ya no existe (drift).")
        continue
    }
    $currentHash = Get-CloudflareFileSha256 -Path $entry.path
    if ($currentHash -ne $entry.hash) {
        $blockers.Add("El inventario '$($entry.path)' cambio desde que se genero el delete plan (drift de hash).")
    }
    $inventoryItem = Get-Item -LiteralPath $entry.path
    $ageHours = ((Get-Date).ToUniversalTime() - $inventoryItem.LastWriteTimeUtc).TotalHours
    if ($ageHours -gt $MaxInventoryAgeHours) {
        $blockers.Add("El inventario '$($entry.path)' tiene $([math]::Round($ageHours,1))h de antiguedad, supera el maximo permitido de $MaxInventoryAgeHours h para un delete plan.")
    }
}

$validationEvidence = [ordered]@{
    validatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    blockers       = @($blockers)
    deleteCount    = $operations.Count
}

if ($blockers.Count -eq 0) {
    $plan.validated = $true
    $plan.validationHash = Get-CloudflarePlanCanonicalHash -Plan $plan
}
else {
    $plan.validated = $false
    $plan.validationHash = $null
}
$plan.validationEvidence = $validationEvidence

$plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $DeletePlanPath -Encoding utf8

[PSCustomObject]@{
    validated = [bool]$plan.validated
    blockers  = @($blockers)
} | ConvertTo-Json -Depth 5
