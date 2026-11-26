<#
Genera un plan JSON determinista (validated=false) para replicar Branch
Policies (Policy Configurations) de un repo origen hacia un repo destino,
dentro del mismo proyecto de Shared-Service-GM. Capacidad "pr-policy-admin"
mencionada como capacidad futura en
.cursor/rules/azure-devops.mdc.

Entrada: los 2 inventarios de solo lectura ya exportados por
Export-AdoPolicyInventory.ps1 (source y target). No hace ninguna llamada
de red -- solo lee esos 2 archivos y compara.

Reglas de esta operacion:
  - Solo se consideran policies del repo origen cuyo scope tenga
    EXACTAMENTE 1 elemento (repositoryId=SourceRepositoryId, refName=
    'refs/heads/<branch>' de -Branches, matchKind='Exact') -- cualquier
    otra forma de scope se reporta como 'skippedUnsupportedScope' y NUNCA
    entra al plan.
  - Se excluyen los policyType.id listados en -ExcludePolicyTypeIds
    (por defecto: Build / '0609b952-1397-4640-95ec-e00a01b2c241').
  - Si el repo destino YA tiene una policy con el mismo (type.id, refName),
    esa policy fuente se reporta como 'skippedAlreadyExists' y NUNCA entra
    al plan -- este script nunca genera un duplicado ni una actualizacion.
  - El body de cada 'create-policy-configuration' es una copia exacta de
    settingsRaw de la policy origen, con 'scope' reemplazado para apuntar
    al repo destino (mismo refName, matchKind Exact). isEnabled/isBlocking
    tambien se copian del origen.

Uso:
  & '.\New-AdoPolicyPlan.ps1' -ProjectName 'Buklo' `
      -SourceRepositoryId '0550ab98-7959-45ee-8361-18b8e4df22a3' `
      -TargetRepositoryId '877b319d-c091-482a-9f0f-19e39ff9b13f' `
      -SourceInventoryPath '...\source-buklo-repo.json' `
      -TargetInventoryPath '...\target-repo.json' `
      -OutFile '...\plan.json'
#>

param(
    [Parameter(Mandatory)] [string]$ProjectName,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')] [string]$SourceRepositoryId,
    [Parameter(Mandatory)] [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')] [string]$TargetRepositoryId,
    [Parameter(Mandatory)] [string]$SourceInventoryPath,
    [Parameter(Mandatory)] [string]$TargetInventoryPath,
    [string[]]$Branches = @('development', 'uat', 'release', 'main'),
    [string[]]$ExcludePolicyTypeIds = @('0609b952-1397-4640-95ec-e00a01b2c241'),
    # Cuando se replica una policy de tipo Build (id
    # '0609b952-1397-4640-95ec-e00a01b2c241'), el buildDefinitionId del
    # ORIGEN casi nunca es valido en el destino -- apunta al pipeline de
    # Build Validation del repo origen, no del destino. Si -ExcludePolicyTypeIds
    # no excluye Build y no se pasa este override, se rechaza generar el
    # plan (nunca se asume "total casualidad de que coincida").
    [Nullable[int]]$BuildDefinitionIdOverride = $null,
    [Parameter(Mandatory)] [string]$OutFile
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Invoke-AdoPermissionsRest.ps1')

if (-not (Test-Path -LiteralPath $SourceInventoryPath)) { throw "No existe el inventario origen: $SourceInventoryPath" }
if (-not (Test-Path -LiteralPath $TargetInventoryPath)) { throw "No existe el inventario destino: $TargetInventoryPath" }

$sourceInv = Get-Content -LiteralPath $SourceInventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json
$targetInv = Get-Content -LiteralPath $TargetInventoryPath -Raw -Encoding UTF8 | ConvertFrom-Json

if ($sourceInv.repositoryId -ne $SourceRepositoryId) {
    throw "El inventario origen ('$SourceInventoryPath') corresponde a repositoryId '$($sourceInv.repositoryId)', no a '$SourceRepositoryId'."
}
if ($targetInv.repositoryId -ne $TargetRepositoryId) {
    throw "El inventario destino ('$TargetInventoryPath') corresponde a repositoryId '$($targetInv.repositoryId)', no a '$TargetRepositoryId'."
}

$wantedRefNames = @($Branches | ForEach-Object { "refs/heads/$_" })

function ConvertTo-AdoPolicyOrderedSettings {
    <#
    Convierte settingsRaw (PSCustomObject deserializado) a un [ordered]
    hashtable, preservando el orden original de propiedades, EXCLUYENDO
    'scope' (se vuelve a agregar despues, ya apuntando al repo destino).
    #>
    param([Parameter(Mandatory)] [psobject]$SettingsRaw)

    $ordered = [ordered]@{}
    foreach ($prop in $SettingsRaw.PSObject.Properties) {
        if ($prop.Name -eq 'scope') { continue }
        $ordered[$prop.Name] = $prop.Value
    }
    return $ordered
}

$approvedOperations = [System.Collections.Generic.List[object]]::new()
$skippedAlreadyExists = [System.Collections.Generic.List[object]]::new()
$skippedUnsupportedScope = [System.Collections.Generic.List[object]]::new()
$skippedExcludedType = [System.Collections.Generic.List[object]]::new()
$opCounter = 0

$targetExistingKeys = New-Object 'System.Collections.Generic.HashSet[string]'
foreach ($p in @($targetInv.policies)) {
    if ($p.isDeleted) { continue }
    foreach ($s in @($p.scope)) {
        if ($s.repositoryId -eq $TargetRepositoryId) {
            $targetExistingKeys.Add("$($p.type.id)|$($s.refName)") | Out-Null
        }
    }
}

foreach ($policy in @($sourceInv.policies)) {
    if ($policy.isDeleted) { continue }

    $scopeList = @($policy.scope)
    $inScopeForSource = @($scopeList | Where-Object { $_.repositoryId -eq $SourceRepositoryId -and $wantedRefNames -contains $_.refName })
    if ($inScopeForSource.Count -eq 0) { continue }

    if ($scopeList.Count -ne 1) {
        $skippedUnsupportedScope.Add([ordered]@{
                sourcePolicyId = $policy.id
                typeId         = $policy.type.id
                typeName       = $policy.type.displayName
                reason         = "El scope de la policy origen tiene $($scopeList.Count) elemento(s) (se soporta exactamente 1)."
            })
        continue
    }

    if ($ExcludePolicyTypeIds -contains $policy.type.id) {
        $skippedExcludedType.Add([ordered]@{
                sourcePolicyId = $policy.id
                typeId         = $policy.type.id
                typeName       = $policy.type.displayName
                refName        = $scopeList[0].refName
                reason         = 'Tipo de policy excluido explicitamente de esta replicacion (ver -ExcludePolicyTypeIds).'
            })
        continue
    }

    $refName = $scopeList[0].refName
    $existsKey = "$($policy.type.id)|$refName"
    if ($targetExistingKeys.Contains($existsKey)) {
        $skippedAlreadyExists.Add([ordered]@{
                sourcePolicyId = $policy.id
                typeId         = $policy.type.id
                typeName       = $policy.type.displayName
                refName        = $refName
                reason         = 'El repo destino ya tiene una policy de este tipo en esta rama -- no se genera un duplicado ni una actualizacion.'
            })
        continue
    }

    $settings = ConvertTo-AdoPolicyOrderedSettings -SettingsRaw $policy.settingsRaw

    if ($policy.type.id -eq '0609b952-1397-4640-95ec-e00a01b2c241') {
        if (-not $BuildDefinitionIdOverride) {
            throw "La policy origen '$($policy.id)' (Build, rama '$refName') no se puede replicar sin -BuildDefinitionIdOverride -- el buildDefinitionId del origen ('$($policy.settingsRaw.buildDefinitionId)') es del pipeline de Build Validation del repo ORIGEN, casi seguro invalido para el repo destino. Pasar -BuildDefinitionIdOverride con el id del Build de destino, o excluir este tipo via -ExcludePolicyTypeIds."
        }
        $settings['buildDefinitionId'] = [int]$BuildDefinitionIdOverride
    }

    $settings['scope'] = @(
        [ordered]@{
            repositoryId = $TargetRepositoryId
            refName      = $refName
            matchKind    = 'Exact'
        }
    )

    $body = [ordered]@{
        isEnabled  = [bool]$policy.isEnabled
        isBlocking = [bool]$policy.isBlocking
        type       = [ordered]@{ id = $policy.type.id }
        settings   = $settings
    }

    $encodedProject = [uri]::EscapeDataString($ProjectName)
    $uri = "https://dev.azure.com/Shared-Service-GM/$encodedProject/_apis/policy/configurations?api-version=7.1"

    $null = Assert-AdoPermissionsOperationRequestMatchesSpec -OperationType 'create-policy-configuration' -Method 'POST' -Uri $uri -Label 'create-policy-configuration'

    $opCounter++
    $entry = [ordered]@{
        operationId    = "policy-{0:d3}" -f $opCounter
        operationType  = 'create-policy-configuration'
        method         = 'POST'
        uri            = $uri
        body           = $body
        bodyHash       = Get-AdoPermissionsBodyCanonicalHash -Body $body
        sourcePolicyId = $policy.id
        typeName       = $policy.type.displayName
        branch         = ($refName -replace '^refs/heads/', '')
        precondition   = [ordered]@{
            targetRepositoryId  = $TargetRepositoryId
            expectedNotExisting = $existsKey
        }
    }
    $approvedOperations.Add([PSCustomObject]$entry)
}

$plan = [ordered]@{
    schemaVersion            = 1
    kind                     = 'ado-policy-configuration-plan'
    createdAtUtc             = (Get-Date).ToUniversalTime().ToString('o')
    organization             = 'Shared-Service-GM'
    project                  = $ProjectName
    sourceRepositoryId       = $SourceRepositoryId
    targetRepositoryId       = $TargetRepositoryId
    branches                 = @($Branches)
    excludedPolicyTypeIds    = @($ExcludePolicyTypeIds)
    buildDefinitionIdOverride = $BuildDefinitionIdOverride
    sourceInventoryPath      = (Resolve-Path -LiteralPath $SourceInventoryPath).Path
    sourceInventoryExportedAtUtc = $sourceInv.exportedAtUtc
    targetInventoryPath      = (Resolve-Path -LiteralPath $TargetInventoryPath).Path
    targetInventoryExportedAtUtc = $targetInv.exportedAtUtc
    approvedOperations       = @($approvedOperations)
    skippedAlreadyExists     = @($skippedAlreadyExists)
    skippedUnsupportedScope  = @($skippedUnsupportedScope)
    skippedExcludedType      = @($skippedExcludedType)
    validated                = $false
    validationHash           = $null
    validationBlockers       = @()
    validationWarnings       = @()
    lastValidatedAtUtc       = $null
}

$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$json = $plan | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($OutFile, $json, [System.Text.UTF8Encoding]::new($false))

Write-Output "Plan generado: $OutFile"
Write-Output "  approvedOperations: $($approvedOperations.Count)"
Write-Output "  skippedAlreadyExists: $($skippedAlreadyExists.Count)"
Write-Output "  skippedUnsupportedScope: $($skippedUnsupportedScope.Count)"
Write-Output "  skippedExcludedType: $($skippedExcludedType.Count)"
