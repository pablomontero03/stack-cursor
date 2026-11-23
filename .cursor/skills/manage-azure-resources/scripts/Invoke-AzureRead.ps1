<#
Wrapper de una consulta `az` de solo lectura (show/list/get, o
`az rest --method get`), con argv tokenizado -- nunca una linea de shell
cruda. Uso pensado para diagnostico puntual de un recurso especifico cuando
Get-AzureInventory.ps1 (Resource Graph) no alcanza (ej. un sub-recurso sin
soportar en Graph, o `az rest` GET contra un endpoint sin CLI dedicado).

Rechaza cualquier verbo que no sea de lectura -- este script nunca escribe.

Uso:
  & '.\Invoke-AzureRead.ps1' -Argv @('vm','show','-g','rg1','-n','vm1')
  & '.\Invoke-AzureRead.ps1' -Argv @('rest','--method','get','--url','https://management.azure.com/subscriptions/.../providers/...?api-version=2023-01-01')
#>
param([Parameter(Mandatory)] [string[]]$Argv)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Azure-Common.ps1')

$joined = ($Argv -join ' ').ToLowerInvariant()

$mutatingVerbs = @(
    'create', 'update', 'delete', 'set', 'add', 'remove', 'restart', 'start',
    'stop', 'deallocate', 'reset', 'rotate', 'assign', 'grant', 'revoke',
    'purge', 'lock', 'deny', 'enable', 'disable', 'move', 'import', 'export',
    'apply', 'deploy', 'push', 'upload', 'restore', 'failover'
)
foreach ($verb in $mutatingVerbs) {
    if ($joined -match "\b$verb\b") {
        throw "Invoke-AzureRead rechazado: el argv incluye '$verb', que no es de solo lectura. Usar New-AzureChangePlan.ps1 / Apply-AzureChangePlan.ps1 para cualquier escritura."
    }
}

if ($Argv -contains 'rest') {
    $methodIdx = [array]::IndexOf($Argv, '--method')
    if ($methodIdx -ge 0 -and ($methodIdx + 1) -lt $Argv.Count) {
        $method = $Argv[$methodIdx + 1].ToLowerInvariant()
        if ($method -ne 'get') {
            throw "Invoke-AzureRead rechazado: 'az rest --method $method' no es de solo lectura. Solo se permite --method get."
        }
    }
}

if ($Argv -contains '--debug') {
    throw "Invoke-AzureRead rechazado: --debug puede exponer informacion sensible (tokens) y no se usa nunca en este dominio."
}

$fullArgv = @($Argv) + @('--output', 'json')
$raw = & az @fullArgv 2>&1
$exitCode = $LASTEXITCODE

if ($exitCode -ne 0) {
    throw "Invoke-AzureRead: 'az $($Argv -join ' ')' fallo (exit=$exitCode). Salida: $($raw | Out-String)"
}

$text = ($raw | Out-String)
if ([string]::IsNullOrWhiteSpace($text)) {
    return $null
}
try {
    return $text | ConvertFrom-Json
}
catch {
    return $text
}
