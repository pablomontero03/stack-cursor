<#
Valida un plan generado por New-AdoPermissionsPlan.ps1 (NUNCA un plan de
eliminacion -- ver Test-AdoPermissionsDeletePlan.ps1). No toca la red. Si
no hay bloqueantes, marca 'validated=true' y calcula 'validationHash'
sobre el plan ya reescrito (mismo criterio que Pipelines:
Get-AdoPermissionsPlanCanonicalHash).

Nunca confia ciegamente en lo que ya escribio New-AdoPermissionsPlan.ps1
(ambiguedad, lockout, blockers): todo se re-deriva aca contra el
inventario referenciado, ademas de conservar cualquier bloqueante que el
plan ya traiga (defensa en profundidad, union de ambos).

Uso:
  .\Test-AdoPermissionsPlan.ps1 -PlanPath '...' -MaxInventoryAgeHours 24
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
    throw "Test-AdoPermissionsPlan rechazado: no se encontro el plan '$PlanPath'."
}

$planRaw = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8
$plan = $planRaw | ConvertFrom-Json

$blockers = [System.Collections.Generic.List[string]]::new()
$warnings = [System.Collections.Generic.List[string]]::new()

# OJO -- bug real encontrado y corregido durante las pruebas de este mismo
# script: NUNCA se arrastra 'plan.validationBlockers' tal cual viene del
# archivo. Como este mismo script reescribe ese campo en CADA corrida
# (incluso al fallar), arrastrarlo auto-envenena el plan: una corrida
# fallida queda fallando para siempre, incluso despues de corregir la
# causa real, porque cada corrida vuelve a leer sus propios bloqueantes de
# la corrida ANTERIOR como si fueran "bloqueantes ya confirmados por
# New-". Las 2 categorias que New-AdoPermissionsPlan.ps1 puede escribir
# ahi (ambiguedad de grupo, lockout) ya se RE-DERIVAN de forma
# independiente contra el inventario en la seccion 4 de abajo -- no hace
# falta (ni es seguro) conservar el campo crudo del archivo.

# --- 1) Forma minima del plan ---
$requiredTopLevel = @('schemaVersion', 'operationKind', 'organization', 'projects', 'approvedOperations', 'inventoryPath', 'inventoryHash', 'inventoryGeneratedAtUtc', 'currentIdentityDescriptor')
foreach ($prop in $requiredTopLevel) {
    if ($plan.PSObject.Properties.Name -notcontains $prop) {
        $blockers.Add("El plan no tiene el campo obligatorio '$prop'.")
    }
}
if ($blockers.Count -gt 0) {
    # Sin la forma minima no se puede seguir validando con seguridad.
    $plan | Add-Member -NotePropertyName validated -NotePropertyValue $false -Force
    $plan | Add-Member -NotePropertyName lastValidatedAtUtc -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
    $plan | Add-Member -NotePropertyName validationBlockers -NotePropertyValue @($blockers) -Force
    $plan | Add-Member -NotePropertyName validationWarnings -NotePropertyValue @($warnings) -Force
    $plan | Add-Member -NotePropertyName validationHash -NotePropertyValue $null -Force
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $PlanPath -Encoding utf8
    Write-Host "Plan INVALIDO -- $($blockers.Count) bloqueante(s):" -ForegroundColor Red
    $blockers | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}

if ($plan.operationKind -ne 'non-destructive') {
    $blockers.Add("El plan tiene operationKind '$($plan.operationKind)' -- Test-AdoPermissionsPlan.ps1 solo valida planes 'non-destructive'. Usar Test-AdoPermissionsDeletePlan.ps1 para eliminaciones.")
}

# --- 2) El plan nunca puede contener una operacion destructiva ---
try {
    Assert-AdoPermissionsPlanIsNonDestructive -Plan $plan
}
catch {
    $blockers.Add($_.Exception.Message)
}

# --- 3) Inventario: existe, hash coincide, no supera el tope absoluto ni -MaxInventoryAgeHours ---
$inventory = $null
if (-not (Test-Path -LiteralPath $plan.inventoryPath)) {
    $blockers.Add("El inventario referenciado ('$($plan.inventoryPath)') ya no existe.")
}
else {
    $inventoryRaw = Get-Content -LiteralPath $plan.inventoryPath -Raw -Encoding UTF8
    $currentInventoryHash = Get-AdoPermissionsSha256OfText -Text ([string]::new($inventoryRaw.ToCharArray()))
    if ($currentInventoryHash -ne $plan.inventoryHash) {
        $blockers.Add("El inventario referenciado cambio despues de generar el plan (hash no coincide). Volver a generar el plan con el inventario actual.")
    }
    else {
        $inventory = $inventoryRaw | ConvertFrom-Json
    }

    $effectiveMaxHours = [Math]::Min($MaxInventoryAgeHours, $script:AdoPermissionsAbsoluteMaxInventoryAgeHours)
    try {
        $generatedAt = [DateTime]::Parse($plan.inventoryGeneratedAtUtc, $null, [Globalization.DateTimeStyles]::RoundtripKind)
        $ageHours = ((Get-Date).ToUniversalTime() - $generatedAt.ToUniversalTime()).TotalHours
        if ($ageHours -gt $effectiveMaxHours -or [double]::IsNaN($ageHours) -or [double]::IsInfinity($ageHours)) {
            $blockers.Add("El inventario tiene $([Math]::Round($ageHours,2)) hora(s) de antiguedad, supera el maximo permitido de $effectiveMaxHours hora(s). Volver a exportarlo.")
        }
    }
    catch {
        $blockers.Add("No se pudo interpretar 'inventoryGeneratedAtUtc' del plan ('$($plan.inventoryGeneratedAtUtc)').")
    }
}

# --- 4) Re-derivar ambiguedad y guard de lockout contra el inventario (nunca confiar solo en lo que ya escribio New-) ---
if ($inventory) {
    foreach ($projPlan in @($plan.projects)) {
        $projInv = $inventory.projects | Where-Object { $_.name -eq $projPlan.name } | Select-Object -First 1
        if (-not $projInv) {
            $blockers.Add("El proyecto '$($projPlan.name)' del plan no esta en el inventario referenciado.")
            continue
        }

        if ($projPlan.developmentTeam.status -eq 'blocked-ambiguous') {
            if (-not ($projInv.groups.developmentTeamAmbiguous -or @($projInv.groups.developmentTeamCandidates).Count -gt 1)) {
                $blockers.Add("Proyecto '$($projPlan.name)': el plan marca Development Team como ambiguo pero el inventario actual no confirma esa ambiguedad. Volver a generar el plan.")
            }
            else {
                $blockers.Add("Proyecto '$($projPlan.name)': Development Team/Development Teams sigue ambiguo en el inventario. No se puede validar hasta resolverlo (developmentTeamDescriptorOverride).")
            }
        }

        if ($projPlan.developmentTeam.status -eq 'existing') {
            $devCandidate = @($projInv.groups.developmentTeamCandidates) | Where-Object { $_ -and $_.descriptor -eq $projPlan.developmentTeam.descriptor } | Select-Object -First 1
            if ($devCandidate -and (@($devCandidate.members) -contains [string]$plan.currentIdentityDescriptor)) {
                $hasAcknowledgement = $false
                if ($plan.PSObject.Properties.Name -contains 'lockoutAcknowledgements') {
                    $hasAcknowledgement = [bool](@($plan.lockoutAcknowledgements) | Where-Object { $_.project -eq $projPlan.name -and $_.role -eq 'developmentTeam' -and $_.descriptor -eq $projPlan.developmentTeam.descriptor })
                }
                $hasDenyManagePermissions = $false
                foreach ($op in @($plan.approvedOperations)) {
                    if ($op.operationType -eq 'set-git-permissions-ace') {
                        $hasDenyManagePermissions = $true
                    }
                }
                if ($hasDenyManagePermissions -and -not $hasAcknowledgement) {
                    $blockers.Add("Proyecto '$($projPlan.name)': la identidad que ejecuta ($($plan.currentIdentityDescriptor)) es miembro de 'Development Team', que recibe Deny en 'Manage permissions'. Guard de lockout no reconocido explicitamente -- regenerar el plan con -AcknowledgeLockoutRisk tras confirmar otra via de administracion.")
                }
            }
        }
    }
}

# --- 5) approvedOperations: operationId unico, operationType conocido, spec exacto ---
$seenOpIds = [System.Collections.Generic.HashSet[string]]::new()
foreach ($op in @($plan.approvedOperations)) {
    if ([string]::IsNullOrWhiteSpace([string]$op.operationId)) {
        $blockers.Add("Una operacion aprobada no tiene operationId.")
        continue
    }
    if (-not $seenOpIds.Add([string]$op.operationId)) {
        $blockers.Add("operationId duplicado en approvedOperations: '$($op.operationId)'.")
    }
    if (-not $script:AdoPermissionsAllowedOperationTypes.Contains([string]$op.operationType)) {
        $blockers.Add("operationType desconocido en '$($op.operationId)': '$($op.operationType)'.")
        continue
    }
    try {
        $null = Assert-AdoPermissionsOperationRequestMatchesSpec -OperationType ([string]$op.operationType) -Method ([string]$op.method) -Uri ([string]$op.uri) -Label ([string]$op.operationId)
    }
    catch {
        $blockers.Add("Operacion '$($op.operationId)' invalida: $($_.Exception.Message)")
    }
    if ([string]$op.bodyHash -notmatch '^[0-9a-f]{64}$') {
        $blockers.Add("Operacion '$($op.operationId)': bodyHash con forma invalida.")
    }
    else {
        $recomputedHash = Get-AdoPermissionsBodyCanonicalHash -Body $op.body
        if ($recomputedHash -ne [string]$op.bodyHash) {
            $blockers.Add("Operacion '$($op.operationId)': el bodyHash no coincide con el 'body' guardado (posible manipulacion del plan).")
        }
    }
    if ($op.PSObject.Properties.Name -notcontains 'precondition') {
        $blockers.Add("Operacion '$($op.operationId)': falta 'precondition'.")
    }
}

# --- 6) Escaneo de secretos (por nombre de propiedad + regex sobre texto crudo) ---
# OJO: 'token' esta en la lista porque puede significar un token de acceso
# (secreto), PERO en este dominio tambien es el nombre legitimo del TOKEN
# DE SEGURIDAD de una ACL (ej. 'repoV2/<projectId>/<repositoryId>/refs/heads/<hex>'
# -- un identificador publico de recurso, nunca un secreto). Por eso una
# propiedad llamada EXACTO 'token' cuyo valor tiene la FORMA de un token de
# seguridad Git (regex de abajo) se trata como excepcion segura -- nunca se
# quita 'token' de la lista entera, solo se agrega esta forma conocida.
$sensitiveNames = @('password', 'passwd', 'pwd', 'pat', 'token', 'accesstoken', 'authorization', 'connectionstring', 'clientsecret', 'secret', 'apikey', 'api_key', 'privatekey', 'client_secret')
$adoGitSecurityTokenPattern = '^repoV2/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}(/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})?(/refs/heads/[0-9a-f]+(/[0-9a-f]+)*)?$'
function Find-AdoPermissionsSensitiveJsonProperties {
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
            foreach ($f in (Find-AdoPermissionsSensitiveJsonProperties -Node $prop.Value -Path $childPath)) { $found.Add($f) }
        }
    }
    elseif ($Node -is [System.Collections.IEnumerable] -and $Node -isnot [string]) {
        $i = 0
        foreach ($item in $Node) {
            foreach ($f in (Find-AdoPermissionsSensitiveJsonProperties -Node $item -Path "$Path[$i]")) { $found.Add($f) }
            $i++
        }
    }
    return $found
}
foreach ($f in (Find-AdoPermissionsSensitiveJsonProperties -Node $plan)) { $blockers.Add($f) }

$rawSecretPatterns = @(
    'AZURE_DEVOPS_PAT\s*=\s*[^\$\s]',
    'Authorization:\s*Basic\s+[A-Za-z0-9+/=]{10,}',
    'Authorization:\s*Bearer\s+[A-Za-z0-9._\-]{10,}'
)
foreach ($pattern in $rawSecretPatterns) {
    if ($planRaw -match $pattern) {
        $blockers.Add("El texto del plan coincide con un patron de secreto literal ('$pattern').")
    }
}

# --- 7) Placeholders sin resolver (excluye los propios campos de bloqueantes/advertencias) ---
$scanTarget = [PSCustomObject]@{}
foreach ($prop in $plan.PSObject.Properties) {
    if ($prop.Name -in @('validationBlockers', 'validationWarnings')) { continue }
    $scanTarget | Add-Member -NotePropertyName $prop.Name -NotePropertyValue $prop.Value
}
$scanText = $scanTarget | ConvertTo-Json -Depth 20 -Compress
if ($scanText -match '(?i)(change_me|\bxxx+\b|\btbd\b|\btodo\b|<[a-z_]+>)') {
    $blockers.Add("El plan contiene un placeholder sin resolver (patron change_me/xxx/tbd/todo/<...>).")
}

# --- Resultado ---
$isValid = ($blockers.Count -eq 0)

$plan | Add-Member -NotePropertyName validated -NotePropertyValue $isValid -Force
$plan | Add-Member -NotePropertyName lastValidatedAtUtc -NotePropertyValue (Get-Date).ToUniversalTime().ToString('o') -Force
$plan | Add-Member -NotePropertyName validationBlockers -NotePropertyValue @($blockers | Select-Object -Unique) -Force
$plan | Add-Member -NotePropertyName validationWarnings -NotePropertyValue @($warnings) -Force

if ($isValid) {
    $plan | Add-Member -NotePropertyName validationEvidence -NotePropertyValue ([PSCustomObject]@{
            inventoryGeneratedAtUtc = [string]$plan.inventoryGeneratedAtUtc
            inventoryHash           = [string]$plan.inventoryHash
            validatedAtUtc          = (Get-Date).ToUniversalTime().ToString('o')
            maxInventoryAgeHours    = [Math]::Min($MaxInventoryAgeHours, $script:AdoPermissionsAbsoluteMaxInventoryAgeHours)
        }) -Force
    # El validationHash DEBE calcularse sobre el plan tal como quedara EN
    # DISCO (serializado y re-parseado), no sobre el objeto en memoria:
    # ConvertTo-Json/ConvertFrom-Json coercionan tipos (ej. un timestamp
    # 'o' ISO-8601 se re-emite en formato corto de cultura, un Int/Double
    # cambia de forma) por lo que el hash del objeto en memoria difiere del
    # que Apply-AdoPermissionsPlan.ps1 recomputa al leer el archivo. Se
    # escribe primero sin hash, se relee, se hashea el objeto re-parseado y
    # recien ahi se persiste el validationHash -- garantiza que Test y
    # Apply calculen exactamente el mismo hash. (Bug real 2026-09-16:
    # validationEvidence.validatedAtUtc se guardaba como DateTime corto en
    # disco pero se hasheaba como string ISO en memoria.)
    $plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $PlanPath -Encoding utf8
    $planFromDisk = Get-Content -Raw -LiteralPath $PlanPath -Encoding UTF8 | ConvertFrom-Json
    $hash = Get-AdoPermissionsPlanCanonicalHash -Plan $planFromDisk
    $plan | Add-Member -NotePropertyName validationHash -NotePropertyValue $hash -Force
}
else {
    $plan | Add-Member -NotePropertyName validationHash -NotePropertyValue $null -Force
}

$plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $PlanPath -Encoding utf8

if ($isValid) {
    Write-Host "Plan VALIDO. validationHash: $($plan.validationHash)" -ForegroundColor Green
    exit 0
}
else {
    Write-Host "Plan INVALIDO -- $($blockers.Count) bloqueante(s):" -ForegroundColor Red
    $blockers | Select-Object -Unique | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
    exit 1
}
