<#
Genera un plan JSON sanitizado para un pipeline clasico de base de datos
(DACPAC/SSDT), sin ejecutar ningun cambio en Azure DevOps. Falla si falta
un dato obligatorio o si detecta un placeholder sin resolver.

A diferencia de AKS, la Library de BD ('Bases Datos SQL') es compartida:
este script NUNCA genera un plan que cree una Library nueva, solo referencia
el nombre esperado para que Test-AdoClassicPlan.ps1 confirme que ya existe.

Uso (ejemplo con datos ficticios):
  powershell -File .\New-AdoClassicDatabasePlan.ps1 `
    -DatabaseProjectName 'sqldb_ejemplo' -DatabaseName 'ejemplo' `
    -RepoName 'project_sqldb_ejemplo' -ProdBranch 'release' `
    -BuildAgentPoolName '172.16.2.127-prtg'
#>

param(
    [Parameter(Mandatory)] [string]$DatabaseProjectName,
    [Parameter(Mandatory)] [string]$DatabaseName,
    [Parameter(Mandatory)] [string]$RepoName,
    [Parameter(Mandatory)] [string]$ProdBranch,
    [Parameter(Mandatory)] [string]$BuildAgentPoolName,
    [string]$RequerimientoPrefijo = 'TKS',
    [string]$AdoPrProject = 'Database-Administration-and-Monitoring',
    [string]$SharedLibraryName = 'Bases Datos SQL',
    [string]$Mode = 'Apply',
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$placeholderPattern = '(?i)^(change_me.*|xxx+|tbd|todo|<.*>)$'

function Assert-NoPlaceholder {
    param([string]$Name, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "New-AdoClassicDatabasePlan: falta el dato obligatorio '$Name'."
    }
    if ($Value -match $placeholderPattern) {
        throw "New-AdoClassicDatabasePlan: '$Name' contiene un placeholder sin resolver ('$Value')."
    }
}

$fieldsToCheck = @{
    DatabaseProjectName = $DatabaseProjectName
    DatabaseName         = $DatabaseName
    RepoName             = $RepoName
    ProdBranch           = $ProdBranch
    BuildAgentPoolName   = $BuildAgentPoolName
}

foreach ($kv in $fieldsToCheck.GetEnumerator()) {
    Assert-NoPlaceholder -Name $kv.Key -Value $kv.Value
}

$projectRoot = $env:REPO_ROOT
if ([string]::IsNullOrWhiteSpace($projectRoot)) { $projectRoot = (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $projectRoot '.local\azure-devops\plans'
}
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

$buildTaskGroupNames = @('Evaluar-ventana-agrupacion', 'Gana-el-mas-nuevo', 'Build-DataBases', 'Reportar-resultado-HU')

# dependencies: nombres conocidos ahora; id/revision quedan null hasta
# que Test-AdoClassicPlan.ps1 los resuelva y confirme contra un
# -InventoryPath real. Nunca se inventan valores aca.
$dependencies = [ordered]@{
    buildTaskGroups = @($buildTaskGroupNames | ForEach-Object { [ordered]@{ name = $_; id = $null; revision = $null } })
    deployTaskGroup = [ordered]@{ name = 'Deployment-DataBases'; id = $null; revision = $null }
    agentPool       = [ordered]@{ name = $BuildAgentPoolName; id = $null }
}

$plan = [PSCustomObject]@{
    family         = 'dacpac'
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    organization   = 'Shared-Service-GM'
    project        = 'DevOps'
    validated      = $false

    names = @{
        build   = "Base_Datos_Build_${DatabaseProjectName}_Produccion"
        release = "Base_Datos_${DatabaseProjectName}_PRODUCCION"
        folder  = "\BaseDatos\$DatabaseProjectName"
    }

    repo = @{
        name       = $RepoName
        prodBranch = $ProdBranch
    }

    buildVariables = @{
        databaseProjectName    = $DatabaseProjectName
        BuildConfiguration      = 'Debug'
        BuildPlatform           = 'any cpu'
        BATCH_PR_TITLE_MARKER   = '[AUTO]'
        BATCH_WAIT_REASONS      = 'IndividualCI,BatchedCI'
        BATCH_WINDOW_MINUTES    = '3'
        SUPERSEDE_REASONS       = 'IndividualCI,BatchedCI'
        'system.debug'          = 'false'
    }

    buildJobs = @('Batch_Gate', 'Batch_Window', 'Job_1')
    buildAgentPool = $BuildAgentPoolName

    dependencies = $dependencies

    sharedLibrary = @{
        name           = $SharedLibraryName
        id             = $null
        expectedExisting = $true
        note           = 'Nunca se crea una Library nueva para BD; se referencia la compartida ya existente.'
    }

    release = @{
        artifactAlias  = "_Base_Datos_Build_${DatabaseProjectName}_Produccion"
        cdTriggerEnabled = $true
        stage          = 'Produccion'
        deployTaskGroup = 'Deployment-DataBases'
        variables = @{
            databaseProjectName = $DatabaseProjectName
            database            = $DatabaseName
            build               = "Base_Datos_Build_${DatabaseProjectName}_Produccion"
            mode                = $Mode
        }
        requerimientoPrefijo = $RequerimientoPrefijo
        adoPrProject          = $AdoPrProject
    }

    # Manifiesto de escrituras aprobadas: vacio a proposito. Los payloads
    # de Build/Release clasico no estan confirmados todavia; hasta que
    # existan, ninguna escritura puede aprobarse aca. Invoke-AdoRest.ps1
    # rechaza toda escritura si este array esta vacio.
    approvedOperations = @()

    notes = @(
        'Plan generado sin ejecutar ningun cambio en Azure DevOps.',
        'mode=Apply en este plan describe la configuracion del Release; NO implica ejecutar el Release ni aplicar el DACPAC ahora - eso exige una aprobacion separada de alto riesgo.'
    )
}

$outFile = Join-Path $OutDir ("dacpac-$DatabaseProjectName-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss')).ToLowerInvariant()
$plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outFile -Encoding utf8

Write-Host "Plan DACPAC (sin validar todavia) escrito en: $outFile" -ForegroundColor Green
Write-Host "Siguiente paso: Test-AdoClassicPlan.ps1 -PlanPath '$outFile'" -ForegroundColor Yellow
