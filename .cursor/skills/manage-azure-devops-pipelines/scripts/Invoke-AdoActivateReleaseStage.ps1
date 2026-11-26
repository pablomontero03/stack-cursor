<#
Crea una instancia de Release a partir de un Build exitoso y activa un stage
especifico (por defecto UAT). Allowlisted para ado-pipeline-builder en el
ciclo agentico BD.

Restricciones:
  - Solo activa stages de Desarrollo o UAT. Produccion siempre requiere
    aprobacion separada y este script la rechaza.
  - No aprueba gates, no cambia definiciones, no modifica task groups.
  - Solo opera sobre definiciones de Release de familia dacpac/unified
    (no puede activar releases de pipelines AKS).

Uso:
  pwsh -File Invoke-AdoActivateReleaseStage.ps1 `
    -ReleaseDefinitionId 413 `
    -BuildId 22545 `
    -ArtifactAlias '_Build_Base_Datos_sqldb_core_module' `
    -StageName 'UAT' `
    -WaitForCompletion `
    -TimeoutMinutes 20
#>

param(
    [Parameter(Mandatory)] [int]    $ReleaseDefinitionId,
    [Parameter(Mandatory)] [int]    $BuildId,
    [Parameter(Mandatory)] [string] $ArtifactAlias,
    [string] $StageName        = 'UAT',
    [switch] $WaitForCompletion,
    [int]    $TimeoutMinutes   = 20,
    [int]    $IntervalSeconds  = 30
)

$ErrorActionPreference = 'Stop'

$allowedStages = @('Desarrollo', 'UAT')
if ($StageName -notin $allowedStages) {
    throw "Invoke-AdoActivateReleaseStage rechazado: StageName='$StageName' no está en la lista permitida ($($allowedStages -join ', ')). Producción requiere aprobación separada."
}

# Resolver PAT
$pat = $env:AZURE_DEVOPS_PAT
if ([string]::IsNullOrWhiteSpace($pat)) {
    $envFile = Join-Path $PSScriptRoot '..' '..' '..' '..' 'env' '.env'
    if (Test-Path $envFile) {
        $pat = (Get-Content $envFile | Where-Object { $_ -match '^AZURE_DEVOPS_PAT=' }) -replace '^AZURE_DEVOPS_PAT=',''
    }
}
if ([string]::IsNullOrWhiteSpace($pat)) {
    throw "Invoke-AdoActivateReleaseStage: no se encontró AZURE_DEVOPS_PAT."
}

$auth  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$base  = "https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis"

function Invoke-Rest {
    param([string]$Method, [string]$Uri, [object]$Body = $null)
    $req = [System.Net.WebRequest]::Create($Uri)
    $req.Method = $Method
    $req.ContentType = 'application/json'
    $req.Headers.Add('Authorization', "Basic $auth")
    if ($null -ne $Body) {
        $bytes = [Text.Encoding]::UTF8.GetBytes(($Body | ConvertTo-Json -Depth 10 -Compress))
        $req.ContentLength = $bytes.Length
        $req.GetRequestStream().Write($bytes, 0, $bytes.Length)
    }
    $resp = $req.GetResponse()
    $reader = [IO.StreamReader]::new($resp.GetResponseStream())
    $result = $reader.ReadToEnd() | ConvertFrom-Json
    $reader.Close(); $resp.Close()
    return $result
}

# 1. Verificar si ya existe un Release para esta definición con este build
Write-Host "Verificando releases existentes para definición $ReleaseDefinitionId..." -ForegroundColor Yellow
$existing = Invoke-Rest -Method GET -Uri "$base/release/releases?definitionId=$ReleaseDefinitionId&`$top=5&api-version=7.1"
$releaseId = $null

foreach ($r in $existing.value) {
    foreach ($a in $r.artifacts) {
        if ($a.alias -eq $ArtifactAlias -and [int]$a.instanceReference.id -eq $BuildId) {
            $releaseId = $r.id
            Write-Host "  Release existente encontrado: id=$releaseId" -ForegroundColor Cyan
            break
        }
    }
    if ($releaseId) { break }
}

# 2. Si no existe, crear el Release
if (-not $releaseId) {
    Write-Host "Creando Release desde Build $BuildId..." -ForegroundColor Yellow
    $body = @{
        definitionId = $ReleaseDefinitionId
        description  = "Agentic cycle — build $BuildId"
        artifacts    = @(@{
            alias             = $ArtifactAlias
            instanceReference = @{ id = [string]$BuildId }
        })
        isDraft = $false
    }
    $newRelease = Invoke-Rest -Method POST -Uri "$base/release/releases?api-version=7.1" -Body $body
    $releaseId = $newRelease.id
    Write-Host "  Release creado: id=$releaseId" -ForegroundColor Green
    Start-Sleep -Seconds 3
}

# 3. Obtener el id del stage y su estado actual
$rel = Invoke-Rest -Method GET -Uri "$base/release/releases/$releaseId`?api-version=7.1"
$env = $rel.environments | Where-Object { $_.name -eq $StageName }
if (-not $env) {
    throw "Invoke-AdoActivateReleaseStage: no se encontró el stage '$StageName' en Release $releaseId."
}

Write-Host "Stage '$StageName' status=$($env.status)" -ForegroundColor Cyan

if ($env.status -eq 'succeeded') {
    Write-Host "Stage '$StageName' ya está succeeded." -ForegroundColor Green
} elseif ($env.status -eq 'notStarted') {
    # 4. Activar el stage
    Write-Host "Activando stage '$StageName'..." -ForegroundColor Yellow
    Invoke-Rest -Method PATCH -Uri "$base/release/releases/$releaseId/environments/$($env.id)?api-version=7.1" `
        -Body @{ status = 'inProgress' } | Out-Null
    Write-Host "  Stage activado." -ForegroundColor Green
} elseif ($env.status -in @('inProgress', 'queued')) {
    Write-Host "Stage '$StageName' ya está en progreso." -ForegroundColor Cyan
}

# 5. Esperar si se solicitó
if ($WaitForCompletion) {
    Write-Host "Esperando que '$StageName' complete (timeout=${TimeoutMinutes}m)..." -ForegroundColor Yellow
    $deadline = (Get-Date).AddMinutes($TimeoutMinutes)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds $IntervalSeconds
        $rel = Invoke-Rest -Method GET -Uri "$base/release/releases/$releaseId`?api-version=7.1"
        $env = $rel.environments | Where-Object { $_.name -eq $StageName }
        Write-Host "  $StageName status=$($env.status)" -ForegroundColor Cyan
        if ($env.status -in @('succeeded', 'failed', 'canceled', 'partiallySucceeded')) { break }
    }
    if ($env.status -ne 'succeeded') {
        throw "Invoke-AdoActivateReleaseStage: stage '$StageName' terminó con status=$($env.status) (esperado: succeeded)."
    }
    Write-Host "Stage '$StageName' succeeded." -ForegroundColor Green
}

[PSCustomObject]@{
    releaseId   = $releaseId
    stageName   = $StageName
    stageStatus = $env.status
    buildId     = $BuildId
}
