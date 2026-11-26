<#
Valida un plan generado por New-AdoDbPolicyBuildPlan.ps1: recalcula
bodyHash, valida cada operacion contra
Assert-AdoPermissionsOperationRequestMatchesSpec, exige que TODAS sean
create-policy-configuration/POST de tipo Build con scope de 1 elemento
matchKind=Exact, escanea el plan por secretos, rechaza cualquier metodo
DELETE, y si todo pasa fija validated=true + validationHash.

NUNCA escribe en Azure DevOps.

Uso:
  & '.\Test-AdoDbPolicyBuildPlan.ps1' -PlanPath '...\plan.json'
#>

param(
    [Parameter(Mandatory)] [string]$PlanPath
)

$ErrorActionPreference = 'Stop'
$buildPolicyTypeId = '0609b952-1397-4640-95ec-e00a01b2c241'

. (Join-Path $PSScriptRoot 'Invoke-AdoPermissionsRest.ps1')

if (-not (Test-Path -LiteralPath $PlanPath)) { throw "No existe el plan: $PlanPath" }

$plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json

$blockers = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

if ($plan.kind -ne 'ado-policy-configuration-plan') {
    $blockers.Add("El plan no tiene kind='ado-policy-configuration-plan' (encontrado: '$($plan.kind)').")
}
if ($plan.generator -ne 'New-AdoDbPolicyBuildPlan.ps1') {
    $blockers.Add("El plan no fue generado por New-AdoDbPolicyBuildPlan.ps1 (generator='$($plan.generator)').")
}

$approvedOps = @()
if ($null -ne $plan.approvedOperations) { $approvedOps = @($plan.approvedOperations) }
if ($approvedOps.Count -eq 0) {
    $blockers.Add('El plan no tiene ninguna approvedOperations -- nada que aplicar.')
}

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
        $blockers.Add("Operacion '$($op.operationId)': bodyHash no coincide con el body actual (contenido modificado despues de generarlo).")
    }

    if (-not $op.body.type -or [string]$op.body.type.id -ne $buildPolicyTypeId) {
        $blockers.Add("Operacion '$($op.operationId)': body.type.id debe ser el tipo Build ('$buildPolicyTypeId').")
    }
    if (-not $op.body.settings -or -not $op.body.settings.buildDefinitionId) {
        $blockers.Add("Operacion '$($op.operationId)': falta body.settings.buildDefinitionId.")
    }

    $scope = @($op.body.settings.scope)
    if ($scope.Count -ne 1) {
        $blockers.Add("Operacion '$($op.operationId)': body.settings.scope debe tener exactamente 1 elemento (encontrado: $($scope.Count)).")
    }
    elseif ($scope[0].matchKind -ne 'Exact') {
        $blockers.Add("Operacion '$($op.operationId)': body.settings.scope[0].matchKind debe ser 'Exact' (encontrado: '$($scope[0].matchKind)').")
    }
    elseif ($scope[0].refName -notmatch '^refs/heads/.+') {
        $blockers.Add("Operacion '$($op.operationId)': body.settings.scope[0].refName debe ser 'refs/heads/<branch>' (encontrado: '$($scope[0].refName)').")
    }
}

# Sin duplicados de operationId.
$opIds = @($approvedOps | ForEach-Object { [string]$_.operationId })
$dupIds = @($opIds | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($dupIds.Count -gt 0) {
    $blockers.Add("operationId duplicado en el plan: $($dupIds -join ', ').")
}

# Sin (repoId, buildId, refName) duplicados -- nunca dos operaciones que crearian la misma policy.
$scopeKeys = @($approvedOps | ForEach-Object { "$($_.body.settings.scope[0].repositoryId)|$($_.body.settings.buildDefinitionId)|$($_.body.settings.scope[0].refName)" })
$dupScope = @($scopeKeys | Group-Object | Where-Object { $_.Count -gt 1 } | ForEach-Object { $_.Name })
if ($dupScope.Count -gt 0) {
    $blockers.Add("Combinacion repoId|buildId|refName duplicada en el plan: $($dupScope -join '; ').")
}

# Nunca DELETE.
if (@($approvedOps | Where-Object { [string]$_.method -eq 'DELETE' }).Count -gt 0) {
    $blockers.Add('El plan contiene una operacion DELETE -- este plan solo crea policies.')
}

# Escaneo de secretos (defensa en profundidad).
$sensitiveNames = @('password', 'passwd', 'pwd', 'pat', 'token', 'accesstoken', 'authorization', 'connectionstring', 'clientsecret', 'secret', 'apikey', 'privatekey')
function Find-Sensitive {
    param($Node, [string]$Path = '$')
    $found = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Node) { return $found }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Node.PSObject.Properties) {
            $childPath = "$Path.$($prop.Name)"
            if ($sensitiveNames -contains $prop.Name.ToLowerInvariant()) {
                $val = [string]$prop.Value
                if (-not [string]::IsNullOrWhiteSpace($val) -and $val -ne '***REDACTED***' -and $val -notmatch '^\$\{[A-Za-z0-9_]+\}$') { $found.Add($childPath) }
            }
            foreach ($f in (Find-Sensitive -Node $prop.Value -Path $childPath)) { $found.Add($f) }
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $i = 0
        foreach ($item in $Node) { foreach ($f in (Find-Sensitive -Node $item -Path "$Path[$i]")) { $found.Add($f) }; $i++ }
    }
    return $found
}
$hits = Find-Sensitive -Node $plan
if ($hits.Count -gt 0) {
    $blockers.Add("El plan contiene valores en propiedades sensibles en: $($hits -join ', ').")
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
