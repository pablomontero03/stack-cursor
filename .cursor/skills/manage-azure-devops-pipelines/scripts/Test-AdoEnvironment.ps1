<#
Valida el entorno local antes de operar Azure DevOps Pipelines, sin
imprimir ningun secreto. Solo lectura: no llama a ninguna API de escritura.

Uso:
  powershell -File .\Test-AdoEnvironment.ps1
#>

$ErrorActionPreference = 'Stop'

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Check, [bool]$Ok, [string]$Detail)
    $results.Add([PSCustomObject]@{ Check = $Check; Ok = $Ok; Detail = $Detail })
}

# 1. PAT presente en el entorno del usuario (solo booleano, nunca el valor)
$patSetForUser = [bool][Environment]::GetEnvironmentVariable('AZURE_DEVOPS_PAT', 'User')
$patSetForProcess = [bool][Environment]::GetEnvironmentVariable('AZURE_DEVOPS_PAT', 'Process')
Add-Result -Check 'AZURE_DEVOPS_PAT (User)' -Ok $patSetForUser -Detail $(if ($patSetForUser) { 'Configurada' } else { 'No configurada - ejecutar setx AZURE_DEVOPS_PAT en una terminal propia' })
Add-Result -Check 'AZURE_DEVOPS_PAT (Process actual)' -Ok $patSetForProcess -Detail $(if ($patSetForProcess) { 'Visible en este proceso' } else { 'No visible en este proceso - abrir una terminal nueva tras setx' })

# 2. .mcp.json contiene el server azure-devops
$projectRoot = $env:REPO_ROOT
if ([string]::IsNullOrWhiteSpace($projectRoot)) { $projectRoot = (Get-Location).Path }
$mcpJsonPath = Join-Path $projectRoot '.mcp.json'

if (Test-Path -LiteralPath $mcpJsonPath) {
    $mcpJson = Get-Content -LiteralPath $mcpJsonPath -Raw | ConvertFrom-Json
    $hasAdoServer = $null -ne $mcpJson.mcpServers.'azure-devops'
    Add-Result -Check '.mcp.json tiene server azure-devops' -Ok $hasAdoServer -Detail $(if ($hasAdoServer) { 'Presente' } else { 'Ausente' })

    $hasN8nInterno = $null -ne $mcpJson.mcpServers.'n8n-interno'
    $hasN8nProductivo = $null -ne $mcpJson.mcpServers.'n8n-productivo'
    Add-Result -Check '.mcp.json conserva n8n-interno' -Ok $hasN8nInterno -Detail $(if ($hasN8nInterno) { 'Presente' } else { 'FALTA - no debia eliminarse' })
    Add-Result -Check '.mcp.json conserva n8n-productivo' -Ok $hasN8nProductivo -Detail $(if ($hasN8nProductivo) { 'Presente' } else { 'FALTA - no debia eliminarse' })
}
else {
    Add-Result -Check '.mcp.json existe' -Ok $false -Detail "No encontrado en $mcpJsonPath"
}

# 3. npm / npx disponibles
$npmCommand = Get-Command npm -ErrorAction SilentlyContinue
Add-Result -Check 'npm disponible' -Ok ([bool]$npmCommand) -Detail $(if ($npmCommand) { $npmCommand.Source } else { 'No encontrado en PATH' })

# 4. claude CLI disponible (para `claude mcp list`)
$claudeCommand = Get-Command claude -ErrorAction SilentlyContinue
Add-Result -Check 'claude CLI disponible' -Ok ([bool]$claudeCommand) -Detail $(if ($claudeCommand) { $claudeCommand.Source } else { 'No encontrado en PATH' })

$results | Format-Table -AutoSize

$failed = $results | Where-Object { -not $_.Ok }
if ($failed) {
    Write-Host ""
    Write-Host "Pendientes antes de poder verificar la conexion MCP en vivo:" -ForegroundColor Yellow
    foreach ($f in $failed) { Write-Host " - $($f.Check): $($f.Detail)" -ForegroundColor Yellow }
    exit 1
}

Write-Host "Entorno OK." -ForegroundColor Green
exit 0
