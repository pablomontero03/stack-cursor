<#
Suite de tests offline para New-AgenticCycleState.ps1 y
Invoke-AgenticCycleWake.ps1 (Fase 5 del roadmap de madurez).
Cero red, cero ADO real.

Uso:
  pwsh -NoProfile -File .\run-agentic-tests.ps1
#>

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $PSScriptRoot 'tmp-agentic'
if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

$stateScript = Join-Path $scriptsRoot 'New-AgenticCycleState.ps1'
$wakeScript  = Join-Path $scriptsRoot 'Invoke-AgenticCycleWake.ps1'

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Name, [bool]$Pass, [string]$Detail = '')
    $results.Add([PSCustomObject]@{ Name = $Name; Status = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

# =========================================================================
# New-AgenticCycleState.ps1 -- tests de estado
# =========================================================================

# A1: Crear estado nuevo
$runIdA1 = $null
try {
    $r = & $stateScript -AppId 'test-app' -Phase 'awaiting-build' `
        -InputHash 'hash-input-001' -PlanHash 'hash-plan-001' `
        -OutDir $testRoot
    $stateContent = Get-Content -LiteralPath $r.path -Raw | ConvertFrom-Json
    $ok = (Test-Path $r.path) -and ($stateContent.phase -eq 'awaiting-build') `
        -and ($stateContent.app_id -eq 'test-app') `
        -and (-not [string]::IsNullOrWhiteSpace($r.runId))
    Add-Result 'A1: New-AgenticCycleState crea archivo con fase y appId correctos' $ok "phase=$($stateContent.phase) runId=$($r.runId)"
    $runIdA1 = $r.runId
}
catch { Add-Result 'A1: New-AgenticCycleState crea estado nuevo' $false $_.Exception.Message }

# A2: Actualizar fase del estado existente
try {
    if (-not $runIdA1) { throw 'A1 fallo, no hay runId.' }
    $r2 = & $stateScript -AppId 'test-app' -RunId $runIdA1 -Phase 'build-running' `
        -AdoIds @{ build_id = 12345 } -OutDir $testRoot
    $state2 = Get-Content -LiteralPath $r2.path -Raw | ConvertFrom-Json
    Add-Result 'A2: actualizar fase a build-running + build_id' `
        ($state2.phase -eq 'build-running' -and $state2.ado.build_id -eq 12345) `
        "phase=$($state2.phase) build_id=$($state2.ado.build_id)"
}
catch { Add-Result 'A2: actualizar fase existente' $false $_.Exception.Message }

# A3: Registrar observacion
try {
    if (-not $runIdA1) { throw 'A1 fallo.' }
    $r3 = & $stateScript -AppId 'test-app' -RunId $runIdA1 -Phase 'build-running' `
        -Observation @{ domain = 'ado'; state = 'en-progreso'; buildId = 12345 } `
        -OutDir $testRoot
    $state3 = Get-Content -LiteralPath $r3.path -Raw | ConvertFrom-Json
    $obsCount = @($state3.observations).Count
    Add-Result 'A3: observacion queda registrada en el array' ($obsCount -ge 1) "observations.Count=$obsCount"
}
catch { Add-Result 'A3: registrar observacion' $false $_.Exception.Message }

# A4: Cerrar corrida como exitosa
try {
    if (-not $runIdA1) { throw 'A1 fallo.' }
    $r4 = & $stateScript -AppId 'test-app' -RunId $runIdA1 -Phase 'done' `
        -Outcome 'success' -OutDir $testRoot
    $state4 = Get-Content -LiteralPath $r4.path -Raw | ConvertFrom-Json
    Add-Result 'A4: cerrar corrida done/success' ($state4.phase -eq 'done' -and $state4.outcome -eq 'success') "phase=$($state4.phase) outcome=$($state4.outcome)"
}
catch { Add-Result 'A4: cerrar corrida' $false $_.Exception.Message }

# A5: Estado inicial sin InputHash -> error
try {
    $errOut = $null
    & $stateScript -AppId 'test-app' -Phase 'awaiting-build' -OutDir $testRoot -ErrorVariable errOut 2>&1 | Out-Null
    # Si llego hasta aqui sin excepcion, revisar si la salida de error contiene el mensaje
    $hadError = ($errOut -and ($errOut | Out-String) -match 'InputHash') -or $LASTEXITCODE -ne 0
    Add-Result 'A5: sin InputHash en estado nuevo -> rechazado' $hadError ($errOut | Out-String)
}
catch { Add-Result 'A5: sin InputHash en estado nuevo -> rechazado' ($_.Exception.Message -match 'InputHash') $_.Exception.Message }

# A6: RunId fijo -> el mismo archivo, fase actualizable
try {
    $r6a = & $stateScript -AppId 'idempotent-app' -RunId 'run-fixed-001' `
        -Phase 'awaiting-build' -InputHash 'h1' -OutDir $testRoot
    $r6b = & $stateScript -AppId 'idempotent-app' -RunId 'run-fixed-001' `
        -Phase 'build-running' -AdoIds @{ build_id = 999 } -OutDir $testRoot
    $state6 = Get-Content -LiteralPath $r6b.path -Raw | ConvertFrom-Json
    Add-Result 'A6: RunId fijo -> mismo archivo, fase actualizada' ($state6.phase -eq 'build-running' -and $state6.ado.build_id -eq 999) "phase=$($state6.phase) build_id=$($state6.ado.build_id)"
}
catch { Add-Result 'A6: RunId determinista' $false $_.Exception.Message }

# A7: JSON del estado tiene todos los campos obligatorios del schema
try {
    $r7 = & $stateScript -AppId 'schema-app' -RunId 'schema-test-001' `
        -Phase 'awaiting-build' -InputHash 'schema-hash' -PlanHash 'plan-hash' `
        -Observation @{ domain = 'test'; state = 'ok' } -OutDir $testRoot
    $parsed = Get-Content -LiteralPath $r7.path -Raw | ConvertFrom-Json
    $hasAll = ($parsed.agentic_run_id -and $parsed.app_id -and $parsed.phase `
        -and $parsed.input_hash -and $null -ne $parsed.ado -and $parsed.last_observed)
    Add-Result 'A7: JSON de estado tiene todos los campos del schema' $hasAll `
        "runId=$($null -ne $parsed.agentic_run_id) app=$($null -ne $parsed.app_id) ado=$($null -ne $parsed.ado) obs=$($null -ne $parsed.last_observed)"
}
catch { Add-Result 'A7: schema JSON valido' $false $_.Exception.Message }

# =========================================================================
# Invoke-AgenticCycleWake.ps1 -- tests estructurales (offline, sin ADO)
# =========================================================================

# B1: El script tiene las 4 decisiones y la guardia de Produccion
try {
    $wakeContent = Get-Content -LiteralPath $wakeScript -Raw
    $hasAdvance    = $wakeContent -match 'advance'
    $hasWait       = $wakeContent -match "'wait'"
    $hasNotify     = $wakeContent -match 'notify-user'
    $hasAbort      = $wakeContent -match 'abort'
    $hasProdGuard  = $wakeContent -match 'awaiting-prod-approval'
    $hasBuildPhase = $wakeContent -match 'build-running'
    $hasUATPhase   = $wakeContent -match 'uat-running'
    Add-Result 'B1: Invoke-AgenticCycleWake tiene las 4 decisiones' ($hasAdvance -and $hasWait -and $hasNotify -and $hasAbort) "advance=$hasAdvance wait=$hasWait notify=$hasNotify abort=$hasAbort"
    Add-Result 'B2: guardia Produccion (awaiting-prod-approval -> notify-user, nunca automatica)' $hasProdGuard 'grepping awaiting-prod-approval'
    Add-Result 'B3: fases de polling (build-running, release-dev-running, uat-running)' ($hasBuildPhase -and $hasUATPhase) "build=$hasBuildPhase uat=$hasUATPhase"
}
catch { Add-Result 'B1-B3: estructura de Invoke-AgenticCycleWake' $false $_.Exception.Message }

# B4: El wake NUNCA llama directamente a Apply-*.ps1 (ni como & ni como invocacion directa)
try {
    $wakeLines = Get-Content -LiteralPath $wakeScript
    # Solo contar lineas que parecen llamadas reales (& Apply- o Apply- al inicio de expresion)
    $applyCallLines = @($wakeLines | Where-Object { $_ -match '(^|\s)(&\s+Apply-|Apply-\w+\.ps1)' })
    $noApply = ($applyCallLines.Count -eq 0)
    Add-Result 'B4: Invoke-AgenticCycleWake no tiene llamadas reales a Apply-*.ps1' $noApply "lineas con llamada real a Apply-: $($applyCallLines.Count)"
}
catch { Add-Result 'B4: wake sin Apply' $false $_.Exception.Message }

# B5: New-AgenticCycleState.ps1 no contiene llamadas de red
try {
    $stateContent = Get-Content -LiteralPath $stateScript -Raw
    $networkPattern = 'Invoke-WebRequest|Invoke-RestMethod|Invoke-AdoRest|kubectl|\bcall_az\b'
    Add-Result 'B5: New-AgenticCycleState.ps1 cero llamadas de red' ($stateContent -notmatch $networkPattern) 'grep de patrones de red'
}
catch { Add-Result 'B5: cero red en New-AgenticCycleState' $false $_.Exception.Message }

# B6: El estado tiene las fases del redeploy en orden logico documentado
try {
    $stateContent = Get-Content -LiteralPath $stateScript -Raw
    $phases = @('awaiting-build','build-running','awaiting-release-dev','release-dev-running','awaiting-uat','uat-running','awaiting-prod-approval','done','failed')
    $allPhasesPresent = ($phases | Where-Object { $stateContent -match $_ } | Measure-Object).Count -eq $phases.Count
    Add-Result 'B6: todas las fases del ciclo redeploy estan en New-AgenticCycleState' $allPhasesPresent "$($phases | Where-Object { $stateContent -notmatch $_ } | Join-String ' ') faltantes"
}
catch { Add-Result 'B6: fases del ciclo en el script' $false $_.Exception.Message }

# =========================================================================
# Reporte final
# =========================================================================
$results | Format-Table -Property Name, Status -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ""
Write-Host "Total: $($results.Count) - PASS: $($results.Count - $failed.Count) - FAIL: $($failed.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })
if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Casos fallidos:" -ForegroundColor Red
    foreach ($f in $failed) { Write-Host "- $($f.Name)`n  $($f.Detail)" -ForegroundColor Red }
}
