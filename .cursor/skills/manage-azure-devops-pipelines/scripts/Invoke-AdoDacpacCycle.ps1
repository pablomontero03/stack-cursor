<#
Orquestador del ciclo agentico completo para pipelines BD (dacpac/unified).
Ejecuta en secuencia: Generate Plan -> Apply -> Queue Build -> Wait Build ->
Activate UAT Stage -> Wait UAT.

Este script es el entrypoint unico para el ado-pipeline-builder en el ciclo BD.
Sustituye llamar a cada script por separado y cierra el 100% del ciclo
agentico sin intervencion del coordinador.

Uso:
  pwsh -File Invoke-AdoDacpacCycle.ps1 `
    -DatabaseProjectName 'sqldb_ejemplo' `
    -DatabaseName 'sqldb_ejemplo' `
    -RepoName 'project_sqldb_ejemplo' `
    -RepoId '<guid>' `
    -RepoProject 'Database-Administration-and-Monitoring' `
    [-SqldbCoreGlobalDbRef 'xxx'] `
    [-PathFilter '/databases/sqldb_ejemplo/**'] `
    [-BuildTimeoutMinutes 30] `
    [-UatTimeoutMinutes 20]
#>

param(
    [Parameter(Mandatory)] [string] $DatabaseProjectName,
    [Parameter(Mandatory)] [string] $DatabaseName,
    [Parameter(Mandatory)] [string] $RepoName,
    [Parameter(Mandatory)] [string] $RepoId,
    [Parameter(Mandatory)] [string] $RepoProject,
    [string] $SqldbCoreGlobalDbRef = 'xxx',
    [string] $PathFilter           = '',
    [string] $RequerimientoPrefijo = 'TKS',
    [string] $AdoPrProject         = 'Database-Administration-and-Monitoring',
    [int]    $BuildTimeoutMinutes  = 30,
    [int]    $UatTimeoutMinutes    = 20,
    [string] $OutDir
)

$ErrorActionPreference = 'Stop'
$scriptRoot = $PSScriptRoot

# Resolver REPO_ROOT
$repoRoot = $env:REPO_ROOT
if ([string]::IsNullOrWhiteSpace($repoRoot)) { $repoRoot = (Get-Item $scriptRoot).Parent.Parent.Parent.Parent.FullName }

if ([string]::IsNullOrWhiteSpace($OutDir)) {
    $OutDir = Join-Path $repoRoot '.local' 'azure-devops' 'plans'
}

Write-Host "=== Ciclo BD agéntico: $DatabaseProjectName ===" -ForegroundColor Cyan
Write-Host "Repo: $RepoName ($RepoId)" -ForegroundColor Cyan

# ── Paso 1: Generar plan ──────────────────────────────────────────────────────
Write-Host "`n[1/5] Generando plan..." -ForegroundColor Yellow
$genArgs = @{
    DatabaseProjectName  = $DatabaseProjectName
    DatabaseName         = $DatabaseName
    RepoName             = $RepoName
    RepoId               = $RepoId
    RepoProject          = $RepoProject
    SqldbCoreGlobalDbRef = $SqldbCoreGlobalDbRef
    RequerimientoPrefijo = $RequerimientoPrefijo
    AdoPrProject         = $AdoPrProject
    OutDir               = $OutDir
}
if (-not [string]::IsNullOrWhiteSpace($PathFilter)) {
    $genArgs['PathFilter'] = $PathFilter
}
& (Join-Path $scriptRoot 'New-AdoClassicDatabasePlan.ps1') @genArgs

# Localizar el plan recién generado
$planPath = Get-ChildItem $OutDir -Filter "dacpac-$DatabaseProjectName-*.json" |
    Sort-Object LastWriteTime -Descending | Select-Object -First 1 -ExpandProperty FullName
if (-not $planPath) { throw "No se encontró el plan generado para $DatabaseProjectName en $OutDir" }
Write-Host "  Plan: $planPath" -ForegroundColor Cyan

# ── Paso 2: Apply (crear Build + Release en ADO) ──────────────────────────────
Write-Host "`n[2/5] Ejecutando Apply (clone+mutate)..." -ForegroundColor Yellow
$applyResult = & (Join-Path $scriptRoot 'Apply-AdoClassicPlan.ps1') `
    -PlanPath $planPath -InventoryPath $planPath 6>&1 2>&1
$applyResult | ForEach-Object { Write-Host "  $_" }

# Leer ids del plan actualizado por Apply
$plan = Get-Content $planPath -Raw | ConvertFrom-Json
$buildId   = $plan.createdResources.buildId
$releaseDefId = $plan.createdResources.releaseId
$artifactAlias = "_Build_Base_Datos_$DatabaseProjectName"

# Fallback: leer del output si Apply no escribió en el plan
if (-not $buildId) {
    $buildLine = $applyResult | Where-Object { $_ -match 'Build creado.*id=(\d+)' } | Select-Object -First 1
    if ($buildLine -match 'id=(\d+)') { $buildId = [int]$Matches[1] }
}
if (-not $releaseDefId) {
    $relLine = $applyResult | Where-Object { $_ -match 'Release creado.*id=(\d+)' } | Select-Object -First 1
    if ($relLine -match 'id=(\d+)') { $releaseDefId = [int]$Matches[1] }
}
if (-not $buildId -or -not $releaseDefId) {
    throw "No se pudieron leer Build id y Release id del output de Apply. Output: $($applyResult -join '; ')"
}
Write-Host "  Build definición id=$buildId  Release definición id=$releaseDefId" -ForegroundColor Green

# ── Paso 3: Encolar build desde uat ───────────────────────────────────────────
Write-Host "`n[3/5] Encolando build desde uat..." -ForegroundColor Yellow
$queueResult = & (Join-Path $scriptRoot 'Invoke-AdoQueueBuild.ps1') `
    -BuildDefinitionId $buildId -SourceBranch 'refs/heads/uat'
$queuedBuildId = $queueResult.buildId
Write-Host "  Build encolado: id=$queuedBuildId" -ForegroundColor Green

# ── Paso 4: Esperar que el build complete ─────────────────────────────────────
Write-Host "`n[4/5] Esperando build $queuedBuildId (timeout=${BuildTimeoutMinutes}m)..." -ForegroundColor Yellow
$buildResult = & (Join-Path $scriptRoot 'Wait-AdoClassicRun.ps1') `
    -Kind Build -Id $queuedBuildId -Project DevOps `
    -IntervalSeconds 30 -TimeoutMinutes $BuildTimeoutMinutes | Out-Null

# Verificar el resultado directamente por REST (evita el problema de ConvertFrom-Json
# cuando Wait-AdoClassicRun mezcla Write-Host con el JSON de salida)
Write-Host "  Verificando resultado de build ${queuedBuildId}..." -ForegroundColor Cyan
$pat = $env:AZURE_DEVOPS_PAT
$authHeader = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat")))"
$buildStatus = $null
$retries = 3
for ($i = 0; $i -lt $retries; $i++) {
    $req = [System.Net.WebRequest]::Create("https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/builds/${queuedBuildId}?api-version=7.1")
    $req.Headers.Add('Authorization', $authHeader)
    $resp = $req.GetResponse()
    $reader = [IO.StreamReader]::new($resp.GetResponseStream())
    $buildStatus = $reader.ReadToEnd() | ConvertFrom-Json
    $reader.Close(); $resp.Close()
    if (-not [string]::IsNullOrWhiteSpace($buildStatus.result)) { break }
    Write-Host "  result aun vacio (intento $($i+1)/$retries) — esperando 10s..." -ForegroundColor Yellow
    Start-Sleep -Seconds 10
}
Write-Host "  Build ${queuedBuildId}: status=$($buildStatus.status) result=$($buildStatus.result)" -ForegroundColor Cyan
if ($buildStatus.result -ne 'succeeded') {
    throw "Build $queuedBuildId termino con result=$($buildStatus.result). Ciclo BD abortado."
}
Write-Host "  Build succeeded." -ForegroundColor Green

# ── Paso 5: Crear Release + activar UAT ──────────────────────────────────────
Write-Host "`n[5/5] Activando stage UAT (Release def=$releaseDefId)..." -ForegroundColor Yellow
$uatResult = & (Join-Path $scriptRoot 'Invoke-AdoActivateReleaseStage.ps1') `
    -ReleaseDefinitionId $releaseDefId `
    -BuildId $queuedBuildId `
    -ArtifactAlias $artifactAlias `
    -StageName UAT `
    -WaitForCompletion `
    -TimeoutMinutes $UatTimeoutMinutes `
    -IntervalSeconds 30

Write-Host "  Release $($uatResult.releaseId) / UAT $($uatResult.stageStatus)" -ForegroundColor $(if ($uatResult.stageStatus -eq 'succeeded') {'Green'} else {'Red'})

if ($uatResult.stageStatus -ne 'succeeded') {
    throw "UAT terminó con status=$($uatResult.stageStatus)."
}

Write-Host "`n✅ Ciclo BD agéntico completo: $DatabaseProjectName" -ForegroundColor Green
Write-Host "   Build def=$buildId  Release def=$releaseDefId  Build run=$queuedBuildId  Release=$($uatResult.releaseId)" -ForegroundColor Cyan

[PSCustomObject]@{
    databaseProjectName = $DatabaseProjectName
    buildDefinitionId   = $buildId
    releaseDefinitionId = $releaseDefId
    buildRunId          = $queuedBuildId
    releaseInstanceId   = $uatResult.releaseId
    uatStatus           = $uatResult.stageStatus
    planPath            = $planPath
}
