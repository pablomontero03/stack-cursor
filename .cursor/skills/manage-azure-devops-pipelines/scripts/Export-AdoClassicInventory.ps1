<#
Exporta un inventario sanitizado de solo lectura (proyectos, definiciones
de Build/Release, Variable Groups SIN NINGUN valor de variable -- ni
siquiera un placeholder, solo nombre + flag isSecret --, task groups,
service connections sin datos de autorizacion, pools, repositorios y
branches) a .local/azure-devops/exports/. Nunca escribe en Azure DevOps.

Cada endpoint se consulta con Get-AdoRestAllPages, que consume todas las
paginas que la API DEVUELVA (via el header de respuesta
x-ms-continuationtoken cuando esta presente). No se afirma que agregar un
parametro continuationToken convierta automaticamente cualquier endpoint
en paginado: los endpoints que Azure DevOps documenta con soporte de
continuation token (Build/Release definitions, Variable Groups, Task
Groups, refs de Git, etc.) se consumen pagina por pagina hasta que el
header deja de aparecer; para los que no lo devuelven, Get-AdoRestAllPages
simplemente procesa la unica pagina de la respuesta completa (su body
'value' completo segun el contrato de esa API), sin asumir que existan
paginas adicionales que nunca se anuncian. El inventario solo se marca
paginationComplete=true si TODAS las llamadas de TODOS los endpoints (la
pagina unica, o todas las paginas cuando hay varias) se consumieron sin
error; si cualquiera falla (ciclo de tokens, limite de paginas superado,
respuesta con forma invalida, error de red), el script completo falla
con throw y NO se escribe ningun archivo de inventario parcial.

Uso:
  powershell -File .\Export-AdoClassicInventory.ps1 -Project DevOps
#>

param(
    [string]$Project = 'DevOps',
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')

$projectRoot = $env:REPO_ROOT
if ([string]::IsNullOrWhiteSpace($projectRoot)) { $projectRoot = (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $projectRoot '.local\azure-devops\exports'
}

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

function Strip-Secrets {
    <#
    Nunca conserva NINGUN valor de variable de un Variable Group, sea o no
    isSecret=true en Azure DevOps -- el inventario solo necesita nombre +
    flag isSecret para que Test-AdoClassicPlan.ps1 pueda validar el
    pipeline (que variables existen, cuales son secretas), nunca sus
    valores. No se guarda 'value' ni un placeholder como '***REDACTED***'
    (ni siquiera eso queda en el archivo).
    #>
    param($VariableGroup)
    $sanitizedVariables = @{}
    foreach ($prop in $VariableGroup.variables.PSObject.Properties) {
        $v = $prop.Value
        $sanitizedVariables[$prop.Name] = @{ isSecret = [bool]$v.isSecret }
    }
    return [PSCustomObject]@{
        id        = $VariableGroup.id
        name      = $VariableGroup.name
        type      = $VariableGroup.type
        variables = $sanitizedVariables
    }
}

Write-Host "Consultando proyectos (todas las paginas)..." -ForegroundColor Cyan
$projectsPages = Get-AdoRestAllPages -BaseUri "$($script:AdoCoreBaseUrl)/_apis/projects?api-version=$($script:AdoApiVersion)"
Write-Host "  $($projectsPages.PagesFetched) pagina(s), $($projectsPages.Items.Count) proyecto(s)." -ForegroundColor DarkCyan

Write-Host "Consultando definiciones de Build ($Project, todas las paginas)..." -ForegroundColor Cyan
$buildDefsPages = Get-AdoRestAllPages -BaseUri "$($script:AdoCoreBaseUrl)/$Project/_apis/build/definitions?api-version=$($script:AdoApiVersion)"
Write-Host "  $($buildDefsPages.PagesFetched) pagina(s), $($buildDefsPages.Items.Count) definicion(es)." -ForegroundColor DarkCyan

Write-Host "Consultando definiciones de Release ($Project, todas las paginas)..." -ForegroundColor Cyan
$releaseDefsPages = Get-AdoRestAllPages -BaseUri "$($script:AdoReleaseBaseUrl)/$Project/_apis/release/definitions?api-version=$($script:AdoApiVersion)"
Write-Host "  $($releaseDefsPages.PagesFetched) pagina(s), $($releaseDefsPages.Items.Count) definicion(es)." -ForegroundColor DarkCyan

Write-Host "Consultando Variable Groups ($Project, todas las paginas)..." -ForegroundColor Cyan
$variableGroupsPages = Get-AdoRestAllPages -BaseUri "$($script:AdoCoreBaseUrl)/$Project/_apis/distributedtask/variablegroups?api-version=$($script:AdoApiVersion)"
$sanitizedVariableGroups = @($variableGroupsPages.Items | ForEach-Object { Strip-Secrets -VariableGroup $_ })
Write-Host "  $($variableGroupsPages.PagesFetched) pagina(s), $($sanitizedVariableGroups.Count) grupo(s)." -ForegroundColor DarkCyan

Write-Host "Consultando Task Groups ($Project, todas las paginas)..." -ForegroundColor Cyan
$taskGroupsPages = Get-AdoRestAllPages -BaseUri "$($script:AdoCoreBaseUrl)/$Project/_apis/distributedtask/taskgroups?api-version=$($script:AdoApiVersion)"
Write-Host "  $($taskGroupsPages.PagesFetched) pagina(s), $($taskGroupsPages.Items.Count) task group(s)." -ForegroundColor DarkCyan

Write-Host "Consultando Service Connections ($Project, todas las paginas)..." -ForegroundColor Cyan
$serviceConnectionsPages = Get-AdoRestAllPages -BaseUri "$($script:AdoCoreBaseUrl)/$Project/_apis/serviceendpoint/endpoints?api-version=$($script:AdoApiVersion)"
$sanitizedServiceConnections = @($serviceConnectionsPages.Items | ForEach-Object {
    [PSCustomObject]@{ id = $_.id; name = $_.name; type = $_.type; isReady = $_.isReady }
})
Write-Host "  $($serviceConnectionsPages.PagesFetched) pagina(s), $($sanitizedServiceConnections.Count) conexion(es)." -ForegroundColor DarkCyan

Write-Host "Consultando Agent Pools (todas las paginas)..." -ForegroundColor Cyan
$poolsPages = Get-AdoRestAllPages -BaseUri "$($script:AdoCoreBaseUrl)/_apis/distributedtask/pools?api-version=$($script:AdoApiVersion)"
Write-Host "  $($poolsPages.PagesFetched) pagina(s), $($poolsPages.Items.Count) pool(s)." -ForegroundColor DarkCyan

Write-Host "Consultando repositorios ($Project, todas las paginas)..." -ForegroundColor Cyan
$reposPages = Get-AdoRestAllPages -BaseUri "$($script:AdoCoreBaseUrl)/$Project/_apis/git/repositories?api-version=$($script:AdoApiVersion)"
Write-Host "  $($reposPages.PagesFetched) pagina(s), $($reposPages.Items.Count) repositorio(s)." -ForegroundColor DarkCyan

$repositoriesWithBranches = [System.Collections.Generic.List[object]]::new()
$totalRefPages = 0
foreach ($repo in $reposPages.Items) {
    Write-Host "  Branches de $($repo.name) (todas las paginas)..." -ForegroundColor DarkCyan
    $refsPages = Get-AdoRestAllPages -BaseUri "$($script:AdoCoreBaseUrl)/$Project/_apis/git/repositories/$($repo.id)/refs?filter=heads/&api-version=$($script:AdoApiVersion)"
    $totalRefPages += $refsPages.PagesFetched
    $branchNames = @($refsPages.Items | ForEach-Object { $_.name -replace '^refs/heads/', '' })
    $repositoriesWithBranches.Add([PSCustomObject]@{
        id            = $repo.id
        name          = $repo.name
        defaultBranch = ($repo.defaultBranch -replace '^refs/heads/', '')
        branches      = $branchNames
    })
}

# Si se llego hasta aca, TODAS las paginas de TODOS los endpoints se
# consumieron sin excepcion (ciclo de tokens o limite de paginas habrian
# detenido el script antes, sin escribir ningun archivo).
$inventory = [PSCustomObject]@{
    generatedAtUtc      = (Get-Date).ToUniversalTime().ToString('o')
    organization        = 'Shared-Service-GM'
    project             = $Project
    paginationComplete  = $true
    projects            = @($projectsPages.Items | ForEach-Object { [PSCustomObject]@{ id = $_.id; name = $_.name } })
    buildDefinitions    = @($buildDefsPages.Items | ForEach-Object { [PSCustomObject]@{ id = $_.id; name = $_.name; path = $_.path } })
    releaseDefinitions  = @($releaseDefsPages.Items | ForEach-Object { [PSCustomObject]@{ id = $_.id; name = $_.name; path = $_.path } })
    variableGroups      = $sanitizedVariableGroups
    taskGroups          = @($taskGroupsPages.Items | ForEach-Object { [PSCustomObject]@{ id = $_.id; name = $_.name; revision = $_.revision } })
    serviceConnections  = $sanitizedServiceConnections
    agentPools          = @($poolsPages.Items | ForEach-Object { [PSCustomObject]@{ id = $_.id; name = $_.name; isHosted = $_.isHosted } })
    repositories        = @($repositoriesWithBranches)
}

$outFile = Join-Path $OutDir ("inventory-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$inventory | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outFile -Encoding utf8

Write-Host "Inventario sanitizado escrito en: $outFile" -ForegroundColor Green
Write-Host "paginationComplete=true (se siguieron todos los continuation tokens de cada endpoint exportado hasta agotarlos)." -ForegroundColor Green
