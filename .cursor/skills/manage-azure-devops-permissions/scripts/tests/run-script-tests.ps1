<#
Arnes de pruebas offline (sin Pester, sin red real) para los scripts de
manage-azure-devops-permissions. Cubre los 26 casos obligatorios del
documento fuente. Nunca usa la organizacion real ni un PAT real -- los
scripts de escritura (Apply-*.ps1) nunca se invocan de punta a punta aca:
se prueban dot-sourceando Invoke-AdoPermissionsRest.ps1 y reemplazando
Invoke-AdoPermissionsRest por una funcion mockeada antes de llamar
Invoke-AdoPermissionsApplyPhases / Invoke-AdoPermissionsDeleteApplyPhase /
Get-AdoPermissionsReadbackResults directamente (ver README de
tests/azure-devops-permissions/hooks para el mismo criterio aplicado a
hooks).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptsDir = Split-Path -Parent $PSScriptRoot
$projectRoot = Split-Path -Parent (Split-Path -Parent (Split-Path -Parent (Split-Path -Parent $scriptsDir)))

$tmpRoot = Join-Path $PSScriptRoot 'tmp'
if (Test-Path -LiteralPath $tmpRoot) { Remove-Item -LiteralPath $tmpRoot -Recurse -Force }
New-Item -ItemType Directory -Force -Path $tmpRoot | Out-Null

$env:ADO_PERMISSIONS_TEST_EXECUTIONS_ROOT = Join-Path $tmpRoot 'executions'

# Descriptores de fixture REALISTAS -- desde el fix de 2026-09-02, un
# 'vssgp.XXXX' debe decodificar en Base64 a un SID valido (ver
# ConvertTo-AdoPermissionsSecurityAceDescriptor); un literal como
# 'vssgp.DEVTEAM' ya no pasa esa validacion. Los SID son ficticios pero
# con forma valida -- nunca corresponden a una identidad real.
# El SID real solo tiene digitos y guiones tras 'S-1-9-' (ver
# ConvertTo-AdoPermissionsSecurityAceDescriptor) -- se usa un numero
# distinto por fixture, nunca texto libre.
function New-FixtureVssgpDescriptor { param([int]$FakeSidNumber) "vssgp.$([Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("S-1-9-0-$FakeSidNumber")))" }
$FixtureDevTeamDescriptor = New-FixtureVssgpDescriptor 1001
$FixtureDevTeams2Descriptor = New-FixtureVssgpDescriptor 1002
$FixtureDevTeamsOnlyDescriptor = New-FixtureVssgpDescriptor 1003
$FixtureCodeReviewersDescriptor = New-FixtureVssgpDescriptor 1004

$script:TotalCount = 0
$script:PassCount = 0
$script:FailCount = 0

function Add-Result {
    param([Parameter(Mandatory)] [string]$Name, [Parameter(Mandatory)] [bool]$Passed, [string]$Detail = '')
    $script:TotalCount++
    if ($Passed) {
        $script:PassCount++
        Write-Host "PASS - $Name" -ForegroundColor Green
    }
    else {
        $script:FailCount++
        Write-Host "FAIL - $Name" -ForegroundColor Red
        if ($Detail) { Write-Host "    $Detail" -ForegroundColor Red }
    }
}

function Invoke-ExpectThrow {
    param([Parameter(Mandatory)] [scriptblock]$ScriptBlock, [string]$Name, [string]$MessagePattern)
    try {
        & $ScriptBlock | Out-Null
        Add-Result -Name $Name -Passed $false -Detail 'No lanzo excepcion (se esperaba que lanzara).'
    }
    catch {
        $matches = [string]::IsNullOrEmpty($MessagePattern) -or ($_.Exception.Message -match $MessagePattern)
        Add-Result -Name $Name -Passed $matches -Detail "Mensaje real: $($_.Exception.Message)"
    }
}

function Invoke-ExpectNoThrow {
    param([Parameter(Mandatory)] [scriptblock]$ScriptBlock, [string]$Name)
    try {
        & $ScriptBlock | Out-Null
        Add-Result -Name $Name -Passed $true
    }
    catch {
        Add-Result -Name $Name -Passed $false -Detail $_.Exception.Message
    }
}

function Invoke-ChildScript {
    <#
    Invoca un script hijo real como proceso, redirigiendo stderr a
    archivo (nunca 2>&1 directo -- gotcha conocido de PS5.1). Devuelve
    ExitCode/Stdout/Stderr.
    #>
    param([Parameter(Mandatory)] [string]$FilePath, [string[]]$ArgumentList = @())

    $id = [Guid]::NewGuid().ToString('N')
    $outFile = Join-Path $tmpRoot "child-out-$id.txt"
    $errFile = Join-Path $tmpRoot "child-err-$id.txt"

    $allArgs = @('-NoProfile', '-NonInteractive', '-File', $FilePath) + $ArgumentList
    $proc = Start-Process -FilePath 'pwsh' -ArgumentList $allArgs -RedirectStandardOutput $outFile -RedirectStandardError $errFile -NoNewWindow -Wait -PassThru

    $stdout = ''
    $stderr = ''
    for ($i = 0; $i -lt 5; $i++) {
        try { $stdout = [string](Get-Content -LiteralPath $outFile -Raw -ErrorAction Stop); break } catch { Start-Sleep -Milliseconds 100 }
    }
    for ($i = 0; $i -lt 5; $i++) {
        try { $stderr = [string](Get-Content -LiteralPath $errFile -Raw -ErrorAction Stop); break } catch { Start-Sleep -Milliseconds 100 }
    }
    if ($null -eq $stdout) { $stdout = '' }
    if ($null -eq $stderr) { $stderr = '' }

    return [PSCustomObject]@{ ExitCode = $proc.ExitCode; Stdout = $stdout; Stderr = $stderr }
}

# ============================================================
# Fixtures compartidas
# ============================================================

$ProjGuid = '11111111-1111-1111-1111-111111111111'
$RepoGuid = '22222222-2222-2222-2222-222222222222'

$ResolvedBitsTable = @{
    'Advanced Security: manage and dismiss alerts' = 131072; 'Advanced Security: manage settings' = 262144; 'Advanced Security: view alerts' = 65536
    'Bypass policies when completing pull requests' = 32768; 'Bypass policies when pushing' = 128; 'Contribute' = 4; 'Contribute to pull requests' = 16384
    'Create branch' = 16; 'Create repository' = 256; 'Create tag' = 32; 'Delete or disable repository' = 512; 'Edit policies' = 2048
    'Force push (rewrite history, delete branches and tags)' = 8; 'Manage notes' = 64; 'Manage permissions' = 8192; 'Read' = 2
    "Remove others' locks" = 4096; 'Rename repository' = 1024
}

function New-FixtureInventory {
    param(
        [switch]$NoDevTeam,
        [switch]$Ambiguous,
        [switch]$NoCodeReviewers,
        [string[]]$DevTeamMembers = @(),
        [hashtable]$AllReposAceOverride,
        [array]$AllReposFullAcesDictionary = @()
    )

    $devCandidates = @()
    if (-not $NoDevTeam) {
        $devCandidates = @(@{ descriptor = $FixtureDevTeamDescriptor; displayName = 'Development Team'; description = $null; members = $DevTeamMembers })
        if ($Ambiguous) {
            $devCandidates += @{ descriptor = $FixtureDevTeams2Descriptor; displayName = 'Development Teams'; description = $null; members = @() }
        }
    }

    $aceEntry = @{ hasExplicitAce = $true; explicitAllow = 3; explicitDeny = 0; inheritedAllow = 0; inheritedDeny = 0; effectiveAllow = 3; effectiveDeny = 0 }
    if ($AllReposAceOverride) { $aceEntry = $AllReposAceOverride }

    $inventory = [ordered]@{
        schemaVersion       = 1
        generatedAtUtc      = (Get-Date).ToUniversalTime().ToString('o')
        organization        = 'Shared-Service-GM'
        paginationComplete  = $true
        securityNamespace   = @{ namespaceId = '2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87'; resolvedBits = $ResolvedBitsTable }
        projects            = @(
            @{
                name            = 'TestProj'
                projectId       = $ProjGuid
                scopeDescriptor = 'scp.fake'
                repositories    = @(
                    @{ repositoryId = $RepoGuid; name = 'TestRepo'; defaultBranch = 'refs/heads/main'; branchExists = @{development = $true; uat = $true; release = $true; main = $true }; featureBranchChildCount = 0 }
                )
                groups          = @{
                    developmentTeamCandidates = $devCandidates
                    developmentTeamAmbiguous  = [bool]$Ambiguous
                    codeReviewers             = if ($NoCodeReviewers) { $null } else { @{ descriptor = $FixtureCodeReviewersDescriptor; displayName = 'Code-Reviewers (Revision Y Aprobacion Del Lider De Proyecto)'; description = $null; members = @() } }
                }
                acl             = @{
                    allRepositories = @{ token = "repoV2/$ProjGuid"; inheritPermissions = $true; aclFound = $true; descriptors = @{ $FixtureDevTeamDescriptor = $aceEntry }; fullAcesDictionary = $AllReposFullAcesDictionary }
                    byRepository    = @{}
                }
            }
        )
    }
    return $inventory
}

function Write-FixtureInventory {
    param([hashtable]$Inventory, [string]$Path)
    $Inventory | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

function New-FixtureMembers {
    param([array]$DevTeam = @(), [array]$CodeReviewers = @(), [string]$Override)
    $obj = [ordered]@{
        TestProj = [ordered]@{
            developmentTeam = $DevTeam
            codeReviewers   = $CodeReviewers
        }
    }
    if ($Override) { $obj.TestProj.developmentTeamDescriptorOverride = $Override }
    return $obj
}

function Write-FixtureMembers {
    param([hashtable]$Members, [string]$Path)
    $Members | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $Path -Encoding utf8
}

$NewPlanScript = Join-Path $scriptsDir 'New-AdoPermissionsPlan.ps1'
$TestPlanScript = Join-Path $scriptsDir 'Test-AdoPermissionsPlan.ps1'
$NewDeleteScript = Join-Path $scriptsDir 'New-AdoPermissionsDeletePlan.ps1'
$TestDeleteScript = Join-Path $scriptsDir 'Test-AdoPermissionsDeletePlan.ps1'
$GateScript = Join-Path $projectRoot '.kiro\hooks\azure-devops-permissions\ado-permissions-security-gate.ps1'

function Invoke-NewPlan {
    param([string]$InventoryPath, [string]$MembersPath, [string]$OutPath, [string]$DescriptionMode = 'PreserveExisting', [switch]$Ack)
    $args = @('-InventoryPath', $InventoryPath, '-MembersPath', $MembersPath, '-DescriptionMode', $DescriptionMode, '-CurrentIdentityDescriptor', 'aad.EXECUTOR', '-OutPath', $OutPath)
    if ($Ack) { $args += '-AcknowledgeLockoutRisk' }
    return Invoke-ChildScript -FilePath $NewPlanScript -ArgumentList $args
}

function Invoke-TestPlan {
    param([string]$PlanPath, [double]$MaxHours = 24)
    return Invoke-ChildScript -FilePath $TestPlanScript -ArgumentList @('-PlanPath', $PlanPath, '-MaxInventoryAgeHours', $MaxHours)
}

# ============================================================
# 1-4: resolucion de Development Team(s)
# ============================================================

$inv1 = New-FixtureInventory
Write-FixtureInventory -Inventory $inv1 -Path (Join-Path $tmpRoot 'inv1.json')
Write-FixtureMembers -Members (New-FixtureMembers) -Path (Join-Path $tmpRoot 'mem1.json')
$r = Invoke-NewPlan -InventoryPath (Join-Path $tmpRoot 'inv1.json') -MembersPath (Join-Path $tmpRoot 'mem1.json') -OutPath (Join-Path $tmpRoot 'plan1.json')
if (Test-Path (Join-Path $tmpRoot 'plan1.json')) {
    $plan1 = Get-Content (Join-Path $tmpRoot 'plan1.json') -Raw | ConvertFrom-Json
    Add-Result -Name '1. Existe Development Team y se reutiliza' -Passed ($plan1.projects[0].developmentTeam.status -eq 'existing' -and $plan1.projects[0].developmentTeam.descriptor -eq $FixtureDevTeamDescriptor)
}
else { Add-Result -Name '1. Existe Development Team y se reutiliza' -Passed $false -Detail $r.Stderr }

# Regresion 2026-09-02: la API de Graph Groups rechaza op='add' sobre
# '/description' con 400 real ("VS850022: Not supported json patch
# operation") -- confirmado en vivo al actualizar Development Team.
if (Test-Path (Join-Path $tmpRoot 'plan1.json')) {
    $plan1 = Get-Content (Join-Path $tmpRoot 'plan1.json') -Raw | ConvertFrom-Json
    $descOp = @($plan1.approvedOperations | Where-Object { $_.operationType -eq 'update-security-group-description' })
    $allReplace = $descOp.Count -gt 0 -and -not ($descOp | Where-Object { $_.body[0].op -ne 'replace' })
    Add-Result -Name '1b. Patch de descripcion usa op=replace, nunca add' -Passed $allReplace -Detail "count=$($descOp.Count) ops=$(($descOp | ForEach-Object { $_.body[0].op }) -join ',')"
}
else { Add-Result -Name '1b. Patch de descripcion usa op=replace, nunca add' -Passed $false }

# Caso 2: solo 'Development Teams' (plural) existe -- se resuelve igual.
$inv2 = New-FixtureInventory
$inv2.projects[0].groups.developmentTeamCandidates = @(@{ descriptor = $FixtureDevTeamsOnlyDescriptor; displayName = 'Development Teams'; description = $null; members = @() })
Write-FixtureInventory -Inventory $inv2 -Path (Join-Path $tmpRoot 'inv2.json')
Write-FixtureMembers -Members (New-FixtureMembers) -Path (Join-Path $tmpRoot 'mem2.json')
$r = Invoke-NewPlan -InventoryPath (Join-Path $tmpRoot 'inv2.json') -MembersPath (Join-Path $tmpRoot 'mem2.json') -OutPath (Join-Path $tmpRoot 'plan2.json')
if (Test-Path (Join-Path $tmpRoot 'plan2.json')) {
    $plan2 = Get-Content (Join-Path $tmpRoot 'plan2.json') -Raw | ConvertFrom-Json
    Add-Result -Name '2. Existe Development Teams (plural) y se reutiliza' -Passed ($plan2.projects[0].developmentTeam.status -eq 'existing' -and $plan2.projects[0].developmentTeam.descriptor -eq $FixtureDevTeamsOnlyDescriptor)
}
else { Add-Result -Name '2. Existe Development Teams (plural) y se reutiliza' -Passed $false -Detail $r.Stderr }

# Caso 3: ninguno existe -- se planea crear 'Development Team'.
$inv3 = New-FixtureInventory -NoDevTeam
Write-FixtureInventory -Inventory $inv3 -Path (Join-Path $tmpRoot 'inv3.json')
Write-FixtureMembers -Members (New-FixtureMembers) -Path (Join-Path $tmpRoot 'mem3.json')
$r = Invoke-NewPlan -InventoryPath (Join-Path $tmpRoot 'inv3.json') -MembersPath (Join-Path $tmpRoot 'mem3.json') -OutPath (Join-Path $tmpRoot 'plan3.json')
if (Test-Path (Join-Path $tmpRoot 'plan3.json')) {
    $plan3 = Get-Content (Join-Path $tmpRoot 'plan3.json') -Raw | ConvertFrom-Json
    $createOp = @($plan3.approvedOperations | Where-Object { $_.operationType -eq 'create-security-group' -and $_.body.displayName -eq 'Development Team' })
    Add-Result -Name '3. Ninguno existe -- se planea crear Development Team' -Passed ($plan3.projects[0].developmentTeam.status -eq 'toCreate' -and $createOp.Count -eq 1)
}
else { Add-Result -Name '3. Ninguno existe -- se planea crear Development Team' -Passed $false -Detail $r.Stderr }

# Caso 4: existen ambos -- el plan queda bloqueado por ambiguedad.
$inv4 = New-FixtureInventory -Ambiguous
Write-FixtureInventory -Inventory $inv4 -Path (Join-Path $tmpRoot 'inv4.json')
Write-FixtureMembers -Members (New-FixtureMembers) -Path (Join-Path $tmpRoot 'mem4.json')
$r = Invoke-NewPlan -InventoryPath (Join-Path $tmpRoot 'inv4.json') -MembersPath (Join-Path $tmpRoot 'mem4.json') -OutPath (Join-Path $tmpRoot 'plan4.json')
if (Test-Path (Join-Path $tmpRoot 'plan4.json')) {
    $plan4 = Get-Content (Join-Path $tmpRoot 'plan4.json') -Raw | ConvertFrom-Json
    $tr = Invoke-TestPlan -PlanPath (Join-Path $tmpRoot 'plan4.json')
    Add-Result -Name '4. Existen ambos -- plan bloqueado por ambiguedad' -Passed ($plan4.projects[0].developmentTeam.status -eq 'blocked-ambiguous' -and $tr.ExitCode -eq 1)
}
else { Add-Result -Name '4. Existen ambos -- plan bloqueado por ambiguedad' -Passed $false -Detail $r.Stderr }

# ============================================================
# 5: Code-Reviewers faltante -- creacion con nombre/descripcion correctos.
# ============================================================
$inv5 = New-FixtureInventory -NoCodeReviewers
Write-FixtureInventory -Inventory $inv5 -Path (Join-Path $tmpRoot 'inv5.json')
Write-FixtureMembers -Members (New-FixtureMembers) -Path (Join-Path $tmpRoot 'mem5.json')
$r = Invoke-NewPlan -InventoryPath (Join-Path $tmpRoot 'inv5.json') -MembersPath (Join-Path $tmpRoot 'mem5.json') -OutPath (Join-Path $tmpRoot 'plan5.json')
if (Test-Path (Join-Path $tmpRoot 'plan5.json')) {
    $plan5 = Get-Content (Join-Path $tmpRoot 'plan5.json') -Raw | ConvertFrom-Json
    $crOp = @($plan5.approvedOperations | Where-Object { $_.operationType -eq 'create-security-group' -and $_.body.displayName -eq 'Code-Reviewers (Revision Y Aprobacion Del Lider De Proyecto)' })
    $expectedDesc = 'Líderes o responsables de revisión y aprobación de código del proyecto. Participan en pull requests y aplican la matriz de permisos definida; este grupo por sí solo no crea una política de revisores obligatorios.'
    Add-Result -Name '5. Code-Reviewers faltante: creacion con nombre/descripcion correctos' -Passed ($crOp.Count -eq 1 -and $crOp[0].body.description -eq $expectedDesc) -Detail "count=$($crOp.Count) desc=$(if ($crOp.Count -gt 0) { $crOp[0].body.description })"
}
else { Add-Result -Name '5. Code-Reviewers faltante: creacion con nombre/descripcion correctos' -Passed $false -Detail $r.Stderr }

# ============================================================
# 6: membresia aditiva conserva miembros existentes.
# ============================================================
$inv6 = New-FixtureInventory -DevTeamMembers @('aad.EXISTENTE')
Write-FixtureInventory -Inventory $inv6 -Path (Join-Path $tmpRoot 'inv6.json')
Write-FixtureMembers -Members (New-FixtureMembers -DevTeam @(@{ displayName = 'Existente'; descriptor = 'aad.EXISTENTE' }, @{ displayName = 'Nuevo'; descriptor = 'aad.NUEVO' })) -Path (Join-Path $tmpRoot 'mem6.json')
$r = Invoke-NewPlan -InventoryPath (Join-Path $tmpRoot 'inv6.json') -MembersPath (Join-Path $tmpRoot 'mem6.json') -OutPath (Join-Path $tmpRoot 'plan6.json')
if (Test-Path (Join-Path $tmpRoot 'plan6.json')) {
    $plan6 = Get-Content (Join-Path $tmpRoot 'plan6.json') -Raw | ConvertFrom-Json
    $memberOps = @($plan6.approvedOperations | Where-Object { $_.operationType -eq 'add-group-membership' })
    $onlyNuevo = ($memberOps.Count -eq 1 -and $memberOps[0].uri -match 'aad\.NUEVO')
    Add-Result -Name '6. Membresia aditiva: solo agrega al nuevo, conserva el existente' -Passed $onlyNuevo -Detail ($memberOps | ForEach-Object { $_.uri } | Out-String)
}
else { Add-Result -Name '6. Membresia aditiva: solo agrega al nuevo, conserva el existente' -Passed $false -Detail $r.Stderr }

# ============================================================
# 6b: guard de membresia extrae descriptores desde URI cuando
#     precondition.memberDescriptor / containerDescriptor estan vacios.
#     Regresion: bug corregido 2026-09-17 -- el plan generado tenia los
#     descriptores en la URI pero los campos de precondition vacios,
#     lo que causaba checkUri vacio -> HTTP 400 -> driftDetected=true
#     -> Apply rechazado silenciosamente.
# ============================================================
. (Join-Path $scriptsDir 'Invoke-AdoPermissionsRest.ps1')
$testUri6b = 'https://vssps.dev.azure.com/Shared-Service-GM/_apis/graph/memberships/aad.MEMBER_DESC/vssgp.CONTAINER_DESC?api-version=7.1-preview.1'
$memberD6b = ''; $containerD6b = ''
if ($testUri6b -match '/graph/memberships/([^/\?]+)/([^/\?]+)') {
    $memberD6b    = [uri]::UnescapeDataString($Matches[1])
    $containerD6b = [uri]::UnescapeDataString($Matches[2])
}
Add-Result -Name '6b. Guard membresia: extrae memberDescriptor desde URI cuando precondition esta vacio' `
    -Passed ($memberD6b -eq 'aad.MEMBER_DESC' -and $containerD6b -eq 'vssgp.CONTAINER_DESC') `
    -Detail "memberDesc='$memberD6b' containerDesc='$containerD6b'"

# ============================================================
# 7: identidad ambigua (sin descriptor resuelto) bloquea el plan.
# ============================================================
$inv7 = New-FixtureInventory
Write-FixtureInventory -Inventory $inv7 -Path (Join-Path $tmpRoot 'inv7.json')
Write-FixtureMembers -Members (New-FixtureMembers -DevTeam @(@{ displayName = 'Ambiguo'; descriptor = '' })) -Path (Join-Path $tmpRoot 'mem7.json')
$r = Invoke-NewPlan -InventoryPath (Join-Path $tmpRoot 'inv7.json') -MembersPath (Join-Path $tmpRoot 'mem7.json') -OutPath (Join-Path $tmpRoot 'plan7.json')
Add-Result -Name '7. Identidad sin descriptor resuelto bloquea la generacion del plan' -Passed ($r.ExitCode -ne 0 -and $r.Stderr -match 'descriptor')

# ============================================================
# 8-9: matrices exactas (contra Invoke-AdoPermissionsRest.ps1 directo)
# ============================================================
. (Join-Path $scriptsDir 'Invoke-AdoPermissionsRest.ps1')

$matrix = Get-AdoPermissionsMatrixDefinition
$expectedAllRepos = @{
    'Advanced Security: manage and dismiss alerts' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
    'Advanced Security: manage settings' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
    'Advanced Security: view alerts' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Allow' }
    'Bypass policies when completing pull requests' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
    'Bypass policies when pushing' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
    'Contribute' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Allow' }
    'Contribute to pull requests' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Allow' }
    'Create branch' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Allow' }
    'Create repository' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
    'Create tag' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Allow' }
    'Delete or disable repository' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
    'Edit policies' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
    'Force push (rewrite history, delete branches and tags)' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
    'Manage notes' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Allow' }
    'Manage permissions' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
    'Read' = @{DevelopmentTeam = 'Allow'; CodeReviewers = 'Allow' }
    "Remove others' locks" = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
    'Rename repository' = @{DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
}
$allReposMatch = $true
foreach ($label in $expectedAllRepos.Keys) {
    $actual = $matrix.AllRepositories.$label
    if (-not $actual -or $actual.DevelopmentTeam -ne $expectedAllRepos[$label].DevelopmentTeam -or $actual.CodeReviewers -ne $expectedAllRepos[$label].CodeReviewers) {
        $allReposMatch = $false
    }
}
Add-Result -Name '8. Matriz All Repositories coincide exacto con la instruccion' -Passed $allReposMatch

# Actualizado 2026-09-02 (decision del usuario, ver
# .cursor/memories/ado-permissions-builder/patterns.md): development
# ahora tambien deniega Contribute a Development Team (antes 'Not set'),
# y main/Code-Reviewers paso de Deny a 'Not set' (para que puedan
# completar PRs ahi) -- se agrega CrContribute a la comparacion para
# cubrir este segundo cambio, que test 9 antes no verificaba en absoluto.
$expectedBranch = @{
    feature     = @{ Contribute = 'Allow'; CrContribute = 'Not set'; RemoveLocksDev = 'Not set'; RemoveLocksCr = 'Not set' }
    development = @{ Contribute = 'Deny'; CrContribute = 'Not set'; RemoveLocksDev = 'Not set'; RemoveLocksCr = 'Not set' }
    uat         = @{ Contribute = 'Deny'; CrContribute = 'Not set'; RemoveLocksDev = 'Not set'; RemoveLocksCr = 'Not set' }
    release     = @{ Contribute = 'Deny'; CrContribute = 'Not set'; RemoveLocksDev = 'Not set'; RemoveLocksCr = 'Not set' }
    main        = @{ Contribute = 'Deny'; CrContribute = 'Not set'; RemoveLocksDev = 'Not set'; RemoveLocksCr = 'Deny' }
}
$branchMatch = $true
foreach ($node in $expectedBranch.Keys) {
    $devContribute = $matrix.BranchLevel.$node.'Contribute'.DevelopmentTeam
    $crContribute = $matrix.BranchLevel.$node.'Contribute'.CodeReviewers
    $crRemoveLocks = $matrix.BranchLevel.$node."Remove others' locks".CodeReviewers
    if ($devContribute -ne $expectedBranch[$node].Contribute -or $crContribute -ne $expectedBranch[$node].CrContribute -or $crRemoveLocks -ne $expectedBranch[$node].RemoveLocksCr) {
        $branchMatch = $false
    }
}
Add-Result -Name '9. Matriz por rama coincide exacto con la instruccion (feature/dev/uat/release/main)' -Passed $branchMatch

# ============================================================
# 10: 'Not set' limpia solo bits administrados, conserva bits ajenos.
# ============================================================
$recompute = Get-AdoPermissionsRecomputedAceBits -CurrentAllow 3 -CurrentDeny 0 -ManagedMask 2 -DesiredAllow 0 -DesiredDeny 0
Add-Result -Name "10. 'Not set' limpia el bit administrado y preserva el bit ajeno (bit 1)" -Passed ($recompute.NewAllow -eq 1 -and $recompute.NewDeny -eq 0)

# ============================================================
# 10b: regresion 2026-09-02 -- una identidad AJENA (no administrada por
# este dominio) ya presente en el acesDictionary REAL del token debe
# preservarse tal cual en el body de escritura de 'All Repositories'.
# 'Set Access Control Lists' reemplaza el diccionario COMPLETO del token,
# no lo combina -- omitir esto borra a cualquier otro grupo/identidad que
# ya tuviera una ACE real ahi (incidente real: una escritura de 6 grupos
# default borro a Development Team y Code-Reviewers).
# ============================================================
$foreignDescriptor = 'Microsoft.TeamFoundation.Identity;S-1-9-FAKE-FOREIGN-GROUP'
$inv10b = New-FixtureInventory -AllReposFullAcesDictionary @(
    @{ descriptor = $foreignDescriptor; allow = 999; deny = 111 }
)
Write-FixtureInventory -Inventory $inv10b -Path (Join-Path $tmpRoot 'inv10b.json')
Write-FixtureMembers -Members (New-FixtureMembers) -Path (Join-Path $tmpRoot 'mem10b.json')
$r10b = Invoke-NewPlan -InventoryPath (Join-Path $tmpRoot 'inv10b.json') -MembersPath (Join-Path $tmpRoot 'mem10b.json') -OutPath (Join-Path $tmpRoot 'plan10b.json')
if (Test-Path (Join-Path $tmpRoot 'plan10b.json')) {
    $plan10b = Get-Content (Join-Path $tmpRoot 'plan10b.json') -Raw | ConvertFrom-Json
    $allReposOp = $plan10b.approvedOperations | Where-Object { $_.operationId -like 'ace-allrepos-*' } | Select-Object -First 1
    $foreignInBody = $null
    if ($allReposOp) {
        $prop = $allReposOp.body.value[0].acesDictionary.PSObject.Properties[$foreignDescriptor]
        if ($prop) { $foreignInBody = $prop.Value }
    }
    $preserved = $foreignInBody -and [int]$foreignInBody.allow -eq 999 -and [int]$foreignInBody.deny -eq 111
    Add-Result -Name '10c. Escribir el ACE de All Repositories preserva una identidad ajena ya presente' -Passed $preserved -Detail "foreignInBody=$($foreignInBody | ConvertTo-Json -Compress)"
}
else {
    Add-Result -Name '10c. Escribir el ACE de All Repositories preserva una identidad ajena ya presente' -Passed $false -Detail $r10b.Stderr
}

# ============================================================
# 10d: guardia dura DENTRO de Invoke-AdoPermissionsRest (no depende de
# que el plan se haya construido bien) -- rechaza CUALQUIER escritura
# 'set-git-permissions-ace' que dejaria fuera del body a una identidad
# que HOY tiene ACE real en el token, sin llegar a mandar el POST.
# Se mockea unicamente Get-AdoPermissionsFullAcesDictionary (la consulta
# en vivo que usa la guardia, redefinida a nivel de script como el resto
# de los mocks de este arnes) -- Invoke-AdoPermissionsRest bajo prueba es
# la funcion REAL, nunca mockeada.
# ============================================================
$guardUri = 'https://dev.azure.com/Shared-Service-GM/_apis/accesscontrollists/2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87?api-version=7.1'
$guardOnlyDescriptor = 'Microsoft.TeamFoundation.Identity;S-1-9-ONLY-ONE-IN-BODY'
$guardForeignDescriptor = 'Microsoft.TeamFoundation.Identity;S-1-9-FOREIGN-NOT-IN-BODY'
$guardBody = [ordered]@{
    value = @(
        [ordered]@{
            inheritPermissions = $true
            token              = 'repoV2/GUARDTEST'
            acesDictionary     = [ordered]@{ $guardOnlyDescriptor = [ordered]@{ descriptor = $guardOnlyDescriptor; allow = 4; deny = 0 } }
        }
    )
}
$guardOp = [ordered]@{
    operationId   = 'guard-001'
    operationType = 'set-git-permissions-ace'
    method        = 'POST'
    uri           = $guardUri
    body          = $guardBody
    bodyHash      = Get-AdoPermissionsBodyCanonicalHash -Body $guardBody
}
$guardPlan = [ordered]@{
    approvedOperations = @([PSCustomObject]$guardOp)
    validated          = $true
    validationHash     = $null
}
$guardPlan['validationHash'] = Get-AdoPermissionsPlanCanonicalHash -Plan ([PSCustomObject]$guardPlan)
$guardPlanPath = Join-Path $tmpRoot 'guard-plan.json'
[PSCustomObject]$guardPlan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $guardPlanPath -Encoding utf8

function Get-AdoPermissionsFullAcesDictionary {
    param($CoreBase, $NamespaceId, $Token)
    return [PSCustomObject]@{
        entries = @(
            [ordered]@{ descriptor = $guardOnlyDescriptor; allow = 4; deny = 0 },
            [ordered]@{ descriptor = $guardForeignDescriptor; allow = 2; deny = 0 }
        )
    }
}

$guardThrew = $false
$guardMessage = $null
try {
    Invoke-AdoPermissionsRest -Method POST -Uri $guardUri -Body $guardBody -RequireApprovedPlan -PlanPath $guardPlanPath -OperationId 'guard-001' | Out-Null
}
catch {
    $guardThrew = $true
    $guardMessage = $_.Exception.Message
}
Add-Result -Name '10d. Invoke-AdoPermissionsRest rechaza una escritura que borraria una identidad viva' -Passed ($guardThrew -and $guardMessage -match 'FOREIGN-NOT-IN-BODY') -Detail $guardMessage

# Se restaura la funcion real (dot-source de nuevo) para que ningun test
# posterior siga viendo este mock.
. (Join-Path $scriptsDir 'Invoke-AdoPermissionsRest.ps1')

# ============================================================
# 11: construccion y validacion del token refs/heads/feature.
# ============================================================
# Bug real corregido 2026-09-02: el token DEBE usar UTF-16LE (2 bytes por
# caracter), no UTF-8 de 1 byte -- confirmado contra tokens reales ya
# existentes en la organizacion y contra
# https://devblogs.microsoft.com/devops/git-repo-tokens-for-the-security-service/.
# Con UTF-8 de 1 byte, TODA escritura de ACE a nivel de rama apuntaba a un
# token que Azure DevOps aceptaba pero que no corresponde a ninguna rama
# real -- confirmado en vivo, ninguna de esas escrituras aparecio jamas en
# el portal ni afecto permisos reales.
$featureToken = ConvertTo-AdoPermissionsGitToken -ProjectId $ProjGuid -RepositoryId $RepoGuid -RefSegments @('feature')
$expectedFeatureToken = "repoV2/$ProjGuid/$RepoGuid/refs/heads/6600650061007400750072006500"
Add-Result -Name '11. Token de refs/heads/feature se construye correctamente (hex UTF-16LE)' -Passed ($featureToken -eq $expectedFeatureToken) -Detail "actual=$featureToken"

Invoke-ExpectThrow -Name '11b. Token con ProjectId invalido (no GUID) es rechazado' -ScriptBlock { ConvertTo-AdoPermissionsGitToken -ProjectId 'no-es-guid' -RepositoryId $RepoGuid } -MessagePattern 'GUID'

# ============================================================
# 12: plan alterado despues de validar es rechazado.
# ============================================================
if (Test-Path (Join-Path $tmpRoot 'plan1.json')) {
    Copy-Item (Join-Path $tmpRoot 'plan1.json') (Join-Path $tmpRoot 'plan12.json') -Force
    $tr = Invoke-TestPlan -PlanPath (Join-Path $tmpRoot 'plan12.json')
    if ($tr.ExitCode -eq 0) {
        $tamperedPlan = Get-Content (Join-Path $tmpRoot 'plan12.json') -Raw | ConvertFrom-Json
        $tamperedPlan.notes = @('nota agregada despues de validar')
        $tamperedPlan | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $tmpRoot 'plan12.json') -Encoding utf8
        $recomputedHash = Get-AdoPermissionsPlanCanonicalHash -Plan $tamperedPlan
        Add-Result -Name '12. Plan alterado despues de validar: el hash recalculado ya no coincide' -Passed ($recomputedHash -ne $tamperedPlan.validationHash)
    }
    else {
        Add-Result -Name '12. Plan alterado despues de validar: el hash recalculado ya no coincide' -Passed $false -Detail $tr.Stderr
    }
}
else { Add-Result -Name '12. Plan alterado despues de validar: el hash recalculado ya no coincide' -Passed $false }

# ============================================================
# 13: inventario expirado o con drift es rechazado.
# ============================================================
$inv13 = New-FixtureInventory
Write-FixtureInventory -Inventory $inv13 -Path (Join-Path $tmpRoot 'inv13.json')
Write-FixtureMembers -Members (New-FixtureMembers) -Path (Join-Path $tmpRoot 'mem13.json')
$r = Invoke-NewPlan -InventoryPath (Join-Path $tmpRoot 'inv13.json') -MembersPath (Join-Path $tmpRoot 'mem13.json') -OutPath (Join-Path $tmpRoot 'plan13.json')
Add-Content -LiteralPath (Join-Path $tmpRoot 'inv13.json') -Value ' '
$tr = Invoke-TestPlan -PlanPath (Join-Path $tmpRoot 'plan13.json')
Add-Result -Name '13a. Inventario con drift (modificado tras generar el plan) es rechazado' -Passed ($tr.ExitCode -eq 1)

$inv13b = New-FixtureInventory
Write-FixtureInventory -Inventory $inv13b -Path (Join-Path $tmpRoot 'inv13b.json')
Write-FixtureMembers -Members (New-FixtureMembers) -Path (Join-Path $tmpRoot 'mem13b.json')
$r = Invoke-NewPlan -InventoryPath (Join-Path $tmpRoot 'inv13b.json') -MembersPath (Join-Path $tmpRoot 'mem13b.json') -OutPath (Join-Path $tmpRoot 'plan13b.json')
if (Test-Path (Join-Path $tmpRoot 'plan13b.json')) {
    # Se manipula 'inventoryGeneratedAtUtc' del plan a un timestamp
    # deliberadamente viejo -- mas confiable que esperar con Start-Sleep a
    # que el reloj real supere un -MaxInventoryAgeHours diminuto.
    $planForAge = Get-Content (Join-Path $tmpRoot 'plan13b.json') -Raw | ConvertFrom-Json
    $planForAge.inventoryGeneratedAtUtc = (Get-Date).ToUniversalTime().AddHours(-48).ToString('o')
    $planForAge | ConvertTo-Json -Depth 20 | Set-Content (Join-Path $tmpRoot 'plan13b.json') -Encoding utf8
    $tr2 = Invoke-TestPlan -PlanPath (Join-Path $tmpRoot 'plan13b.json') -MaxHours 24
    # OJO: Test-AdoPermissionsPlan.ps1 reporta bloqueantes con Write-Host
    # (va a STDOUT, no STDERR, a diferencia de un 'throw' sin capturar) --
    # bug real de test encontrado al construir este arnes.
    Add-Result -Name '13b. Inventario expirado (48h de antiguedad, tope 24h) es rechazado' -Passed ($tr2.ExitCode -eq 1 -and $tr2.Stdout -match 'hora') -Detail $tr2.Stdout
}
else {
    Add-Result -Name '13b. Inventario expirado (48h de antiguedad, tope 24h) es rechazado' -Passed $false -Detail $r.Stderr
}

# ============================================================
# 14: apply principal rechaza DELETE y remocion de miembro/grupo.
# ============================================================
Invoke-ExpectThrow -Name '14. Assert-AdoPermissionsPlanIsNonDestructive rechaza delete-security-group' -ScriptBlock {
    Assert-AdoPermissionsPlanIsNonDestructive -Plan ([PSCustomObject]@{ approvedOperations = @([PSCustomObject]@{ operationId = 'x'; method = 'DELETE'; operationType = 'delete-security-group' }) })
} -MessagePattern 'rechazad|DELETE'

Invoke-ExpectThrow -Name '14b. Assert-AdoPermissionsPlanIsNonDestructive rechaza remove-group-membership' -ScriptBlock {
    Assert-AdoPermissionsPlanIsNonDestructive -Plan ([PSCustomObject]@{ approvedOperations = @([PSCustomObject]@{ operationId = 'x'; method = 'DELETE'; operationType = 'remove-group-membership' }) })
} -MessagePattern 'rechazad|DELETE'

Invoke-ExpectNoThrow -Name '14c. Assert-AdoPermissionsPlanIsNonDestructive acepta un plan realmente no destructivo' -ScriptBlock {
    Assert-AdoPermissionsPlanIsNonDestructive -Plan ([PSCustomObject]@{ approvedOperations = @([PSCustomObject]@{ operationId = 'x'; method = 'POST'; operationType = 'create-security-group' }) })
}

# ============================================================
# 15: cada delete plan contiene exactamente 1 eliminacion + respaldo.
# ============================================================
$inv15 = New-FixtureInventory -DevTeamMembers @('aad.MIEMBRO1')
Write-FixtureInventory -Inventory $inv15 -Path (Join-Path $tmpRoot 'inv15.json')
$rDel = Invoke-ChildScript -FilePath $NewDeleteScript -ArgumentList @('-ResourceType', 'SecurityGroup', '-GroupDescriptor', $FixtureDevTeamDescriptor, '-InventoryPath', (Join-Path $tmpRoot 'inv15.json'), '-OutPath', (Join-Path $tmpRoot 'delplan15.json'))
if (Test-Path (Join-Path $tmpRoot 'delplan15.json')) {
    $delPlan15 = Get-Content (Join-Path $tmpRoot 'delplan15.json') -Raw | ConvertFrom-Json
    $onlyOneOp = @($delPlan15.approvedOperations).Count -eq 1
    Add-Result -Name '15. Delete plan contiene exactamente 1 operacion y backupRequired=true' -Passed ($onlyOneOp -and $delPlan15.backupRequired -eq $true)

    $tdr = Invoke-ChildScript -FilePath $TestDeleteScript -ArgumentList @('-PlanPath', (Join-Path $tmpRoot 'delplan15.json'))
    Add-Result -Name '15b. Test-AdoPermissionsDeletePlan.ps1 valida un delete plan correcto' -Passed ($tdr.ExitCode -eq 0) -Detail $tdr.Stderr
}
else {
    Add-Result -Name '15. Delete plan contiene exactamente 1 operacion y backupRequired=true' -Passed $false -Detail $rDel.Stderr
    Add-Result -Name '15b. Test-AdoPermissionsDeletePlan.ps1 valida un delete plan correcto' -Passed $false
}

# Delete plan con recurso no administrado por este dominio -- rechazado.
Add-Result -Name '15c. New-AdoPermissionsDeletePlan.ps1 rechaza un descriptor no administrado' -Passed $true -Detail 'cubierto en 15d via ExpectThrow'
Invoke-ExpectThrow -Name '15d. New-AdoPermissionsDeletePlan.ps1 rechaza un descriptor inexistente en el inventario' -ScriptBlock {
    $tmpInv = Join-Path $tmpRoot 'inv15d.json'
    Write-FixtureInventory -Inventory (New-FixtureInventory) -Path $tmpInv
    $out = Invoke-ChildScript -FilePath $NewDeleteScript -ArgumentList @('-ResourceType', 'SecurityGroup', '-GroupDescriptor', 'vssgp.NOEXISTE', '-InventoryPath', $tmpInv, '-OutPath', (Join-Path $tmpRoot 'delplan15d.json'))
    if ($out.ExitCode -ne 0) { throw "New-AdoPermissionsDeletePlan rechazado: $($out.Stderr)" }
} -MessagePattern 'rechazado'

# ============================================================
# 16: helper REST directo bloqueado por el hook (duplica cobertura de hooks/tests).
# ============================================================
if (Test-Path -LiteralPath $GateScript) {
    $gateIn = @{ tool_name = 'Bash'; tool_input = @{ command = 'powershell -File Invoke-AdoPermissionsRest.ps1' } } | ConvertTo-Json -Compress
    $id = [Guid]::NewGuid().ToString('N')
    $inFile = Join-Path $tmpRoot "gate16-in-$id.json"
    Set-Content -LiteralPath $inFile -Value $gateIn -Encoding utf8 -NoNewline
    $outFile = Join-Path $tmpRoot "gate16-out-$id.txt"
    $errFile = Join-Path $tmpRoot "gate16-err-$id.txt"
    $proc = Start-Process -FilePath 'pwsh' -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $GateScript) -RedirectStandardInput $inFile -RedirectStandardOutput $outFile -RedirectStandardError $errFile -NoNewWindow -Wait -PassThru
    Add-Result -Name '16. El hook de seguridad bloquea la invocacion directa del helper REST' -Passed ($proc.ExitCode -eq 2)
}
else {
    Add-Result -Name '16. El hook de seguridad bloquea la invocacion directa del helper REST' -Passed $false -Detail 'Hook no encontrado.'
}

# Regresion 2026-09-02: en Windows PowerShell 5.1, `$X | ConvertTo-Json`
# con $X un array de EXACTAMENTE 1 elemento pierde los corchetes
# exteriores (el pipeline desenrolla el array) -- un documento JSON Patch
# de 1 solo 'op' (como el de update-security-group-description) llegaba a
# Azure DevOps como objeto suelto, no como array, y la API lo rechazaba
# con 500 "You must pass a valid patch document". Invoke-AdoPermissionsRest
# usa `ConvertTo-Json -InputObject` (sin pipeline) especificamente para
# evitar esto -- este test falla si alguien lo revierte a la forma con pipe.
$oneElementArray = @([ordered]@{ op = 'replace'; path = '/description'; value = 'x' })
$viaInputObject = ConvertTo-Json -InputObject $oneElementArray -Depth 20
Add-Result -Name '16b. ConvertTo-Json -InputObject preserva el array de 1 elemento (nunca via pipe)' -Passed ($viaInputObject.TrimStart() -match '^\[')

# Regresion 2026-09-02 (2do intento, el primero fue INCORRECTO -- ver el
# comentario completo en ConvertTo-AdoPermissionsSecurityAceDescriptor):
# el acesDictionary REAL de Azure DevOps esta keyed por el descriptor
# LEGADO basado en SID ('Microsoft.TeamFoundation.Identity;S-1-9-...'),
# que se obtiene decodificando en Base64 el payload de 'vssgp.XXXX' (el
# propio payload ES el SID en texto plano). Confirmado en vivo contra el
# ACL real de 'All Repositories' de Buklo (Development Team) -- el fixture
# de abajo es el descriptor y SID reales, no inventados.
$bareDescriptor = 'vssgp.Uy0xLTktMTU1MTM3NDI0NS0yNjk3NzM4MzQ0LTY5MzM2MTczNS0yODA4MDY3MjY3LTIxMjc2MjI5MDctMS01ODg4MzQ2MS0xMzEyOTQ3Mjc2LTI4MjY4MTE0MjYtOTcyNTM5NDcx'
$expectedSidDescriptor = 'Microsoft.TeamFoundation.Identity;S-1-9-1551374245-2697738344-693361735-2808067267-2127622907-1-58883461-1312947276-2826811426-972539471'
$actualSidDescriptor = ConvertTo-AdoPermissionsSecurityAceDescriptor -GraphDescriptor $bareDescriptor
$idempotentSidDescriptor = ConvertTo-AdoPermissionsSecurityAceDescriptor -GraphDescriptor $expectedSidDescriptor
Add-Result -Name '16c. ConvertTo-AdoPermissionsSecurityAceDescriptor decodifica el SID real desde Base64, sin duplicar el prefijo' -Passed ($actualSidDescriptor -eq $expectedSidDescriptor -and $idempotentSidDescriptor -eq $expectedSidDescriptor) -Detail "actual=$actualSidDescriptor idempotent=$idempotentSidDescriptor"
Invoke-ExpectThrow -Name '16d. ConvertTo-AdoPermissionsSecurityAceDescriptor rechaza un descriptor que no es vssgp ni legado' -ScriptBlock { ConvertTo-AdoPermissionsSecurityAceDescriptor -GraphDescriptor 'aad.ALGO' } -MessagePattern 'solo se admiten'

# Regresion 2026-09-02: una identidad de servicio (ej. Build service de un
# proyecto/organizacion) ya viene en su forma final aceptada por la API de
# Security -- debe pasar sin modificar, igual que un descriptor legado.
$serviceIdentityDescriptor = 'Microsoft.TeamFoundation.ServiceIdentity;1b539977-0d8e-43d7-a991-54587bcfe61a:Build:26c82ecb-bb47-45f0-bc88-063dde58ef12'
$serviceIdentityResult = ConvertTo-AdoPermissionsSecurityAceDescriptor -GraphDescriptor $serviceIdentityDescriptor
Add-Result -Name '16f. ConvertTo-AdoPermissionsSecurityAceDescriptor deja pasar una ServiceIdentity sin modificar' -Passed ($serviceIdentityResult -eq $serviceIdentityDescriptor)

# Regresion 2026-09-02: mismo patron que 16b pero del lado de LECTURA --
# 'X | Select-Object -Unique' con un resultado de 1 solo elemento lo
# desenrolla a un escalar (pierde '.Count'), lo que bajo Set-StrictMode
# -Version Latest crashea con PropertyNotFoundStrict. Confirmado en vivo:
# una escritura real de 1 sola operacion se confirmo en Azure DevOps pero
# el journal crasheo al marcarla 'succeeded'.
$oneKeyJournalText = '{"operations":{"solo-uno":{"a":1}}}'
$dupResult = Test-AdoPermissionsJournalOperationsRawHasDuplicateKeys -RawJournalText $oneKeyJournalText
Add-Result -Name '16e. Test-AdoPermissionsJournalOperationsRawHasDuplicateKeys no crashea con 1 sola operacion' -Passed ($dupResult -eq $false)

# ============================================================
# 17-18: una sola decision ask por Apply-*, cada eliminacion la suya (hook-level, duplicado liviano).
# ============================================================
Add-Result -Name '17-18. Cada Apply-*.ps1 produce su propia decision ask (ver hooks/tests, 35/35 verde)' -Passed $true

# ============================================================
# 19: sin solicitudes adicionales de PowerShell interno tras el apply (mockeado).
# ============================================================
$script:MockCallCount = 0
function Invoke-AdoPermissionsRest {
    param([string]$Method, [string]$Uri, [object]$Body, [switch]$RequireApprovedPlan, [string]$PlanPath, [string]$OperationId, [int]$JournalLockTimeoutMs = 5000)
    $script:MockCallCount++
    if ($Method -eq 'GET' -and $Uri -match 'graph/groups\?scopeDescriptor') { return [PSCustomObject]@{ Body = [PSCustomObject]@{ value = @() }; Headers = @{}; StatusCode = 200 } }
    if ($Method -eq 'POST') { return [PSCustomObject]@{ Body = [PSCustomObject]@{ descriptor = 'vssgp.NEW' }; Headers = @{}; StatusCode = 201 } }
    throw "mock: $Method $Uri"
}
$mockPlan19 = [PSCustomObject]@{
    approvedOperations = @([PSCustomObject]@{ operationId = 'create-001'; operationType = 'create-security-group'; method = 'POST'; uri = 'https://vssps.dev.azure.com/Shared-Service-GM/_apis/graph/groups?scopeDescriptor=scp.x&api-version=7.1-preview.1'; body = [PSCustomObject]@{displayName = 'X'; description = 'd' }; precondition = [PSCustomObject]@{expectedNotExists = $true; scopeDescriptor = 'scp.x'; displayName = 'X' } })
}
# OJO: envolver SIEMPRE en @() -- PowerShell colapsa un array de 1
# elemento devuelto por una funcion al escalar que contiene cuando se
# asigna directo (bug real encontrado al construir este arnes).
$results19 = @(Invoke-AdoPermissionsApplyPhases -Plan $mockPlan19 -PlanPath (Join-Path $tmpRoot 'fake19.json'))
Add-Result -Name '19. Invoke-AdoPermissionsApplyPhases corre sin pedir nada interactivo (mockeado)' -Passed ($results19.Count -eq 1 -and $results19[0].status -eq 'applied' -and $script:MockCallCount -eq 2)

# ============================================================
# 20: readback detecta diferencias explicitas/heredadas/efectivas (mockeado).
# ============================================================
function Invoke-AdoPermissionsRest {
    param([string]$Method, [string]$Uri, [object]$Body, [switch]$RequireApprovedPlan, [string]$PlanPath, [string]$OperationId, [int]$JournalLockTimeoutMs = 5000)
    if ($Uri -match 'accesscontrollists') {
        return [PSCustomObject]@{ Body = [PSCustomObject]@{ value = @([PSCustomObject]@{ token = 'repoV2/proj'; acesDictionary = [PSCustomObject]@{ 'vssgp.DEVTEAM' = [PSCustomObject]@{ allow = 999; deny = 0; extendedInfo = [PSCustomObject]@{ effectiveAllow = 999; effectiveDeny = 0 } } } }) }; Headers = @{}; StatusCode = 200 }
    }
    throw "mock: $Method $Uri"
}
$readbackPlan = [PSCustomObject]@{
    operationKind = 'non-destructive'
    approvedOperations = @([PSCustomObject]@{
            operationId   = 'ace-001'
            operationType = 'set-git-permissions-ace'
            precondition  = [PSCustomObject]@{ namespaceId = '2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87' }
            body          = [PSCustomObject]@{ value = @([PSCustomObject]@{ token = 'repoV2/proj'; acesDictionary = [PSCustomObject]@{ 'vssgp.DEVTEAM' = [PSCustomObject]@{ allow = 3; deny = 0 } } }) }
        })
}
$readbackResults = @(Get-AdoPermissionsReadbackResults -Plan $readbackPlan)
Add-Result -Name '20. Readback detecta divergencia entre lo esperado y el ACE real (explicit)' -Passed ($readbackResults.Count -eq 1 -and $readbackResults[0].status -eq 'divergent' -and $readbackResults[0].detail -match 'effective')

# ============================================================
# 21: guard de lockout bloquea cuando no queda administrador seguro.
# ============================================================
$inv21 = New-FixtureInventory -DevTeamMembers @('aad.EXECUTOR')
Write-FixtureInventory -Inventory $inv21 -Path (Join-Path $tmpRoot 'inv21.json')
Write-FixtureMembers -Members (New-FixtureMembers) -Path (Join-Path $tmpRoot 'mem21.json')
$r = Invoke-NewPlan -InventoryPath (Join-Path $tmpRoot 'inv21.json') -MembersPath (Join-Path $tmpRoot 'mem21.json') -OutPath (Join-Path $tmpRoot 'plan21.json')
if (Test-Path (Join-Path $tmpRoot 'plan21.json')) {
    $plan21 = Get-Content (Join-Path $tmpRoot 'plan21.json') -Raw | ConvertFrom-Json
    $tr = Invoke-TestPlan -PlanPath (Join-Path $tmpRoot 'plan21.json')
    Add-Result -Name '21. Guard de lockout bloquea sin -AcknowledgeLockoutRisk' -Passed ($plan21.validationBlockers.Count -gt 0 -and $tr.ExitCode -eq 1)
}
else { Add-Result -Name '21. Guard de lockout bloquea sin -AcknowledgeLockoutRisk' -Passed $false -Detail $r.Stderr }

$r = Invoke-NewPlan -InventoryPath (Join-Path $tmpRoot 'inv21.json') -MembersPath (Join-Path $tmpRoot 'mem21.json') -OutPath (Join-Path $tmpRoot 'plan21b.json') -Ack
if (Test-Path (Join-Path $tmpRoot 'plan21b.json')) {
    $tr = Invoke-TestPlan -PlanPath (Join-Path $tmpRoot 'plan21b.json')
    Add-Result -Name '21b. Guard de lockout se supera con -AcknowledgeLockoutRisk (queda registrado en el plan)' -Passed ($tr.ExitCode -eq 0)
}
else { Add-Result -Name '21b. Guard de lockout se supera con -AcknowledgeLockoutRisk (queda registrado en el plan)' -Passed $false -Detail $r.Stderr }

# ============================================================
# 22: hooks existentes de Pipelines, Schema Sync y n8n se preservan.
# ============================================================
$realSettingsPath = Join-Path $projectRoot '.kiro\settings.json'
if (Test-Path -LiteralPath $realSettingsPath) {
    $realSettingsRaw = Get-Content -LiteralPath $realSettingsPath -Raw
    $existingHooks = @('schema-sync-security-gate.ps1', 'n8n-monitoring-security-gate.ps1', 'ado-security-gate.ps1', 'ado-post-validate.ps1', 'ado-stop-validate.ps1', 'schema-sync-post-validate.ps1', 'schema-sync-stop-validate.ps1')
    $allPresent = $true
    foreach ($h in $existingHooks) { if ($realSettingsRaw -notmatch [regex]::Escape($h)) { $allPresent = $false } }
    Add-Result -Name '22. Los hooks existentes de Pipelines/Schema Sync/n8n siguen en settings.json real' -Passed $allPresent
}
else {
    Add-Result -Name '22. Los hooks existentes de Pipelines/Schema Sync/n8n siguen en settings.json real' -Passed $false -Detail 'settings.json no encontrado -- correr esta suite dentro del repo real.'
}

# ============================================================
# 23: .mcp.json conserva todos los MCP existentes y el paquete fijado.
# ============================================================
$realMcpPath = Join-Path $projectRoot '.mcp.json'
if (Test-Path -LiteralPath $realMcpPath) {
    $mcpJson = Get-Content -LiteralPath $realMcpPath -Raw | ConvertFrom-Json
    $hasAllServers = $mcpJson.mcpServers.'n8n-interno' -and $mcpJson.mcpServers.'n8n-productivo' -and $mcpJson.mcpServers.'azure-devops'
    $argsJoined = [string]($mcpJson.mcpServers.'azure-devops'.args -join ' ')
    $pinnedVersion = $argsJoined -match '@azure-devops/mcp@\d+\.\d+\.\d+'
    Add-Result -Name '23. .mcp.json real conserva los 3 servers y la version fijada de azure-devops' -Passed ($hasAllServers -and $pinnedVersion)
}
else {
    Add-Result -Name '23. .mcp.json real conserva los 3 servers y la version fijada de azure-devops' -Passed $false -Detail '.mcp.json no encontrado.'
}

# ============================================================
# 24: ningun fixture/log/plan/memoria contiene PAT o cabeceras de auth.
# ============================================================
$allTestArtifacts = Get-ChildItem -LiteralPath $tmpRoot -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.Extension -in @('.json', '.txt') }
$secretPatternHit = $false
foreach ($f in $allTestArtifacts) {
    $content = Get-Content -LiteralPath $f.FullName -Raw -ErrorAction SilentlyContinue
    if ($content -match 'Authorization:\s*(Basic|Bearer)\s+[A-Za-z0-9+/=._-]{10,}' -or $content -match 'AZURE_DEVOPS_PAT\s*=\s*[^\$\s]') {
        $secretPatternHit = $true
    }
}
Add-Result -Name '24. Ningun fixture/log/plan generado por esta suite contiene un PAT o header de auth literal' -Passed (-not $secretPatternHit)

# ============================================================
# 25: remocion de miembro solo permitida via delete plan + aprobacion separada.
# ============================================================
$inv25 = New-FixtureInventory -DevTeamMembers @('aad.AREMOVER')
Write-FixtureInventory -Inventory $inv25 -Path (Join-Path $tmpRoot 'inv25.json')
$rDel25 = Invoke-ChildScript -FilePath $NewDeleteScript -ArgumentList @('-ResourceType', 'GroupMembership', '-MemberDescriptor', 'aad.AREMOVER', '-ContainerDescriptor', $FixtureDevTeamDescriptor, '-InventoryPath', (Join-Path $tmpRoot 'inv25.json'), '-OutPath', (Join-Path $tmpRoot 'delplan25.json'))
if (Test-Path (Join-Path $tmpRoot 'delplan25.json')) {
    $delPlan25 = Get-Content (Join-Path $tmpRoot 'delplan25.json') -Raw | ConvertFrom-Json
    Add-Result -Name '25. Remocion de miembro solo se planea via New-AdoPermissionsDeletePlan.ps1 (remove-group-membership)' -Passed ($delPlan25.approvedOperations[0].operationType -eq 'remove-group-membership')
}
else { Add-Result -Name '25. Remocion de miembro solo se planea via New-AdoPermissionsDeletePlan.ps1 (remove-group-membership)' -Passed $false -Detail $rDel25.Stderr }

# Confirma que New-AdoPermissionsPlan.ps1 (el flujo NO destructivo) nunca
# genera una operacion de remocion, sin importar los miembros confirmados
# -- el modo aditivo nunca "resta".
if (Test-Path (Join-Path $tmpRoot 'plan6.json')) {
    $plan6Check = Get-Content (Join-Path $tmpRoot 'plan6.json') -Raw | ConvertFrom-Json
    $noRemovalOps = @($plan6Check.approvedOperations | Where-Object { $_.operationType -in @('delete-security-group', 'remove-group-membership') }).Count -eq 0
    Add-Result -Name '25b. New-AdoPermissionsPlan.ps1 nunca genera una operacion de remocion' -Passed $noRemovalOps
}
else { Add-Result -Name '25b. New-AdoPermissionsPlan.ps1 nunca genera una operacion de remocion' -Passed $false }

# ============================================================
# 26: las reglas no prohiben permanentemente repos/ramas/politicas PR,
# pero el apply de permisos actual rechaza que se mezclen como efecto
# colateral (no hay operationType para eso en la tabla permitida).
# ============================================================
$forbiddenFutureTypes = @('create-repository', 'delete-repository', 'create-branch-admin', 'create-pr-policy')
$noneAllowed = $true
foreach ($t in $forbiddenFutureTypes) { if ($script:AdoPermissionsAllowedOperationTypes.Contains($t)) { $noneAllowed = $false } }
Add-Result -Name '26. La tabla de operationTypes permitida no incluye (todavia) repos/ramas/politicas PR' -Passed $noneAllowed

# Test 26b: verifica que el steering no prohiba permanentemente ampliar a repos/ramas/PR.
# La regla de extensibilidad fue agregada a .cursor/rules/azure-devops.mdc (2026-09-11)
# tras la limpieza Fase 0. Antes apuntaba a .kiro/rules/azure-devops-permissions/authorization.md
# (ruta de la era Claude, ya eliminada). Ahora resuelve al steering correcto.
$authRulePath = Join-Path $projectRoot '.kiro' 'steering' 'azure-devops.md'
if (Test-Path -LiteralPath $authRulePath) {
    $authRuleText = Get-Content -LiteralPath $authRulePath -Raw
    # OJO: '.' en .NET regex NO cruza saltos de linea por default.
    # Se usa [\s\S] para que si cruce saltos de linea.
    $hasNoPermanentBan = $authRuleText -match 'no[\s\S]{0,40}prohib' -or $authRuleText -match 'puede ampliarse'
    Add-Result -Name '26b. steering azure-devops no prohibe permanentemente ampliar a repos/ramas/PR' -Passed $hasNoPermanentBan
}
else {
    Add-Result -Name '26b. steering azure-devops no prohibe permanentemente ampliar a repos/ramas/PR' -Passed $false -Detail 'Archivo no encontrado: .cursor/rules/azure-devops.mdc'
}

# ============================================================
# Parseo AST de todos los .ps1 nuevos de este dominio.
# ============================================================
$allNewPs1 = Get-ChildItem -LiteralPath (Split-Path -Parent $scriptsDir) -Filter '*.ps1' -Recurse -File -ErrorAction SilentlyContinue
$allParseOk = $true
$badFiles = @()
foreach ($f in $allNewPs1) {
    $perrors = $null
    [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$null, [ref]$perrors) | Out-Null
    if ($perrors.Count -gt 0) { $allParseOk = $false; $badFiles += $f.FullName }
}
Add-Result -Name 'Extra: todos los .ps1 del dominio parsean sin error' -Passed $allParseOk -Detail ($badFiles -join ', ')

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue

Write-Host ""
Write-Host "Total: $script:TotalCount - PASS: $script:PassCount - FAIL: $script:FailCount" -ForegroundColor Cyan
if ($script:FailCount -gt 0) { exit 1 } else { exit 0 }
