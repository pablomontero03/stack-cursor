<#
Valida de forma independiente un plan de BORRADO generado por
New-AdoClassicDeletePlan.ps1 (operationKind='delete'). No ejecuta ningun
cambio en Azure DevOps -- solo lee el plan y un inventario fresco.

A diferencia de Test-AdoClassicPlan.ps1 (donde "el recurso ya existe" es
un bloqueante de "posible duplicado"), aca es AL REVES: el recurso DEBE
existir de verdad, con el mismo id exacto que trae el plan, o se
bloquea -- no se puede borrar algo que no esta, ni algo cuyo id cambio
desde que se genero el plan (podria ser un recurso distinto que
coincidentemente tiene el mismo nombre).

Cuando el plan queda validated=true, se le agregan los mismos 2 campos
que Test-AdoClassicPlan.ps1 (validationEvidence, validationHash), con el
mismo contrato exacto -- Apply-AdoClassicPlan.ps1 no necesita saber cual
de los dos validadores produjo el plan, solo que sea internamente
consistente.

Uso:
  powershell -File .\Test-AdoClassicDeletePlan.ps1 -PlanPath '...\delete-....json' -InventoryPath '...\inventory-....json'
#>
param(
    [Parameter(Mandatory)] [string]$PlanPath,
    [Parameter(Mandatory)] [string]$InventoryPath,
    [ValidateRange(0.01, 24)] [double]$MaxInventoryAgeHours = 24
)

$ErrorActionPreference = 'Stop'

if ([double]::IsNaN($MaxInventoryAgeHours) -or [double]::IsInfinity($MaxInventoryAgeHours)) {
    throw "Test-AdoClassicDeletePlan: -MaxInventoryAgeHours no puede ser NaN ni infinito."
}

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Test-AdoClassicDeletePlan: no existe el archivo de plan '$PlanPath'."
}
$planRaw = Get-Content -LiteralPath $PlanPath -Raw
$plan = $planRaw | ConvertFrom-Json

if ([string]$plan.operationKind -ne 'delete') {
    throw "Test-AdoClassicDeletePlan: el plan no tiene operationKind='delete' (usar Test-AdoClassicPlan.ps1 para planes de creacion/actualizacion de pipeline)."
}

if (-not (Test-Path -LiteralPath $InventoryPath)) {
    throw "Test-AdoClassicDeletePlan: no existe el inventario '$InventoryPath'."
}
$inventoryRaw = Get-Content -LiteralPath $InventoryPath -Raw
$inventory = $inventoryRaw | ConvertFrom-Json

$blockers = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()
function Add-Blocker { param([string]$Msg) $blockers.Add($Msg) }
function Add-Warning { param([string]$Msg) $warnings.Add($Msg) }

if ([string]$plan.organization -ne 'Shared-Service-GM') {
    Add-Blocker "organization debe ser 'Shared-Service-GM', encontrado: '$($plan.organization)'."
}
if ([string]::IsNullOrWhiteSpace([string]$plan.project)) {
    Add-Blocker "project no puede estar vacio."
}
if ([string]$plan.resourceType -notin @('VariableGroup', 'BuildDefinition', 'ReleaseDefinition')) {
    Add-Blocker "resourceType debe ser VariableGroup, BuildDefinition o ReleaseDefinition, encontrado: '$($plan.resourceType)'."
}
if ([string]::IsNullOrWhiteSpace([string]$plan.resourceName)) {
    Add-Blocker "resourceName no puede estar vacio."
}
if ($plan.backupRequired -ne $true) {
    Add-Blocker "backupRequired debe ser true -- un plan de borrado sin respaldo obligatorio nunca es valido."
}

# ---- Frescura del inventario (mismo contrato que Test-AdoClassicPlan.ps1) ----
$inventoryComplete = $false
if ($inventory.paginationComplete -ne $true) {
    Add-Blocker "El inventario no tiene paginationComplete=true."
}
else {
    $generatedAt = $null
    try {
        $generatedAt = [DateTime]::Parse([string]$inventory.generatedAtUtc, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch { $generatedAt = $null }
    if (-not $generatedAt) {
        Add-Blocker "El inventario no tiene generatedAtUtc valido."
    }
    else {
        $ageHours = ((Get-Date).ToUniversalTime() - $generatedAt.ToUniversalTime()).TotalHours
        if ($ageHours -gt $MaxInventoryAgeHours) {
            Add-Blocker "El inventario tiene $([math]::Round($ageHours, 1))h de antiguedad, mas que el limite de $MaxInventoryAgeHours h. Volver a correr Export-AdoClassicInventory.ps1 antes de validar."
        }
        else {
            $inventoryComplete = $true
        }
    }
}

# ---- El recurso DEBE existir de verdad, con el mismo id (al reves de "posible duplicado") ----
$collectionMap = @{
    VariableGroup     = 'variableGroups'
    BuildDefinition   = 'buildDefinitions'
    ReleaseDefinition = 'releaseDefinitions'
}
$collectionName = $collectionMap[[string]$plan.resourceType]

if ($inventoryComplete -and $collectionName) {
    if (-not $inventory.PSObject.Properties[$collectionName] -or $null -eq $inventory.$collectionName) {
        Add-Blocker "El inventario no tiene la coleccion '$collectionName' para resourceType '$($plan.resourceType)'."
    }
    else {
        $matchesFound = @($inventory.$collectionName | Where-Object { $_.name -eq [string]$plan.resourceName })
        if ($matchesFound.Count -eq 0) {
            Add-Blocker "No existe ningun $($plan.resourceType) llamado '$($plan.resourceName)' en el inventario -- no se puede borrar un recurso que ya no existe (o nunca existio con ese nombre exacto)."
        }
        elseif ($matchesFound.Count -gt 1) {
            Add-Blocker "Se encontro mas de un $($plan.resourceType) llamado '$($plan.resourceName)' en el inventario -- ambiguo, resolver a mano antes de borrar."
        }
        else {
            $liveId = [int]$matchesFound[0].id
            if ($liveId -ne [int]$plan.resourceId) {
                Add-Blocker "El id en vivo de '$($plan.resourceName)' es $liveId, pero el plan trae resourceId=$($plan.resourceId) -- no coinciden. El recurso pudo haber sido borrado y recreado con otro id desde que se genero el plan; volver a generarlo."
            }
        }
    }
}
elseif (-not $inventoryComplete) {
    Add-Blocker "No se pudo verificar la existencia del recurso contra un inventario completo y fresco -- ver bloqueantes de inventario arriba."
}

# ---- approvedOperations: EXACTAMENTE 1 entrada, delete-*, spec-conforme ----
$approvedOps = @()
if ($null -ne $plan.approvedOperations) { $approvedOps = @($plan.approvedOperations) }
if ($approvedOps.Count -ne 1) {
    Add-Blocker "Un plan de borrado debe tener EXACTAMENTE 1 entrada en approvedOperations, encontradas: $($approvedOps.Count)."
}
else {
    $op = $approvedOps[0]
    $expectedOpType = switch ([string]$plan.resourceType) {
        'VariableGroup' { 'delete-variable-group' }
        'BuildDefinition' { 'delete-build-definition' }
        'ReleaseDefinition' { 'delete-release-definition' }
        default { $null }
    }
    if ([string]$op.operationType -ne $expectedOpType) {
        Add-Blocker "approvedOperations[0].operationType debe ser '$expectedOpType' para resourceType '$($plan.resourceType)', encontrado: '$($op.operationType)'."
    }
    else {
        try {
            $null = Assert-AdoOperationRequestMatchesSpec -OperationType ([string]$op.operationType) -Method ([string]$op.method) -Uri ([string]$op.uri) -Label ([string]$op.operationId)
        }
        catch {
            Add-Blocker "approvedOperations[0] no cumple el contrato de su operationType: $($_.Exception.Message)"
        }
    }

    if ([string]::IsNullOrWhiteSpace([string]$op.operationId)) {
        Add-Blocker "approvedOperations[0].operationId no puede estar vacio."
    }
    if ([string]$op.bodyHash -notmatch '^[0-9a-f]{64}$') {
        Add-Blocker "approvedOperations[0].bodyHash no es un SHA-256 valido (64 hex)."
    }

    # El id numerico al final de la uri aprobada debe coincidir con
    # plan.resourceId -- nunca confiar en que ya vengan iguales.
    if ([string]$op.uri -match '/(\d+)(\?|$)') {
        $uriId = [int]$Matches[1]
        if ($uriId -ne [int]$plan.resourceId) {
            Add-Blocker "El id en la uri aprobada ($uriId) no coincide con plan.resourceId ($($plan.resourceId))."
        }
    }
    else {
        Add-Blocker "No se pudo extraer un id numerico de approvedOperations[0].uri."
    }
}

# ---- Resultado (mismo contrato de salida que Test-AdoClassicPlan.ps1) ----
$nowUtc = (Get-Date).ToUniversalTime().ToString('o')
$plan.validated = ($blockers.Count -eq 0)
$plan | Add-Member -NotePropertyName 'lastValidatedAtUtc' -NotePropertyValue $nowUtc -Force
$plan | Add-Member -NotePropertyName 'validationBlockers' -NotePropertyValue @($blockers) -Force
$plan | Add-Member -NotePropertyName 'validationWarnings' -NotePropertyValue @($warnings) -Force

if ($inventoryComplete) {
    $plan | Add-Member -NotePropertyName 'validationEvidence' -NotePropertyValue ([PSCustomObject]@{
        inventoryGeneratedAtUtc = $inventory.generatedAtUtc
        inventoryHash           = (Get-AdoSha256OfText -Text $inventoryRaw)
        validatedAtUtc          = $nowUtc
        maxInventoryAgeHours    = $MaxInventoryAgeHours
    }) -Force
}
else {
    $plan | Add-Member -NotePropertyName 'validationEvidence' -NotePropertyValue $null -Force
}

if ($plan.validated) {
    $hash = Get-AdoPlanCanonicalHash -Plan $plan
    $plan | Add-Member -NotePropertyName 'validationHash' -NotePropertyValue $hash -Force
}
else {
    $plan | Add-Member -NotePropertyName 'validationHash' -NotePropertyValue $null -Force
}

$json = $plan | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($PlanPath, $json, (New-Object System.Text.UTF8Encoding($false)))

Write-Host "=== Resultado de validacion (BORRADO): $PlanPath ===" -ForegroundColor Cyan
if ($blockers.Count -eq 0) {
    Write-Host "Sin bloqueantes. plan.validated = true (validationHash calculado). Recurso a borrar: $($plan.resourceType) '$($plan.resourceName)' (id=$($plan.resourceId))." -ForegroundColor Green
}
else {
    Write-Host "Bloqueantes ($($blockers.Count)):" -ForegroundColor Red
    foreach ($b in $blockers) { Write-Host " - $b" -ForegroundColor Red }
}
if ($warnings.Count -gt 0) {
    Write-Host "Advertencias ($($warnings.Count)):" -ForegroundColor Yellow
    foreach ($w in $warnings) { Write-Host " - $w" -ForegroundColor Yellow }
}
