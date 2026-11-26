<#
Pruebas offline de Ado-RunPolling-Common.ps1 (Get-AdoClassicRunStatus /
Wait-AdoClassicRun). Mismo truco de shadowing que run-script-tests.ps1:
define una funcion Invoke-WebRequest en este scope ANTES de dot-sourcear
Invoke-AdoRest.ps1, para que sus llamadas de red se resuelvan contra una
cola de respuestas simuladas -- cero red real. El "reloj" y el "sleep" del
polling se inyectan como scriptblocks falsos: nunca se espera de verdad.

Uso:
  pwsh -NoProfile -File .\run-run-polling-tests.ps1
#>

$ErrorActionPreference = 'Stop'
$scriptsRoot = Split-Path -Parent $PSScriptRoot

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Name, [bool]$Pass, [string]$Detail = '')
    $results.Add([PSCustomObject]@{ Name = $Name; Status = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

$script:mockResponseQueue = [System.Collections.Generic.Queue[object]]::new()
function Reset-MockWebRequest { $script:mockResponseQueue = [System.Collections.Generic.Queue[object]]::new() }
function Add-MockWebJsonResponse {
    param($BodyObject)
    $content = $BodyObject | ConvertTo-Json -Depth 15 -Compress
    $script:mockResponseQueue.Enqueue([PSCustomObject]@{ StatusCode = 200; Content = $content })
}
function Invoke-WebRequest {
    param([string]$Method, [string]$Uri, $Headers, $Body, [int]$MaximumRedirection, [switch]$UseBasicParsing)
    if ($script:mockResponseQueue.Count -eq 0) { throw "Mock de Invoke-WebRequest: se pidio una respuesta de mas para $Uri." }
    $next = $script:mockResponseQueue.Dequeue()
    return [PSCustomObject]@{ StatusCode = $next.StatusCode; Content = $next.Content; Headers = @{} }
}

$env:AZURE_DEVOPS_PAT = 'FAKE_TEST_PAT_NEVER_REAL_0000000000000000'
. (Join-Path $scriptsRoot 'Invoke-AdoRest.ps1')
. (Join-Path $scriptsRoot 'Ado-RunPolling-Common.ps1')

function New-FakeClockAndSleep {
    # Reloj falso: cada llamada a $SleepAction avanza el reloj en
    # exactamente $Seconds sin dormir de verdad. Devuelve ambos
    # scriptblocks mas una referencia a la lista de "sleeps" pedidos.
    $state = [PSCustomObject]@{ Now = [datetime]'2026-01-01T00:00:00Z'; SleepCalls = [System.Collections.Generic.List[int]]::new() }
    $nowProvider = { $state.Now }.GetNewClosure()
    $sleepAction = { param($Seconds) $state.SleepCalls.Add($Seconds); $state.Now = $state.Now.AddSeconds($Seconds) }.GetNewClosure()
    return [PSCustomObject]@{ State = $state; NowProvider = $nowProvider; SleepAction = $sleepAction }
}

# --- Build: consulta inmediata + 2 iteraciones hasta terminal exitoso ---
Reset-MockWebRequest
Add-MockWebJsonResponse -BodyObject @{ id = 501; status = 'inProgress'; result = $null }
Add-MockWebJsonResponse -BodyObject @{ id = 501; status = 'inProgress'; result = $null }
Add-MockWebJsonResponse -BodyObject @{ id = 501; status = 'completed'; result = 'succeeded' }
$clock = New-FakeClockAndSleep
$waitResult = Wait-AdoClassicRun -Kind Build -Id 501 -Project DevOps -IntervalSeconds 120 -TimeoutMinutes 60 -SleepAction $clock.SleepAction -NowProvider $clock.NowProvider

Add-Result 'Build: consulta 3 veces (inmediata + 2 reintentos) hasta terminal' ($waitResult.pollCount -eq 3) "pollCount=$($waitResult.pollCount)"
Add-Result 'Build: estado final normalizado = exitoso' ($waitResult.finalState.normalizedState -eq 'exitoso') $waitResult.finalState.normalizedState
Add-Result 'Build: nunca marca timedOut cuando termina antes del limite' (-not $waitResult.timedOut) 'timedOut'
Add-Result 'Escenario 15: cada sleep pedido es EXACTAMENTE 120s (el intervalo configurado), nunca una espera real' `
    ((@($clock.State.SleepCalls) -join ',') -eq '120,120') (@($clock.State.SleepCalls) -join ',')
Add-Result 'Escenario 15: el reloj avanzo exactamente 240s (2 intervalos) sin Start-Sleep real' `
    (($clock.State.Now - [datetime]'2026-01-01T00:00:00Z').TotalSeconds -eq 240) $clock.State.Now

# --- Build: timeout -- nunca declara exito ni fracaso sin evidencia terminal ---
Reset-MockWebRequest
1..5 | ForEach-Object { Add-MockWebJsonResponse -BodyObject @{ id = 777; status = 'inProgress'; result = $null } }
$clock2 = New-FakeClockAndSleep
$waitTimeout = Wait-AdoClassicRun -Kind Build -Id 777 -Project DevOps -IntervalSeconds 60 -TimeoutMinutes 2 -SleepAction $clock2.SleepAction -NowProvider $clock2.NowProvider
Add-Result 'Build: agota timeout sin declarar exito ni fracaso (normalizedState sigue en-progreso)' `
    ($waitTimeout.timedOut -and $waitTimeout.finalState.normalizedState -eq 'en-progreso') "timedOut=$($waitTimeout.timedOut) state=$($waitTimeout.finalState.normalizedState)"

# --- Release: ambiente especifico exitoso, otro ambiente irrelevante ---
Reset-MockWebRequest
Add-MockWebJsonResponse -BodyObject @{ id = 900; environments = @(
        @{ name = 'Desarrollo'; status = 'inProgress' },
        @{ name = 'UAT'; status = 'notStarted' }
    ) }
Add-MockWebJsonResponse -BodyObject @{ id = 900; environments = @(
        @{ name = 'Desarrollo'; status = 'succeeded' },
        @{ name = 'UAT'; status = 'notStarted' }
    ) }
$clock3 = New-FakeClockAndSleep
$waitRelease = Wait-AdoClassicRun -Kind Release -Id 900 -Project DevOps -EnvironmentName Desarrollo -IntervalSeconds 120 -TimeoutMinutes 60 -SleepAction $clock3.SleepAction -NowProvider $clock3.NowProvider
Add-Result 'Release: sigue el estado del ambiente Desarrollo (no el de UAT)' ($waitRelease.finalState.normalizedState -eq 'exitoso') $waitRelease.finalState.normalizedState
Add-Result 'Release: environmentName reportado coincide con el pedido' ($waitRelease.finalState.environmentName -eq 'Desarrollo') $waitRelease.finalState.environmentName

# --- Release: ambiente rechazado -> fallido, nunca "exitoso" ---
Reset-MockWebRequest
Add-MockWebJsonResponse -BodyObject @{ id = 901; environments = @(@{ name = 'Produccion'; status = 'rejected' }) }
$clock4 = New-FakeClockAndSleep
$waitRejected = Wait-AdoClassicRun -Kind Release -Id 901 -Project DevOps -EnvironmentName Produccion -IntervalSeconds 120 -TimeoutMinutes 60 -SleepAction $clock4.SleepAction -NowProvider $clock4.NowProvider
Add-Result 'Release: ambiente rechazado clasifica fallido' ($waitRejected.finalState.normalizedState -eq 'fallido') $waitRejected.finalState.normalizedState

Remove-Item Env:\AZURE_DEVOPS_PAT -ErrorAction SilentlyContinue

# =========================================================================
# Reporte final
# =========================================================================
$results | Format-Table -Property Name, Status -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ""
Write-Host "Total: $($results.Count) - PASS: $($results.Count - $failed.Count) - FAIL: $($failed.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })
if ($failed.Count -gt 0) {
    foreach ($f in $failed) { Write-Host "- $($f.Name): $($f.Detail)" -ForegroundColor Red }
}

if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
