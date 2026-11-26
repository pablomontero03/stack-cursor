<#
Crea o actualiza el estado persistido de una corrida agentica del ciclo
de pipeline. El estado vive en docs/pipeline-cycles/<appId>-agentic-<runId>.json
(versionado junto al historial de la app -- decision 2026-09-11).

Casos de uso:
  1. Crear un estado nuevo al iniciar una corrida agentica:
     New-AgenticCycleState.ps1 -AppId buklo-app-sso -Phase awaiting-build -InputHash <hash> -PlanHash <hash>

  2. Actualizar el estado en un tick del loop de polling:
     New-AgenticCycleState.ps1 -AppId buklo-app-sso -RunId <existing-id> -Phase build-running -Observation @{domain='ado';state='en-progreso';buildId=12345}

  3. Cerrar la corrida (exito o fallo):
     New-AgenticCycleState.ps1 -AppId buklo-app-sso -RunId <existing-id> -Phase done -Outcome success

Fases validas (orden del ciclo redeploy):
  awaiting-build        -- plan aprobado, esperando que el usuario o el ciclo encole el Build
  build-running         -- Build en progreso, polling activo
  awaiting-release-dev  -- Build exitoso, esperando encolar Release Desarrollo
  release-dev-running   -- Release Desarrollo en progreso, polling activo
  awaiting-uat          -- Desarrollo completado, esperando encolar Release UAT
  uat-running           -- Release UAT en progreso, polling activo
  awaiting-prod-approval -- UAT completado, esperando Aprobacion 2 del usuario (NUNCA automatica)
  done                  -- corrida terminada (exito o fallo)
  failed                -- error no recuperable detectado, corrida abortada

SEGURIDAD: esta capa de estado NUNCA ejecuta Apply-*.ps1 ni toma
decisiones de Produccion. Solo registra lo que paso y el proximo paso
esperado. Produccion siempre requiere aprobacion separada del usuario.
#>

param(
    [Parameter(Mandatory)] [string]$AppId,
    [string]$RunId,
    [Parameter(Mandatory)] [ValidateSet(
        'awaiting-build', 'build-running',
        'awaiting-release-dev', 'release-dev-running',
        'pod-running',
        'awaiting-uat', 'uat-running',
        'pod-running-uat',
        'awaiting-prod-approval', 'done', 'failed'
    )] [string]$Phase,
    [string]$InputHash,
    [string]$PlanHash,
    [hashtable]$AdoIds,
    [hashtable]$Observation,
    [ValidateSet('success', 'failure', 'pending')] [string]$Outcome = 'pending',
    [string]$ErrorMessage,
    [string]$OutDir
)

$ErrorActionPreference = 'Stop'

function Get-AgenticStateDir {
    if ($OutDir) { return $OutDir }
    $repoRoot = $env:REPO_ROOT
    if (-not $repoRoot) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    }
    return Join-Path $repoRoot 'docs' 'pipeline-cycles'
}

$stateDir = Get-AgenticStateDir
if (-not (Test-Path -LiteralPath $stateDir)) {
    New-Item -ItemType Directory -Force -Path $stateDir | Out-Null
}

$nowUtc = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')

# Resolver RunId -- crear uno nuevo o usar el existente
if (-not $RunId) {
    $RunId = "$AppId-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}

$stateFile = Join-Path $stateDir "$RunId.json"

# Cargar estado existente si existe
$state = $null
if (Test-Path -LiteralPath $stateFile) {
    try {
        $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
    }
    catch {
        Write-Warning "New-AgenticCycleState: no se pudo leer el estado existente en '$stateFile'. Se creara uno nuevo."
        $state = $null
    }
}

# Crear estado inicial si no existe
if ($null -eq $state) {
    if (-not $InputHash) { throw "New-AgenticCycleState: -InputHash es obligatorio al crear un nuevo estado." }
    $state = [PSCustomObject]@{
        agentic_run_id       = $RunId
        app_id               = $AppId
        started_at           = $nowUtc
        phase                = $Phase
        input_hash           = $InputHash
        plan_validation_hash = $PlanHash
        ado                  = [PSCustomObject]@{
            build_id              = $null
            release_definition_id = $null
            release_instance_dev  = $null
            release_instance_uat  = $null
            namespace             = $null
            namespace_uat         = $null
            servicesname          = $null
        }
        last_observed        = [PSCustomObject]@{ domain = 'init'; state = 'created'; at = $nowUtc }
        observations         = @()
        outcome              = $Outcome
        error                = $ErrorMessage
    }
}
else {
    # Actualizar campos del estado existente
    $state.phase = $Phase
    $state.outcome = $Outcome
    if ($ErrorMessage) { $state.error = $ErrorMessage }
    if ($PlanHash) { $state.plan_validation_hash = $PlanHash }
}

# Actualizar IDs de ADO si se proporcionan
if ($AdoIds) {
    foreach ($key in $AdoIds.Keys) {
        if ($state.ado.PSObject.Properties.Name -contains $key) {
            $state.ado.$key = $AdoIds[$key]
        }
        else {
            # Estado antiguo sin esta propiedad -- agregarla (namespace, servicesname, etc.)
            $state.ado | Add-Member -MemberType NoteProperty -Name $key -Value $AdoIds[$key] -Force
        }
    }
}

# Registrar observacion si se proporciona
if ($Observation) {
    $obs = [PSCustomObject]($Observation + @{ at = $nowUtc })
    $state.observations = @($state.observations) + @($obs)
    $state.last_observed = $obs
}
else {
    $state.last_observed = [PSCustomObject]@{ domain = 'phase-change'; state = $Phase; at = $nowUtc }
}

# Escribir estado al disco
$state | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $stateFile -Encoding utf8

return [PSCustomObject]@{
    runId     = $RunId
    path      = $stateFile
    phase     = $Phase
    outcome   = $Outcome
    state     = $state
}
