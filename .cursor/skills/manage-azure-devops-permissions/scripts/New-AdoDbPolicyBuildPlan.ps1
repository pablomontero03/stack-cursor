<#
Genera un plan JSON determinista (validated=false, kind=
'ado-policy-configuration-plan') para crear Build policies especificas
por repo en Database-Administration-and-Monitoring: cada repo apunta a su
propio policy build en las ramas que EXISTAN (development, uat, release,
main).

A diferencia de New-AdoPolicyPlan.ps1 (que replica desde un repo origen),
este generador parte de un mapeo explicito repo->repoId->buildId. Emite el
MISMO shape de plan, por lo que Test-AdoPolicyPlan.ps1 y
Apply-AdoPolicyPlan.ps1 lo consumen sin cambios.

Hace SOLO lecturas GET (git refs por repo + policy configurations por
repo) via Invoke-AdoPermissionsRest -Method GET (no requiere plan
aprobado). Nunca escribe.

Reglas:
  - Solo crea para ramas que existan realmente en el repo.
  - Omite (no duplica) si ya existe una Build policy con el mismo
    buildDefinitionId + refName en ese repo.
  - Un repo puede aparecer mas de una vez en el mapeo (repo compartido con
    dos builds): genera una Build policy por cada build/rama.

Uso:
  & '.\New-AdoDbPolicyBuildPlan.ps1' -MappingPath '...\mapping.csv' -OutFile '...\plan.json'

mapping.csv (sin header): repoName,repoId,buildId  (una linea por par)
#>

param(
    [Parameter(Mandatory)] [string]$MappingPath,
    [string]$ProjectName = 'Database-Administration-and-Monitoring',
    [string[]]$Branches = @('development', 'uat', 'release', 'main'),
    [Parameter(Mandatory)] [string]$OutFile
)

$ErrorActionPreference = 'Stop'
$buildPolicyTypeId = '0609b952-1397-4640-95ec-e00a01b2c241'

. (Join-Path $PSScriptRoot 'Invoke-AdoPermissionsRest.ps1')

if (-not (Test-Path -LiteralPath $MappingPath)) { throw "No existe el mapeo: $MappingPath" }

$encodedProject = [uri]::EscapeDataString($ProjectName)

# --- Parseo del mapeo (repoName,repoId,buildId) ---
$mapEntries = [System.Collections.Generic.List[object]]::new()
foreach ($line in (Get-Content -LiteralPath $MappingPath)) {
    $t = $line.Trim()
    if (-not $t -or $t.StartsWith('#')) { continue }
    $parts = $t -split ','
    if ($parts.Count -ne 3) { throw "Linea de mapeo invalida (se esperan 3 campos repoName,repoId,buildId): '$t'" }
    $mapEntries.Add([ordered]@{
            repoName = $parts[0].Trim()
            repoId   = $parts[1].Trim()
            buildId  = [int]$parts[2].Trim()
        })
}

# --- Cache de lecturas por repo (una sola vez por repoId) ---
$repoBranchCache = @{}   # repoId -> hashset de refName existentes
$repoPolicyCache = @{}   # repoId -> hashset de "buildDefId|refName" existentes (Build policies)

function Get-RepoExistingBranches {
    param([string]$RepoId)
    if ($repoBranchCache.ContainsKey($RepoId)) { return $repoBranchCache[$RepoId] }
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $uri = "https://dev.azure.com/Shared-Service-GM/$encodedProject/_apis/git/repositories/$RepoId/refs?filter=heads&api-version=7.1"
    $res = Get-AdoPermissionsRestAllPages -BaseUri $uri
    foreach ($ref in @($res.Items)) {
        if ($ref.name) { $set.Add([string]$ref.name) | Out-Null }  # ya viene como refs/heads/<branch>
    }
    $repoBranchCache[$RepoId] = $set
    return $set
}

function Get-RepoExistingBuildPolicies {
    param([string]$RepoId)
    if ($repoPolicyCache.ContainsKey($RepoId)) { return $repoPolicyCache[$RepoId] }
    $set = New-Object 'System.Collections.Generic.HashSet[string]'
    $uri = "https://dev.azure.com/Shared-Service-GM/$encodedProject/_apis/policy/configurations?repositoryId=$RepoId&api-version=7.1"
    $res = Get-AdoPermissionsRestAllPages -BaseUri $uri
    foreach ($p in @($res.Items)) {
        if ($p.isDeleted) { continue }
        if ([string]$p.type.id -ne $buildPolicyTypeId) { continue }
        $bd = $null
        if ($p.settings -and ($p.settings.PSObject.Properties.Name -contains 'buildDefinitionId')) { $bd = [int]$p.settings.buildDefinitionId }
        foreach ($s in @($p.settings.scope)) {
            if ($s.repositoryId -eq $RepoId -and $null -ne $bd) {
                $set.Add("$bd|$($s.refName)") | Out-Null
            }
        }
    }
    $repoPolicyCache[$RepoId] = $set
    return $set
}

$approvedOperations   = [System.Collections.Generic.List[object]]::new()
$skippedAlreadyExists = [System.Collections.Generic.List[object]]::new()
$skippedBranchMissing = [System.Collections.Generic.List[object]]::new()
$opCounter = 0

$wantedRefNames = @($Branches | ForEach-Object { "refs/heads/$_" })

foreach ($m in $mapEntries) {
    $existingBranches = Get-RepoExistingBranches -RepoId $m.repoId
    $existingPolicies = Get-RepoExistingBuildPolicies -RepoId $m.repoId

    foreach ($refName in $wantedRefNames) {
        $branch = $refName -replace '^refs/heads/', ''

        if (-not $existingBranches.Contains($refName)) {
            $skippedBranchMissing.Add([ordered]@{ repoName = $m.repoName; repoId = $m.repoId; buildId = $m.buildId; branch = $branch; reason = 'La rama no existe en el repo.' })
            continue
        }

        $existsKey = "$($m.buildId)|$refName"
        if ($existingPolicies.Contains($existsKey)) {
            $skippedAlreadyExists.Add([ordered]@{ repoName = $m.repoName; repoId = $m.repoId; buildId = $m.buildId; branch = $branch; reason = 'Ya existe una Build policy con este buildDefinitionId+rama en el repo.' })
            continue
        }

        $settings = [ordered]@{
            buildDefinitionId       = [int]$m.buildId
            queueOnSourceUpdateOnly = $true
            manualQueueOnly         = $false
            displayName             = 'Policy Build Validation'
            validDuration           = 720
            scope                   = @(
                [ordered]@{ repositoryId = $m.repoId; refName = $refName; matchKind = 'Exact' }
            )
        }

        $body = [ordered]@{
            isEnabled  = $true
            isBlocking = $true
            type       = [ordered]@{ id = $buildPolicyTypeId }
            settings   = $settings
        }

        $uri = "https://dev.azure.com/Shared-Service-GM/$encodedProject/_apis/policy/configurations?api-version=7.1"
        $null = Assert-AdoPermissionsOperationRequestMatchesSpec -OperationType 'create-policy-configuration' -Method 'POST' -Uri $uri -Label 'create-policy-configuration'

        $opCounter++
        $entry = [ordered]@{
            operationId   = "policy-{0:d3}" -f $opCounter
            operationType = 'create-policy-configuration'
            method        = 'POST'
            uri           = $uri
            body          = $body
            bodyHash      = Get-AdoPermissionsBodyCanonicalHash -Body $body
            repoName      = $m.repoName
            typeName      = 'Build'
            branch        = $branch
            precondition  = [ordered]@{ targetRepositoryId = $m.repoId; buildDefinitionId = [int]$m.buildId; expectedNotExisting = $existsKey }
        }
        $approvedOperations.Add([PSCustomObject]$entry)
    }
}

$plan = [ordered]@{
    schemaVersion            = 1
    kind                     = 'ado-policy-configuration-plan'
    createdAtUtc             = (Get-Date).ToUniversalTime().ToString('o')
    organization             = 'Shared-Service-GM'
    project                  = $ProjectName
    generator                = 'New-AdoDbPolicyBuildPlan.ps1'
    branches                 = @($Branches)
    mappingPath              = (Resolve-Path -LiteralPath $MappingPath).Path
    approvedOperations       = @($approvedOperations)
    skippedAlreadyExists     = @($skippedAlreadyExists)
    skippedBranchMissing     = @($skippedBranchMissing)
    validated                = $false
    validationHash           = $null
    validationBlockers       = @()
    validationWarnings       = @()
    lastValidatedAtUtc       = $null
}

$dir = Split-Path -Parent $OutFile
if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
$json = [PSCustomObject]$plan | ConvertTo-Json -Depth 20
[System.IO.File]::WriteAllText($OutFile, $json, [System.Text.UTF8Encoding]::new($false))

Write-Output "Plan generado: $OutFile"
Write-Output "  approvedOperations (a crear): $($approvedOperations.Count)"
Write-Output "  skippedAlreadyExists: $($skippedAlreadyExists.Count)"
Write-Output "  skippedBranchMissing: $($skippedBranchMissing.Count)"
