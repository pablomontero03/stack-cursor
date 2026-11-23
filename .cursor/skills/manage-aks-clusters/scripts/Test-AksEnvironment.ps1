<#
Diagnostico de solo lectura del entorno local para el dominio AKS: version
de az/kubectl/helm/kubelogin (o "no instalado"), existencia del
kubeconfig resuelto, contexto actual, y estado de conexion del MCP `aks`.
No modifica nada. No requiere aprobacion.

Uso:
  powershell -File .\Test-AksEnvironment.ps1

Ademas de la resolucion ambiente ($env:KUBECONFIG ->
$env:USERPROFILE\.kube\config), reporta existencia y contextos de los
kubeconfigs reales conocidos de este proyecto (exportados por Lens -- ver
references/kubeconfig-and-contexts.md). Pasar -KnownKubeconfigPaths para
sobreescribir esa lista si cambia.
#>

param(
    [string[]]$KnownKubeconfigPaths = @(
        "$env:APPDATA\Lens\kubeconfigs\2d2709fd-80b8-4086-808a-717488711436-pasted-kubeconfig.yaml",
        "$env:APPDATA\Lens\kubeconfigs\8cd569be-c5c7-4ab7-b1b3-698430ba90c8",
        "$env:APPDATA\Lens\kubeconfigs\f0aef227-affb-4a6a-9c16-f11c80566d66-pasted-kubeconfig.yaml"
    )
)

$ErrorActionPreference = 'Continue'
. (Join-Path $PSScriptRoot 'Aks-Common.ps1')

function Get-ToolVersionOrMissing {
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] [scriptblock]$VersionCommand)

    $cmd = Get-Command $Name -ErrorAction SilentlyContinue
    if (-not $cmd) {
        return [PSCustomObject]@{ Tool = $Name; Installed = $false; Version = $null }
    }
    try {
        $out = & $VersionCommand 2>&1 | Select-Object -First 1
        return [PSCustomObject]@{ Tool = $Name; Installed = $true; Version = [string]$out }
    }
    catch {
        return [PSCustomObject]@{ Tool = $Name; Installed = $true; Version = "(no se pudo determinar la version: $($_.Exception.Message))" }
    }
}

$results = [ordered]@{}

$results.tools = @(
    Get-ToolVersionOrMissing -Name 'az' -VersionCommand { (az version -o json | Out-String | ConvertFrom-Json).'azure-cli' }
    Get-ToolVersionOrMissing -Name 'kubectl' -VersionCommand { (kubectl version --client --output=json | ConvertFrom-Json).clientVersion.gitVersion }
    Get-ToolVersionOrMissing -Name 'helm' -VersionCommand { helm version --short }
    Get-ToolVersionOrMissing -Name 'kubelogin' -VersionCommand { kubelogin --version }
)

$kubeconfigPaths = Get-AksResolvedKubeconfigPaths
$results.kubeconfig = @($kubeconfigPaths | ForEach-Object {
    [PSCustomObject]@{ Path = $_; Exists = (Test-Path -LiteralPath $_) }
})

$currentContext = $null
try { $currentContext = (kubectl config current-context) 2>$null } catch { $currentContext = $null }
$results.currentContext = $currentContext

$contexts = @()
try {
    $ctxRaw = kubectl config get-contexts -o name 2>$null
    if ($ctxRaw) { $contexts = @($ctxRaw -split "`r?`n" | Where-Object { $_ }) }
}
catch { $contexts = @() }
$results.contexts = $contexts

$results.knownKubeconfigs = @($KnownKubeconfigPaths | ForEach-Object {
    $path = $_
    $exists = Test-Path -LiteralPath $path
    $ctxNames = @()
    if ($exists) {
        try {
            $raw = kubectl config get-contexts --kubeconfig $path -o name 2>$null
            if ($raw) { $ctxNames = @($raw -split "`r?`n" | Where-Object { $_ }) }
        }
        catch { $ctxNames = @() }
    }
    [PSCustomObject]@{ Path = $path; Exists = $exists; Contexts = $ctxNames }
})

$mcpBinaryPath = Join-Path (Get-AksProjectRoot) '.local\aks\tools\aks-mcp\v0.0.20\aks-mcp.exe'
$results.mcpBinary = [PSCustomObject]@{
    Path   = $mcpBinaryPath
    Exists = (Test-Path -LiteralPath $mcpBinaryPath)
}

$results | ConvertTo-Json -Depth 6
