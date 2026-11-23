<#
Valida un plan de eliminacion generado por New-AdoPermissionsDeletePlan.ps1.
NUNCA valida un plan no-destructivo (usar Test-AdoPermissionsPlan.ps1 para
eso). Exige EXACTAMENTE una operacion, backupRequired=true, y que el
operationType sea uno de los 2 tipos DELETE permitidos.

Uso:
  .\Test-AdoPermissionsDeletePlan.ps1 -PlanPath '...' -MaxInventoryAgeHours 24
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$PlanPath,

    [ValidateRange(0.01, 24)]
    [double]$MaxInventoryAgeHours = 24
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoPermissionsRest.ps1')

if (-not (Test-Path -LiteralPath $PlanPath)) {
    throw "Test-AdoPermissionsDeletePlan rechazado: no se encontro el plan '$PlanPath'."
}
$planRaw = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8
$plan = $planRaw | ConvertFrom-Json

$blockers = [System.Collections.Generic.List[string]]::new()

if ($plan.operationKind -ne 'destructive') {
    $blockers.Add("El plan tiene operationKind '$($plan.operationKind)' -- Test-AdoPermissionsDeletePlan.ps1 solo valida planes 'destructive'. Usar Test-AdoPermissionsPlan.ps1 para planes no destructivos.")
}
if ($plan.backupRequired -ne $true) {
    $blockers.Add("El plan no tiene backupRequired=true. Un plan de eliminacion siempre exige respaldo previo obligatorio.")
}
if ($plan.resourceType -notin @('SecurityGroup', 'GroupMembership')) {
    $blockers.Add("resourceType invalido: '$($plan.resourceType)'.")
}

$approvedOps = @()
if ($null -ne $plan.approvedOperations) { $approvedOps = @($plan.approvedOperations) }
if ($approvedOps.Count -ne 1) {
    $blockers.Add("El plan tiene $($approvedOps.Count) operacion(es) aprobada(s) -- un plan de eliminacion debe tener EXACTAMENTE una. Nunca se agrupan varias eliminaciones.")
}
else {
    $op = $approvedOps[0]
    if (-not $script:AdoPermissionsDestructiveOperationTypes -contains [string]$op.operationType) {
        $blockers.Add("operationType '$($op.operationType)' no es un tipo de eliminacion permitido ($($script:AdoPermissionsDestructiveOperationTypes -join ', ')).")
    }
    if ([string]$op.method -ne 'DELETE') {
        $blockers.Add("El metodo de la operacion debe ser DELETE. Encontrado: '$($op.method)'.")
    }
    try {
        $null = Assert-AdoPermissionsOperationRequestMatchesSpec -OperationType ([string]$op.operationType) -Method ([string]$op.method) -Uri ([string]$op.uri) -Label ([string]$op.operationId)
    }
    catch {
        $blockers.Add("Operacion invalida: $($_.Exception.Message)")
    }
    if ($null -ne $op.body) {
        $blockers.Add("La operacion de eliminacion no debe llevar body. Encontrado un body no nulo.")
    }
    if ($op.PSObject.Properties.Name -notcontains 'precondition' -or -not $op.precondition) {
        $blockers.Add("Falta 'precondition' en la operacion de eliminacion.")
    }
}

# --- Inventario: existe, hash coincide, fresco ---
if (-not (Test-Path -LiteralPath $plan.inventoryPath)) {
    $blockers.Add("El inventario referenciado ('$($plan.inventoryPath)') ya no existe.")
}
else {
    $inventoryRaw = Get-Content -LiteralPath $plan.inventoryPath -Raw -Encoding UTF8
    $currentInventoryHash = Get-AdoPermissionsSha256OfText -Text ([string]::new($inventoryRaw.ToCharArray()))
    if ($currentInventoryHash -ne [string]$plan.inventoryHash) {
        $blockers.Add("El inventario referenciado cambio despues de generar el plan (hash no coincide).")
    }
    $effectiveMaxHours = [Math]::Min($MaxInventoryAgeHours, $script:AdoPermissionsAbsoluteMaxInventoryAgeHours)
    try {
        $generatedAt = [DateTime]::Parse([string]$plan.generatedAtUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        $ageHours = ((Get-Date).ToUniversalTime() - $generatedAt.ToUniversalTime()).TotalHours
        if ($ageHours -gt $effectiveMaxHours -or [double]::IsNaN($ageHours) -or [double]::IsInfinity($ageHours)) {
            $blockers.Add("El plan tiene $([Math]::Round($ageHours,2)) hora(s) de antiguedad, supera el maximo permitido de $effectiveMaxHours hora(s). Volver a generarlo.")
        }
    }
    catch {
        $blockers.Add("No se pudo interpretar 'generatedAtUtc' del plan.")
    }
}

# --- Secretos (mismo criterio que Test-AdoPermissionsPlan.ps1) ---
$sensitiveNames = @('password', 'passwd', 'pwd', 'pat', 'token', 'accesstoken', 'authorization', 'connectionstring', 'clientsecret', 'secret', 'apikey', 'api_key', 'privatekey', 'client_secret')
$adoGitSecurityTokenPattern = '^repoV2/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})?(/refs/heads/[0-9a-f]+(/[0-9a-f]+)*)?$'
function Find-AdoPermissionsDeleteSensitiveJsonProperties {
    param($Node, [string]$Path = '$')
    $found = [System.Collections.Generic.List[string]]::new()
    if ($null -eq $Node) { return $found }
    if ($Node -is [System.Management.Automation.PSCustomObject]) {
        foreach ($prop in $Node.PSObject.Properties) {
            $childPath = "$Path.$($prop.Name)"
            if ($sensitiveNames -contains $prop.Name.ToLowerInvariant()) {
                $val = $prop.Value
                $isPlaceholder = ($null -eq $val) -or ([string]$val -match '^\$\{[A-Za-z0-9_]+\}$') -or ([string]$val -eq '***REDACTED***')
                $isGitSecurityToken = ($prop.Name -ceq 'token') -and ([string]$val -match $adoGitSecurityTokenPattern)
                if (-not $isPlaceholder -and -not $isGitSecurityToken) {
                    $found.Add("Propiedad sensible con valor literal en $childPath")
                }
            }
            foreach ($f in (Find-AdoPermissionsDeleteSensitiveJsonProperties -Node $prop.Value -Path $childPath)) { $found.Add($f) }
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $i = 0
        foreach ($item in $Node) {
            foreach ($f in (Find-AdoPermissionsDeleteSensitiveJsonProperties -Node $item -Path "$Path[$i]")) { $found.Add($f) }
            $i++
        }
    }
    return $found
}
foreach ($f in (Find-AdoPermissionsDeleteSensitiveJsonProperties -Node $plan)) { $blockers.Add($f) }

$isValid = ($blockers.Count -eq 0)

$plan | Add-Member -NotePropertyName validated -NotePropertyValue $isValid -Force
$plan | Add-Member -NotePropertyName lastValidatedAtUtc -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
$plan | Add-Member -NotePropertyName validationBlockers -NotePropertyValue @($blockers | Select-Object -Unique) -Force
$plan | Add-Member -NotePropertyName validationWarnings -NotePropertyValue @() -Force

if ($isValid) {
    $plan | Add-Member -NotePropertyName validationEvidence -NotePropertyValue ([PSCustomObject]@{
            inventoryGeneratedAtUtc = [string]$plan.generatedAtUtc
            inventoryHash           = [string]$plan.inventoryHash
            validatedAtUtc          = (Get-Date).ToUniversalTime().ToString('o')
            maxInventoryAgeHours    = [Math]::Min($MaxInventoryAgeHours, $script:AdoPermissionsAbsoluteMaxInventoryAgeHours)
        }) -Force
    $hash = Get-AdoPermissionsPlanCanonicalHash -Plan $plan
    $plan | Add-Member -NotePropertyName validationHash -NotePropertyValue $hash -Force
}
else {
    $plan | Add-Member -NotePropertyName validationHash -NotePropertyValue $null -Force
}

$plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $PlanPath -Encoding utf8

if ($isValid) {
    Write-Host "Plan de eliminacion VALIDO. validationHash: $($plan.validationHash)" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "Plan de eliminacion INVALIDO -- $($blockers.Count) bloqueante(s):" -ForegroundColor Red
    $blockers | Select-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
