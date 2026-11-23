<#
Valida un plan de replicacion de Branch Policies generado por
New-AdoPolicyPlan.ps1: recalcula bodyHash y valida cada operacion contra
Assert-AdoPermissionsOperationRequestMatchesSpec, rechaza cualquier
operationType destructivo, escanea el plan por secretos (defensa en
profundidad -- ninguna policy configuration de Azure DevOps contiene un
secreto real, pero se aplica el mismo criterio que el resto del dominio),
verifica que los 2 inventarios de origen no superen la antiguedad maxima,
y si todo pasa fija validated=true + validationHash.

NUNCA escribe en Azure DevOps.

Uso:
  & '.\Test-AdoPolicyPlan.ps1' -PlanPath '...\plan.json'
#>

param(
    [Parameter(Mandatory)] [string]$PlanPath
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Invoke-AdoPermissionsRest.ps1')

if (-not (Test-Path -LiteralPath $PlanPath)) { throw "No existe el plan: $PlanPath" }

$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json

$blockers = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

if ($plan.kind -ne 'ado-policy-configuration-plan') {
    $blockers.Add("El plan no tiene kind='ado-policy-configuration-plan' (encontrado: '$($plan.kind)').")
}

$approvedOps = @()
if ($null -ne $plan.approvedOperations) { $approvedOps = @($plan.approvedOperations) }

if ($approvedOps.Count -eq 0) {
    $blockers.Add('El plan no tiene ninguna approvedOperations -- nada que aplicar.')
}

# Nunca destructivo: solo 'create-policy-configuration' (POST) es valido en
# este plan.
foreach ($op in $approvedOps) {
    if ([string]$op.method -ne 'POST' -or [string]$op.operationType -ne 'create-policy-configuration') {
        $blockers.Add("La operacion '$($op.operationId)' tiene method/operationType inesperado ('$($op.method)'/'$($op.operationType)') -- este plan solo admite create-policy-configuration/POST.")
        continue
    }

    try {
        $null = Assert-AdoPermissionsOperationRequestMatchesSpec -OperationType 'create-policy-configuration' -Method 'POST' -Uri ([string]$op.uri) -Label $op.operationId
    }
    catch {
        $blockers.Add("Operacion '$($op.operationId)': $($_.Exception.Message)")
    }

    $recomputedHash = Get-AdoPermissionsBodyCanonicalHash -Body $op.body
    if ($recomputedHash -ne $op.bodyHash) {
        $blockers.Add("Operacion '$($op.operationId)': bodyHash no coincide con el body actual del plan (contenido modificado despues de generarlo).")
    }

    if (-not $op.body.type -or [string]::IsNullOrWhiteSpace([string]$op.body.type.id)) {
        $blockers.Add("Operacion '$($op.operationId)': falta body.type.id.")
    }

    $scope = @($op.body.settings.scope)
    if ($scope.Count -ne 1) {
        $blockers.Add("Operacion '$($op.operationId)': body.settings.scope debe tener exactamente 1 elemento (encontrado: $($scope.Count)).")
    }
    elseif ($scope[0].repositoryId -ne $plan.targetRepositoryId) {
        $blockers.Add("Operacion '$($op.operationId)': body.settings.scope[0].repositoryId ('$($scope[0].repositoryId)') no coincide con plan.targetRepositoryId ('$($plan.targetRepositoryId)').")
    }
    elseif ($scope[0].matchKind -ne 'Exact') {
        $blockers.Add("Operacion '$($op.operationId)': body.settings.scope[0].matchKind debe ser 'Exact' (encontrado: '$($scope[0].matchKind)').")
    }

    # Defensa en profundidad: si esta operacion es de tipo Build, su
    # buildDefinitionId DEBE coincidir con plan.buildDefinitionIdOverride
    # -- nunca un valor copiado sin querer del repo origen (ver
    # New-AdoPolicyPlan.ps1, que ya rechaza generar esto sin el override,
    # pero un plan podria haber sido editado a mano despues).
    if ([string]$op.body.type.id -eq '0609b952-1397-4640-95ec-e00a01b2c241') {
        if (-not $plan.buildDefinitionIdOverride) {
            $blockers.Add("Operacion '$($op.operationId)' es de tipo Build pero el plan no tiene buildDefinitionIdOverride -- nunca se aplica un buildDefinitionId sin confirmar que corresponde al repo destino.")
        }
        elseif ([int]$op.body.settings.buildDefinitionId -ne [int]$plan.buildDefinitionIdOverride) {
            $blockers.Add("Operacion '$($op.operationId)': body.settings.buildDefinitionId ($($op.body.settings.buildDefinitionId)) no coincide con plan.buildDefinitionIdOverride ($($plan.buildDefinitionIdOverride)).")
        }
    }
}

# Sin duplicados de operationId.
$opIds = @($approvedOps | ForEach-Object { [string]$_.operationId })
$dupIds = @($opIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($dupIds.Count -gt 0) {
    $blockers.Add("operationId duplicado en el plan: $($dupIds -join ', ').")
}

# Escaneo de secretos (defensa en profundidad, mismo criterio que
# Test-AdoPermissionsPlan.ps1): ninguna propiedad sensible con valor
# literal no-placeholder.
$sensitiveNames = @('password', 'passwd', 'pwd', 'pat', 'token', 'accesstoken', 'authorization', 'connectionstring', 'clientsecret', 'secret', 'apikey', 'privatekey')
function Find-AdoPolicySensitiveProperties {
    param($Node, [string]$Path = '$')

    $found = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Node) { return $found }

    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Node.PSObject.Properties) {
            $childPath = "$Path.$($prop.Name)"
            if ($sensitiveNames -contains $prop.Name.ToLowerInvariant()) {
                $val = [string]$prop.Value
                if (-not [string]::IsNullOrWhiteSpace($val) -and $val -ne '***REDACTED***' -and $val -notmatch '^\$\{[A-Za-z0-9_]+\}$') {
                    $found.Add($childPath)
                }
            }
            foreach ($f in (Find-AdoPolicySensitiveProperties -Node $prop.Value -Path $childPath)) { $found.Add($f) }
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $i = 0
        foreach ($item in $Node) {
            foreach ($f in (Find-AdoPolicySensitiveProperties -Node $item -Path "$Path[$i]")) { $found.Add($f) }
            $i++
        }
    }
    return $found
}

$sensitiveHits = Find-AdoPolicySensitiveProperties -Node $plan
if ($sensitiveHits.Count -gt 0) {
    $blockers.Add("El plan contiene valores en propiedades sensibles (nombre de propiedad reservado) en: $($sensitiveHits -join ', ').")
}

# Antiguedad de los inventarios de origen.
$maxAgeHours = $script:AdoPermissionsAbsoluteMaxInventoryAgeHours
foreach ($pair in @(
        @{ Label = 'source'; Value = $plan.sourceInventoryExportedAtUtc },
        @{ Label = 'target'; Value = $plan.targetInventoryExportedAtUtc }
    )) {
    if ([string]::IsNullOrWhiteSpace($pair.Value)) {
        $blockers.Add("Falta la marca de tiempo de exportacion del inventario '$($pair.Label)'.")
        continue
    }
    try {
        $ts = [DateTime]::Parse($pair.Value, $null, [System.Globalization.DateTimeStyles]::RoundtripKind)
    }
    catch {
        $blockers.Add("La marca de tiempo del inventario '$($pair.Label)' no es una fecha valida: '$($pair.Value)'.")
        continue
    }
    $ageHours = ((Get-Date).ToUniversalTime() - $ts.ToUniversalTime()).TotalHours
    if ($ageHours -gt $maxAgeHours) {
        $blockers.Add("El inventario '$($pair.Label)' tiene $([Math]::Round($ageHours, 1))h de antiguedad, supera el maximo de $maxAgeHours h. Volver a exportar con Export-AdoPolicyInventory.ps1 y regenerar el plan.")
    }
}

$validated = ($blockers.Count -eq 0)

$updatedPlan = [ordered]@{}
foreach ($prop in $plan.PSObject.Properties) { $updatedPlan[$prop.Name] = $prop.Value }
$updatedPlan['validated'] = $validated
$updatedPlan['validationBlockers'] = @($blockers)
$updatedPlan['validationWarnings'] = @($warnings)
$updatedPlan['lastValidatedAtUtc'] = (Get-Date).ToUniversalTime().ToString('o')
$updatedPlan['validationHash'] = if ($validated) { Get-AdoPermissionsPlanCanonicalHash -Plan ([PSCustomObject]$updatedPlan) } else { $null }

$json = [PSCustomObject]$updatedPlan | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($PlanPath, $json, [System.Text.UTF8Encoding]::new($false))

if ($validated) {
    Write-Output "Plan VALIDO. validationHash=$($updatedPlan['validationHash'])"
    Write-Output "  operaciones aprobadas: $($approvedOps.Count)"
}
else {
    Write-Output "Plan NO VALIDO. Bloqueantes:"
    foreach ($b in $blockers) { Write-Output "  - $b" }
}
