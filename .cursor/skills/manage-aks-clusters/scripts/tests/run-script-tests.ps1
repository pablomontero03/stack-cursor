<#
Harness de pruebas de los scripts del dominio AKS. Usa archivos
temporales y, cuando hace falta interceptar kubectl (sin tocar ningun
cluster real), un stub kubectl.cmd temporal antepuesto al PATH del
proceso de prueba unicamente. Cero red, cero cluster real.
#>

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $PSScriptRoot 'tmp'
if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

$results = [System.Collections.Generic.List[object]]::new()

function Add-Result {
    param([string]$Case, [bool]$Pass, [string]$Detail = '')
    $results.Add([PSCustomObject]@{ Case = $Case; Status = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

# Aisla .local\aks de este proceso de prueba: Aks-Common.ps1 resuelve
# rutas relativas a $PSScriptRoot, no a variables de entorno, asi que las
# pruebas que llaman a los scripts reales escriben bajo la raiz real del
# proyecto (.local\aks\plans, etc.) salvo que se les pase -OutDir
# explicito -- por eso todas las pruebas de abajo usan -OutDir/$testRoot.

# ============================================================
# New-AksChangePlan.ps1
# ============================================================

$opsOkPath = Join-Path $testRoot 'ops-ok.json'
@'
[
  {"operationId":"apply-deploy-my-app","kind":"apply","resourceKind":"Deployment","resourceName":"my-app","namespace":"desarrollo","manifestPath":"cluster/deployment.yaml"}
]
'@ | Set-Content -LiteralPath $opsOkPath -Encoding utf8

$planArgsOk = @{
    Context = 'gmon-innovacion-aks-eastus2-0001'; Namespace = 'desarrollo'
    SubscriptionId = 'sub-1'; ResourceGroup = 'rg-1'; ClusterName = 'gmon-innovacion-aks-eastus2-0001'
    Description = 'Prueba'; OperationsJson = $opsOkPath
    WhatChanges = 'Actualiza la imagen del Deployment my-app'; WhatDoesNotChange = 'No cambia el Service ni el Ingress'
    VerificationStrategy = 'kubectl rollout status'; RollbackStrategy = 'kubectl rollout undo'
    OutDir = $testRoot
}
try {
    $planResult = & (Join-Path $scriptsRoot 'New-AksChangePlan.ps1') @planArgsOk
    $planOkPath = $planResult.outPath
    Add-Result 'New-AksChangePlan: genera plan valido' (Test-Path -LiteralPath $planOkPath)
}
catch {
    Add-Result 'New-AksChangePlan: genera plan valido' $false $_.Exception.Message
}

try {
    $opsDupPath = Join-Path $testRoot 'ops-dup.json'
    '[{"operationId":"x","kind":"apply","resourceKind":"Deployment","resourceName":"a"},{"operationId":"x","kind":"apply","resourceKind":"Deployment","resourceName":"b"}]' | Set-Content -LiteralPath $opsDupPath -Encoding utf8
    $dupArgs = $planArgsOk.Clone(); $dupArgs.OperationsJson = $opsDupPath
    & (Join-Path $scriptsRoot 'New-AksChangePlan.ps1') @dupArgs | Out-Null
    Add-Result 'New-AksChangePlan: rechaza operationId duplicado' $false 'no lanzo excepcion'
}
catch {
    Add-Result 'New-AksChangePlan: rechaza operationId duplicado' ($_.Exception.Message -match 'duplicado')
}

try {
    $opsDeleteNoBackupPath = Join-Path $testRoot 'ops-delete-nobackup.json'
    '[{"operationId":"del-1","kind":"delete","resourceKind":"Pod","resourceName":"my-pod"}]' | Set-Content -LiteralPath $opsDeleteNoBackupPath -Encoding utf8
    $delArgs = $planArgsOk.Clone(); $delArgs.OperationsJson = $opsDeleteNoBackupPath
    & (Join-Path $scriptsRoot 'New-AksChangePlan.ps1') @delArgs | Out-Null
    Add-Result 'New-AksChangePlan: rechaza delete sin requiresBackup' $false 'no lanzo excepcion'
}
catch {
    Add-Result 'New-AksChangePlan: rechaza delete sin requiresBackup' ($_.Exception.Message -match 'requiresBackup')
}

# ============================================================
# Test-AksChangePlan.ps1
# ============================================================

$inventoryOkPath = Join-Path $testRoot 'inventory-ok.json'
[PSCustomObject]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    context        = 'gmon-innovacion-aks-eastus2-0001'
} | ConvertTo-Json | Set-Content -LiteralPath $inventoryOkPath -Encoding utf8

try {
    $testResult = & (Join-Path $scriptsRoot 'Test-AksChangePlan.ps1') -PlanPath $planOkPath -InventoryPath $inventoryOkPath
    Add-Result 'Test-AksChangePlan: valida plan OK y escribe validationHash' ($testResult.validated -eq $true -and $testResult.validationHash)
}
catch {
    Add-Result 'Test-AksChangePlan: valida plan OK y escribe validationHash' $false $_.Exception.Message
}

try {
    $rehashed = Get-Content -LiteralPath $planOkPath -Raw | ConvertFrom-Json
    Add-Result 'Test-AksChangePlan: plan en disco quedo validated=true' ($rehashed.validated -eq $true)
}
catch {
    Add-Result 'Test-AksChangePlan: plan en disco quedo validated=true' $false $_.Exception.Message
}

# Plan con secreto embebido -- debe bloquear.
$planSecretPath = Join-Path $testRoot 'plan-secret.json'
$planSecretObj = Get-Content -LiteralPath $planOkPath -Raw | ConvertFrom-Json
$planSecretObj | Add-Member -NotePropertyName 'password' -NotePropertyValue 'SuperSecreto123' -Force
$planSecretObj.validated = $false
$planSecretObj.validationHash = $null
$planSecretObj | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $planSecretPath -Encoding utf8

try {
    & (Join-Path $scriptsRoot 'Test-AksChangePlan.ps1') -PlanPath $planSecretPath -InventoryPath $inventoryOkPath | Out-Null
    Add-Result 'Test-AksChangePlan: bloquea plan con secreto embebido' ($LASTEXITCODE -ne 0)
}
catch {
    Add-Result 'Test-AksChangePlan: bloquea plan con secreto embebido' $true
}

# Inventario viejo -- debe bloquear.
$inventoryOldPath = Join-Path $testRoot 'inventory-old.json'
[PSCustomObject]@{
    generatedAtUtc = (Get-Date).ToUniversalTime().AddHours(-48).ToString('o')
    context        = 'gmon-innovacion-aks-eastus2-0001'
} | ConvertTo-Json | Set-Content -LiteralPath $inventoryOldPath -Encoding utf8

$opsOldPath = Join-Path $testRoot 'ops-old.json'
Copy-Item -LiteralPath $opsOkPath -Destination $opsOldPath -Force
$planOldArgs = $planArgsOk.Clone(); $planOldArgs.OperationsJson = $opsOldPath
try {
    $planOldResult = & (Join-Path $scriptsRoot 'New-AksChangePlan.ps1') @planOldArgs
    & (Join-Path $scriptsRoot 'Test-AksChangePlan.ps1') -PlanPath $planOldResult.outPath -InventoryPath $inventoryOldPath -MaxInventoryAgeHours 24 | Out-Null
    Add-Result 'Test-AksChangePlan: bloquea inventario mas viejo que MaxInventoryAgeHours' ($LASTEXITCODE -ne 0)
}
catch {
    Add-Result 'Test-AksChangePlan: bloquea inventario mas viejo que MaxInventoryAgeHours' $true
}

# ============================================================
# Aks-Common.ps1: hash determinista + journal
# ============================================================

. (Join-Path $scriptsRoot 'Aks-Common.ps1')

try {
    $samplePlan = [PSCustomObject]@{ a = 1; b = 'x'; validated = $false; validationHash = $null; validationEvidence = $null }
    $h1 = Get-AksPlanCanonicalHash -Plan $samplePlan
    $h2 = Get-AksPlanCanonicalHash -Plan $samplePlan
    Add-Result 'Aks-Common: Get-AksPlanCanonicalHash es determinista' ($h1 -eq $h2 -and $h1.Length -eq 64)
}
catch {
    Add-Result 'Aks-Common: Get-AksPlanCanonicalHash es determinista' $false $_.Exception.Message
}

try {
    $planA = [PSCustomObject]@{ a = 1; validated = $false; validationHash = $null; validationEvidence = $null }
    $planB = [PSCustomObject]@{ a = 2; validated = $false; validationHash = $null; validationEvidence = $null }
    $hA = Get-AksPlanCanonicalHash -Plan $planA
    $hB = Get-AksPlanCanonicalHash -Plan $planB
    Add-Result 'Aks-Common: Get-AksPlanCanonicalHash cambia con el contenido' ($hA -ne $hB)
}
catch {
    Add-Result 'Aks-Common: Get-AksPlanCanonicalHash cambia con el contenido' $false $_.Exception.Message
}

try {
    $journalTestHash = 'testhash1234567890'
    $journalPath = Join-Path $testRoot "executions\$journalTestHash.json"
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $journalPath) | Out-Null

    $j1 = Read-AksExecutionJournal -JournalPath $journalPath -PlanValidationHash $journalTestHash -OperationIds @('op-1', 'op-2')
    Write-AksExecutionJournalAtomic -JournalPath $journalPath -Journal $j1

    $j2 = Read-AksExecutionJournal -JournalPath $journalPath -PlanValidationHash $journalTestHash -OperationIds @('op-1', 'op-2')
    $j2.operations.'op-1'.state = 'succeeded'
    Write-AksExecutionJournalAtomic -JournalPath $journalPath -Journal $j2

    $j3 = Read-AksExecutionJournal -JournalPath $journalPath -PlanValidationHash $journalTestHash -OperationIds @('op-1', 'op-2')
    Add-Result 'Aks-Common: journal persiste estado entre lecturas' ($j3.operations.'op-1'.state -eq 'succeeded' -and $j3.operations.'op-2'.state -eq 'pending')
}
catch {
    Add-Result 'Aks-Common: journal persiste estado entre lecturas' $false $_.Exception.Message
}

try {
    Read-AksExecutionJournal -JournalPath $journalPath -PlanValidationHash $journalTestHash -OperationIds @('op-1', 'op-2', 'op-3-nueva') | Out-Null
    Add-Result 'Aks-Common: journal rechaza operationId faltante (bloqueo seguro)' $false 'no lanzo excepcion'
}
catch {
    Add-Result 'Aks-Common: journal rechaza operationId faltante (bloqueo seguro)' ($_.Exception.Message -match 'falta')
}

try {
    Read-AksExecutionJournal -JournalPath $journalPath -PlanValidationHash $journalTestHash -OperationIds @('op-1') | Out-Null
    Add-Result 'Aks-Common: journal rechaza operationId sobrante (bloqueo seguro)' $false 'no lanzo excepcion'
}
catch {
    Add-Result 'Aks-Common: journal rechaza operationId sobrante (bloqueo seguro)' ($_.Exception.Message -match 'no estan en el plan')
}

try {
    $paths = Get-AksResolvedKubeconfigPaths
    Add-Result 'Aks-Common: Get-AksResolvedKubeconfigPaths devuelve al menos 1 ruta' ($paths.Count -ge 1)
}
catch {
    Add-Result 'Aks-Common: Get-AksResolvedKubeconfigPaths devuelve al menos 1 ruta' $false $_.Exception.Message
}

# ============================================================
# Apply-AksChangePlan.ps1 -- solo las rutas de RECHAZO (no llegan a
# invocar kubectl, asi que no hace falta mockearlo).
# ============================================================

try {
    $unvalidatedPlanPath = Join-Path $testRoot 'plan-unvalidated.json'
    [PSCustomObject]@{ validated = $false; validationHash = $null; approvedOperations = @() } | ConvertTo-Json | Set-Content -LiteralPath $unvalidatedPlanPath -Encoding utf8
    & (Join-Path $scriptsRoot 'Apply-AksChangePlan.ps1') -PlanPath $unvalidatedPlanPath | Out-Null
    Add-Result 'Apply-AksChangePlan: rechaza plan con validated=false' $false 'no lanzo excepcion'
}
catch {
    Add-Result 'Apply-AksChangePlan: rechaza plan con validated=false' ($_.Exception.Message -match 'validated=true')
}

try {
    $tamperedPlanPath = Join-Path $testRoot 'plan-tampered.json'
    $tamperedPlan = Get-Content -LiteralPath $planOkPath -Raw | ConvertFrom-Json
    $tamperedPlan.description = 'Contenido modificado despues de validar'
    $tamperedPlan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tamperedPlanPath -Encoding utf8
    & (Join-Path $scriptsRoot 'Apply-AksChangePlan.ps1') -PlanPath $tamperedPlanPath | Out-Null
    Add-Result 'Apply-AksChangePlan: rechaza plan modificado tras validar (hash no coincide)' $false 'no lanzo excepcion'
}
catch {
    Add-Result 'Apply-AksChangePlan: rechaza plan modificado tras validar (hash no coincide)' ($_.Exception.Message -match 'validationHash no coincide')
}

# --- Mismatch de contexto: requiere mockear kubectl config current-context ---
$stubDir = Join-Path $testRoot 'stub-path'
New-Item -ItemType Directory -Force -Path $stubDir | Out-Null

# Stub portable: .cmd en Windows, script shell sin extension en Linux/macOS
$isWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)
if ($isWindows) {
    $stubKubectl = Join-Path $stubDir 'kubectl.cmd'
    @'
@echo off
if "%1"=="config" if "%2"=="current-context" (
  echo otro-contexto-distinto
  exit /b 0
)
exit /b 1
'@ | Set-Content -LiteralPath $stubKubectl -Encoding ascii
} else {
    $stubKubectl = Join-Path $stubDir 'kubectl'
    @'
#!/bin/sh
if [ "$1" = "config" ] && [ "$2" = "current-context" ]; then
  echo "otro-contexto-distinto"
  exit 0
fi
exit 1
'@ | Set-Content -LiteralPath $stubKubectl -Encoding utf8
    chmod +x $stubKubectl
}

$originalPath = $env:PATH
$pathSep = [System.IO.Path]::PathSeparator
try {
    $env:PATH = "${stubDir}${pathSep}${originalPath}"
    & (Join-Path $scriptsRoot 'Apply-AksChangePlan.ps1') -PlanPath $planOkPath | Out-Null
    Add-Result 'Apply-AksChangePlan: rechaza si el contexto actual no coincide con el del plan' $false 'no lanzo excepcion'
}
catch {
    Add-Result 'Apply-AksChangePlan: rechaza si el contexto actual no coincide con el del plan' ($_.Exception.Message -match 'contexto actual')
}
finally {
    $env:PATH = $originalPath
}

# --- -KubeconfigPath se propaga de verdad hasta la invocacion de kubectl
#     (bug real encontrado en uso: los clusteres reales de este proyecto
#     viven en kubeconfigs exportados por Lens, no en el default ambiente) ---
try {
    $fakeKubeconfigPath = Join-Path $testRoot 'fake-kubeconfig.yaml'
    'apiVersion: v1' | Set-Content -LiteralPath $fakeKubeconfigPath -Encoding utf8

    $opsKcPath = Join-Path $testRoot 'ops-kubeconfig.json'
    Copy-Item -LiteralPath $opsOkPath -Destination $opsKcPath -Force
    $planKcArgs = $planArgsOk.Clone()
    $planKcArgs.OperationsJson = $opsKcPath
    $planKcArgs.KubeconfigPath = $fakeKubeconfigPath
    $planKcResult = & (Join-Path $scriptsRoot 'New-AksChangePlan.ps1') @planKcArgs
    & (Join-Path $scriptsRoot 'Test-AksChangePlan.ps1') -PlanPath $planKcResult.outPath -InventoryPath $inventoryOkPath | Out-Null

    $stubLogPath = Join-Path $testRoot 'stub-invocations.log'
    if (Test-Path -LiteralPath $stubLogPath) { Remove-Item -LiteralPath $stubLogPath -Force }
    $loggingStubKubectl = if ($isWindows) { Join-Path $stubDir 'kubectl.cmd' } else { Join-Path $stubDir 'kubectl' }
    if ($isWindows) {
        @"
@echo off
echo %* >> "$stubLogPath"
if "%1"=="config" if "%2"=="current-context" (
  echo gmon-innovacion-aks-eastus2-0001
  exit /b 0
)
exit /b 1
"@ | Set-Content -LiteralPath $loggingStubKubectl -Encoding ascii
    } else {
        @"
#!/bin/sh
echo `$* >> "$stubLogPath"
if [ "`$1" = "config" ] && [ "`$2" = "current-context" ]; then
  echo "gmon-innovacion-aks-eastus2-0001"
  exit 0
fi
exit 1
"@ | Set-Content -LiteralPath $loggingStubKubectl -Encoding utf8
        chmod +x $loggingStubKubectl
    }

    $originalPath2 = $env:PATH
    try {
        $env:PATH = "${stubDir}${pathSep}${originalPath2}"
        try { & (Join-Path $scriptsRoot 'Apply-AksChangePlan.ps1') -PlanPath $planKcResult.outPath | Out-Null } catch { }
    }
    finally {
        $env:PATH = $originalPath2
    }

    $invocations = if (Test-Path -LiteralPath $stubLogPath) { Get-Content -LiteralPath $stubLogPath -Raw } else { '' }
    $sawKubeconfigOnContextCheck = $invocations -match [regex]::Escape('config current-context --kubeconfig ' + $fakeKubeconfigPath)
    Add-Result '-KubeconfigPath: se propaga a la invocacion real de "kubectl config current-context"' $sawKubeconfigOnContextCheck $invocations
}
catch {
    Add-Result '-KubeconfigPath: se propaga a la invocacion real de "kubectl config current-context"' $false $_.Exception.Message
}

# ---- Reporte ----

$results | Format-Table -Property Case, Status -AutoSize
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })

Write-Host ""
Write-Host "Total: $($results.Count) - PASS: $(($results.Count) - ($failed.Count)) - FAIL: $($failed.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })

if ($failed.Count -gt 0) {
    Write-Host ""
    Write-Host "Casos fallidos:" -ForegroundColor Red
    foreach ($f in $failed) {
        Write-Host "- $($f.Case)" -ForegroundColor Red
        Write-Host "  $($f.Detail)" -ForegroundColor Red
    }
    exit 1
}
