<#
Wrapper de tick del loop agentico para el ciclo de redeploy.
Lee el estado persistido, consulta ADO (Build o Release segun la fase),
compara con el ultimo estado observado, y devuelve una DECISION sin
ejecutar nada. La ejecucion siempre la hace el agente (o el usuario) en
respuesta a la decision.

Uso (desde el agente operator o una sesion principal):
  Invoke-AgenticCycleWake.ps1 -RunId <run-id> -StateDir <dir> -AdoProject DevOps

Retorna un PSCustomObject con:
  decision: advance|wait|notify-user|abort
  reason  : por que tomo esa decision
  phase   : fase actual del estado
  nextPhase: fase propuesta si decision=advance (puede ser null)
  data    : datos adicionales del poll (rawStatus, buildId, etc.)

Decisiones:
  advance      -- la fase actual termino exitosamente; propone la siguiente
  wait         -- la fase actual sigue en progreso; seguir esperando
  notify-user  -- se necesita intervencion humana (error, Prod, stale)
  abort        -- error irrecuperable; la corrida debe cerrarse como failed

SEGURIDAD:
  - Este script NUNCA llama a Apply-*.ps1 ni encola Builds/Releases.
  - NUNCA decide automaticamente sobre Produccion.
  - Solo lee y compara; la escritura del nuevo estado la hace el llamador
    usando New-AgenticCycleState.ps1 con el resultado de este script.
#>

param(
    [Parameter(Mandatory)] [string]$RunId,
    [Parameter(Mandatory)] [string]$AdoProject,
    [string]$StateDir,
    [int]$StaleThresholdMinutes = 90
)

$ErrorActionPreference = 'Stop'

# Resolver rutas de dependencias cross-platform (Linux/Windows)
$_adoRest = Join-Path $PSScriptRoot '..' '..' 'manage-azure-devops-pipelines' 'scripts' 'Invoke-AdoRest.ps1'
$_adoRest = [System.IO.Path]::GetFullPath($_adoRest)
if (-not (Test-Path -LiteralPath $_adoRest)) {
    throw "Invoke-AgenticCycleWake: no se encontro Invoke-AdoRest.ps1 en '$_adoRest'."
}
. $_adoRest

$_pollingCommon = Join-Path $PSScriptRoot '..' '..' 'manage-azure-devops-pipelines' 'scripts' 'Ado-RunPolling-Common.ps1'
$_pollingCommon = [System.IO.Path]::GetFullPath($_pollingCommon)
if (-not (Test-Path -LiteralPath $_pollingCommon)) {
    throw "Invoke-AgenticCycleWake: no se encontro Ado-RunPolling-Common.ps1 en '$_pollingCommon'. Verificar estructura del repo."
}
. $_pollingCommon

function Get-AgenticStateDir {
    param([string]$Override)
    if ($Override) { return $Override }
    $repoRoot = $env:REPO_ROOT
    if (-not $repoRoot) {
        $repoRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $PSScriptRoot))
    }
    return Join-Path $repoRoot 'docs' 'pipeline-cycles'
}

function New-WakeDecision {
    param([string]$Decision, [string]$Reason, [string]$Phase, [string]$NextPhase, $Data)
    return [PSCustomObject]@{
        decision  = $Decision
        reason    = $Reason
        phase     = $Phase
        nextPhase = $NextPhase
        data      = $Data
        checkedAt = [System.DateTime]::UtcNow.ToString('yyyy-MM-ddTHH:mm:ssZ')
    }
}

<#
Readback estructurado del pod desplegado via kubectl.

Consulta `kubectl get pods -n <Namespace> -l app=<AppSelector> -o json` y
evalua la salud de los pods segun:
  - ready  : al menos 1 pod con containerStatuses[].ready = true
  - restartCount : conteo de reinicios por contenedor
  - waiting.reason : CrashLoopBackOff / OOMKilled / ErrImagePull, etc.
  - startTime : para calcular la edad del pod (staleness del deploy)

Retorna un PSCustomObject:
  verdict : ready | crash | stale | pending | error
  reason  : texto explicativo
  data    : detalle de los pods observados
#>
function Get-AgenticPodReadback {
    param(
        [Parameter(Mandatory)] [string]$Namespace,
        [Parameter(Mandatory)] [string]$AppSelector,
        [int]$MaxRestartCount = 5,
        [int]$StaleMinutes = 15
    )

    if (-not (Get-Command kubectl -ErrorAction SilentlyContinue)) {
        return [PSCustomObject]@{ verdict = 'error'; reason = "kubectl no esta disponible en PATH; no se puede hacer readback del pod."; data = $null }
    }

    $selector = "app=$AppSelector"
    try {
        $raw = & kubectl get pods -n $Namespace -l $selector -o json 2>&1
        if ($LASTEXITCODE -ne 0) {
            return [PSCustomObject]@{ verdict = 'error'; reason = "kubectl fallo (exit $LASTEXITCODE) para -n $Namespace -l $selector`: $raw"; data = $null }
        }
        $parsed = ($raw | Out-String) | ConvertFrom-Json
    }
    catch {
        return [PSCustomObject]@{ verdict = 'error'; reason = "Error consultando/parsing kubectl para -n $Namespace -l $selector`: $($_.Exception.Message)"; data = $null }
    }

    $items = @($parsed.items)
    if ($items.Count -eq 0) {
        return [PSCustomObject]@{ verdict = 'pending'; reason = "Sin pods aun para -n $Namespace -l $selector (deploy en curso)."; data = $null }
    }

    $now = [System.DateTime]::UtcNow
    $podSummaries = @()
    $anyReady = $false
    $anyCrash = $false
    $crashDetail = $null
    $allRunningNotReady = $true

    foreach ($pod in $items) {
        $podName = [string]$pod.metadata.name
        $phaseK8s = [string]$pod.status.phase
        $startTime = $null
        if ($pod.status.startTime) {
            try { $startTime = [System.DateTime]::Parse($pod.status.startTime, $null, [System.Globalization.DateTimeStyles]::AssumeUniversal -bor [System.Globalization.DateTimeStyles]::AdjustToUniversal) } catch { }
        }
        $ageMinutes = if ($startTime) { ($now - $startTime).TotalMinutes } else { $null }

        $cs = @($pod.status.containerStatuses)
        foreach ($c in $cs) {
            $ready = [bool]$c.ready
            $restarts = [int]$c.restartCount
            $waitingReason = $null
            if ($c.state -and $c.state.waiting -and $c.state.waiting.reason) { $waitingReason = [string]$c.state.waiting.reason }
            $lastTerminatedReason = $null
            if ($c.lastState -and $c.lastState.terminated -and $c.lastState.terminated.reason) { $lastTerminatedReason = [string]$c.lastState.terminated.reason }

            $podSummaries += [PSCustomObject]@{
                pod                  = $podName
                container            = [string]$c.name
                k8sPhase             = $phaseK8s
                ready                = $ready
                restartCount         = $restarts
                waitingReason        = $waitingReason
                lastTerminatedReason = $lastTerminatedReason
                ageMinutes           = if ($null -ne $ageMinutes) { [math]::Round($ageMinutes, 1) } else { $null }
            }

            # Deteccion de crash / OOM / limite de reinicios
            if ($waitingReason -in @('CrashLoopBackOff', 'ErrImagePull', 'ImagePullBackOff') -or
                $lastTerminatedReason -eq 'OOMKilled' -or
                $restarts -ge $MaxRestartCount) {
                $anyCrash = $true
                $crashDetail = "pod=$podName container=$($c.name) waiting='$waitingReason' lastTerminated='$lastTerminatedReason' restarts=$restarts"
            }

            # Ready reciente (readback exitoso): ready=true y restarts bajo
            if ($ready -and $restarts -lt $MaxRestartCount) {
                $anyReady = $true
                $allRunningNotReady = $false
            }
            if ($ready) { $allRunningNotReady = $false }
        }
    }

    $data = [PSCustomObject]@{ namespace = $Namespace; selector = $selector; pods = $podSummaries }

    if ($anyReady) {
        return [PSCustomObject]@{ verdict = 'ready'; reason = "Al menos 1 pod 1/1 Running (ready=true, restartCount < $MaxRestartCount) para -l $selector."; data = $data }
    }
    if ($anyCrash) {
        return [PSCustomObject]@{ verdict = 'crash'; reason = "Pod en estado de fallo: $crashDetail"; data = $data }
    }

    # Ninguno ready, ninguno crash -- evaluar staleness (Running pero ready=false demasiado tiempo)
    $maxAge = ($podSummaries | Where-Object { $null -ne $_.ageMinutes } | Measure-Object -Property ageMinutes -Maximum).Maximum
    if ($allRunningNotReady -and $null -ne $maxAge -and $maxAge -ge $StaleMinutes) {
        return [PSCustomObject]@{ verdict = 'stale'; reason = "Pod(s) en Running pero ready=false hace $([math]::Round($maxAge,1)) min (umbral $StaleMinutes min). Posible fallo de readiness/health check."; data = $data }
    }

    return [PSCustomObject]@{ verdict = 'pending'; reason = "Pod(s) aun no ready (readback en curso, edad max $(if($null -ne $maxAge){[math]::Round($maxAge,1)}else{'?'}) min)."; data = $data }
}

$dir = Get-AgenticStateDir -Override $StateDir
$stateFile = Join-Path $dir "$RunId.json"

if (-not (Test-Path -LiteralPath $stateFile)) {
    throw "Invoke-AgenticCycleWake: no existe el estado '$stateFile'. Verificar RunId."
}

$state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json
$phase = [string]$state.phase

# Corrida ya terminada -- nada que hacer
if ($phase -in @('done', 'failed')) {
    return New-WakeDecision -Decision 'abort' -Reason "Corrida ya terminada con outcome='$($state.outcome)'." -Phase $phase -NextPhase $null -Data $state
}

# Verificar staleness -- si no hubo observacion reciente, notificar
$lastObservedAt = [System.DateTime]::UtcNow  # default seguro
if ($state.last_observed -and $state.last_observed.at) {
    try { $lastObservedAt = [System.DateTime]::Parse($state.last_observed.at) } catch { }
}
$minutesSinceLastObservation = ([System.DateTime]::UtcNow - $lastObservedAt).TotalMinutes
if ($minutesSinceLastObservation -gt $StaleThresholdMinutes -and $phase -notin @('awaiting-prod-approval')) {
    return New-WakeDecision -Decision 'notify-user' -Reason "Sin observacion hace $([math]::Round($minutesSinceLastObservation,1)) minutos (umbral: $StaleThresholdMinutes min). Posible cuelgue o problema de red." -Phase $phase -NextPhase $null -Data $state.last_observed
}

# Fases que esperan intervencion humana -- no hay nada que pollear
if ($phase -eq 'awaiting-prod-approval') {
    return New-WakeDecision -Decision 'notify-user' -Reason "UAT completado. Se requiere Aprobacion 2 del usuario para desplegar a Produccion. NUNCA automatica." -Phase $phase -NextPhase 'done' -Data $null
}

if ($phase -in @('awaiting-release-dev', 'awaiting-uat')) {
    return New-WakeDecision -Decision 'notify-user' -Reason "Fase '$phase' espera que el agente o el usuario encole el siguiente paso (sin acceso a Apply desde este wake)." -Phase $phase -NextPhase $null -Data $null
}

# awaiting-build: si hay build_id, pollear ADO directamente
if ($phase -eq 'awaiting-build') {
    $buildId = [int]$state.ado.build_id
    if (-not $buildId) {
        return New-WakeDecision -Decision 'notify-user' -Reason "Fase 'awaiting-build' sin state.ado.build_id definido. El agente debe encolar el build y actualizar el estado." -Phase $phase -NextPhase $null -Data $null
    }
    # build_id presente -- pollear directamente; transicionar a build-running si aun corre
    try {
        $status = Get-AdoClassicRunStatus -Kind 'Build' -Id $buildId -Project $AdoProject
        if ($status.terminal) {
            if ($status.normalizedState -eq 'exitoso') {
                return New-WakeDecision -Decision 'advance' -Reason "Build $buildId completado exitosamente (detectado en awaiting-build)." -Phase $phase -NextPhase 'awaiting-release-dev' -Data $status
            }
            else {
                return New-WakeDecision -Decision 'notify-user' -Reason "Build $buildId termino con '$($status.normalizedState)'. Requiere atencion." -Phase $phase -NextPhase 'failed' -Data $status
            }
        }
        # Aun corriendo -- avanzar a build-running para que el proximo tick lo pida bien
        return New-WakeDecision -Decision 'advance' -Reason "Build $buildId detectado en progreso ($($status.normalizedState)). Avanzando a build-running para seguimiento." -Phase $phase -NextPhase 'build-running' -Data $status
    }
    catch {
        return New-WakeDecision -Decision 'notify-user' -Reason "Error consultando Build $buildId en awaiting-build: $($_.Exception.Message)" -Phase $phase -NextPhase $null -Data $null
    }
}

# Fases con polling activo -- consultar ADO
if ($phase -eq 'build-running') {
    $buildId = [int]$state.ado.build_id
    if (-not $buildId) {
        return New-WakeDecision -Decision 'notify-user' -Reason "Fase 'build-running' pero state.ado.build_id no esta definido." -Phase $phase -NextPhase $null -Data $null
    }
    try {
        $status = Get-AdoClassicRunStatus -Kind 'Build' -Id $buildId -Project $AdoProject
        if ($status.terminal) {
            if ($status.normalizedState -eq 'exitoso') {
                return New-WakeDecision -Decision 'advance' -Reason "Build $buildId completado: $($status.normalizedState)." -Phase $phase -NextPhase 'awaiting-release-dev' -Data $status
            }
            else {
                return New-WakeDecision -Decision 'notify-user' -Reason "Build $buildId termino con estado '$($status.normalizedState)'. Requiere atencion." -Phase $phase -NextPhase 'failed' -Data $status
            }
        }
        return New-WakeDecision -Decision 'wait' -Reason "Build $buildId en progreso ($($status.normalizedState))." -Phase $phase -NextPhase $null -Data $status
    }
    catch {
        return New-WakeDecision -Decision 'notify-user' -Reason "Error consultando Build $buildId`: $($_.Exception.Message)" -Phase $phase -NextPhase $null -Data $null
    }
}

if ($phase -eq 'release-dev-running') {
    $releaseId = [int]$state.ado.release_instance_dev
    if (-not $releaseId) {
        return New-WakeDecision -Decision 'notify-user' -Reason "Fase 'release-dev-running' pero state.ado.release_instance_dev no esta definido." -Phase $phase -NextPhase $null -Data $null
    }
    try {
        $status = Get-AdoClassicRunStatus -Kind 'Release' -Id $releaseId -Project $AdoProject -EnvironmentName 'Desarrollo'
        if ($status.terminal) {
            if ($status.normalizedState -eq 'exitoso') {
                return New-WakeDecision -Decision 'advance' -Reason "Release $releaseId/Desarrollo completado: $($status.normalizedState). Verificar pod antes de UAT." -Phase $phase -NextPhase 'pod-running' -Data $status
            }
            else {
                return New-WakeDecision -Decision 'notify-user' -Reason "Release $releaseId/Desarrollo termino con '$($status.normalizedState)'. Requiere atencion." -Phase $phase -NextPhase 'failed' -Data $status
            }
        }
        return New-WakeDecision -Decision 'wait' -Reason "Release $releaseId/Desarrollo en progreso ($($status.normalizedState))." -Phase $phase -NextPhase $null -Data $status
    }
    catch {
        return New-WakeDecision -Decision 'notify-user' -Reason "Error consultando Release $releaseId`: $($_.Exception.Message)" -Phase $phase -NextPhase $null -Data $null
    }
}

if ($phase -eq 'uat-running') {
    $releaseId = [int]$state.ado.release_instance_uat
    if (-not $releaseId) {
        return New-WakeDecision -Decision 'notify-user' -Reason "Fase 'uat-running' pero state.ado.release_instance_uat no esta definido." -Phase $phase -NextPhase $null -Data $null
    }
    try {
        $status = Get-AdoClassicRunStatus -Kind 'Release' -Id $releaseId -Project $AdoProject -EnvironmentName 'UAT'

        # Auto-activar stage UAT si quedo en notStarted (race condition CD trigger)
        if ($status.rawStatus -eq 'notStarted') {
            Write-Host "  Stage UAT notStarted en Release $releaseId -- activando automaticamente..." -ForegroundColor Yellow
            $authHeader = "Basic $([Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$($env:AZURE_DEVOPS_PAT)")))"
            # Obtener el environment id del stage UAT
            $relReq = [System.Net.WebRequest]::Create("https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/releases/${releaseId}?api-version=7.1")
            $relReq.Headers.Add('Authorization', $authHeader)
            $relReader = [IO.StreamReader]::new($relReq.GetResponse().GetResponseStream())
            $relData = $relReader.ReadToEnd() | ConvertFrom-Json
            $relReader.Close()
            $uatEnv = $relData.environments | Where-Object { $_.name -eq 'UAT' }
            if ($uatEnv) {
                $patchReq = [System.Net.WebRequest]::Create("https://vsrm.dev.azure.com/Shared-Service-GM/DevOps/_apis/release/releases/${releaseId}/environments/$($uatEnv.id)?api-version=7.1")
                $patchReq.Method = 'PATCH'; $patchReq.ContentType = 'application/json'
                $patchReq.Headers.Add('Authorization', $authHeader)
                $patchBytes = [Text.Encoding]::UTF8.GetBytes('{"status":"inProgress"}')
                $patchReq.ContentLength = $patchBytes.Length
                $patchReq.GetRequestStream().Write($patchBytes, 0, $patchBytes.Length)
                $patchReq.GetResponse().Close()
                Write-Host "  Stage UAT activado (inProgress)." -ForegroundColor Green
                return New-WakeDecision -Decision 'wait' -Reason "Stage UAT activado automaticamente desde notStarted. Esperando completion." -Phase $phase -NextPhase $null -Data $status
            }
        }

        if ($status.terminal) {
            if ($status.normalizedState -eq 'exitoso') {
                return New-WakeDecision -Decision 'advance' -Reason "Release $releaseId/UAT completado: $($status.normalizedState). Verificar pod UAT antes de Prod." -Phase $phase -NextPhase 'pod-running-uat' -Data $status
            }
            else {
                return New-WakeDecision -Decision 'notify-user' -Reason "Release $releaseId/UAT termino con '$($status.normalizedState)'. Requiere atencion." -Phase $phase -NextPhase 'failed' -Data $status
            }
        }
        return New-WakeDecision -Decision 'wait' -Reason "Release $releaseId/UAT en progreso ($($status.normalizedState))." -Phase $phase -NextPhase $null -Data $status
    }
    catch {
        return New-WakeDecision -Decision 'notify-user' -Reason "Error consultando Release $releaseId`: $($_.Exception.Message)" -Phase $phase -NextPhase $null -Data $null
    }
}

# Fase pod-running -- readback estructurado del pod Desarrollo via kubectl
if ($phase -eq 'pod-running') {
    $namespace = [string]$state.ado.namespace
    $servicesname = [string]$state.ado.servicesname
    if (-not $namespace -or -not $servicesname) {
        return New-WakeDecision -Decision 'notify-user' -Reason "Fase 'pod-running' pero falta state.ado.namespace ('$namespace') y/o state.ado.servicesname ('$servicesname'). No se puede construir el selector de kubectl." -Phase $phase -NextPhase $null -Data $null
    }
    $rb = Get-AgenticPodReadback -Namespace $namespace -AppSelector $servicesname -MaxRestartCount 5 -StaleMinutes 15
    switch ($rb.verdict) {
        'ready' { return New-WakeDecision -Decision 'advance'     -Reason "Pod Desarrollo saludable: $($rb.reason)"                          -Phase $phase -NextPhase 'awaiting-uat' -Data $rb.data }
        'crash' { return New-WakeDecision -Decision 'notify-user' -Reason "Pod Desarrollo en fallo: $($rb.reason)"                           -Phase $phase -NextPhase 'failed'       -Data $rb.data }
        'stale' { return New-WakeDecision -Decision 'notify-user' -Reason "Pod Desarrollo no alcanza readiness: $($rb.reason)"              -Phase $phase -NextPhase $null         -Data $rb.data }
        'error' { return New-WakeDecision -Decision 'notify-user' -Reason "No se pudo hacer readback del pod Desarrollo: $($rb.reason)"     -Phase $phase -NextPhase $null         -Data $rb.data }
        default { return New-WakeDecision -Decision 'wait'        -Reason "Pod Desarrollo aun no ready: $($rb.reason)"                       -Phase $phase -NextPhase $null         -Data $rb.data }
    }
}

# Fase pod-running-uat -- readback estructurado del pod UAT via kubectl
if ($phase -eq 'pod-running-uat') {
    $namespace = [string]$state.ado.namespace_uat
    if (-not $namespace) { $namespace = [string]$state.ado.namespace }  # fallback si no hay namespace_uat separado
    $servicesname = [string]$state.ado.servicesname
    if (-not $namespace -or -not $servicesname) {
        return New-WakeDecision -Decision 'notify-user' -Reason "Fase 'pod-running-uat' pero falta state.ado.namespace_uat/namespace ('$namespace') y/o state.ado.servicesname ('$servicesname'). No se puede construir el selector de kubectl." -Phase $phase -NextPhase $null -Data $null
    }
    $rb = Get-AgenticPodReadback -Namespace $namespace -AppSelector $servicesname -MaxRestartCount 5 -StaleMinutes 15
    switch ($rb.verdict) {
        'ready' { return New-WakeDecision -Decision 'advance'     -Reason "Pod UAT saludable: $($rb.reason)"                           -Phase $phase -NextPhase 'awaiting-prod-approval' -Data $rb.data }
        'crash' { return New-WakeDecision -Decision 'notify-user' -Reason "Pod UAT en fallo: $($rb.reason)"                            -Phase $phase -NextPhase 'failed'                -Data $rb.data }
        'stale' { return New-WakeDecision -Decision 'notify-user' -Reason "Pod UAT no alcanza readiness: $($rb.reason)"               -Phase $phase -NextPhase $null                  -Data $rb.data }
        'error' { return New-WakeDecision -Decision 'notify-user' -Reason "No se pudo hacer readback del pod UAT: $($rb.reason)"      -Phase $phase -NextPhase $null                  -Data $rb.data }
        default { return New-WakeDecision -Decision 'wait'        -Reason "Pod UAT aun no ready: $($rb.reason)"                        -Phase $phase -NextPhase $null                  -Data $rb.data }
    }
}

# Fase no reconocida
return New-WakeDecision -Decision 'notify-user' -Reason "Fase '$phase' no reconocida por Invoke-AgenticCycleWake. Verificar estado." -Phase $phase -NextPhase $null -Data $null
