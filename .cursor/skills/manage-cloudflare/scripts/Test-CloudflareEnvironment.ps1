<#
Diagnostico de solo lectura del entorno Cloudflare: existencia (booleana,
nunca el valor) de CLOUDFLARE_API_TOKEN, si .mcp.json declara el servidor
cloudflare-api, y -- solo si hay token -- una verificacion de conectividad
real contra el endpoint oficial de solo verificacion de tokens. Nunca falla
si no hay token: reporta el hallazgo y sigue.
#>
param()

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cloudflare-Common.ps1')

$hasToken = -not [string]::IsNullOrWhiteSpace([Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN'))

$mcpDeclared = $false
$mcpJsonPath = Join-Path (Get-CloudflareProjectRoot) '.mcp.json'
if (Test-Path -LiteralPath $mcpJsonPath) {
    try {
        $mcpConfig = Get-Content -LiteralPath $mcpJsonPath -Raw | ConvertFrom-Json
        $mcpDeclared = $null -ne $mcpConfig.mcpServers.'cloudflare-api'
    }
    catch {
        Write-Warning "No se pudo parsear .mcp.json para verificar el servidor cloudflare-api."
    }
}

$tokenVerification = $null
if ($hasToken) {
    $verifyResponse = Invoke-CloudflareApiRequest -Method GET -Uri "$(Get-CloudflareApiBaseUri)/user/tokens/verify"
    if ($verifyResponse -and $verifyResponse.success) {
        $tokenVerification = [PSCustomObject]@{
            status  = [string]$verifyResponse.result.status
            checked = $true
        }
    }
    else {
        $tokenVerification = [PSCustomObject]@{ status = 'unknown'; checked = $false }
    }
}

[PSCustomObject]@{
    cloudflareApiTokenConfigured = $hasToken
    mcpCloudflareApiDeclared     = $mcpDeclared
    tokenVerification            = $tokenVerification
    checkedAtUtc                 = (Get-Date).ToUniversalTime().ToString('o')
} | ConvertTo-Json -Depth 5
