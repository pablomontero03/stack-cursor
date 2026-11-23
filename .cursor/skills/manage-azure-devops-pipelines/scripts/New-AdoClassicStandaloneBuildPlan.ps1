<#
Genera el esqueleto de plan JSON sanitizado para un Build clasico
STANDALONE (family='standalone-build'): sin familia AKS/DACPAC, sin
Release, sin Variable Group -- pensado para casos como una politica de
"Build Validation" de Pull Request. Nunca ejecuta ningun cambio en Azure
DevOps -- solo escribe el plan bajo .local/azure-devops/plans/ para que
Test-AdoClassicPlan.ps1 lo valide (resuelve repo.id contra el inventario
del PROYECTO EXACTO indicado, que puede ser distinto de 'DevOps') y
New-AdoClassicCreatePlan.ps1 -Kind StandaloneBuild pueble despues
approvedOperations.

Agregado 2026-08-27 (gap identificado armando
Build-Validation-buklo-backend, ver memoria de agente
ado-pipeline-builder: "Gap real de capacidad"). Paralelo a
New-AdoClassicAksPlan.ps1/New-AdoClassicDatabasePlan.ps1 -- no los
modifica, no comparte campos especificos de esas 2 familias (dockerfile,
buildVariables, mergeBatching, release, variableGroup, dependencies de
task groups Docker/AKS).

Uso:
  powershell -File .\New-AdoClassicStandaloneBuildPlan.ps1 `
    -Project 'Buklo' -BuildName 'Build-Validation-buklo-backend' `
    -RepoName 'buklo-backend' -DefaultBranch 'development'
#>

param(
    [Parameter(Mandatory)] [string]$Project,
    [Parameter(Mandatory)] [string]$BuildName,
    [Parameter(Mandatory)] [string]$RepoName,
    [Parameter(Mandatory)] [string]$DefaultBranch,
    [string]$RepoProject,
    [string]$FolderPath = '\\',
    [string]$Notes,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$placeholderPattern = '(?i)^(change_me.*|xxx+|tbd|todo|<.*>)$'

function Assert-NoPlaceholder {
    param([string]$Name, [string]$Value)
    if ([string]::IsNullOrWhiteSpace($Value)) {
        throw "New-AdoClassicStandaloneBuildPlan: falta el dato obligatorio '$Name'."
    }
    if ($Value -match $placeholderPattern) {
        throw "New-AdoClassicStandaloneBuildPlan: '$Name' contiene un placeholder sin resolver ('$Value')."
    }
}

foreach ($kv in @{ Project = $Project; BuildName = $BuildName; RepoName = $RepoName; DefaultBranch = $DefaultBranch }.GetEnumerator()) {
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

$plan = [ordered]@{
    family        = 'standalone-build'
    organization  = 'Shared-Service-GM'
    project       = $Project
    names         = [ordered]@{ build = $BuildName; folder = $FolderPath }
    repo          = [ordered]@{
        name       = $RepoName
        prodBranch = $DefaultBranch
    }
    dependencies  = [ordered]@{}
    notes         = $(if ($Notes) { $Notes } else { '' })
    approvedOperations = @()
    validated     = $false
    validationHash = $null
    validationEvidence = $null
}
if (-not [string]::IsNullOrWhiteSpace($RepoProject)) {
    $plan.repo['project'] = $RepoProject
}

$safeProject = ($Project -replace '[^A-Za-z0-9_.-]', '_').ToLowerInvariant()
$safeBuildName = ($BuildName -replace '[^A-Za-z0-9_.-]', '_').ToLowerInvariant()
$outFile = Join-Path $OutDir ("standalone-build-$safeProject-$safeBuildName-{0}.json" -f (Get-Date -Format 'yyyyMMdd-HHmmss'))
$plan | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $outFile -Encoding utf8

Write-Host "Plan Build standalone (sin validar todavia) escrito en: $outFile" -ForegroundColor Green
Write-Host "Siguiente paso: New-AdoClassicCreatePlan.ps1 -Kind StandaloneBuild -InputPlanPath '$outFile' -OutPlanPath '...' -OperationId '...' -StepsSpecPath '...'" -ForegroundColor Yellow
Write-Host "Despues: Test-AdoClassicPlan.ps1 -PlanPath '...' -InventoryPath '...' (resuelve repo.id contra el inventario REAL del proyecto '$Project')." -ForegroundColor Yellow
