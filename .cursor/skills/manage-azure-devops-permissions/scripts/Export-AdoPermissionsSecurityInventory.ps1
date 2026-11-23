<#
Genera un inventario de solo lectura de grupos, membresias, security
namespaces y ACL/ACE Git para uno o varios proyectos de Shared-Service-GM.
Es la unica fuente que consumen New-AdoPermissionsPlan.ps1 y
Test-AdoPermissionsPlan.ps1 -- nunca se asume nada que no venga de aca.

No modifica nada en Azure DevOps. Todas las llamadas son GET.

Uso:
  .\Export-AdoPermissionsSecurityInventory.ps1 -Projects 'Administracion-de-proyectos'
  .\Export-AdoPermissionsSecurityInventory.ps1 -Projects 'DevOps','Administracion-de-proyectos' -OutDir '...'

Requiere $env:AZURE_DEVOPS_PAT con scopes de lectura de proyectos/repos +
vso.graph + vso.security_manage (o el equivalente de lectura de graph
namespace). Ver references/ado-security-api-map.md.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string[]]$Projects,

    [string]$Organization = 'Shared-Service-GM',

    [string]$OutDir,

    # Switch de PRESENCIA/AUSENCIA (nunca [bool] con default $true) -- ver
    # el gotcha conocido de PowerShell 5.1: "powershell -File script.ps1
    # -Param <valor>" nunca puede setear un [bool]/[switch] con un valor
    # explicito (llega vacio, throw). Por eso el default deseado ($true,
    # incluir ACL de rama) se logra invirtiendo el switch: su AUSENCIA es
    # el comportamiento por defecto.
    [switch]$SkipBranchAcl
)

$IncludeBranchAcl = -not $SkipBranchAcl

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoPermissionsRest.ps1')

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $projectRoot = if ($env:REPO_ROOT) { $env:REPO_ROOT } else { (Get-Location).Path }
    $OutDir = Join-Path $projectRoot '.local\azure-devops-permissions\exports'
}
if (-not (Test-Path -LiteralPath $OutDir)) { New-Item -ItemType Directory -Force -Path $OutDir | Out-Null }

$coreBase = "https://dev.azure.com/$Organization"
$graphBase = "https://vssps.dev.azure.com/$Organization"

Write-Host "Exportando inventario de permisos para $($Projects.Count) proyecto(s)..." -ForegroundColor Cyan

# 1) Security namespaces (una sola vez, vale para toda la organizacion).
Write-Host "Consultando security namespaces..." -ForegroundColor Cyan
$namespacesResult = Invoke-AdoPermissionsRest -Method GET -Uri "$coreBase/_apis/securitynamespaces?api-version=$($script:AdoPermissionsCoreApiVersion)"
if ($namespacesResult.StatusCode -lt 200 -or $namespacesResult.StatusCode -ge 300) {
    throw "Export-AdoPermissionsSecurityInventory rechazado: fallo la consulta de security namespaces (HTTP $($namespacesResult.StatusCode))."
}
$allNamespaces = @($namespacesResult.Body.value)
$resolvedActions = Resolve-AdoPermissionsNamespaceActions -Namespaces $allNamespaces
Write-Host "Namespace 'Git Repositories' resuelto: $($resolvedActions.NamespaceId)" -ForegroundColor Green

function Get-AdoPermissionsAclSnapshot {
    <#
    Consulta el ACL de un token con includeExtendedInfo=true, y devuelve
    por cada descriptor pedido: explicitAllow/explicitDeny (de la propia
    ACE), inheritedAllow/inheritedDeny/effectiveAllow/effectiveDeny (que la
    API ya calcula en AceExtendedInformation -- no se recalculan a mano),
    inheritPermissions (del nodo), y si no existe ACE explicita para ese
    descriptor en este token (hasExplicitAce=$false, todo en 0 salvo lo
    heredado).
    #>
    param(
        [Parameter(Mandatory)] [string]$CoreBase,
        [Parameter(Mandatory)] [string]$NamespaceId,
        [Parameter(Mandatory)] [string]$Token,
        [Parameter(Mandatory)] [string[]]$Descriptors
    )

    # El acesDictionary REAL que devuelve Azure DevOps esta keyed por la
    # forma COMPUESTA del descriptor ('Microsoft.IdentityModel.Claims.
    # ClaimsIdentity;vssgp....'), nunca por el descriptor de Graph desnudo
    # -- ver ConvertTo-AdoPermissionsSecurityAceDescriptor. Bug real
    # confirmado 2026-09-02: sin esta conversion, esta funcion SIEMPRE
    # reportaba hasExplicitAce=false para cualquier ACE real ya existente,
    # incluso cuando el portal mostraba una entrada real -- causa raiz por
    # la que el "antes" de este dominio parecia estar siempre en blanco.
    $aceDescriptors = @($Descriptors | ForEach-Object { ConvertTo-AdoPermissionsSecurityAceDescriptor -GraphDescriptor $_ })
    $descriptorsParam = [uri]::EscapeDataString(($aceDescriptors -join ','))
    $uri = "$CoreBase/_apis/accesscontrollists/$($NamespaceId)?token=$([uri]::EscapeDataString($Token))&descriptors=$descriptorsParam&includeExtendedInfo=True&api-version=$($script:AdoPermissionsCoreApiVersion)"
    $result = Invoke-AdoPermissionsRest -Method GET -Uri $uri
    if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
        throw "Get-AdoPermissionsAclSnapshot rechazado: fallo la consulta de ACL para el token '$Token' (HTTP $($result.StatusCode))."
    }

    $acls = @($result.Body.value)
    $matchedAcl = $acls | Where-Object { [string]$_.token -eq $Token } | Select-Object -First 1

    # Set-StrictMode -Version Latest hace que acceder a una propiedad que
    # no existe en absoluto (no solo $null) lance PropertyNotFoundStrict.
    # Confirmado en vivo 2026-09-02: una ACE 'en blanco' (allow=0, deny=0,
    # ej. la creada automaticamente por el portal al ver una rama) trae
    # 'extendedInfo' como un objeto VACIO -- '{}', sin
    # inheritedAllow/inheritedDeny/effectiveAllow/effectiveDeny -- no solo
    # casos donde 'extendedInfo' falta del todo. Cada sub-propiedad se
    # chequea por separado con .PSObject.Properties[...], nunca por la
    # sola presencia del objeto 'extendedInfo' contenedor.
    function Get-AdoPermissionsIntPropertyOrDefault {
        param($Object, [string]$Name, [int]$Default)
        if ($null -eq $Object) { return $Default }
        $prop = $Object.PSObject.Properties[$Name]
        if (-not $prop -or $null -eq $prop.Value) { return $Default }
        return [int]$prop.Value
    }

    $perDescriptor = [ordered]@{}
    foreach ($d in $Descriptors) {
        $ace = $null
        $aceKey = ConvertTo-AdoPermissionsSecurityAceDescriptor -GraphDescriptor $d
        if ($matchedAcl -and $matchedAcl.acesDictionary) {
            $prop = $matchedAcl.acesDictionary.PSObject.Properties[$aceKey]
            if ($prop) { $ace = $prop.Value }
        }
        if ($ace) {
            $extendedInfoProp = $ace.PSObject.Properties['extendedInfo']
            $extendedInfo = if ($extendedInfoProp) { $extendedInfoProp.Value } else { $null }
            $perDescriptor[$d] = [ordered]@{
                hasExplicitAce  = $true
                explicitAllow   = [int]$ace.allow
                explicitDeny    = [int]$ace.deny
                inheritedAllow  = Get-AdoPermissionsIntPropertyOrDefault -Object $extendedInfo -Name 'inheritedAllow' -Default 0
                inheritedDeny   = Get-AdoPermissionsIntPropertyOrDefault -Object $extendedInfo -Name 'inheritedDeny' -Default 0
                effectiveAllow  = Get-AdoPermissionsIntPropertyOrDefault -Object $extendedInfo -Name 'effectiveAllow' -Default ([int]$ace.allow)
                effectiveDeny   = Get-AdoPermissionsIntPropertyOrDefault -Object $extendedInfo -Name 'effectiveDeny' -Default ([int]$ace.deny)
            }
        }
        else {
            $perDescriptor[$d] = [ordered]@{
                hasExplicitAce  = $false
                explicitAllow   = 0
                explicitDeny    = 0
                inheritedAllow  = 0
                inheritedDeny   = 0
                effectiveAllow  = 0
                effectiveDeny   = 0
            }
        }
    }

    # Ademas del detalle por-descriptor de arriba (solo para los que este
    # dominio administra), se guarda el acesDictionary COMPLETO real de
    # este token -- necesario para que New-AdoPermissionsPlan.ps1 pueda
    # preservar cualquier otra identidad ya presente al escribir (ver
    # Get-AdoPermissionsFullAcesDictionary; incidente real 2026-09-02:
    # 'Set ACL' reemplaza todo el diccionario, no lo combina).
    $fullDictionary = Get-AdoPermissionsFullAcesDictionary -CoreBase $CoreBase -NamespaceId $NamespaceId -Token $Token

    return [PSCustomObject]@{
        token              = $Token
        inheritPermissions = if ($matchedAcl) { [bool]$matchedAcl.inheritPermissions } else { $null }
        aclFound           = [bool]$matchedAcl
        descriptors        = [PSCustomObject]$perDescriptor
        fullAcesDictionary = @($fullDictionary.entries)
    }
}

$projectEntries = [System.Collections.Generic.List[object]]::new()
$devTeamPattern = '^(development team|development teams)$'
$codeReviewersPattern = '^code-reviewers \(revision y aprobacion del lider de proyecto\)$'

foreach ($projectName in $Projects) {
    Write-Host "Proyecto: $projectName" -ForegroundColor Cyan

    # 2) Resolver el proyecto (id) via Core API.
    $projResult = Invoke-AdoPermissionsRest -Method GET -Uri "$coreBase/_apis/projects/$([uri]::EscapeDataString($projectName))?api-version=$($script:AdoPermissionsCoreApiVersion)"
    if ($projResult.StatusCode -lt 200 -or $projResult.StatusCode -ge 300 -or -not $projResult.Body.id) {
        throw "Export-AdoPermissionsSecurityInventory rechazado: no se pudo resolver el proyecto '$projectName' (HTTP $($projResult.StatusCode))."
    }
    $projectId = [string]$projResult.Body.id

    # 3) Resolver el scope descriptor del proyecto (graph descriptor del storageKey = projectId).
    $descResult = Invoke-AdoPermissionsRest -Method GET -Uri "$graphBase/_apis/graph/descriptors/$($projectId)?api-version=$($script:AdoPermissionsGraphApiVersion)"
    if ($descResult.StatusCode -lt 200 -or $descResult.StatusCode -ge 300 -or -not $descResult.Body.value) {
        throw "Export-AdoPermissionsSecurityInventory rechazado: no se pudo resolver el scope descriptor del proyecto '$projectName' (HTTP $($descResult.StatusCode))."
    }
    $scopeDescriptor = [string]$descResult.Body.value

    # 4) Listar repositorios del proyecto.
    $reposResult = Invoke-AdoPermissionsRest -Method GET -Uri "$coreBase/$([uri]::EscapeDataString($projectName))/_apis/git/repositories?api-version=$($script:AdoPermissionsCoreApiVersion)"
    if ($reposResult.StatusCode -lt 200 -or $reposResult.StatusCode -ge 300) {
        throw "Export-AdoPermissionsSecurityInventory rechazado: no se pudo listar repositorios de '$projectName' (HTTP $($reposResult.StatusCode))."
    }
    $repos = @($reposResult.Body.value)

    $repoEntries = [System.Collections.Generic.List[object]]::new()
    foreach ($repo in $repos) {
        $repoId = [string]$repo.id
        $repoName = [string]$repo.name

        $branchStates = [ordered]@{}
        foreach ($branchName in @('development', 'uat', 'release', 'main')) {
            $refsResult = Invoke-AdoPermissionsRest -Method GET -Uri "$coreBase/$([uri]::EscapeDataString($projectName))/_apis/git/repositories/$repoId/refs?filter=$([uri]::EscapeDataString("heads/$branchName"))&api-version=$($script:AdoPermissionsCoreApiVersion)"
            $branchStates[$branchName] = ($refsResult.StatusCode -ge 200 -and $refsResult.StatusCode -lt 300 -and @($refsResult.Body.value).Count -gt 0)
        }
        $featureRefsResult = Invoke-AdoPermissionsRest -Method GET -Uri "$coreBase/$([uri]::EscapeDataString($projectName))/_apis/git/repositories/$repoId/refs?filter=$([uri]::EscapeDataString('heads/feature'))&api-version=$($script:AdoPermissionsCoreApiVersion)"
        $featureChildCount = if ($featureRefsResult.StatusCode -ge 200 -and $featureRefsResult.StatusCode -lt 300) { @($featureRefsResult.Body.value).Count } else { 0 }

        $repoEntries.Add([PSCustomObject]@{
                repositoryId   = $repoId
                name           = $repoName
                defaultBranch  = [string]$repo.defaultBranch
                branchExists   = [PSCustomObject]$branchStates
                featureBranchChildCount = $featureChildCount
            })
    }

    # 5) Listar grupos del proyecto y resolver Development Team(s) / Code-Reviewers.
    $groupsResult = Invoke-AdoPermissionsRest -Method GET -Uri "$graphBase/_apis/graph/groups?scopeDescriptor=$([uri]::EscapeDataString($scopeDescriptor))&api-version=$($script:AdoPermissionsGraphApiVersion)"
    if ($groupsResult.StatusCode -lt 200 -or $groupsResult.StatusCode -ge 300) {
        throw "Export-AdoPermissionsSecurityInventory rechazado: no se pudo listar grupos de '$projectName' (HTTP $($groupsResult.StatusCode))."
    }
    $allGroups = @($groupsResult.Body.value)

    $devTeamMatches = @($allGroups | Where-Object { [string]$_.displayName -imatch $devTeamPattern })
    $codeReviewersMatches = @($allGroups | Where-Object { [string]$_.displayName -imatch $codeReviewersPattern })

    function ConvertTo-AdoPermissionsGroupSummary {
        param($Group)
        if (-not $Group) { return $null }
        $membersResult = Invoke-AdoPermissionsRest -Method GET -Uri "$graphBase/_apis/graph/memberships/$([uri]::EscapeDataString([string]$Group.descriptor))?direction=down&api-version=$($script:AdoPermissionsGraphApiVersion)"
        $memberDescriptors = @()
        if ($membersResult.StatusCode -ge 200 -and $membersResult.StatusCode -lt 300) {
            $memberDescriptors = @($membersResult.Body.value | ForEach-Object { [string]$_.memberDescriptor })
        }
        return [PSCustomObject]@{
            descriptor  = [string]$Group.descriptor
            displayName = [string]$Group.displayName
            description = [string]$Group.description
            members     = $memberDescriptors
        }
    }

    $devTeamGroups = @($devTeamMatches | ForEach-Object { ConvertTo-AdoPermissionsGroupSummary -Group $_ })
    $codeReviewersGroup = if ($codeReviewersMatches.Count -gt 0) { ConvertTo-AdoPermissionsGroupSummary -Group $codeReviewersMatches[0] } else { $null }

    # 6) ACL de "All Repositories" (token de proyecto) y, si corresponde,
    # de cada nodo de rama administrado por repositorio -- SOLO para
    # descriptores de grupos que ya existen (un grupo nuevo, todavia no
    # creado, no tiene ACE previa que preservar: su ACE actual es 0/0 por
    # definicion, sin necesidad de consultarla).
    $managedDescriptors = [System.Collections.Generic.List[string]]::new()
    foreach ($g in $devTeamGroups) { if ($g) { $managedDescriptors.Add($g.descriptor) } }
    if ($codeReviewersGroup) { $managedDescriptors.Add($codeReviewersGroup.descriptor) }

    $allRepositoriesAcl = $null
    $repoAclEntries = [ordered]@{}
    if ($managedDescriptors.Count -gt 0) {
        $projectToken = ConvertTo-AdoPermissionsProjectToken -ProjectId $projectId
        $allRepositoriesAcl = Get-AdoPermissionsAclSnapshot -CoreBase $coreBase -NamespaceId $resolvedActions.NamespaceId -Token $projectToken -Descriptors @($managedDescriptors)

        if ($IncludeBranchAcl) {
            foreach ($repo in $repoEntries) {
                $branchAclForRepo = [ordered]@{}

                $featureToken = ConvertTo-AdoPermissionsGitToken -ProjectId $projectId -RepositoryId $repo.repositoryId -RefSegments @('feature')
                $branchAclForRepo['feature'] = Get-AdoPermissionsAclSnapshot -CoreBase $coreBase -NamespaceId $resolvedActions.NamespaceId -Token $featureToken -Descriptors @($managedDescriptors)

                foreach ($branchName in @('development', 'uat', 'release', 'main')) {
                    if ($repo.branchExists.$branchName) {
                        $branchToken = ConvertTo-AdoPermissionsGitToken -ProjectId $projectId -RepositoryId $repo.repositoryId -RefSegments @($branchName)
                        $branchAclForRepo[$branchName] = Get-AdoPermissionsAclSnapshot -CoreBase $coreBase -NamespaceId $resolvedActions.NamespaceId -Token $branchToken -Descriptors @($managedDescriptors)
                    }
                    else {
                        $branchAclForRepo[$branchName] = $null
                    }
                }

                $repoAclEntries[$repo.repositoryId] = [PSCustomObject]$branchAclForRepo
            }
        }
    }

    $projectEntries.Add([PSCustomObject]@{
            name             = $projectName
            projectId        = $projectId
            scopeDescriptor  = $scopeDescriptor
            repositories     = @($repoEntries)
            groups           = [PSCustomObject]@{
                developmentTeamCandidates = $devTeamGroups
                developmentTeamAmbiguous  = ($devTeamMatches.Count -gt 1)
                codeReviewers             = $codeReviewersGroup
            }
            acl              = [PSCustomObject]@{
                allRepositories = $allRepositoriesAcl
                byRepository    = [PSCustomObject]$repoAclEntries
            }
        })
}

$inventory = [PSCustomObject]@{
    schemaVersion         = 1
    generatedAtUtc        = (Get-Date).ToUniversalTime().ToString('o')
    organization           = $Organization
    paginationComplete      = $true
    securityNamespace       = [PSCustomObject]@{
        namespaceId  = $resolvedActions.NamespaceId
        resolvedBits = $resolvedActions.ResolvedBits
    }
    projects                = @($projectEntries)
}

$timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
$safeName = ($Projects -join '-') -replace '[^A-Za-z0-9\-]', '-'
$outPath = Join-Path $OutDir "inventory-permissions-$safeName-$timestamp.json"
$inventory | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $outPath -Encoding utf8

Write-Host "Inventario escrito en: $outPath" -ForegroundColor Green
return $outPath
