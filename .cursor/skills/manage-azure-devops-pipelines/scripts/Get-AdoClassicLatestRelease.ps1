<#
GET de solo lectura: la instancia de Release mas reciente de una
definicion clasica dada (para confirmar si un trigger CD de artifactSource
ya disparo una instancia despues de un Build exitoso). Nunca escribe.
Gap real encontrado 2026-09-07: la API de Release Management clasica no
esta cubierta por el MCP oficial, y no existia ningun script autorizado
para esta consulta puntual (solo para status de una instancia YA
conocida, via Ado-RunPolling-Common.ps1).

Uso:
  powershell -File .\Get-AdoClassicLatestRelease.ps1 -DefinitionId 390 -Project DevOps
#>

param(
    [Parameter(Mandatory)] [int]$DefinitionId,
    [string]$Project = 'DevOps',
    [int]$Top = 5
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Invoke-AdoRest.ps1')

$uri = "$($script:AdoReleaseBaseUrl)/$Project/_apis/release/releases?definitionId=$DefinitionId&`$top=$Top&queryOrder=descending&api-version=$($script:AdoApiVersion)"
$body = (Invoke-AdoRest -Method GET -Uri $uri).Body

if (-not $body -or -not $body.value -or @($body.value).Count -eq 0) {
    [PSCustomObject]@{ definitionId = $DefinitionId; found = $false; releases = @() } | ConvertTo-Json -Depth 10
    return
}

$releases = @($body.value | ForEach-Object {
        [PSCustomObject]@{
            id            = $_.id
            name          = $_.name
            status        = $_.status
            createdOn     = $_.createdOn
            environments  = @($_.environments | ForEach-Object { [PSCustomObject]@{ id = $_.id; name = $_.name; status = $_.status } })
        }
    })

[PSCustomObject]@{ definitionId = $DefinitionId; found = $true; releases = $releases } | ConvertTo-Json -Depth 10
