<#
Wrapper de lectura generico: ejecuta un subcomando kubectl de solo lectura
ya clasificado como automatico en references/command-classification.md
(get, describe, logs, events, top, api-resources, explain, diff, auth
can-i, config get-contexts/current-context/view sin --raw) contra un
contexto explicito, y devuelve la salida cruda. Nunca escribe en el
cluster -- si el subcomando no esta en la lista permitida, se rechaza sin
ejecutar nada.

Uso:
  powershell -File .\Invoke-AksRead.ps1 -Context <contexto> -Subcommand get -ResourceArgs @('pods','-n','desarrollo') [-KubeconfigPath <ruta>]

-KubeconfigPath es opcional (default: resolucion ambiente de kubectl).
#>

param(
    [Parameter(Mandatory)] [string]$Context,
    [Parameter(Mandatory)]
    [ValidateSet('get', 'describe', 'logs', 'events', 'top', 'api-resources', 'api-versions', 'version', 'cluster-info', 'explain', 'diff', 'auth-can-i', 'config-get-contexts', 'config-current-context', 'config-view')]
    [string]$Subcommand,
    [string[]]$ResourceArgs = @(),
    [string]$KubeconfigPath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Aks-Common.ps1')

$subcommandMap = @{
    'get'                    = @('get')
    'describe'               = @('describe')
    'logs'                   = @('logs')
    'events'                 = @('get', 'events')
    'top'                    = @('top')
    'api-resources'          = @('api-resources')
    'api-versions'           = @('api-versions')
    'version'                = @('version')
    'cluster-info'           = @('cluster-info')
    'explain'                = @('explain')
    'diff'                   = @('diff')
    'auth-can-i'             = @('auth', 'can-i')
    'config-get-contexts'    = @('config', 'get-contexts')
    'config-current-context' = @('config', 'current-context')
    'config-view'            = @('config', 'view', '--minify')
}

# Defensa en profundidad: aunque $ResourceArgs viniera con '--raw' (lo que
# no deberia pasar para 'config-view', que ya fija --minify arriba), nunca
# se deja pasar -- eso exige aprobacion explicita fuera de este script.
if ($ResourceArgs -contains '--raw') {
    throw "Invoke-AksRead.ps1 rechazado: '--raw' expone datos de autenticacion del kubeconfig y requiere aprobacion explicita fuera de este wrapper de solo lectura."
}

$baseArgs = $subcommandMap[$Subcommand]
$needsContext = $Subcommand -notin @('config-get-contexts', 'config-current-context')
$connArgs = if ($needsContext) {
    Get-AksKubectlConnectionArgs -Context $Context -KubeconfigPath $KubeconfigPath
}
elseif ($KubeconfigPath) {
    @('--kubeconfig', $KubeconfigPath)
}
else {
    @()
}
$fullArgs = $baseArgs + $ResourceArgs + $connArgs

Write-Host "kubectl $($fullArgs -join ' ')" -ForegroundColor DarkGray
& kubectl @fullArgs
exit $LASTEXITCODE
