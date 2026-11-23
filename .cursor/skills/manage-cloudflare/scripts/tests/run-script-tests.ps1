<#
Harness de pruebas offline del dominio Cloudflare. Cero llamadas de red
reales: Invoke-CloudflareApiRequest (en Cloudflare-Common.ps1) revisa un
seam de pruebas ($Global:CloudflareApiRequestMock) que este harness define
ANTES de invocar cualquier script -- ver el comentario en esa funcion para
por que se eligio una variable global en vez de redefinir la funcion (cada
script vuelve a dot-sourcear Cloudflare-Common.ps1 en su propio scope, lo
que pisaria una funcion redefinida pero no una variable global).
#>

$ErrorActionPreference = 'Stop'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $scriptsRoot 'Cloudflare-Common.ps1')

$tmpRoot = Join-Path $PSScriptRoot 'tmp'
if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

$results = [System.Collections.Generic.List[object]]::new()
$createdPlanFiles = [System.Collections.Generic.List[string]]::new()
$createdJournalHashes = [System.Collections.Generic.List[string]]::new()
$createdBackupFiles = [System.Collections.Generic.List[string]]::new()

function Add-Result {
    param([string]$Name, [bool]$Pass, [string]$Detail = '')
    $results.Add([PSCustomObject]@{ Case = $Name; Status = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

function Test-Throws {
    param([scriptblock]$Action)
    try { & $Action; return $false } catch { return $true }
}

# --- Mock de Invoke-CloudflareApiRequest ---
$script:ApiBase = Get-CloudflareApiBaseUri
$Global:CfMockAccountValid = $true
$Global:CfMockBackupEmpty = $false
$Global:CfMockWriteSucceeds = $true

$Global:CloudflareApiRequestMock = {
    param($Method, $Uri, $Body, $Headers)
    if ($Method -eq 'GET' -and $Uri -match '/accounts/') {
        if (-not $Global:CfMockAccountValid) { return $null }
        return [PSCustomObject]@{ success = $true; result = [PSCustomObject]@{ id = 'acct-test-0001'; name = 'Test Account' } }
    }
    if ($Method -eq 'GET' -and $Uri -match '/to-delete/') {
        if ($Global:CfMockBackupEmpty) { return $null }
        return [PSCustomObject]@{ success = $true; result = [PSCustomObject]@{ id = 'rec-del-1'; name = 'stale.example.com' } }
    }
    if ($Method -in @('POST', 'PUT', 'PATCH', 'DELETE')) {
        if (-not $Global:CfMockWriteSucceeds) { return $null }
        return [PSCustomObject]@{ success = $true; result = [PSCustomObject]@{ id = 'result-ok'; method = $Method } }
    }
    return [PSCustomObject]@{ success = $true; result = [PSCustomObject]@{ id = 'generic'; uri = $Uri } }
}

$TestAccountId = 'acct-test-0001'
$TestZoneId = 'zone-test-0001'

function New-TestOp {
    param(
        [string]$OperationId,
        [string]$Phase = 'nonDestructive',
        [string]$Action = 'update',
        [string]$ResourceType = 'dns_record',
        [string]$ResourceId = 'rec1',
        [string]$ResourceName = 'test.example.com',
        [string]$Executor = 'cloudflareRest',
        [string]$Method = 'PATCH',
        [string]$Uri = "$($script:ApiBase)/zones/$TestZoneId/dns_records/rec1",
        [array]$Argv = @(),
        $Body = [PSCustomObject]@{ content = '1.2.3.4' },
        [bool]$IsDestructive = $false
    )
    return [PSCustomObject]@{
        operationId         = $OperationId
        phase               = $Phase
        action              = $Action
        accountId           = $TestAccountId
        zoneId              = $TestZoneId
        resourceType        = $ResourceType
        resourceId          = $ResourceId
        resourceName        = $ResourceName
        executor            = $Executor
        method              = $Method
        uri                 = $Uri
        argv                = $Argv
        body                = $Body
        bodyHash            = $null
        preconditionHash    = 'n-a'
        currentState        = [PSCustomObject]@{ content = '5.6.7.8' }
        desiredState        = [PSCustomObject]@{ content = '1.2.3.4' }
        dependencies        = @()
        isDestructive       = $IsDestructive
        reversible          = $true
        backupStrategy      = 'n/a'
        rollbackStrategy    = 'n/a'
        verification        = @()
        retryPolicy         = [PSCustomObject]@{ maxAttempts = 1; retryableCodes = @(); delaySeconds = 0 }
        timeoutSeconds      = 60
        expectedFinalState  = 'ok'
        expectedReadback    = 'ok'
    }
}

function New-TestInventory {
    param([string]$Name, [string]$Content = 'seed')
    $path = Join-Path $tmpRoot "$Name.json"
    [PSCustomObject]@{ marker = $Content; capturedAtUtc = (Get-Date).ToUniversalTime().ToString('o') } | ConvertTo-Json | Set-Content -LiteralPath $path -Encoding utf8
    return $path
}

$newPlanScript = Join-Path $scriptsRoot 'New-CloudflareChangePlan.ps1'
$testPlanScript = Join-Path $scriptsRoot 'Test-CloudflareChangePlan.ps1'
$applyPlanScript = Join-Path $scriptsRoot 'Apply-CloudflareChangePlan.ps1'
$newDeleteScript = Join-Path $scriptsRoot 'New-CloudflareDeletePlan.ps1'
$testDeleteScript = Join-Path $scriptsRoot 'Test-CloudflareDeletePlan.ps1'
$applyDeleteScript = Join-Path $scriptsRoot 'Apply-CloudflareDeletePlan.ps1'

# =========================================================================
# 1. Hash canonico -- estable y sensible a cambios.
# =========================================================================
$planForHash = [PSCustomObject]@{ a = 1; b = 'x'; validated = $false; validationHash = $null }
$h1 = Get-CloudflarePlanCanonicalHash -Plan $planForHash
$h2 = Get-CloudflarePlanCanonicalHash -Plan $planForHash
Add-Result 'Hash canonico estable (mismo input, mismo hash)' ($h1 -eq $h2)

$planForHash.validated = $true
$planForHash.validationHash = 'algo'
$h3 = Get-CloudflarePlanCanonicalHash -Plan $planForHash
Add-Result 'Hash canonico excluye validated/validationHash (no cambia)' ($h1 -eq $h3)

$planChanged = [PSCustomObject]@{ a = 2; b = 'x'; validated = $false; validationHash = $null }
$h4 = Get-CloudflarePlanCanonicalHash -Plan $planChanged
Add-Result 'Hash canonico sensible a cambios reales' ($h1 -ne $h4)

# =========================================================================
# 2. Journal -- lock, escritura atomica, 8 estados, no re-ejecuta succeeded.
# =========================================================================
$journalTestHash = "test-journal-$([Guid]::NewGuid().ToString('N').Substring(0,8))"
$createdJournalHashes.Add($journalTestHash)
$allOps = @('op1', 'op2')

$started1 = Start-CloudflareJournaledOperation -PlanValidationHash $journalTestHash -AllOperationIds $allOps -OperationId 'op1'
Add-Result 'Journal: Start en pending devuelve true' ($started1 -eq $true)

$startedAgain = Start-CloudflareJournaledOperation -PlanValidationHash $journalTestHash -AllOperationIds $allOps -OperationId 'op1'
Add-Result 'Journal: Start sobre in-progress devuelve false (no reintenta)' ($startedAgain -eq $false)

Complete-CloudflareJournaledOperation -PlanValidationHash $journalTestHash -AllOperationIds $allOps -OperationId 'op1' -FinalState 'succeeded' -ResultId 'r1'
$journalAfterComplete = Read-CloudflareExecutionJournal -JournalPath (Get-CloudflareExecutionJournalPath -PlanValidationHash $journalTestHash) -PlanValidationHash $journalTestHash -OperationIds $allOps
Add-Result 'Journal: estado succeeded persistido' ($journalAfterComplete.operations.op1.state -eq 'succeeded')

$startedAfterSucceeded = Start-CloudflareJournaledOperation -PlanValidationHash $journalTestHash -AllOperationIds $allOps -OperationId 'op1'
Add-Result 'Journal: succeeded nunca se re-ejecuta' ($startedAfterSucceeded -eq $false)

$corruptJournalThrows = Test-Throws { Read-CloudflareExecutionJournal -JournalPath (Get-CloudflareExecutionJournalPath -PlanValidationHash $journalTestHash) -PlanValidationHash $journalTestHash -OperationIds @('op1', 'op2', 'op-extra') }
Add-Result 'Journal: conjunto de operationIds distinto es bloqueo seguro' $corruptJournalThrows

# =========================================================================
# 3. Escaneo de secretos.
# =========================================================================
$secretObj = [PSCustomObject]@{ clientSecret = 'realvalue1234567890' }
$findings1 = Find-CloudflareSensitiveJsonProperties -Object $secretObj
Add-Result 'Secretos: valor literal en propiedad sensible se detecta' (@($findings1).Count -eq 1)

$placeholderObj = [PSCustomObject]@{ token = '${CLOUDFLARE_API_TOKEN}'; apiKey = '***REDACTED***'; secret = $null }
$findings2 = Find-CloudflareSensitiveJsonProperties -Object $placeholderObj
Add-Result 'Secretos: placeholders `${VAR}`/`***REDACTED***`/null no disparan' (@($findings2).Count -eq 0)

$exemptObj = [PSCustomObject]@{ resourceId = 'a-very-long-id-that-looks-like-a-token-but-is-not-1234567890' }
$findings3 = Find-CloudflareSensitiveJsonProperties -Object $exemptObj
Add-Result 'Secretos: resourceId/id exento aunque sea largo' (@($findings3).Count -eq 0)

$pemFinding = Find-CloudflareSensitiveRawText -Text "key content`n-----BEGIN PRIVATE KEY-----`nMIIExample`n-----END PRIVATE KEY-----"
Add-Result 'Secretos: clave PEM tipo Origin CA se detecta en texto crudo' (@($pemFinding).Count -gt 0)

# =========================================================================
# 4. New-CloudflareChangePlan.ps1 -- rechazos estructurales.
# =========================================================================
$inv1 = New-TestInventory -Name 'inv-basic'

$opA = New-TestOp -OperationId 'op-a'
$opADup = New-TestOp -OperationId 'op-a'
$dupThrows = Test-Throws {
    & $newPlanScript -AccountId $TestAccountId -Objective 'test' -InventoryPaths @($inv1) -Operations @($opA, $opADup) | Out-Null
}
Add-Result 'New-CloudflareChangePlan: operationId duplicado rechazado' $dupThrows

$opMisplaced = New-TestOp -OperationId 'op-misplaced' -IsDestructive $true
$misplacedThrows = Test-Throws {
    & $newPlanScript -AccountId $TestAccountId -Objective 'test' -InventoryPaths @($inv1) -Operations @($opMisplaced) | Out-Null
}
Add-Result 'New-CloudflareChangePlan: isDestructive=true en Operations rechazado' $misplacedThrows

$opValid = New-TestOp -OperationId 'op-valid-1'
$validPlanJson = & $newPlanScript -AccountId $TestAccountId -ZoneIds @($TestZoneId) -Objective 'update DNS record' -InventoryPaths @($inv1) -Operations @($opValid) -RiskAndImpactAnalysis 'bajo' -BackupStrategy 'inventario previo' -VerificationPlan 'readback' -RollbackStrategy 'revertir a currentState' | ConvertFrom-Json
$validPlanPath = $validPlanJson.path
if ($validPlanPath) { $createdPlanFiles.Add($validPlanPath) }
Add-Result 'New-CloudflareChangePlan: plan valido se crea' (Test-Path -LiteralPath $validPlanPath)

# =========================================================================
# 5. Test-CloudflareChangePlan.ps1
# =========================================================================
$testResult1 = & $testPlanScript -PlanPath $validPlanPath | ConvertFrom-Json
Add-Result 'Test-CloudflareChangePlan: plan bien formado valida OK' ($testResult1.validated -eq $true -and @($testResult1.blockers).Count -eq 0)

$inv2 = New-TestInventory -Name 'inv-graphql'
$opMutation = New-TestOp -OperationId 'op-mutation' -Executor 'cloudflareGraphQL' -Method 'POST' -Uri "$($script:ApiBase)/graphql" -Body ([PSCustomObject]@{ query = 'mutation { doThing }' })
$mutationPlanJson = & $newPlanScript -AccountId $TestAccountId -ZoneIds @($TestZoneId) -Objective 'graphql mutation attempt' -InventoryPaths @($inv2) -Operations @($opMutation) | ConvertFrom-Json
$mutationPlanPath = $mutationPlanJson.path
if ($mutationPlanPath) { $createdPlanFiles.Add($mutationPlanPath) }
$mutationTestResult = & $testPlanScript -PlanPath $mutationPlanPath | ConvertFrom-Json
Add-Result 'Test-CloudflareChangePlan: bloquea mutation GraphQL' ($mutationTestResult.validated -eq $false -and (@($mutationTestResult.blockers) | Where-Object { $_ -match 'mutation' }).Count -gt 0)

$inv3 = New-TestInventory -Name 'inv-drift'
$opDrift = New-TestOp -OperationId 'op-drift'
$driftPlanJson = & $newPlanScript -AccountId $TestAccountId -ZoneIds @($TestZoneId) -Objective 'drift test' -InventoryPaths @($inv3) -Operations @($opDrift) | ConvertFrom-Json
$driftPlanPath = $driftPlanJson.path
if ($driftPlanPath) { $createdPlanFiles.Add($driftPlanPath) }
Add-Content -LiteralPath $inv3 -Value 'tampered' -Encoding utf8
$driftTestResult = & $testPlanScript -PlanPath $driftPlanPath | ConvertFrom-Json
Add-Result 'Test-CloudflareChangePlan: bloquea drift de inventario' ($driftTestResult.validated -eq $false -and (@($driftTestResult.blockers) | Where-Object { $_ -match 'drift' }).Count -gt 0)

$secretPlanRaw = Get-Content -LiteralPath $mutationPlanPath -Raw
# Reusar un plan ya escrito para inyectar un secreto crudo y confirmar el bloqueante de texto.
$inv4 = New-TestInventory -Name 'inv-secret'
$opWithSecret = New-TestOp -OperationId 'op-secret'
$opWithSecret | Add-Member -NotePropertyName 'apiToken' -NotePropertyValue 'sk-realtokenvalue1234567890' -Force
$secretPlanJson = & $newPlanScript -AccountId $TestAccountId -ZoneIds @($TestZoneId) -Objective 'secret test' -InventoryPaths @($inv4) -Operations @($opWithSecret) | ConvertFrom-Json
$secretPlanPath = $secretPlanJson.path
if ($secretPlanPath) { $createdPlanFiles.Add($secretPlanPath) }
$secretTestResult = & $testPlanScript -PlanPath $secretPlanPath | ConvertFrom-Json
Add-Result 'Test-CloudflareChangePlan: bloquea secreto embebido' ($secretTestResult.validated -eq $false -and @($secretTestResult.blockers).Count -gt 0)

# =========================================================================
# 6. Apply-CloudflareChangePlan.ps1
# =========================================================================
$applyResult = & $applyPlanScript -PlanPath $validPlanPath | ConvertFrom-Json
$validatedPlanAfterApply = Get-Content -LiteralPath $validPlanPath -Raw | ConvertFrom-Json
$createdJournalHashes.Add($validatedPlanAfterApply.validationHash)
Add-Result 'Apply-CloudflareChangePlan: ejecuta contra el mock y devuelve resumen' ((@($applyResult.applied)).Count -eq 1)

$journalAfterApply = Read-CloudflareExecutionJournal -JournalPath (Get-CloudflareExecutionJournalPath -PlanValidationHash $validatedPlanAfterApply.validationHash) -PlanValidationHash $validatedPlanAfterApply.validationHash -OperationIds @('op-valid-1')
Add-Result 'Apply-CloudflareChangePlan: journal marca succeeded' ($journalAfterApply.operations.'op-valid-1'.state -eq 'succeeded')

# Hash alterado tras validar: editar el archivo directamente (sin re-validar) debe bloquear el Apply.
$inv5 = New-TestInventory -Name 'inv-hashalter'
$opHashAlter = New-TestOp -OperationId 'op-hashalter'
$hashAlterPlanJson = & $newPlanScript -AccountId $TestAccountId -ZoneIds @($TestZoneId) -Objective 'hash alter test' -InventoryPaths @($inv5) -Operations @($opHashAlter) | ConvertFrom-Json
$hashAlterPlanPath = $hashAlterPlanJson.path
if ($hashAlterPlanPath) { $createdPlanFiles.Add($hashAlterPlanPath) }
& $testPlanScript -PlanPath $hashAlterPlanPath | Out-Null
$hashAlterPlanObj = Get-Content -LiteralPath $hashAlterPlanPath -Raw | ConvertFrom-Json
$hashAlterPlanObj.objective = 'objetivo modificado despues de validar'
$hashAlterPlanObj | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $hashAlterPlanPath -Encoding utf8
$hashAlterThrows = Test-Throws { & $applyPlanScript -PlanPath $hashAlterPlanPath | Out-Null }
Add-Result 'Apply-CloudflareChangePlan: rechaza plan con hash alterado tras validar' $hashAlterThrows

# Operacion destructiva colada en approvedOperations (plan armado a mano, sin pasar por New-).
$inv6 = New-TestInventory -Name 'inv-sneaky'
$sneakyOp = New-TestOp -OperationId 'op-sneaky' -IsDestructive $true
$sneakyOp.phase = 'nonDestructive'
$sneakyPlan = [ordered]@{
    schemaVersion = 1; planId = [Guid]::NewGuid().ToString(); createdAtUtc = (Get-Date).ToUniversalTime().ToString('o')
    expiresAtUtc = (Get-Date).ToUniversalTime().AddHours(24).ToString('o'); ownerTranscriptId = $null
    connectionMode = 'rest'; accountId = $TestAccountId; zoneIds = @($TestZoneId); objective = 'sneaky test'
    inventoryHashes = @([PSCustomObject]@{ path = $inv6; hash = (Get-CloudflareFileSha256 -Path $inv6) })
    preStateHash = 'n-a'; approvedOperations = @($sneakyOp); pendingDeleteOperations = @()
    riskAndImpactAnalysis = ''; backupStrategy = ''; verificationPlan = ''; rollbackStrategy = ''
    validated = $false; validationHash = $null; validationEvidence = $null; reviewStatus = 'not-reviewed'
}
$sneakyPlanPath = Join-Path $tmpRoot 'sneaky-plan.json'
($sneakyPlan | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $sneakyPlanPath -Encoding utf8
$sneakyPlanObj = Get-Content -LiteralPath $sneakyPlanPath -Raw | ConvertFrom-Json
$sneakyPlanObj.validated = $true
$sneakyPlanObj.validationHash = Get-CloudflarePlanCanonicalHash -Plan $sneakyPlanObj
($sneakyPlanObj | ConvertTo-Json -Depth 30) | Set-Content -LiteralPath $sneakyPlanPath -Encoding utf8
$sneakyThrows = Test-Throws { & $applyPlanScript -PlanPath $sneakyPlanPath | Out-Null }
Add-Result 'Apply-CloudflareChangePlan: rechaza isDestructive=true colado en approvedOperations' $sneakyThrows

# =========================================================================
# 7. New-/Test-/Apply-CloudflareDeletePlan.ps1
# =========================================================================
$inv7 = New-TestInventory -Name 'inv-delete-reject'
$nonDestructiveForDelete = New-TestOp -OperationId 'op-not-destructive'
$rejectNonDestructiveThrows = Test-Throws {
    & $newDeleteScript -AccountId $TestAccountId -InventoryPaths @($inv7) -Operations @($nonDestructiveForDelete) | Out-Null
}
Add-Result 'New-CloudflareDeletePlan: rechaza operacion no destructiva' $rejectNonDestructiveThrows

$inv8 = New-TestInventory -Name 'inv-delete-a'
$deleteOpA = New-TestOp -OperationId 'op-delete-a' -Phase 'destructive' -Action 'delete' -ResourceType 'dns_record' -ResourceId 'rec-del-1' -Executor 'cloudflareRest' -Method 'DELETE' -Uri "$($script:ApiBase)/zones/$TestZoneId/dns_records/to-delete/rec-del-1" -IsDestructive $true
$deletePlanAJson = & $newDeleteScript -AccountId $TestAccountId -InventoryPaths @($inv8) -Operations @($deleteOpA) -BackupPlan 'GET antes de DELETE' -RecoveryAnalysis 'recrear con currentState' | ConvertFrom-Json
$deletePlanAPath = $deletePlanAJson.path
if ($deletePlanAPath) { $createdPlanFiles.Add($deletePlanAPath) }
Add-Result 'New-CloudflareDeletePlan: plan destructivo valido se crea' (Test-Path -LiteralPath $deletePlanAPath)

$deleteTestResultA = & $testDeleteScript -DeletePlanPath $deletePlanAPath | ConvertFrom-Json
Add-Result 'Test-CloudflareDeletePlan: plan destructivo bien formado valida OK' ($deleteTestResultA.validated -eq $true)

$deletePlanAObj = Get-Content -LiteralPath $deletePlanAPath -Raw | ConvertFrom-Json
$createdJournalHashes.Add($deletePlanAObj.validationHash)

$wrongIdsThrows = Test-Throws { & $applyDeleteScript -DeletePlanPath $deletePlanAPath -OperationIds @('id-que-no-existe') | Out-Null }
Add-Result 'Apply-CloudflareDeletePlan: rechaza OperationIds que no coinciden exacto' $wrongIdsThrows

$Global:CfMockBackupEmpty = $true
$backupEmptyThrows = Test-Throws { & $applyDeleteScript -DeletePlanPath $deletePlanAPath -OperationIds @('op-delete-a') | Out-Null }
Add-Result 'Apply-CloudflareDeletePlan: bloquea si el respaldo pre-delete viene vacio' $backupEmptyThrows
$Global:CfMockBackupEmpty = $false

$backupFileACandidate = Join-Path (Get-CloudflareBackupsDir) "$($deletePlanAObj.validationHash)-op-delete-a.json"
Add-Result 'Apply-CloudflareDeletePlan: no escribe respaldo si el GET de respaldo fallo' (-not (Test-Path -LiteralPath $backupFileACandidate))

# Plan B, fresco, para el camino de exito completo (respaldo + delete real contra el mock).
$inv9 = New-TestInventory -Name 'inv-delete-b'
$deleteOpB = New-TestOp -OperationId 'op-delete-b' -Phase 'destructive' -Action 'delete' -ResourceType 'dns_record' -ResourceId 'rec-del-2' -Executor 'cloudflareRest' -Method 'DELETE' -Uri "$($script:ApiBase)/zones/$TestZoneId/dns_records/to-delete/rec-del-2" -IsDestructive $true
$deletePlanBJson = & $newDeleteScript -AccountId $TestAccountId -InventoryPaths @($inv9) -Operations @($deleteOpB) | ConvertFrom-Json
$deletePlanBPath = $deletePlanBJson.path
if ($deletePlanBPath) { $createdPlanFiles.Add($deletePlanBPath) }
& $testDeleteScript -DeletePlanPath $deletePlanBPath | Out-Null
$deletePlanBObj = Get-Content -LiteralPath $deletePlanBPath -Raw | ConvertFrom-Json
$createdJournalHashes.Add($deletePlanBObj.validationHash)

$applyDeleteBResult = & $applyDeleteScript -DeletePlanPath $deletePlanBPath -OperationIds @('op-delete-b') | ConvertFrom-Json
Add-Result 'Apply-CloudflareDeletePlan: elimina con respaldo previo exitoso contra el mock' ((@($applyDeleteBResult.applied)).Count -eq 1)

$backupFileB = Join-Path (Get-CloudflareBackupsDir) "$($deletePlanBObj.validationHash)-op-delete-b.json"
if (Test-Path -LiteralPath $backupFileB) { $createdBackupFiles.Add($backupFileB) }
Add-Result 'Apply-CloudflareDeletePlan: escribe respaldo antes del DELETE real' (Test-Path -LiteralPath $backupFileB)

$journalAfterDeleteB = Read-CloudflareExecutionJournal -JournalPath (Get-CloudflareExecutionJournalPath -PlanValidationHash $deletePlanBObj.validationHash) -PlanValidationHash $deletePlanBObj.validationHash -OperationIds @('op-delete-b')
Add-Result 'Apply-CloudflareDeletePlan: journal marca succeeded tras eliminar' ($journalAfterDeleteB.operations.'op-delete-b'.state -eq 'succeeded')

# =========================================================================
# Reporte final
# =========================================================================
$results | Format-Table -AutoSize | Out-String | Write-Host

$passCount = @($results | Where-Object { $_.Status -eq 'PASS' }).Count
$failCount = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
Write-Host ""
Write-Host "PASS: $passCount, FAIL: $failCount" -ForegroundColor $(if ($failCount -eq 0) { 'Green' } else { 'Red' })

# --- Limpieza de artefactos reales creados durante las pruebas ---
foreach ($p in $createdPlanFiles) { if (Test-Path -LiteralPath $p) { Remove-Item -LiteralPath $p -Force -ErrorAction SilentlyContinue } }
foreach ($h in ($createdJournalHashes | Select-Object -Unique)) {
    if ([string]::IsNullOrWhiteSpace($h)) { continue }
    $jPath = Get-CloudflareExecutionJournalPath -PlanValidationHash $h
    if (Test-Path -LiteralPath $jPath) { Remove-Item -LiteralPath $jPath -Force -ErrorAction SilentlyContinue }
    if (Test-Path -LiteralPath "$jPath.lock") { Remove-Item -LiteralPath "$jPath.lock" -Force -ErrorAction SilentlyContinue }
}
foreach ($b in $createdBackupFiles) { if (Test-Path -LiteralPath $b) { Remove-Item -LiteralPath $b -Force -ErrorAction SilentlyContinue } }
Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
$Global:CloudflareApiRequestMock = $null

if ($failCount -gt 0) { exit 1 } else { exit 0 }
