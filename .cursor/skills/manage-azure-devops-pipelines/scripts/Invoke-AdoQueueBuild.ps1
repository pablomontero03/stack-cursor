<#
Encola una ejecucion de build en Azure DevOps.

Script allowlisted para ado-pipeline-builder en el ciclo agentico BD y AKS:
permite encolar el primer build de prueba sin llamar Invoke-AdoRest.ps1
directamente.

Restricciones:
  - Solo encola; nunca aprueba stages, crea releases ni modifica definiciones.
  - SourceBranch debe ser 'refs/heads/development', 'refs/heads/uat' o
    'refs/heads/release' — cualquier otro valor es rechazado.
  - Solo encola builds de definiciones que existan en el proyecto DevOps de
    Shared-Service-GM.
  - Produccion: no esta prohibida por este script pero la approval-matrix
    exige aprobacion separada para despliegues a Produccion; encolar un build
    desde 'release' es valido (es solo compilacion, no despliegue).

Uso:
  pwsh -File Invoke-AdoQueueBuild.ps1 `
    -BuildDefinitionId 652 `
    -SourceBranch 'refs/heads/uat'
#>

param(
    [Parameter(Mandatory)] [int]    $BuildDefinitionId,
    [Parameter(Mandatory)] [string] $SourceBranch,
    [string] $Parameters = '{}'
)

$ErrorActionPreference = 'Stop'

$allowedBranches = @('refs/heads/development','refs/heads/uat','refs/heads/release')
if ($SourceBranch -notin $allowedBranches) {
    throw "Invoke-AdoQueueBuild rechazado: SourceBranch='$SourceBranch' no esta en la lista permitida ($($allowedBranches -join ', '))."
}
if ($BuildDefinitionId -le 0) {
    throw "Invoke-AdoQueueBuild rechazado: BuildDefinitionId debe ser mayor que 0."
}

# Resolver PAT
$pat = $env:AZURE_DEVOPS_PAT
if ([string]::IsNullOrWhiteSpace($pat)) {
    $envFile = Join-Path (Split-Path $PSScriptRoot -Parent) '..' '..' '..' 'env' '.env'
    if (Test-Path $envFile) {
        $pat = (Get-Content $envFile | Where-Object { $_ -match '^AZURE_DEVOPS_PAT=' }) -replace '^AZURE_DEVOPS_PAT=',''
    }
}
if ([string]::IsNullOrWhiteSpace($pat)) {
    throw "Invoke-AdoQueueBuild: no se encontro AZURE_DEVOPS_PAT en el entorno ni en env/.env."
}

$auth  = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$uri   = "https://dev.azure.com/Shared-Service-GM/DevOps/_apis/build/builds?api-version=7.1"
$body  = @{
    definition   = @{ id = $BuildDefinitionId }
    sourceBranch = $SourceBranch
    reason       = 1
    parameters   = $Parameters
} | ConvertTo-Json -Compress

$req = [System.Net.WebRequest]::Create($uri)
$req.Method      = 'POST'
$req.ContentType = 'application/json'
$req.Headers.Add('Authorization', "Basic $auth")
$bytes = [Text.Encoding]::UTF8.GetBytes($body)
$req.ContentLength = $bytes.Length
$req.GetRequestStream().Write($bytes, 0, $bytes.Length)

$resp = $req.GetResponse()
$reader = [IO.StreamReader]::new($resp.GetResponseStream())
$result = $reader.ReadToEnd() | ConvertFrom-Json
$reader.Close()
$resp.Close()

Write-Host "Build encolado: id=$($result.id) status=$($result.status) branch=$($result.sourceBranch)" -ForegroundColor Green
Write-Host "  buildNumber=$($result.buildNumber)" -ForegroundColor Cyan
Write-Host "  queueTime=$($result.queueTime)" -ForegroundColor Cyan

[PSCustomObject]@{
    buildId      = $result.id
    status       = $result.status
    sourceBranch = $result.sourceBranch
    buildNumber  = $result.buildNumber
}
