<#
Inventario de solo lectura (GET puro) de las Branch Policies (Policy
Configurations) de un repositorio de Azure DevOps, Shared-Service-GM.

Parte de la capacidad futura "pr-policy-admin" mencionada en
.kiro/rules/azure-devops-permissions/authorization.md -- primer paso
(inventario) antes de un plan actual->deseado. No escribe nada.

Reutiliza Invoke-AdoPermissionsRest.ps1 (dot-source interno, nunca
invocado directo desde shell) -- GET no requiere plan aprobado, solo
pasa por Assert-AdoPermissionsAllowedUri (host dev.azure.com/
vssps.dev.azure.com, ruta bajo /Shared-Service-GM/).

Uso:
  & '.\Export-AdoPolicyInventory.ps1' -ProjectName 'Buklo' -RepositoryId '0550ab98-7959-45ee-8361-18b8e4df22a3' -OutFile '...\source-policies.json'
#>

param(
    [Parameter(Mandatory)]
    [string]$ProjectName,

    [Parameter(Mandatory)]
    [ValidatePattern('^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$')]
    [string]$RepositoryId,

    [string]$OutFile
)

$ErrorActionPreference = 'Stop'

. (Join-Path $PSScriptRoot 'Invoke-AdoPermissionsRest.ps1')

$encodedProject = [uri]::EscapeDataString($ProjectName)
$baseUri = "https://dev.azure.com/Shared-Service-GM/$encodedProject/_apis/policy/configurations?repositoryId=$RepositoryId&api-version=7.1"

$result = Get-AdoPermissionsRestAllPages -BaseUri $baseUri

$normalized = @($result.Items | ForEach-Object {
        $scopes = @()
        if ($_.settings -and $_.settings.scope) {
            $scopes = @($_.settings.scope | ForEach-Object {
                    [ordered]@{
                        repositoryId = $_.repositoryId
                        refName      = $_.refName
                        matchKind    = $_.matchKind
                    }
                })
        }

        [ordered]@{
            id            = $_.id
            isEnabled     = $_.isEnabled
            isBlocking    = $_.isBlocking
            isDeleted     = $_.isDeleted
            type          = [ordered]@{
                id          = $_.type.id
                displayName = $_.type.displayName
            }
            settingsRaw   = $_.settings
            scope         = $scopes
            createdDate   = $_.createdDate
            revision      = $_.revision
            url           = $_.url
        }
    })

$inventory = [ordered]@{
    schemaVersion  = 1
    exportedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    organization   = 'Shared-Service-GM'
    project        = $ProjectName
    repositoryId   = $RepositoryId
    pagesFetched   = $result.PagesFetched
    policyCount    = $normalized.Count
    policies       = $normalized
}

$json = $inventory | ConvertTo-Json -Depth 20

if ($OutFile) {
    $dir = Split-Path -Parent $OutFile
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }
    [System.IO.File]::WriteAllText($OutFile, $json, [System.Text.UTF8Encoding]::new($false))
    Write-Output "Inventario guardado en: $OutFile ($($normalized.Count) policy configurations)"
}
else {
    Write-Output $json
}
