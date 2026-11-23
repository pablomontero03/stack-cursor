<#
Genera el diff actual -> deseado para una operacion planeada, sin aplicar
nada. Dos vias segun el tipo de operacion:

  - Si la operacion tiene un template ARM/Bicep (deployment): usa
    `az deployment group what-if` / `az deployment sub what-if` real.
  - Si es una operacion `az` simple (ej. `az resource update`) sin
    deployment: arma un diff manual comparando `currentState` (ya capturado
    en el inventario) contra `desiredState` del borrador de operacion --
    no ejecuta ningun comando real de Azure.

Nunca escribe en Azure. Uso pensado para alimentar la evidencia de
what-if/diff que New-AzureChangePlan.ps1 exige por operacion.

Uso:
  & '.\Invoke-AzureWhatIf.ps1' -Mode Deployment -ResourceGroup rg1 -TemplateFile t.json -ParametersFile p.json -SubscriptionId <id>
  & '.\Invoke-AzureWhatIf.ps1' -Mode ManualDiff -CurrentStatePath current.json -DesiredStatePath desired.json
#>
param(
    [Parameter(Mandatory)] [ValidateSet('Deployment', 'ManualDiff')] [string]$Mode,
    [string]$SubscriptionId,
    [string]$ResourceGroup,
    [string]$TemplateFile,
    [string]$ParametersFile,
    [ValidateSet('ResourceGroup', 'Subscription')] [string]$Scope = 'ResourceGroup',
    [string]$CurrentStatePath,
    [string]$DesiredStatePath
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Azure-Common.ps1')

if ($Mode -eq 'Deployment') {
    if (-not $SubscriptionId -or -not $TemplateFile) {
        throw "Invoke-AzureWhatIf -Mode Deployment requiere -SubscriptionId y -TemplateFile."
    }
    if (-not (Test-Path -LiteralPath $TemplateFile)) {
        throw "Invoke-AzureWhatIf: no existe el template '$TemplateFile'."
    }

    $argv = @()
    if ($Scope -eq 'ResourceGroup') {
        if (-not $ResourceGroup) { throw "Invoke-AzureWhatIf -Scope ResourceGroup requiere -ResourceGroup." }
        $argv = @('deployment', 'group', 'what-if', '--resource-group', $ResourceGroup, '--template-file', $TemplateFile, '--subscription', $SubscriptionId)
    }
    else {
        $argv = @('deployment', 'sub', 'what-if', '--location', 'eastus', '--template-file', $TemplateFile, '--subscription', $SubscriptionId)
    }
    if ($ParametersFile) {
        if (-not (Test-Path -LiteralPath $ParametersFile)) { throw "Invoke-AzureWhatIf: no existe el archivo de parametros '$ParametersFile'." }
        $argv += @('--parameters', "@$ParametersFile")
    }
    $argv += @('--no-pretty-print')

    $raw = & az @argv 2>&1
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) {
        throw "Invoke-AzureWhatIf: 'az $($argv -join ' ')' fallo (exit=$exitCode). Salida: $($raw | Out-String)"
    }

    return [PSCustomObject]@{
        mode       = 'Deployment'
        capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        rawOutput  = ($raw | Out-String)
    }
}
else {
    if (-not $CurrentStatePath -or -not $DesiredStatePath) {
        throw "Invoke-AzureWhatIf -Mode ManualDiff requiere -CurrentStatePath y -DesiredStatePath."
    }
    if (-not (Test-Path -LiteralPath $CurrentStatePath)) { throw "Invoke-AzureWhatIf: no existe '$CurrentStatePath'." }
    if (-not (Test-Path -LiteralPath $DesiredStatePath)) { throw "Invoke-AzureWhatIf: no existe '$DesiredStatePath'." }

    $current = Get-Content -LiteralPath $CurrentStatePath -Raw | ConvertFrom-Json
    $desired = Get-Content -LiteralPath $DesiredStatePath -Raw | ConvertFrom-Json

    $currentProps = @($current.PSObject.Properties.Name)
    $desiredProps = @($desired.PSObject.Properties.Name)
    $allProps = @($currentProps + $desiredProps | Select-Object -Unique)

    $diffs = [System.Collections.Generic.List[object]]::new()
    foreach ($p in $allProps) {
        $curVal = if ($currentProps -contains $p) { $current.$p | ConvertTo-Json -Depth 10 -Compress } else { $null }
        $desVal = if ($desiredProps -contains $p) { $desired.$p | ConvertTo-Json -Depth 10 -Compress } else { $null }
        if ($curVal -ne $desVal) {
            $diffs.Add([PSCustomObject]@{ property = $p; current = $curVal; desired = $desVal })
        }
    }

    return [PSCustomObject]@{
        mode          = 'ManualDiff'
        capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        changedProperties = @($diffs)
        hasChanges    = ($diffs.Count -gt 0)
    }
}
