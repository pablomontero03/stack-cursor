<#
Genera un plan JSON sanitizado para un pipeline clasico de base de datos
(DACPAC/SSDT) — patron UNIFICADO (1 Build + 1 Release con 3 stages).

El plan describe la estructura esperada sin ejecutar ningun cambio en ADO.
Apply-AdoClassicPlan.ps1 lo materializa via GET+clone del modelo de referencia
(Build 647 / Release 403) mutando solo los campos especificos de la BD.

Patron generado:
  Build: Build_Base_Datos_<DatabaseProjectName>
    - Queue: self-hosted 172.16.2.127-prtg (id=393)
    - Trigger CI: branches development + uat + release
    - TGs: Evaluar-ventana-agrupacion → Gana-el-mas-nuevo → Build-DataBases → Reportar-resultado-HU
    - VG compartido: 181 (Bases Datos SQL)

  Release: Deploy-Desarrollo-UAT-Produccion-Base_Datos_<DatabaseProjectName>
    - 3 stages: Desarrollo (development), UAT (uat), Produccion (release)
    - Stage trigger: ReleaseStarted (After release) + artifact filter por branch
    - TG Deployment-DataBases: disabled por defecto (mode=DryRun)
    - Produccion: aprobacion manual (Release Executers)

La Library 'Bases Datos SQL' (VG 181) es compartida: este script NUNCA
genera un plan que cree una Library nueva.

Uso:
  pwsh -File .\New-AdoClassicDatabasePlan.ps1 `
    -DatabaseProjectName 'sqldb_ejemplo' -DatabaseName 'ejemplo' `
    -RepoName 'project_sqldb_ejemplo' -RepoProject 'Database-Administration-and-Monitoring' `
    -RepoId '<guid-del-repo>'
#>

param(
    [Parameter(Mandatory)] [string]$DatabaseProjectName,
    [Parameter(Mandatory)] [string]$DatabaseName,
    [Parameter(Mandatory)] [string]$RepoName,
    [Parameter(Mandatory)] [string]$RepoId,
    [string]$RepoProject          = 'Database-Administration-and-Monitoring',
    [string]$RequerimientoPrefijo = 'TKS',
    [string]$AdoPrProject         = 'Database-Administration-and-Monitoring',
    [string]$SqldbCoreGlobalDbRef = 'xxx',
    # PathFilter: requerido cuando dos BDs comparten repo (ej: sqldb_core_global y sqldb_core_workflow).
    # Formato: /databases/sqldb_<name>/** — el Apply handler lo aplica al trigger CI del Build.
    # Dejar vacío si el repo es exclusivo de esta BD (no se aplica filtro).
    [string]$PathFilter = '',
    [string]$SharedLibraryName    = 'Bases Datos SQL',
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$placeholderPattern = '(?i)^(change_me.*|tbd|todo|<.*>)$'

function Assert-NoPlaceholder {
    param([string]$Name, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "New-AdoClassicDatabasePlan: falta el dato obligatorio '$Name'."
    }
    if ($Value -match $placeholderPattern) {
        throw "New-AdoClassicDatabasePlan: '$Name' contiene un placeholder sin resolver ('$Value')."
    }
}

foreach ($kv in @{
    DatabaseProjectName = $DatabaseProjectName
    DatabaseName        = $DatabaseName
    RepoName            = $RepoName
    RepoId              = $RepoId
}.GetEnumerator()) {
    Assert-NoPlaceholder -Name $kv.Key -Value $kv.Value
}

$projectRoot = $env:REPO_ROOT
if ([string]::IsNullOrWhiteSpace($projectRoot)) { $projectRoot = (Get-Location).Path }

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $projectRoot '.local' 'azure-devops' 'plans'
}
if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

$buildName   = "Build_Base_Datos_$DatabaseProjectName"
$releaseName = "Deploy-Desarrollo-UAT-Produccion-Base_Datos_$DatabaseProjectName"
$folderPath  = "\BaseDatos\$DatabaseProjectName"
$artifactAlias = "_$buildName"

# Task group names for Build
$buildTaskGroupNames = @(
    'Evaluar-ventana-agrupacion',
    'Gana-el-mas-nuevo',
    'Build-DataBases',
    'Reportar-resultado-HU'
)

$plan = [PSCustomObject]@{
    family         = 'dacpac'
    pattern        = 'unified'   # 1 Build + 1 Release 3 stages (vs 'legacy': 1 Build per ambiente)
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    organization   = 'Shared-Service-GM'
    project        = 'DevOps'
    validated      = $false

    # ── NOMBRES ──────────────────────────────────────────
    names = @{
        build      = $buildName
        release    = $releaseName
        folder     = $folderPath
    }

    # ── REPO ─────────────────────────────────────────────
    repo = @{
        id         = $RepoId
        name       = $RepoName
        project    = $RepoProject
        branches   = @('development', 'uat', 'release')
    }

    # ── BUILD ─────────────────────────────────────────────
    build = @{
        agentPoolName  = '172.16.2.127-prtg'
        agentPoolId    = 393
        triggerBranches = @('+refs/heads/development', '+refs/heads/uat', '+refs/heads/release')
        pathFilter      = if ([string]::IsNullOrWhiteSpace($PathFilter)) { $null } else { "+$PathFilter" }
        taskGroups     = $buildTaskGroupNames
        variables = @{
            databaseProjectName   = $DatabaseProjectName
            BuildConfiguration    = 'Debug'
            BuildPlatform         = 'any cpu'
            BATCH_PR_TITLE_MARKER = '[AUTO]'
            BATCH_WAIT_REASONS    = 'IndividualCI,BatchedCI'
            BATCH_WINDOW_MINUTES  = '3'
            SUPERSEDE_REASONS     = 'IndividualCI,BatchedCI'
            'system.debug'        = 'false'
        }
        # Inputs para TG Build-DataBases (incluyendo literales de PS requeridos por ADO)
        buildDataBasesInputs = [ordered]@{
            'databaseProjectName'      = '$(databaseProjectName)'
            'BuildConfiguration'       = '$(BuildConfiguration)'
            'BuildPlatform'            = '$(BuildPlatform)'
            'requerimientoPrefijo'     = '$(requerimientoPrefijo)'
            'adoPrProject'             = '$(adoPrProject)'
            '$_.Exception.Message'    = '$_.Exception.Message'
            '$ordered -join , '       = '$ordered -join , '
            '$prefixes -join , '      = '$(requerimientoPrefijo)'
            '$rqCodes -join , '       = '$rqCodes -join , '
        }
    }

    # ── RELEASE ───────────────────────────────────────────
    release = @{
        artifactAlias    = $artifactAlias
        cdTriggerEnabled = $true

        # Estandar de stage (aplicado en vivo 2026-09-23 a 403 y derivados):
        #  - deployLatestAndCancel: executionPolicy.queueDepthCount=1 + concurrencyCount=1
        #    ('Deploy latest and cancel the others' — NO 'Deploy all in sequence'/queueDepthCount=0).
        #  - releaseCreatorCanApprove: preDeployApprovals.approvalOptions.releaseCreatorCanBeApprover=true
        #    (quien pide el release puede aprobar sus propios cambios; relevante solo en el stage con
        #     aprobacion real = Produccion → Release Executers).
        stages = @(
            @{
                name                     = 'Desarrollo'
                artifactBranch           = 'development'
                instanciadb              = '$(instanciadb_dev)'
                approval                 = 'auto'
                deployLatestAndCancel    = $true
                releaseCreatorCanApprove = $true
            },
            @{
                name                     = 'UAT'
                artifactBranch           = 'uat'
                instanciadb              = '$(instanciadb_uat)'
                approval                 = 'auto'
                deployLatestAndCancel    = $true
                releaseCreatorCanApprove = $true
            },
            @{
                name                     = 'Produccion'
                artifactBranch           = 'release'
                instanciadb              = '$(instanciadb_prod)'
                approval                 = 'manual'
                approverId               = '397ddbfe-1d60-4533-a4c9-b099f80ac154'
                approverName             = 'Release Executers'
                deployLatestAndCancel    = $true
                releaseCreatorCanApprove = $true
            }
        )

        variables = @{
            database            = $DatabaseName
            databaseProjectName = $DatabaseProjectName
            build               = $buildName
            mode                = @{ value = 'DryRun'; allowOverride = $true }
        }

        # Inputs para TG Deployment-DataBases (incluyendo literales de PS)
        deploymentDataBasesInputs = [ordered]@{
            'build'                           = $buildName
            'database'                        = '$(database)'
            'databaseProjectName'             = '$(databaseProjectName)'
            'instanciadb'                     = '$(instanciadb_<env>)'
            'mode'                            = '$(mode)'
            'pass_db'                         = '$(pass_db)'
            'requerimientoPrefijo'            = '$(requerimientoPrefijo)'
            'sqldb_core_global_db_reference'  = $SqldbCoreGlobalDbRef
            'usuario_db'                      = '$(usuario_db)'
            '$dup.Count'                      = '$dup.Count'
            '$dup.Name'                       = '$dup.Name'
            '$listing -join , '              = '$listing -join , '
            '$rqCodes -join , '              = '$rqCodes -join , '
        }

        deployTaskGroupEnabled = $false   # disabled por defecto, habilitar para Apply real
        requerimientoPrefijo   = $RequerimientoPrefijo
        adoPrProject           = $AdoPrProject
    }

    # ── SHARED LIBRARY ────────────────────────────────────
    sharedLibrary = @{
        name             = $SharedLibraryName
        id               = 181
        expectedExisting = $true
        note             = 'VG 181 compartido para todos los pipelines BD. Nunca se crea uno nuevo.'
    }

    # ── MODELOS DE REFERENCIA (para Apply clone+mutate) ───
    referenceModels = @{
        buildId   = 647   # Build_Base_Datos_sqldb_buklo_lab
        releaseId = 403   # Deploy-Desarrollo-UAT-Produccion-Base_Datos_sqldb_buklo_lab
        note      = 'Apply-AdoClassicPlan clona estos modelos y muta solo los campos especificos de la BD.'
    }

    # ── DEPENDENCIAS (para Test-AdoClassicPlan) ──────────
    dependencies = @{
        buildTaskGroups = @($buildTaskGroupNames | ForEach-Object { @{ name = $_; id = $null; revision = $null } })
        deployTaskGroup = @{ name = 'Deployment-DataBases'; id = $null; revision = $null }
        agentPool       = @{ name = '172.16.2.127-prtg'; id = 393 }
        sharedLibrary   = @{ name = $SharedLibraryName; id = 181 }
    }

    # Manifiesto de escrituras: vacio hasta que Apply-AdoClassicPlan lo ejecute.
    approvedOperations = @()

    notes = @(
        'Plan generado sin ejecutar ningun cambio en Azure DevOps.',
        'TG Deployment-DataBases disabled por defecto. mode=DryRun — ningun SQL se ejecuta hasta habilitar el TG y cambiar mode=Apply.',
        'Para aplicar: habilitar TG Deployment-DataBases en el stage deseado + cambiar mode=Apply en esa ejecucion del Release.',
        'Estandar de release (aplicado en vivo 2026-09-23): cada stage con artifact filter por branch (dev/uat/release), executionPolicy queueDepthCount=1+concurrencyCount=1 (Deploy latest and cancel others), y preDeployApprovals.releaseCreatorCanBeApprover=true.'
    )
}

$outFile = Join-Path $OutDir ("dacpac-$DatabaseProjectName-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss')).ToLowerInvariant()
$plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outFile -Encoding utf8

Write-Host "Plan DACPAC unificado (sin validar todavia) escrito en: $outFile" -ForegroundColor Green
Write-Host "Build: $buildName" -ForegroundColor Cyan
Write-Host "Release: $releaseName" -ForegroundColor Cyan
Write-Host "Siguiente paso: Test-AdoClassicPlan.ps1 -PlanPath '$outFile'" -ForegroundColor Yellow
