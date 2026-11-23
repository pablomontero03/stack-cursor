<#
Wrapper delgado de solo lectura sobre Invoke-CloudflareApiRequest. Exige
-Method GET o HEAD -- cualquier otro valor lanza una excepcion antes de
llamar a la API. Este script nunca escribe: es la barrera que usan
Get-CloudflareInventory.ps1 y cualquier consulta de solo lectura de este
dominio.
#>
param(
    [Parameter(Mandatory)] [ValidateSet('GET', 'HEAD')] [string]$Method,
    [Parameter(Mandatory)] [string]$Uri
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cloudflare-Common.ps1')

Invoke-CloudflareApiRequest -Method $Method -Uri $Uri
