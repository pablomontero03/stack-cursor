<#
Pruebas offline de la skill coordinadora orchestrate-application-pipeline-cycle.
Cero red, cero llamadas a Azure DevOps/Cloudflare/AKS -- ninguno de los 2
scripts de este dominio las hace. Cubre los escenarios obligatorios de
docs/INSTRUCCIONES-REFACTORIZAR-CICLO-PIPELINE-APLICACION.md que aplican
a validacion de INPUT y snapshot (4, 5, 6, 17, 18 y la agregacion de
faltantes en una sola pasada); los escenarios de dominio (1,2,3,7,8,9,10)
tienen su propio suite en manage-cloudflare/manage-aks-clusters/
manage-azure-devops-pipelines, y los de aprobacion/plan (11,12,13,14) se
verifican leyendo el codigo real de los hooks en
references/approval-envelope.md, no con un mock aqui.

Uso:
  pwsh -NoProfile -File .\run-script-tests.ps1
#>

$ErrorActionPreference = 'Stop'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $scriptsRoot 'Test-ApplicationCycleInput.ps1')
. (Join-Path $scriptsRoot 'New-ApplicationCycleSnapshot.ps1')

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Name, [bool]$Pass, [string]$Detail = '')
    $results.Add([PSCustomObject]@{ Name = $Name; Status = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

function New-ValidInputHashtable {
    return @{
        INPUT = @{
            application = @{ id = 'app-directory'; type = 'web' }
            repository  = @{
                organization = 'Shared-Service-GM'; project = 'Buklo'; name = 'buklo-web'
                url          = 'https://dev.azure.com/Shared-Service-GM/Buklo/_git/buklo-web'; path = '/apps/app-directory'
                branches     = @{ development = 'development'; uat = 'uat'; production = 'release' }
            }
            azure_devops = @{
                project = 'DevOps'; pipeline_folder = '\buklo'; canonical_exports_directory = 'D:\x'
                build_export_candidates = @('Build-modelo.json'); release_export = 'Release-modelo.json'
                secret_sources = @{ container_registry_password = @{ environment_variable = 'ADO_SECRET_CONTAINERREGISTRYPASSWORD'; target_name = 'resolve_from_canonical_model' } }
            }
            application_variables = @{ image = 'app-directory-web'; appname_candidate = 'app-directory' }
            manifests   = @{ development = './deployment-dev.yml'; uat = './deployment-uat.yml'; production = './deployment-prod.yml' }
            environments = @{
                development = @{ namespace = 'desarrollo'; dns = @{ fqdn = 'a-dev.example.com'; type = 'A'; ip = '1.2.3.4'; proxied = $false; ttl = 'auto' }; cluster_candidate = 'discover'; node_selector = 'inherit' }
                uat         = @{ namespace = 'uat'; dns = @{ fqdn = 'a-uat.example.com'; type = 'A'; ip = '1.2.3.4'; proxied = $false; ttl = 'auto' }; cluster_candidate = 'discover'; node_selector = 'inherit' }
                production  = @{ namespace = 'apps-web'; dns = @{ fqdn = 'a.example.com'; type = 'A'; ip = '5.6.7.8'; proxied = $false; ttl = 'auto' }; cluster_candidate = 'gmon-prod-aks-eastus2-0004'; node_selector = @{ agentpool = 'userpool03' } }
            }
            discovery = @{ cluster_validation_before_plan = 'minima' }
            execution = @{
                max_automatic_configuration_retries_per_environment = 2; status_poll_interval_seconds = 120
                build_wait_timeout_minutes = 60; release_wait_timeout_minutes = 60; rollout_wait_timeout_minutes = 20
                aks_capacity_validation_max_age_seconds = 300; record_phase_timings = $true
                run_development_after_plan_approval = $true; run_uat_after_development_success = $true
                prepare_production = $true; production_requires_separate_approval = $true
                allow_application_code_changes = $false; allow_deletions = $false
            }
        }
    }
}

# --- Caso base: aplicacion web con todos los datos validos ---
$validInput = New-ValidInputHashtable
$resultValid = Test-ApplicationCycleInputObject -InputObject $validInput
Add-Result 'INPUT valido (web, todos los campos) -> ok=true, sin errores' ($resultValid.ok -and $resultValid.errors.Count -eq 0) ($resultValid.errors -join ' | ')
Add-Result 'INPUT valido: normalized.clusterValidationBeforePlan = minima' ($resultValid.normalized.clusterValidationBeforePlan -eq 'minima') $resultValid.normalized.clusterValidationBeforePlan

# --- Escenario 6: OrderedDictionary atravesando el validador ---
$orderedInput = [ordered]@{ INPUT = [ordered]@{} }
foreach ($key in (New-ValidInputHashtable).INPUT.Keys) {
    $orderedInput.INPUT[$key] = (New-ValidInputHashtable).INPUT[$key]
}
$resultOrdered = Test-ApplicationCycleInputObject -InputObject $orderedInput
Add-Result 'Escenario 6: OrderedDictionary de nivel superior valida igual que Hashtable' ($resultOrdered.ok) ($resultOrdered.errors -join ' | ')

# --- PSCustomObject (via ConvertTo-Json/ConvertFrom-Json, como llegaria de un archivo real) ---
$jsonInput = (New-ValidInputHashtable) | ConvertTo-Json -Depth 20 | ConvertFrom-Json
$resultJson = Test-ApplicationCycleInputObject -InputObject $jsonInput
Add-Result 'PSCustomObject (deserializado desde JSON) valida igual que Hashtable' ($resultJson.ok) ($resultJson.errors -join ' | ')

# --- application.type=database: nunca reutiliza modelos de aplicacion ---
$dbInput = New-ValidInputHashtable
$dbInput.INPUT.application.type = 'database'
$resultDb = Test-ApplicationCycleInputObject -InputObject $dbInput
Add-Result "'application.type'=database es rechazado (no soportado todavia)" (-not $resultDb.ok -and (($resultDb.errors -join ' ') -match 'database')) ($resultDb.errors -join ' | ')

# --- discovery.cluster_validation_before_plan invalido -> default 'preguntar' con warning, nunca error duro ---
$badModeInput = New-ValidInputHashtable
$badModeInput.INPUT.discovery.cluster_validation_before_plan = 'valor-inventado'
$resultBadMode = Test-ApplicationCycleInputObject -InputObject $badModeInput
Add-Result 'Modo de validacion AKS invalido cae a preguntar (warning, no bloquea el plan)' `
    ($resultBadMode.ok -and $resultBadMode.normalized.clusterValidationBeforePlan -eq 'preguntar' -and $resultBadMode.warnings.Count -gt 0) `
    "ok=$($resultBadMode.ok) modo=$($resultBadMode.normalized.clusterValidationBeforePlan)"

# --- Faltantes agrupados en una sola pasada, no uno por uno ---
$incompleteInput = @{ INPUT = @{ application = @{ id = 'x' } } }
$resultIncomplete = Test-ApplicationCycleInputObject -InputObject $incompleteInput
Add-Result 'Multiples secciones faltantes se agrupan en una sola pasada (>=5 errores de una vez)' `
    (-not $resultIncomplete.ok -and $resultIncomplete.errors.Count -ge 5) "errors.Count=$($resultIncomplete.errors.Count)"

# --- allow_application_code_changes=true nunca se acepta desde INPUT ---
$codeChangeInput = New-ValidInputHashtable
$codeChangeInput.INPUT.execution.allow_application_code_changes = $true
$resultCodeChange = Test-ApplicationCycleInputObject -InputObject $codeChangeInput
Add-Result 'allow_application_code_changes=true en INPUT es rechazado (cambio de codigo exige plan nuevo, nunca una bandera)' `
    (-not $resultCodeChange.ok) ($resultCodeChange.errors -join ' | ')

# --- Escenario 4: secreto ACR presente por variable de entorno, sin revelar su valor ---
$env:ADO_SECRET_CONTAINERREGISTRYPASSWORD_TEST = 'valor-ficticio-nunca-real-123'
$secretPresent = Test-ApplicationCycleSecretPresence -EnvironmentVariableName 'ADO_SECRET_CONTAINERREGISTRYPASSWORD_TEST'
# --- Caso real 2026-09-07 (app-sso): sin export sanitizado, solo referencia en vivo ---
$liveRefInput = New-ValidInputHashtable
$liveRefInput.INPUT.azure_devops.build_export_candidates = @()
$liveRefInput.INPUT.azure_devops.release_export = $null
$liveRefInput.INPUT.azure_devops.canonical_model_live_reference = 'https://dev.azure.com/Shared-Service-GM/DevOps/_build?definitionId=633'
$resultLiveRef = Test-ApplicationCycleInputObject -InputObject $liveRefInput
Add-Result 'Sin export sanitizado pero con canonical_model_live_reference -> ok=true con advertencia (no error duro)' `
    ($resultLiveRef.ok -and ($resultLiveRef.warnings -join ' ') -match 'en vivo') "ok=$($resultLiveRef.ok) warnings=$($resultLiveRef.warnings -join ' | ')"

$noModelInput = New-ValidInputHashtable
$noModelInput.INPUT.azure_devops.build_export_candidates = @()
$noModelInput.INPUT.azure_devops.release_export = $null
$resultNoModel = Test-ApplicationCycleInputObject -InputObject $noModelInput
Add-Result 'Sin export sanitizado NI referencia en vivo -> error duro (ningun modelo canonico declarado)' `
    (-not $resultNoModel.ok) ($resultNoModel.errors -join ' | ')

Add-Result 'Escenario 4: secreto presente -> present=true' ($secretPresent.present) $secretPresent.guidance
$secretPresentJson = $secretPresent | ConvertTo-Json -Compress
Add-Result 'Escenario 4 / 17: el valor real del secreto NUNCA aparece en la salida' `
    ($secretPresentJson -notmatch 'valor-ficticio-nunca-real-123') $secretPresentJson
Remove-Item Env:\ADO_SECRET_CONTAINERREGISTRYPASSWORD_TEST -ErrorAction SilentlyContinue

# --- Escenario 5: variable creada con setx, no visible en el proceso actual ---
$secretMissing = Test-ApplicationCycleSecretPresence -EnvironmentVariableName 'ADO_SECRET_QUE_NO_EXISTE_EN_ESTE_PROCESO'
Add-Result 'Escenario 5: secreto no visible -> present=false, guidance pide reiniciar sesion (nunca clasifica como faltante ni pide pegarlo en el chat)' `
    ((-not $secretMissing.present) -and ($secretMissing.guidance -match 'reiniciar') -and ($secretMissing.guidance -notmatch 'pegar|escrib')) $secretMissing.guidance

# =========================================================================
# New-ApplicationCycleSnapshot.ps1
# =========================================================================
$sectionsV1 = @{
    adoExports = @{ buildHash = 'abc123'; releaseHash = 'def456' }
    branches   = @{ development = 'commit-aaa'; uat = 'commit-bbb'; production = 'commit-ccc' }
    dns        = @{ development = 'to_create'; uat = 'reuse' }
}
$snapshot1 = New-ApplicationCycleSnapshotObject -Sections $sectionsV1
$snapshot1Again = New-ApplicationCycleSnapshotObject -Sections $sectionsV1
Add-Result 'Snapshot: el mismo contenido produce el mismo hash (determinista)' ($snapshot1.snapshotHash -ceq $snapshot1Again.snapshotHash) $snapshot1.snapshotHash

$sectionsV2 = @{
    adoExports = @{ buildHash = 'abc123'; releaseHash = 'def456' }   # sin cambios
    branches   = @{ development = 'commit-NEW'; uat = 'commit-bbb'; production = 'commit-ccc' }  # development cambio
    dns        = @{ development = 'to_create'; uat = 'reuse' }
}
$snapshot2 = New-ApplicationCycleSnapshotObject -Sections $sectionsV2
Add-Result 'Snapshot: contenido distinto produce hash distinto' ($snapshot1.snapshotHash -cne $snapshot2.snapshotHash) "$($snapshot1.snapshotHash) vs $($snapshot2.snapshotHash)"

$comparison = Compare-ApplicationCycleSnapshot -PreviousSnapshot $snapshot1 -NewSnapshot $snapshot2
$adoComparison = $comparison.sections | Where-Object { $_.section -eq 'adoExports' }
$branchesComparison = $comparison.sections | Where-Object { $_.section -eq 'branches' }
Add-Result 'Comparacion de snapshot: adoExports sin cambios -> reusable=true' ($adoComparison.reusable) $adoComparison.reason
Add-Result 'Comparacion de snapshot: branches con drift -> reusable=false' (-not $branchesComparison.reusable) $branchesComparison.reason
Add-Result 'Comparacion de snapshot: unchanged=false a nivel global cuando alguna seccion cambio' (-not $comparison.unchanged) "unchanged=$($comparison.unchanged)"

$comparisonSame = Compare-ApplicationCycleSnapshot -PreviousSnapshot $snapshot1 -NewSnapshot $snapshot1Again
Add-Result 'Comparacion de snapshot: unchanged=true cuando nada cambio' ($comparisonSame.unchanged) "unchanged=$($comparisonSame.unchanged)"

# --- Escenario 18: cero llamadas de red -- verificacion estructural de los 2 scripts fuente ---
$adoScriptSource = Get-Content -LiteralPath (Join-Path $scriptsRoot 'Test-ApplicationCycleInput.ps1') -Raw
$snapshotScriptSource = Get-Content -LiteralPath (Join-Path $scriptsRoot 'New-ApplicationCycleSnapshot.ps1') -Raw
$networkPattern = 'Invoke-WebRequest|Invoke-RestMethod|Invoke-AdoRest|Invoke-CloudflareApiRequest|kubectl|\bcall_az\b'
Add-Result 'Escenario 18: Test-ApplicationCycleInput.ps1 no contiene ninguna llamada de red/kubectl' ($adoScriptSource -notmatch $networkPattern) 'grep de patrones de red'
Add-Result 'Escenario 18: New-ApplicationCycleSnapshot.ps1 no contiene ninguna llamada de red/kubectl' ($snapshotScriptSource -notmatch $networkPattern) 'grep de patrones de red'

# --- Escenarios 19-22: interruptor agentico (Fase 8 del roadmap) ---

# 19: agentic_mode no declarado -> default 'off' (no modo agentico)
try {
    $inputNoAgentic = New-ValidInputHashtable
    # Quitar agentic_mode si existia en el execution por algun default previo
    $inputNoAgentic.INPUT.execution.Remove('agentic_mode') | Out-Null
    $r19 = Test-ApplicationCycleInputObject -InputObject $inputNoAgentic
    $gotOff = ($r19.normalized.execution.agentic_mode -eq 'off')
    Add-Result 'Escenario 19: agentic_mode no declarado -> default off' ($r19.ok -eq $true -and $gotOff) "agentic_mode=$($r19.normalized.execution.agentic_mode)"
}
catch { Add-Result 'Escenario 19: agentic_mode no declarado -> default off' $false $_.Exception.Message }

# 20: agentic_mode: "on" -> aceptado
try {
    $inputAgenticOn = New-ValidInputHashtable
    $inputAgenticOn.INPUT.execution['agentic_mode'] = 'on'
    $r20 = Test-ApplicationCycleInputObject -InputObject $inputAgenticOn
    $gotOn = ($r20.normalized.execution.agentic_mode -eq 'on')
    Add-Result 'Escenario 20: agentic_mode = "on" -> aceptado, ok=true' ($r20.ok -eq $true -and $gotOn) "agentic_mode=$($r20.normalized.execution.agentic_mode)"
}
catch { Add-Result 'Escenario 20: agentic_mode = "on" -> aceptado' $false $_.Exception.Message }

# 21: agentic_mode: "invalid" -> rechazado con error
try {
    $inputAgenticInvalid = New-ValidInputHashtable
    $inputAgenticInvalid.INPUT.execution['agentic_mode'] = 'invalid_value'
    $r21 = Test-ApplicationCycleInputObject -InputObject $inputAgenticInvalid
    $rejectedInvalid = ($r21.ok -eq $false -and ($r21.errors | Where-Object { $_ -match 'agentic_mode' }))
    Add-Result 'Escenario 21: agentic_mode invalido -> rechazado con error' $rejectedInvalid ($r21.errors -join '; ')
}
catch { Add-Result 'Escenario 21: agentic_mode invalido -> rechazado con error' $false $_.Exception.Message }

# 22: agentic_mode queda en el resultado normalizado listo para congelarse en el snapshot
try {
    $inputOnAndOff = New-ValidInputHashtable
    $inputOnAndOff.INPUT.execution['agentic_mode'] = 'on'
    $r22on = Test-ApplicationCycleInputObject -InputObject $inputOnAndOff
    $inputOnAndOff.INPUT.execution['agentic_mode'] = 'off'
    $r22off = Test-ApplicationCycleInputObject -InputObject $inputOnAndOff
    $onIsOn = ($r22on.normalized.execution.agentic_mode -eq 'on')
    $offIsOff = ($r22off.normalized.execution.agentic_mode -eq 'off')
    $twoRunsDifferent = ($r22on.normalized.execution.agentic_mode -ne $r22off.normalized.execution.agentic_mode)
    Add-Result 'Escenario 22: agentic_mode queda en normalized -> on/off son independientes' ($r22on.ok -and $r22off.ok -and $onIsOn -and $offIsOff -and $twoRunsDifferent) "on=$($r22on.normalized.execution.agentic_mode) off=$($r22off.normalized.execution.agentic_mode)"
}
catch { Add-Result 'Escenario 22: agentic_mode en normalized es independiente por corrida' $false $_.Exception.Message }

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
