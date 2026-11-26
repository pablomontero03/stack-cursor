<#
Backstop de validacion de secretos para el dominio Azure DevOps Pipelines.
Escanea todos los archivos JSON bajo $env:REPO_ROOT/.local/azure-devops/
en busca de secretos embebidos (propiedades sensibles o patrones regex).
Sale con exitCode != 0 si encuentra algo; exitCode 0 si todo limpio.

Llamado por el harness de pruebas y opcionalmente por hooks del flujo.
Creado 2026-09-11 para resolver referencia fantasma de la era Claude.
#>

$ErrorActionPreference = 'Stop'

# Cargar la biblioteca de escaneo del mismo directorio
. (Join-Path $PSScriptRoot 'ado-secret-scan-lib.ps1')

$repoRoot = $env:REPO_ROOT
if ([string]::IsNullOrWhiteSpace($repoRoot)) {
    Write-Host 'ado-stop-validate: REPO_ROOT no esta definido -- no hay nada que escanear.'
    exit 0
}

$scanDir = Join-Path $repoRoot '.local' 'azure-devops'
if (-not (Test-Path -LiteralPath $scanDir)) {
    exit 0
}

$jsonFiles = Get-ChildItem -LiteralPath $scanDir -Filter '*.json' -Recurse -File -ErrorAction SilentlyContinue
if (-not $jsonFiles) {
    exit 0
}

$violations = [System.Collections.Generic.List[string]]::new()

foreach ($f in $jsonFiles) {
    $raw = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
    if ([string]::IsNullOrWhiteSpace($raw)) { continue }

    $parsed = $null
    try { $parsed = $raw | ConvertFrom-Json } catch { }

    if ($null -ne $parsed) {
        $props = Find-AdoSensitiveJsonProperties -Node $parsed
        if ($props.Count -gt 0) {
            $violations.Add("$($f.Name): propiedades sensibles en $($props | ForEach-Object { $_.path } | Join-String -Separator ', ')")
        }
    }

    $rawHits = Find-AdoRawTextSecretPatterns -RawText $raw
    if ($rawHits.Count -gt 0) {
        $violations.Add("$($f.Name): secreto embebido en texto crudo ($($rawHits.Count) patron(es) detectado(s))")
    }
}

if ($violations.Count -gt 0) {
    Write-Host 'ado-stop-validate: BLOQUEADO -- se detectaron propiedades sensibles o secretos embebidos en los siguientes archivos:'
    foreach ($v in $violations) { Write-Host "  - $v" }
    exit 1
}

exit 0
