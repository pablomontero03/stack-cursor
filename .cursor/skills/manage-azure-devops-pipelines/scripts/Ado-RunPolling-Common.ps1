<#
Libreria de solo funciones (sin bloque param() de nivel superior, nunca se
ejecuta por si sola) para consultar y esperar el estado de un Build o
Release clasico. Dot-sourceada por Wait-AdoClassicRun.ps1 (wrapper CLI) y
directamente por tests\run-run-polling-tests.ps1 -- mismo patron que
Invoke-AdoApplyPhases en New-AdoClassicPayloads.ps1: funciones puras,
testables en el mismo proceso sin lanzar un script hijo.

Requiere que el llamador ya haya hecho:
  . .\Invoke-AdoRest.ps1
antes de dot-sourcear este archivo (usa $script:AdoCoreBaseUrl,
$script:AdoReleaseBaseUrl, $script:AdoApiVersion e Invoke-AdoRest).
#>

function Get-AdoClassicRunStatus {
    <#
    Snapshot de solo lectura (GET) del estado actual de un Build o Release
    clasico. Nunca escribe. Para Release, si se indica -EnvironmentName,
    el estado normalizado corresponde a ESE ambiente especifico (una
    Release puede tener ambientes en distintos estados simultaneamente);
    sin -EnvironmentName se usa el estado global de la Release.
    #>
    param(
        [Parameter(Mandatory)] [ValidateSet('Build', 'Release')] [string]$Kind,
        [Parameter(Mandatory)] [int]$Id,
        [Parameter(Mandatory)] [string]$Project,
        [string]$EnvironmentName
    )

    if ($Kind -eq 'Build') {
        $uri = "$($script:AdoCoreBaseUrl)/$Project/_apis/build/builds/$($Id)?api-version=$($script:AdoApiVersion)"
        # Invoke-AdoRest devuelve un envoltorio {Body, Headers, StatusCode}
        # -- nunca el cuerpo de la respuesta directamente.
        $body = (Invoke-AdoRest -Method GET -Uri $uri).Body
        if (-not $body) { throw "Get-AdoClassicRunStatus: no se pudo consultar el Build $Id." }

        $status = [string]$body.status
        $result = [string]$body.result
        $terminal = $status -eq 'completed'
        $normalized = if (-not $terminal) { 'en-progreso' } elseif ($result -eq 'succeeded') { 'exitoso' } elseif ($result -eq 'partiallySucceeded') { 'parcialmente-exitoso' } else { 'fallido' }

        return [PSCustomObject]@{
            kind            = 'Build'
            id              = $Id
            rawStatus       = $status
            rawResult       = $result
            terminal        = $terminal
            normalizedState = $normalized
            queueTime       = $body.queueTime
            startTime       = $body.startTime
            finishTime      = $body.finishTime
            sourceBranch    = $body.sourceBranch
            sourceVersion   = $body.sourceVersion
        }
    }

    $uri = "$($script:AdoReleaseBaseUrl)/$Project/_apis/release/releases/$($Id)?api-version=$($script:AdoApiVersion)"
    $body = (Invoke-AdoRest -Method GET -Uri $uri).Body
    if (-not $body) { throw "Get-AdoClassicRunStatus: no se pudo consultar el Release $Id." }

    $env = $null
    if ($EnvironmentName) {
        $env = @($body.environments) | Where-Object { $_.name -eq $EnvironmentName } | Select-Object -First 1
        if (-not $env) { throw "Get-AdoClassicRunStatus: el Release $Id no tiene un ambiente llamado '$EnvironmentName'." }
    }
    else {
        $env = @($body.environments) | Select-Object -First 1
    }

    $envStatus = [string]$env.status
    $terminalStates = @('succeeded', 'rejected', 'canceled', 'partiallySucceeded')
    $terminal = $envStatus -in $terminalStates
    $normalized = switch ($envStatus) {
        'succeeded' { 'exitoso' }
        'partiallySucceeded' { 'parcialmente-exitoso' }
        'rejected' { 'fallido' }
        'canceled' { 'fallido' }
        default { 'en-progreso' }
    }

    return [PSCustomObject]@{
        kind            = 'Release'
        id              = $Id
        environmentName = [string]$env.name
        rawStatus       = $envStatus
        terminal        = $terminal
        normalizedState = $normalized
    }
}

function Wait-AdoClassicRun {
    <#
    Consulta el estado inmediatamente, y mientras no sea terminal vuelve a
    consultar cada $IntervalSeconds hasta un estado terminal o hasta
    $TimeoutMinutes. $SleepAction y $NowProvider son inyectables para que
    las pruebas simulen el paso del tiempo con un reloj falso, sin esperar
    de verdad (ver tests\run-run-polling-tests.ps1, escenario "polling
    simulado con reloj falso").
    #>
    param(
        [Parameter(Mandatory)] [ValidateSet('Build', 'Release')] [string]$Kind,
        [Parameter(Mandatory)] [int]$Id,
        [Parameter(Mandatory)] [string]$Project,
        [string]$EnvironmentName,
        [int]$IntervalSeconds = 120,
        [int]$TimeoutMinutes = 60,
        [scriptblock]$SleepAction = { param($Seconds) Start-Sleep -Seconds $Seconds },
        [scriptblock]$NowProvider = { (Get-Date).ToUniversalTime() }
    )

    $startedAt = & $NowProvider
    $observations = [System.Collections.Generic.List[object]]::new()

    $status = Get-AdoClassicRunStatus -Kind $Kind -Id $Id -Project $Project -EnvironmentName $EnvironmentName
    $observations.Add([PSCustomObject]@{ atUtc = (& $NowProvider); normalizedState = $status.normalizedState; rawStatus = $status.rawStatus })

    $timedOut = $false
    while (-not $status.terminal) {
        $elapsedMinutes = ((& $NowProvider) - $startedAt).TotalMinutes
        if ($elapsedMinutes -ge $TimeoutMinutes) { $timedOut = $true; break }

        & $SleepAction $IntervalSeconds

        $status = Get-AdoClassicRunStatus -Kind $Kind -Id $Id -Project $Project -EnvironmentName $EnvironmentName
        $observations.Add([PSCustomObject]@{ atUtc = (& $NowProvider); normalizedState = $status.normalizedState; rawStatus = $status.rawStatus })
    }

    return [PSCustomObject]@{
        kind            = $Kind
        id              = $Id
        finalState      = $status
        timedOut        = $timedOut
        pollCount       = $observations.Count
        observations    = $observations
    }
}
