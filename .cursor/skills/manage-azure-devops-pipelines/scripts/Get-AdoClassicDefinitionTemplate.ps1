<#
Lee (GET, solo lectura) el body COMPLETO de una definicion clasica de
Build o Release existente, para usarla como plantilla real al implementar
Apply-AdoClassicPlan.ps1. Nunca escribe nada en Azure DevOps. Escribe el
body crudo (SIN sanitizar) unicamente en -OutDir, para inspeccion humana
puntual -- ese archivo crudo NUNCA debe commitearse ni quedar en
.local/azure-devops/ (puede contener nombres de variables reales, ids
internos, etc. aunque Azure DevOps no devuelve valores de variables
isSecret=true via GET). La version sanitizada para uso como plantilla
reusable se documenta aparte, a mano, revisando este archivo.

Uso:
  powershell -File .\Get-AdoClassicDefinitionTemplate.ps1 -Kind Build -DefinitionId 578 -OutDir 'C:\ruta\temporal'
  powershell -File .\Get-AdoClassicDefinitionTemplate.ps1 -Kind Release -DefinitionId 360 -OutDir 'C:\ruta\temporal'
#>

param(
    [Parameter(Mandatory)] [ValidateSet('Build', 'Release', 'TaskGroup', 'VariableGroup')] [string]$Kind,
    [Parameter(Mandatory)] [string]$DefinitionId,
    [string]$Project = 'DevOps',
    [Parameter(Mandatory)] [string]$OutDir
)

$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoRest.ps1')

if (-not (Test-Path -LiteralPath $OutDir)) {
    New-Item -ItemType Directory -Force -Path $OutDir | Out-Null
}

if ($Kind -eq 'Build') {
    $uri = "$($script:AdoCoreBaseUrl)/$Project/_apis/build/definitions/$DefinitionId`?api-version=$($script:AdoApiVersion)"
}
elseif ($Kind -eq 'Release') {
    $uri = "$($script:AdoReleaseBaseUrl)/$Project/_apis/release/definitions/$DefinitionId`?api-version=$($script:AdoApiVersion)"
}
elseif ($Kind -eq 'TaskGroup') {
    $uri = "$($script:AdoCoreBaseUrl)/$Project/_apis/distributedtask/taskgroups/$DefinitionId`?api-version=$($script:AdoApiVersion)"
}
else {
    $uri = "$($script:AdoCoreBaseUrl)/$Project/_apis/distributedtask/variablegroups/$DefinitionId`?api-version=$($script:AdoApiVersion)"
}

Write-Host "GET (solo lectura) $Kind $DefinitionId ..." -ForegroundColor Cyan
$result = Invoke-AdoRest -Method GET -Uri $uri

$outFile = Join-Path $OutDir ("raw-{0}-{1}-{2}.json" -f $Kind.ToLowerInvariant(), ($DefinitionId -replace '[^a-zA-Z0-9]', ''), (Get-Date -Format 'yyyyMMdd-HHmmss'))
$result.Body | ConvertTo-Json -Depth 40 | Set-Content -LiteralPath $outFile -Encoding utf8

Write-Host "Body crudo (SIN sanitizar) escrito en: $outFile" -ForegroundColor Yellow
Write-Host "Este archivo es solo para inspeccion humana puntual -- NO commitear, NO dejar en .local/azure-devops/." -ForegroundColor Yellow
