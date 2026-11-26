<#
Harness de pruebas de los scripts del dominio manage-azure-resources. `az`
se intercepta anteponiendo este directorio (que contiene az.cmd -> stub
az-stub.ps1) al PATH del proceso de prueba unicamente -- cero red, cero
Azure real. Mismo patron que run-script-tests.ps1 de AKS (stub kubectl.cmd).
#>

$scriptsRoot = Split-Path -Parent $PSScriptRoot
$testRoot = Join-Path $PSScriptRoot 'tmp'
if (Test-Path -LiteralPath $testRoot) { Remove-Item -LiteralPath $testRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $testRoot | Out-Null

$pathSep = [System.IO.Path]::PathSeparator
$isWindows = [System.Runtime.InteropServices.RuntimeInformation]::IsOSPlatform([System.Runtime.InteropServices.OSPlatform]::Windows)

# En Linux, az.cmd no es ejecutable; crear un stub shell que delegue a pwsh az-stub.ps1
if (-not $isWindows) {
    $azStubShell = Join-Path $PSScriptRoot 'az'
    $azStubPs1 = Join-Path $PSScriptRoot 'az-stub.ps1'
    @"
#!/bin/sh
exec pwsh -NoProfile -File "$azStubPs1" "`$@"
"@ | Set-Content -LiteralPath $azStubShell -Encoding utf8
    chmod +x $azStubShell
}

$env:PATH = "${PSScriptRoot}${pathSep}${env:PATH}"

. (Join-Path $scriptsRoot 'Azure-Common.ps1')

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Case, [bool]$Pass, [string]$Detail = '')
    $results.Add([PSCustomObject]@{ Case = $Case; Status = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

$tenantId = 'tenant-stub-0001'
$subId = 'sub-stub-0001'

function New-TestAzureOperation {
    param(
        [string]$OperationId, [string]$Action = 'create', [bool]$Destructive = $false,
        [string]$ResourceType = 'Microsoft.Storage/storageAccounts', [string[]]$Argv = @('storage', 'account', 'create', '-n', 'st1', '-g', 'rg1')
    )
    return [ordered]@{
        operationId       = $OperationId
        phase             = if ($Destructive) { 'destructive' } else { 'nonDestructive' }
        action            = $Action
        tenantId          = $tenantId
        subscriptionId    = $subId
        resourceGroup     = 'rg1'
        resourceId        = "/subscriptions/$subId/resourceGroups/rg1/providers/$ResourceType/st1"
        resourceType      = $ResourceType
        apiVersion        = '2023-01-01'
        executor          = 'azureCli'
        argv              = $Argv
        bodyHash          = $null
        preconditionHash  = 'x'
        currentState      = @{}
        desiredState      = @{ sku = 'Standard_LRS' }
        dependencies      = @()
        destructive       = $Destructive
        reversible        = (-not $Destructive)
        backupStrategy    = 'N/A'
        rollbackStrategy  = 'N/A'
        verification      = @('az resource show --ids x')
        retryPolicy       = @{ maxAttempts = 1; retryableCodes = @(); delaySeconds = 0 }
        timeoutSeconds    = 600
        expectedFinalState = 'ok'
    }
}

# ============================================================
# Azure-Common.ps1 -- journal + hash + secret scan
# ============================================================

try {
    $planForHash = [PSCustomObject]@{ a = 1; b = 2; validated = $true; validationHash = 'zzz'; validationEvidence = @{}; reviewStatus = 'x' }
    $h1 = Get-AzurePlanCanonicalHash -Plan $planForHash
    $planForHash.validated = $false
    $h2 = Get-AzurePlanCanonicalHash -Plan $planForHash
    Add-Result 'Get-AzurePlanCanonicalHash: ignora validated/validationHash/validationEvidence/reviewStatus' ($h1 -eq $h2)
}
catch { Add-Result 'Get-AzurePlanCanonicalHash: ignora campos de validacion' $false $_.Exception.Message }

try {
    $findings = @(Find-AzureSensitiveJsonProperties -Object ([PSCustomObject]@{ password = 'realvalue123' }))
    Add-Result 'Find-AzureSensitiveJsonProperties: detecta password literal' ($findings.Count -eq 1)
    $findingsOk = @(Find-AzureSensitiveJsonProperties -Object ([PSCustomObject]@{ password = '${AZURE_SECRET_X}' }))
    Add-Result 'Find-AzureSensitiveJsonProperties: ignora placeholder' ($findingsOk.Count -eq 0)
}
catch { Add-Result 'Find-AzureSensitiveJsonProperties' $false $_.Exception.Message }

try {
    $journalHash = 'journal-test-hash-1'
    $opIds = @('op-a', 'op-b')
    $localRoot = Get-AzureExecutionsDir
    $journalPath = Join-Path $localRoot "$journalHash.json"
    if (Test-Path -LiteralPath $journalPath) { Remove-Item -LiteralPath $journalPath -Force }
    if (Test-Path -LiteralPath "$journalPath.lock") { Remove-Item -LiteralPath "$journalPath.lock" -Force }

    $started1 = Start-AzureJournaledOperation -PlanValidationHash $journalHash -AllOperationIds $opIds -OperationId 'op-a'
    Complete-AzureJournaledOperation -PlanValidationHash $journalHash -AllOperationIds $opIds -OperationId 'op-a' -FinalState 'succeeded' -ResultId 'done'
    $startedAgain = Start-AzureJournaledOperation -PlanValidationHash $journalHash -AllOperationIds $opIds -OperationId 'op-a'
    Add-Result 'Journal: primera vez in-progress=true, reintento de succeeded se omite' ($started1 -eq $true -and $startedAgain -eq $false)

    Remove-Item -LiteralPath $journalPath -Force -ErrorAction SilentlyContinue
}
catch { Add-Result 'Journal: ciclo start/complete/skip-retry' $false $_.Exception.Message }

# ============================================================
# Test-AzureEnvironment.ps1 (usa el stub az)
# ============================================================

try {
    $envResult = & (Join-Path $scriptsRoot 'Test-AzureEnvironment.ps1') | ConvertFrom-Json
    Add-Result 'Test-AzureEnvironment: detecta CLI y sesion via stub' ($envResult.azureCli.installed -eq $true -and $envResult.session.loggedIn -eq $true -and $envResult.session.tenantId -eq $tenantId)
}
catch { Add-Result 'Test-AzureEnvironment' $false $_.Exception.Message }

# ============================================================
# Get-AzureInventory.ps1 (usa el stub az)
# ============================================================

$invPath = $null
try {
    $originalLocalRoot = Get-AzureLocalRoot
    $inv = & (Join-Path $scriptsRoot 'Get-AzureInventory.ps1') -SubscriptionId $subId -ResourceGroup 'rg1'
    $invPath = $inv.path
    Add-Result 'Get-AzureInventory: escribe snapshot con resourceCount>0' ((Test-Path -LiteralPath $invPath) -and $inv.resourceCount -gt 0)
}
catch { Add-Result 'Get-AzureInventory' $false $_.Exception.Message }

# ============================================================
# Invoke-AzureRead.ps1
# ============================================================

try {
    & (Join-Path $scriptsRoot 'Invoke-AzureRead.ps1') -Argv @('storage', 'account', 'create', '-n', 'st1') | Out-Null
    Add-Result 'Invoke-AzureRead: rechaza verbo mutante' $false 'no lanzo excepcion'
}
catch { Add-Result 'Invoke-AzureRead: rechaza verbo mutante' ($_.Exception.Message -match 'no es de solo lectura') }

try {
    $readResult = & (Join-Path $scriptsRoot 'Invoke-AzureRead.ps1') -Argv @('resource', 'show', '--ids', '/subscriptions/x')
    Add-Result 'Invoke-AzureRead: permite show via stub' ($null -ne $readResult)
}
catch { Add-Result 'Invoke-AzureRead: permite show' $false $_.Exception.Message }

try {
    & (Join-Path $scriptsRoot 'Invoke-AzureRead.ps1') -Argv @('rest', '--method', 'post', '--url', 'https://x') | Out-Null
    Add-Result 'Invoke-AzureRead: rechaza az rest --method post' $false 'no lanzo excepcion'
}
catch { Add-Result 'Invoke-AzureRead: rechaza az rest --method post' ($_.Exception.Message -match 'no es de solo lectura') }

# ============================================================
# Invoke-AzureWhatIf.ps1 (ManualDiff -- no llama a az)
# ============================================================

try {
    $curPath = Join-Path $testRoot 'current.json'
    $desPath = Join-Path $testRoot 'desired.json'
    '{"sku":"Standard_LRS","tags":{"env":"dev"}}' | Set-Content -LiteralPath $curPath -Encoding utf8
    '{"sku":"Standard_GRS","tags":{"env":"dev"}}' | Set-Content -LiteralPath $desPath -Encoding utf8
    $diff = & (Join-Path $scriptsRoot 'Invoke-AzureWhatIf.ps1') -Mode ManualDiff -CurrentStatePath $curPath -DesiredStatePath $desPath
    Add-Result 'Invoke-AzureWhatIf ManualDiff: detecta cambio de sku' ($diff.hasChanges -eq $true -and @($diff.changedProperties | Where-Object { $_.property -eq 'sku' }).Count -eq 1)
}
catch { Add-Result 'Invoke-AzureWhatIf ManualDiff' $false $_.Exception.Message }

# ============================================================
# New-AzureChangePlan.ps1
# ============================================================

$planPath = $null
try {
    $ops = @(New-TestAzureOperation -OperationId 'create-storageaccounts-st1')
    $planPath = Join-Path $testRoot 'plan-ok.json'
    $planResult = & (Join-Path $scriptsRoot 'New-AzureChangePlan.ps1') -TenantId $tenantId -SubscriptionId $subId -Operations $ops -InventoryPaths @($invPath) -OutPath $planPath
    Add-Result 'New-AzureChangePlan: genera plan valido' (Test-Path -LiteralPath $planPath)
}
catch { Add-Result 'New-AzureChangePlan: genera plan valido' $false $_.Exception.Message }

try {
    $dupOps = @((New-TestAzureOperation -OperationId 'dup-1'), (New-TestAzureOperation -OperationId 'dup-1'))
    & (Join-Path $scriptsRoot 'New-AzureChangePlan.ps1') -TenantId $tenantId -SubscriptionId $subId -Operations $dupOps -InventoryPaths @($invPath) -OutPath (Join-Path $testRoot 'plan-dup.json') | Out-Null
    Add-Result 'New-AzureChangePlan: rechaza operationId duplicado' $false 'no lanzo excepcion'
}
catch { Add-Result 'New-AzureChangePlan: rechaza operationId duplicado' ($_.Exception.Message -match 'duplicado') }

try {
    $rgOp1 = New-TestAzureOperation -OperationId 'delete-rg-rg1' -Action 'delete' -Destructive $true -ResourceType 'Microsoft.Resources/resourceGroups'
    $rgOp2 = New-TestAzureOperation -OperationId 'delete-storageaccounts-st2' -Action 'delete' -Destructive $true
    & (Join-Path $scriptsRoot 'New-AzureChangePlan.ps1') -TenantId $tenantId -SubscriptionId $subId -Operations @() -PendingDeleteOperations @($rgOp1, $rgOp2) -InventoryPaths @($invPath) -OutPath (Join-Path $testRoot 'plan-rg-mixed.json') | Out-Null
    Add-Result 'New-AzureChangePlan: rechaza RG-delete mezclado con otra eliminacion' $false 'no lanzo excepcion'
}
catch { Add-Result 'New-AzureChangePlan: rechaza RG-delete mezclado con otra eliminacion' ($_.Exception.Message -match 'Resource Group completo') }

# ============================================================
# Test-AzureChangePlan.ps1
# ============================================================

try {
    $valResult = & (Join-Path $scriptsRoot 'Test-AzureChangePlan.ps1') -PlanPath $planPath
    Add-Result 'Test-AzureChangePlan: valida plan limpio -> validated=true' ($valResult.validated -eq $true -and -not [string]::IsNullOrWhiteSpace($valResult.validationHash))
}
catch { Add-Result 'Test-AzureChangePlan: valida plan limpio' $false $_.Exception.Message }

try {
    $secretOps = @(New-TestAzureOperation -OperationId 'create-storageaccounts-st9')
    $secretOps[0]['currentState'] = @{ password = 'literalPlano123' }
    $secretPlanPath = Join-Path $testRoot 'plan-secret.json'
    & (Join-Path $scriptsRoot 'New-AzureChangePlan.ps1') -TenantId $tenantId -SubscriptionId $subId -Operations $secretOps -InventoryPaths @($invPath) -OutPath $secretPlanPath | Out-Null
    & (Join-Path $scriptsRoot 'Test-AzureChangePlan.ps1') -PlanPath $secretPlanPath | Out-Null
    Add-Result 'Test-AzureChangePlan: bloquea secreto literal' $false 'no lanzo excepcion'
}
catch { Add-Result 'Test-AzureChangePlan: bloquea secreto literal' ($_.Exception.Message -match 'bloqueante') }

try {
    'not json' | Add-Content -LiteralPath $invPath
    $driftOps = @(New-TestAzureOperation -OperationId 'create-storageaccounts-drift')
    $driftPlanPath = Join-Path $testRoot 'plan-drift.json'
    & (Join-Path $scriptsRoot 'New-AzureChangePlan.ps1') -TenantId $tenantId -SubscriptionId $subId -Operations $driftOps -InventoryPaths @($invPath) -OutPath $driftPlanPath | Out-Null
    'append changes the hash of the file after the plan referenced it' | Add-Content -LiteralPath $invPath
    & (Join-Path $scriptsRoot 'Test-AzureChangePlan.ps1') -PlanPath $driftPlanPath | Out-Null
    Add-Result 'Test-AzureChangePlan: detecta drift de inventario' $false 'no lanzo excepcion'
}
catch { Add-Result 'Test-AzureChangePlan: detecta drift de inventario' ($_.Exception.Message -match 'bloqueante') }

# ============================================================
# Apply-AzureChangePlan.ps1
# ============================================================

try {
    & (Join-Path $scriptsRoot 'Apply-AzureChangePlan.ps1') -PlanPath (Join-Path $testRoot 'plan-dup.json') 2>$null | Out-Null
}
catch { }

try {
    $unvalidatedOps = @(New-TestAzureOperation -OperationId 'create-storageaccounts-unval')
    $unvalidatedPlanPath = Join-Path $testRoot 'plan-unvalidated.json'
    & (Join-Path $scriptsRoot 'New-AzureChangePlan.ps1') -TenantId $tenantId -SubscriptionId $subId -Operations $unvalidatedOps -InventoryPaths @($invPath) -OutPath $unvalidatedPlanPath | Out-Null
    & (Join-Path $scriptsRoot 'Apply-AzureChangePlan.ps1') -PlanPath $unvalidatedPlanPath | Out-Null
    Add-Result 'Apply-AzureChangePlan: rechaza plan sin validated=true' $false 'no lanzo excepcion'
}
catch { Add-Result 'Apply-AzureChangePlan: rechaza plan sin validated=true' ($_.Exception.Message -match 'validated=true') }

try {
    $applyOps = @(New-TestAzureOperation -OperationId 'create-storageaccounts-apply1')
    $applyPlanPath = Join-Path $testRoot 'plan-apply-ok.json'
    & (Join-Path $scriptsRoot 'New-AzureChangePlan.ps1') -TenantId $tenantId -SubscriptionId $subId -Operations $applyOps -InventoryPaths @($invPath) -OutPath $applyPlanPath | Out-Null
    & (Join-Path $scriptsRoot 'Test-AzureChangePlan.ps1') -PlanPath $applyPlanPath | Out-Null
    $applyResult = & (Join-Path $scriptsRoot 'Apply-AzureChangePlan.ps1') -PlanPath $applyPlanPath
    Add-Result 'Apply-AzureChangePlan: aplica operacion valida via stub' (@($applyResult.applied).Count -eq 1)

    $applyResult2 = & (Join-Path $scriptsRoot 'Apply-AzureChangePlan.ps1') -PlanPath $applyPlanPath
    Add-Result 'Apply-AzureChangePlan: reintento no re-aplica (ya succeeded en journal)' (@($applyResult2.applied).Count -eq 0)
}
catch { Add-Result 'Apply-AzureChangePlan: aplica + no reintenta' $false $_.Exception.Message }

# ============================================================
# Apply-AzureDeletePlan.ps1
# ============================================================

try {
    $delOps = @(New-TestAzureOperation -OperationId 'delete-storageaccounts-del1' -Action 'delete' -Destructive $true)
    $delPlanPath = Join-Path $testRoot 'plan-delete-ok.json'
    & (Join-Path $scriptsRoot 'New-AzureChangePlan.ps1') -TenantId $tenantId -SubscriptionId $subId -Operations @() -PendingDeleteOperations $delOps -InventoryPaths @($invPath) -OutPath $delPlanPath | Out-Null
    & (Join-Path $scriptsRoot 'Test-AzureChangePlan.ps1') -PlanPath $delPlanPath | Out-Null

    try {
        & (Join-Path $scriptsRoot 'Apply-AzureDeletePlan.ps1') -PlanPath $delPlanPath -OperationIds @('operationid-que-no-existe') | Out-Null
        Add-Result 'Apply-AzureDeletePlan: rechaza OperationIds que no coincide con el plan' $false 'no lanzo excepcion'
    }
    catch {
        Add-Result 'Apply-AzureDeletePlan: rechaza OperationIds que no coincide con el plan' ($_.Exception.Message -match 'no estan en pendingDeleteOperations')
    }

    $delResult = & (Join-Path $scriptsRoot 'Apply-AzureDeletePlan.ps1') -PlanPath $delPlanPath -OperationIds @('delete-storageaccounts-del1')
    $backupWritten = Test-Path -LiteralPath (Join-Path (Get-AzureBackupsDir) "$((Get-Content -LiteralPath $delPlanPath -Raw | ConvertFrom-Json).validationHash)-delete-storageaccounts-del1.json")
    Add-Result 'Apply-AzureDeletePlan: elimina via stub y escribe respaldo pre-delete' (@($delResult.deleted).Count -eq 1 -and $backupWritten)
}
catch { Add-Result 'Apply-AzureDeletePlan: flujo completo' $false $_.Exception.Message }

try {
    $rgOnly = @(New-TestAzureOperation -OperationId 'delete-rg-onlyrg' -Action 'delete' -Destructive $true -ResourceType 'Microsoft.Resources/resourceGroups')
    $otherDel = @(New-TestAzureOperation -OperationId 'delete-storageaccounts-other' -Action 'delete' -Destructive $true)
    $rgPlanPath = Join-Path $testRoot 'plan-rg-solo.json'
    # Generar el plan salteando el chequeo de New-AzureChangePlan (que ya lo bloquea) escribiendolo a mano para probar el chequeo de Apply-AzureDeletePlan de forma aislada.
    $rawPlan = Get-Content -LiteralPath $delPlanPath -Raw | ConvertFrom-Json
    $rawPlan.pendingDeleteOperations = @($rgOnly + $otherDel)
    $rawPlan.validated = $false
    ($rawPlan | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $rgPlanPath -Encoding utf8
    & (Join-Path $scriptsRoot 'Test-AzureChangePlan.ps1') -PlanPath $rgPlanPath | Out-Null
    Add-Result 'Test-AzureChangePlan: rechaza RG + otra eliminacion en el mismo lote (armado directo)' $false 'no lanzo excepcion'
}
catch {
    $blockersRaw = (Get-Content -LiteralPath $rgPlanPath -Raw | ConvertFrom-Json).validationEvidence.blockers -join ' | '
    Add-Result 'Test-AzureChangePlan: rechaza RG + otra eliminacion en el mismo lote (armado directo)' ($blockersRaw -match 'Resource Group completo')
}

# ============================================================
# Test-AzurePostChange.ps1
# ============================================================

try {
    $postResult = & (Join-Path $scriptsRoot 'Test-AzurePostChange.ps1') -PlanPath $applyPlanPath
    Add-Result 'Test-AzurePostChange: readback via stub sin error' ($null -ne $postResult.operationResults)
}
catch { Add-Result 'Test-AzurePostChange' $false $_.Exception.Message }

# ============================================================
# New-AzureRollbackPlan.ps1
# ============================================================

try {
    $rollbackOutPath = Join-Path $testRoot 'rollback-plan.json'
    $rollbackResult = & (Join-Path $scriptsRoot 'New-AzureRollbackPlan.ps1') -OriginalPlanPath $applyPlanPath -OutPath $rollbackOutPath
    Add-Result 'New-AzureRollbackPlan: genera plan inverso (create -> delete)' ((Test-Path -LiteralPath $rollbackOutPath) -and $rollbackResult.inverseOperations -eq 1)
}
catch { Add-Result 'New-AzureRollbackPlan' $false $_.Exception.Message }

# ============================================================
# Limpieza + Resumen
# ============================================================

# Calcular los hashes de journal/backups ANTES de borrar $testRoot (los
# planes que los generaron viven ahi -- borrar primero perderia la
# referencia para poder limpiar .local\azure\executions\ y \backups\).
$planHashCleanup = $null
if ($planPath -and (Test-Path -LiteralPath $applyPlanPath)) {
    $planHashCleanup = try { (Get-Content -LiteralPath $applyPlanPath -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue).validationHash } catch { $null }
}
$delPlanHashCleanup = $null
$delPlanPathForCleanup = Join-Path $testRoot 'plan-delete-ok.json'
if (Test-Path -LiteralPath $delPlanPathForCleanup) {
    $delPlanHashCleanup = try { (Get-Content -LiteralPath $delPlanPathForCleanup -Raw -ErrorAction SilentlyContinue | ConvertFrom-Json -ErrorAction SilentlyContinue).validationHash } catch { $null }
}

Remove-Item -LiteralPath $testRoot -Recurse -Force -ErrorAction SilentlyContinue
Get-ChildItem -LiteralPath (Get-AzureExecutionsDir) -Filter 'journal-test-hash-1.json*' -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
if ($invPath -and (Test-Path -LiteralPath $invPath)) { Remove-Item -LiteralPath $invPath -Force -ErrorAction SilentlyContinue }
if ($planHashCleanup) {
    Get-ChildItem -LiteralPath (Get-AzureExecutionsDir) -Filter "$planHashCleanup.json*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}
if ($delPlanHashCleanup) {
    Get-ChildItem -LiteralPath (Get-AzureExecutionsDir) -Filter "$delPlanHashCleanup.json*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
    Get-ChildItem -LiteralPath (Get-AzureBackupsDir) -Filter "$delPlanHashCleanup-*" -ErrorAction SilentlyContinue | Remove-Item -Force -ErrorAction SilentlyContinue
}

$total = $results.Count
$passed = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$failed = $total - $passed

$results | Format-Table -AutoSize Case, Status | Out-String | Write-Host
Write-Host "`n=== Resumen: $passed/$total PASS ($failed FAIL) ===" -ForegroundColor $(if ($failed -eq 0) { 'Green' } else { 'Red' })
if ($failed -gt 0) {
    Write-Host "Casos fallidos:" -ForegroundColor Red
    $results | Where-Object { $_.Status -eq 'FAIL' } | ForEach-Object { Write-Host " - $($_.Case): $($_.Detail)" -ForegroundColor Red }
    exit 1
}
exit 0
