<#
Valida (nunca aplica) un plan de cambio Cloudflare. Bloqueantes: secretos
embebidos, forma incompleta, eliminacion logica colada como no-destructiva,
drift de inventario, plan vacio, y mutaciones GraphQL fuera del flujo de
eliminacion. Si pasa sin bloqueantes, marca validated=true y calcula
validationHash -- cualquier edicion posterior del archivo invalida ese hash.
#>
param(
    [Parameter(Mandatory)] [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cloudflare-Common.ps1')

if (-not (Test-Path -LiteralPath $PlanPath -PathType Leaf)) {
    throw "El plan '$PlanPath' no existe."
}

$rawText = Get-Content -LiteralPath $PlanPath -Raw
$plan = $rawText | ConvertFrom-Json

$blockers = [System.Collections.Generic.List[string]]::new()

# 1. Secretos.
$jsonFindings = Find-CloudflareSensitiveJsonProperties -Object $plan
foreach ($finding in $jsonFindings) {
    $blockers.Add("Posible secreto en '$($finding.path)' (propiedad '$($finding.property)') -- usa un placeholder `${VAR}` o `***REDACTED***`.")
}
$rawFindings = Find-CloudflareSensitiveRawText -Text $rawText
foreach ($pattern in $rawFindings) {
    $blockers.Add("El texto crudo del plan coincide con un patron de secreto conocido ($pattern).")
}

# 2. Forma.
$requiredFields = Get-CloudflareRequiredOperationFields
$allOperations = @(@($plan.approvedOperations) + @($plan.pendingDeleteOperations))
foreach ($op in $allOperations) {
    foreach ($field in $requiredFields) {
        if (-not ($op.PSObject.Properties.Name -contains $field)) {
            $blockers.Add("Operacion '$($op.operationId)' no tiene el campo obligatorio '$field'.")
        }
    }
    if ($op.executor -in @('terraform', 'wrangler') -and -not ($op.argv -is [array])) {
        $blockers.Add("Operacion '$($op.operationId)': argv debe ser un array tokenizado cuando executor es '$($op.executor)'.")
    }
    if ([string]$op.accountId -ne [string]$plan.accountId) {
        $blockers.Add("Operacion '$($op.operationId)': accountId ('$($op.accountId)') no coincide con el del plan ('$($plan.accountId)').")
    }
    if ($op.zoneId -and (@($plan.zoneIds) -notcontains [string]$op.zoneId)) {
        $blockers.Add("Operacion '$($op.operationId)': zoneId ('$($op.zoneId)') no esta en zoneIds del plan.")
    }
}

foreach ($op in @($plan.approvedOperations)) {
    if ([bool]$op.isDestructive -ne $false) {
        $blockers.Add("Operacion '$($op.operationId)' vive en approvedOperations pero isDestructive no es false.")
    }
}
foreach ($op in @($plan.pendingDeleteOperations)) {
    if ([bool]$op.isDestructive -ne $true) {
        $blockers.Add("Operacion '$($op.operationId)' vive en pendingDeleteOperations pero isDestructive no es true.")
    }
}

# 3. Eliminacion logica colada como no-destructiva.
$logicalDeletionResourceTypes = @('cache_purge', 'ruleset_replace', 'custom_domain_unlink', 'token_revoke')
foreach ($op in @($plan.approvedOperations)) {
    if ($logicalDeletionResourceTypes -contains [string]$op.resourceType) {
        $blockers.Add("Operacion '$($op.operationId)' (resourceType='$($op.resourceType)') es una eliminacion logica conocida -- debe moverse a pendingDeleteOperations con isDestructive=true. Ver references/resource-classification.md para el detalle completo de eliminacion logica por efecto.")
    }
}

# 4. Drift de inventario.
foreach ($entry in @($plan.inventoryHashes)) {
    if (-not (Test-Path -LiteralPath $entry.path -PathType Leaf)) {
        $blockers.Add("El inventario '$($entry.path)' referenciado por el plan ya no existe (drift).")
        continue
    }
    $currentHash = Get-CloudflareFileSha256 -Path $entry.path
    if ($currentHash -ne $entry.hash) {
        $blockers.Add("El inventario '$($entry.path)' cambio desde que se genero el plan (drift de hash).")
    }
}

# 5. Plan vacio.
if ($allOperations.Count -eq 0) {
    $blockers.Add('El plan no contiene ninguna operacion (ni approvedOperations ni pendingDeleteOperations).')
}

# 6. GraphQL: nunca una mutation, en ningun array.
foreach ($op in $allOperations) {
    if ([string]$op.executor -eq 'cloudflareGraphQL') {
        $queryText = [string]$op.body.query
        if ($queryText -match '(?i)\bmutation\b') {
            $blockers.Add("Operacion '$($op.operationId)': el body GraphQL contiene 'mutation' -- este dominio nunca ejecuta mutaciones GraphQL via plan normal.")
        }
    }
}

$validationEvidence = [ordered]@{
    validatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    blockers       = @($blockers)
    operationCount = @($plan.approvedOperations).Count
    deleteCount    = @($plan.pendingDeleteOperations).Count
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

$plan | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $PlanPath -Encoding utf8

[PSCustomObject]@{
    validated = [bool]$plan.validated
    blockers  = @($blockers)
} | ConvertTo-Json -Depth 5
