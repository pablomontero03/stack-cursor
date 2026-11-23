<#
Genera un plan JSON determinista de administracion de grupos y permisos
Git a partir de un inventario ya exportado (Export-AdoPermissionsSecurityInventory.ps1)
y de un intake de miembros ya resuelto (nunca por similitud -- ver
-MembersPath). No toca la red ni Azure DevOps. Siempre produce
'validated=false': el plan resultante debe pasar por
Test-AdoPermissionsPlan.ps1 antes de poder aplicarse.

Limitacion de diseno DELIBERADA (documentada, no un descuido): cuando un
grupo (Development Team(s) o Code-Reviewers) TODAVIA NO EXISTE, este plan
SOLO incluye su creacion (create-security-group, con la descripcion
estandar). Los miembros y las ACE de ese grupo especifico quedan en
'deferredAfterCreation' -- NUNCA en approvedOperations -- porque
Invoke-AdoPermissionsRest exige que la URI (para membresias) o el body
(para ACE) de una escritura coincidan EXACTO con lo aprobado, y el
descriptor real de un grupo nuevo no existe todavia al momento de
validar/aprobar este plan (no hay forma segura de "adivinarlo"). Despues
de aplicar este plan y confirmar el descriptor real por readback, hay que
volver a exportar el inventario y generar un plan nuevo para ese grupo:
en ese momento ya existe y sus miembros/ACE si entran en
approvedOperations. Esto es el mismo patron que exige Pipelines para
'update-build-definition'/'update-release-definition' (nunca se
referencia dentro de un mismo plan un id que ese mismo plan todavia no
creo).

Uso:
  .\New-AdoPermissionsPlan.ps1 -InventoryPath '...' -MembersPath '...' -DescriptionMode PreserveExisting -CurrentIdentityDescriptor '...' -OutPath '...'
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$InventoryPath,

    [Parameter(Mandatory)]
    [string]$MembersPath,

    [Parameter(Mandatory)]
    [ValidateSet('PreserveExisting', 'ReplaceWithStandard')]
    [string]$DescriptionMode,

    [Parameter(Mandatory)]
    [string]$CurrentIdentityDescriptor,

    [string[]]$Projects,

    [string]$OutPath,

    [switch]$AcknowledgeLockoutRisk
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$scriptRoot = $PSScriptRoot
. (Join-Path $scriptRoot 'Invoke-AdoPermissionsRest.ps1')

$DevTeamStandardDescription = 'Equipo de desarrollo del proyecto. Puede leer y contribuir en los repositorios y ramas autorizadas según la matriz definida, sin administrar permisos, editar políticas, omitir políticas ni eliminar recursos.'
$CodeReviewersStandardDescription = 'Líderes o responsables de revisión y aprobación de código del proyecto. Participan en pull requests y aplican la matriz de permisos definida; este grupo por sí solo no crea una política de revisores obligatorios.'
$CodeReviewersGroupName = 'Code-Reviewers (Revision Y Aprobacion Del Lider De Proyecto)'

if (-not (Test-Path -LiteralPath $InventoryPath)) {
    throw "New-AdoPermissionsPlan rechazado: no se encontro el inventario '$InventoryPath'. Ejecutar primero Export-AdoPermissionsSecurityInventory.ps1."
}
$inventoryRaw = Get-Content -LiteralPath $InventoryPath -Raw -Encoding UTF8
$inventory = $inventoryRaw | ConvertFrom-Json
$inventoryHash = Get-AdoPermissionsSha256OfText -Text ([string]::new($inventoryRaw.ToCharArray()))

if (-not (Test-Path -LiteralPath $MembersPath)) {
    throw "New-AdoPermissionsPlan rechazado: no se encontro el archivo de miembros '$MembersPath'."
}
$members = Get-Content -LiteralPath $MembersPath -Raw -Encoding UTF8 | ConvertFrom-Json

$targetProjects = if ($Projects -and @($Projects).Count -gt 0) { @($Projects) } else { @($inventory.projects | ForEach-Object { $_.name }) }

$blockers = [System.Collections.Generic.List[string]]::new()
$notes = [System.Collections.Generic.List[string]]::new()
$approvedOperations = [System.Collections.Generic.List[object]]::new()
$deferredAfterCreation = [System.Collections.Generic.List[object]]::new()
$projectPlans = [System.Collections.Generic.List[object]]::new()
$lockoutAcknowledgements = [System.Collections.Generic.List[object]]::new()
$opCounter = 0

function New-AdoPermissionsOperationId {
    param([string]$Prefix)
    $script:opCounter++
    return "$Prefix-$($script:opCounter.ToString('000'))"
}

function New-AdoPermissionsApprovedOperationEntry {
    <#
    Arma una entrada de approvedOperations. method y bodyHash SIEMPRE se
    derivan aca (nunca se aceptan pre-calculados de afuera), mismo
    criterio que Pipelines. A diferencia de Pipelines, esta entrada
    tambien guarda 'body' (sanitizado -- nunca contiene secretos, ya que
    ningun body de este dominio los necesita) y 'precondition', tal como
    exige el documento fuente ("body sanitizado, bodyHash, precondicion y
    operationId"). Guardar el body real (no solo su hash) es lo que le
    permite a Apply-AdoPermissionsPlan.ps1 ejecutar la escritura sin tener
    que RECONSTRUIR el body de forma independiente -- una sola
    implementacion (esta), nunca dos que puedan divergir.
    #>
    param(
        [Parameter(Mandatory)] [string]$OperationType,
        [Parameter(Mandatory)] [string]$Uri,
        [object]$Body,
        [object]$Precondition,
        [string]$IdPrefix = 'op'
    )
    $spec = $script:AdoPermissionsAllowedOperationTypes[$OperationType]
    if (-not $spec) { throw "New-AdoPermissionsApprovedOperationEntry: operationType desconocido '$OperationType'." }
    $null = Assert-AdoPermissionsOperationRequestMatchesSpec -OperationType $OperationType -Method $spec.method -Uri $Uri -Label $OperationType

    $entry = [ordered]@{
        operationId   = New-AdoPermissionsOperationId -Prefix $IdPrefix
        operationType = $OperationType
        method        = $spec.method
        uri           = $Uri
        body          = $Body
        bodyHash      = Get-AdoPermissionsBodyCanonicalHash -Body $Body
        precondition  = $Precondition
    }
    return [PSCustomObject]$entry
}

foreach ($projectName in $targetProjects) {
    $projInv = $inventory.projects | Where-Object { $_.name -eq $projectName } | Select-Object -First 1
    if (-not $projInv) {
        throw "New-AdoPermissionsPlan rechazado: el proyecto '$projectName' no esta en el inventario '$InventoryPath'."
    }
    $projMembers = $members.PSObject.Properties[$projectName]
    if (-not $projMembers) {
        throw "New-AdoPermissionsPlan rechazado: no hay entrada de miembros para el proyecto '$projectName' en '$MembersPath'."
    }
    $projMembers = $projMembers.Value

    $graphBase = "https://vssps.dev.azure.com/Shared-Service-GM"
    $coreBase = "https://dev.azure.com/Shared-Service-GM"
    $namespaceId = [string]$inventory.securityNamespace.namespaceId
    $resolvedBits = $inventory.securityNamespace.resolvedBits

    # --- Resolucion de Development Team(s) ---
    $devCandidates = @($projInv.groups.developmentTeamCandidates | Where-Object { $_ })
    $devResolution = [ordered]@{ role = 'developmentTeam'; status = $null; descriptor = $null; displayName = $null; existingDescription = $null }

    if ($projInv.groups.developmentTeamAmbiguous -or $devCandidates.Count -gt 1) {
        $overrideDescriptor = $null
        if ($projMembers.PSObject.Properties['developmentTeamDescriptorOverride']) {
            $overrideDescriptor = [string]$projMembers.developmentTeamDescriptorOverride
        }
        if ($overrideDescriptor -and ($devCandidates | Where-Object { $_.descriptor -eq $overrideDescriptor })) {
            $chosen = $devCandidates | Where-Object { $_.descriptor -eq $overrideDescriptor } | Select-Object -First 1
            $devResolution.status = 'existing'
            $devResolution.descriptor = $chosen.descriptor
            $devResolution.displayName = $chosen.displayName
            $devResolution.existingDescription = $chosen.description
            $notes.Add("Proyecto '$projectName': ambiguedad Development Team/Development Teams resuelta por override explicito -> '$($chosen.displayName)' ($($chosen.descriptor)).")
        }
        else {
            $blockers.Add("Proyecto '$projectName': existen tanto 'Development Team' como 'Development Teams' (o mas de un grupo coincidente). No se genera ninguna operacion para este rol hasta que el usuario indique cual administrar via 'developmentTeamDescriptorOverride' en $MembersPath.")
            $devResolution.status = 'blocked-ambiguous'
        }
    }
    elseif ($devCandidates.Count -eq 1) {
        $devResolution.status = 'existing'
        $devResolution.descriptor = $devCandidates[0].descriptor
        $devResolution.displayName = $devCandidates[0].displayName
        $devResolution.existingDescription = $devCandidates[0].description
    }
    else {
        $devResolution.status = 'toCreate'
        $devResolution.displayName = 'Development Team'
    }

    # --- Resolucion de Code-Reviewers ---
    $crCandidate = $projInv.groups.codeReviewers
    $crResolution = [ordered]@{ role = 'codeReviewers'; status = $null; descriptor = $null; displayName = $null; existingDescription = $null }
    if ($crCandidate) {
        $crResolution.status = 'existing'
        $crResolution.descriptor = $crCandidate.descriptor
        $crResolution.displayName = $crCandidate.displayName
        $crResolution.existingDescription = $crCandidate.description
    }
    else {
        $crResolution.status = 'toCreate'
        $crResolution.displayName = $CodeReviewersGroupName
    }

    # --- Guard de lockout: Development Team siempre recibe Deny en
    # 'Manage permissions' a nivel All Repositories (matriz fija). Si la
    # identidad que ejecuta es miembro directo de ese grupo, y no se
    # confirmo -AcknowledgeLockoutRisk, se bloquea. Este plan nunca toca
    # Project Administrators / Project Collection Administrators, que
    # siempre quedan como via de administracion no afectada -- ver
    # rules/security.md.
    if ($devResolution.status -eq 'existing') {
        $devMembersInInventory = @(($devCandidates | Where-Object { $_.descriptor -eq $devResolution.descriptor } | Select-Object -First 1).members)
        if ($devMembersInInventory -contains $CurrentIdentityDescriptor) {
            if ($AcknowledgeLockoutRisk) {
                # Se persiste la confirmacion EN EL PLAN (nunca solo en el
                # flag de esta invocacion) para que Test-AdoPermissionsPlan.ps1
                # pueda re-derivar el guard de forma independiente sin tener
                # que confiar en que "no hay bloqueante" significa "fue
                # revisado" -- ver ese script.
                $lockoutAcknowledgements.Add([PSCustomObject]@{
                        project    = $projectName
                        role       = 'developmentTeam'
                        descriptor = $devResolution.descriptor
                    })
                $notes.Add("Proyecto '$projectName': riesgo de lockout ACKNOWLEDGED via -AcknowledgeLockoutRisk -- la identidad que ejecuta ($CurrentIdentityDescriptor) es miembro de '$($devResolution.displayName)', que recibira Deny en 'Manage permissions'.")
            }
            else {
                $blockers.Add("Proyecto '$projectName': la identidad que ejecuta este plan ($CurrentIdentityDescriptor) es miembro directo de '$($devResolution.displayName)', que recibira Deny en 'Manage permissions'. Confirmar con -AcknowledgeLockoutRisk que existe otra via de administracion (Project Administrators no se modifica por este plan) antes de reintentar.")
            }
        }
    }

    # --- Operaciones de creacion ---
    $groupResolutions = @($devResolution, $crResolution)
    foreach ($res in $groupResolutions) {
        if ($res.status -ne 'toCreate') { continue }

        $desc = $DevTeamStandardDescription
        if ($res.role -eq 'codeReviewers') { $desc = $CodeReviewersStandardDescription }

        $createUri = "$graphBase/_apis/graph/groups?scopeDescriptor=$([uri]::EscapeDataString([string]$projInv.scopeDescriptor))&api-version=$($script:AdoPermissionsGraphApiVersion)"
        $createBody = [ordered]@{ displayName = $res.displayName; description = $desc }
        $createPrecondition = [ordered]@{ expectedNotExists = $true; scopeDescriptor = [string]$projInv.scopeDescriptor; displayName = $res.displayName }
        $entry = New-AdoPermissionsApprovedOperationEntry -OperationType 'create-security-group' -Uri $createUri -Body $createBody -Precondition $createPrecondition -IdPrefix "create-$($res.role)"
        $approvedOperations.Add($entry)

        $confirmedMembers = @()
        if ($res.role -eq 'developmentTeam' -and $projMembers.PSObject.Properties['developmentTeam']) { $confirmedMembers = @($projMembers.developmentTeam) }
        if ($res.role -eq 'codeReviewers' -and $projMembers.PSObject.Properties['codeReviewers']) { $confirmedMembers = @($projMembers.codeReviewers) }

        $deferredAfterCreation.Add([PSCustomObject]@{
                project              = $projectName
                role                 = $res.role
                reason               = 'El grupo todavia no existe -- su descriptor real solo se conoce despues de aplicar la creacion (operationId de arriba) y hacer readback.'
                pendingMembers       = $confirmedMembers
                pendingAceManaged    = $true
                nextStep             = 'Volver a exportar el inventario y correr New-AdoPermissionsPlan.ps1 de nuevo para este proyecto una vez creado el grupo.'
            })
    }

    # --- Operaciones de descripcion (solo para grupos EXISTENTES) ---
    foreach ($res in $groupResolutions) {
        if ($res.status -ne 'existing') { continue }
        $standard = if ($res.role -eq 'developmentTeam') { $DevTeamStandardDescription } else { $CodeReviewersStandardDescription }
        $current = [string]$res.existingDescription

        $needsUpdate = $false
        if ([string]::IsNullOrWhiteSpace($current)) {
            $needsUpdate = $true
            $notes.Add("Proyecto '$projectName' / $($res.displayName): sin descripcion -- se agrega la estandar.")
        }
        elseif ($current -ne $standard) {
            if ($DescriptionMode -eq 'ReplaceWithStandard') {
                $needsUpdate = $true
                $notes.Add("Proyecto '$projectName' / $($res.displayName): descripcion actual '$current' -> propuesta '$standard'.")
            }
            else {
                $notes.Add("Proyecto '$projectName' / $($res.displayName): descripcion actual '$current' conservada (DescriptionMode=PreserveExisting; estandar propuesta: '$standard').")
            }
        }

        if ($needsUpdate) {
            $patchUri = "$graphBase/_apis/graph/groups/$([uri]::EscapeDataString($res.descriptor))?api-version=$($script:AdoPermissionsGraphApiVersion)"
            # 'op'='replace', nunca 'add': la API de Graph Groups rechaza
            # 'add' sobre '/description' con 400 "VS850022: Not supported
            # json patch operation" -- confirmado en vivo 2026-09-02, aun
            # cuando la descripcion actual esta vacia (el campo ya existe
            # en el recurso, solo cambia su valor).
            $patchBody = @(
                [ordered]@{ op = 'replace'; path = '/description'; value = $standard }
            )
            $descPrecondition = [ordered]@{ expectedCurrentDescription = $current; groupDescriptor = $res.descriptor }
            $entry = New-AdoPermissionsApprovedOperationEntry -OperationType 'update-security-group-description' -Uri $patchUri -Body $patchBody -Precondition $descPrecondition -IdPrefix "desc-$($res.role)"
            $approvedOperations.Add($entry)
        }
    }

    # --- Operaciones de membresia aditiva (solo para grupos EXISTENTES) ---
    foreach ($res in $groupResolutions) {
        if ($res.status -ne 'existing') { continue }
        $confirmedMembers = @()
        if ($res.role -eq 'developmentTeam' -and $projMembers.PSObject.Properties['developmentTeam']) { $confirmedMembers = @($projMembers.developmentTeam) }
        if ($res.role -eq 'codeReviewers' -and $projMembers.PSObject.Properties['codeReviewers']) { $confirmedMembers = @($projMembers.codeReviewers) }

        $existingMembers = @(($devCandidates + @($crCandidate) | Where-Object { $_ -and $_.descriptor -eq $res.descriptor } | Select-Object -First 1).members)

        foreach ($m in $confirmedMembers) {
            $memberDescriptor = [string]$m.descriptor
            if ([string]::IsNullOrWhiteSpace($memberDescriptor)) {
                throw "New-AdoPermissionsPlan rechazado: un miembro de '$($res.role)' en el proyecto '$projectName' no tiene 'descriptor' resuelto en $MembersPath. Resolver la identidad (nunca por similitud) antes de generar el plan."
            }
            if ($existingMembers -contains $memberDescriptor) {
                continue # ya es miembro -- aditivo, nunca se re-agrega ni se reporta como cambio.
            }
            $addUri = "$graphBase/_apis/graph/memberships/$([uri]::EscapeDataString($memberDescriptor))/$([uri]::EscapeDataString($res.descriptor))?api-version=$($script:AdoPermissionsGraphApiVersion)"
            $memberPrecondition = [ordered]@{ expectedMembershipNotExists = $true; memberDescriptor = $memberDescriptor; containerDescriptor = $res.descriptor }
            $entry = New-AdoPermissionsApprovedOperationEntry -OperationType 'add-group-membership' -Uri $addUri -Body $null -Precondition $memberPrecondition -IdPrefix "member-$($res.role)"
            $approvedOperations.Add($entry)
        }
    }

    # --- Operaciones de ACE (All Repositories + por rama) -- solo incluye
    # en acesDictionary los roles que ya estan 'existing'; los 'toCreate'
    # quedan fuera de ESTA operacion (se agregan en un plan posterior, ver
    # deferredAfterCreation de arriba). Si NINGUN rol esta 'existing' para
    # este proyecto, no se genera ninguna operacion de ACE.
    $existingRoles = @($groupResolutions | Where-Object { $_.status -eq 'existing' })
    if ($existingRoles.Count -gt 0) {
        $matrix = Get-AdoPermissionsMatrixDefinition
        $catalog = Get-AdoPermissionsManagedActionCatalog

        function Get-AdoPermissionsAceOperationForToken {
            param(
                [string]$Token,
                [psobject]$AclSnapshot,
                [hashtable]$DesiredByRole,
                [string]$IdSuffix
            )
            # SIEMPRE partir del acesDictionary COMPLETO ya existente en
            # este token, nunca de uno vacio -- 'Set Access Control Lists'
            # REEMPLAZA todo el diccionario del token con lo que se envia,
            # no lo combina (incidente real 2026-09-02, ver debugging.md
            # de ado-permissions-builder: una escritura que solo incluia
            # 2 descriptores borro cualquier otra identidad que ya tuviera
            # ACE real ahi). Los descriptores preservados se re-envian
            # exactamente con su allow/deny actual, sin modificar.
            $acesDictionary = [ordered]@{}
            $preconditionDescriptors = [ordered]@{}
            $managedAceDescriptors = [System.Collections.Generic.HashSet[string]]::new()
            foreach ($res in $existingRoles) {
                $managedAceDescriptors.Add((ConvertTo-AdoPermissionsSecurityAceDescriptor -GraphDescriptor $res.descriptor)) | Out-Null
            }
            # .PSObject.Properties[...], nunca acceso directo: un
            # inventario generado ANTES de este fix (o un fixture de
            # prueba) no tiene 'fullAcesDictionary' en absoluto, y
            # Set-StrictMode -Version Latest lanza PropertyNotFoundStrict
            # al acceder a una propiedad ausente -- mismo patron que otros
            # bugs reales de esta misma sesion.
            $fullAcesProp = if ($AclSnapshot) { $AclSnapshot.PSObject.Properties['fullAcesDictionary'] } else { $null }
            if ($fullAcesProp -and $fullAcesProp.Value) {
                foreach ($entry in @($fullAcesProp.Value)) {
                    if ($managedAceDescriptors.Contains([string]$entry.descriptor)) { continue }
                    $acesDictionary[[string]$entry.descriptor] = [ordered]@{ descriptor = [string]$entry.descriptor; allow = [int]$entry.allow; deny = [int]$entry.deny }
                    $preconditionDescriptors[[string]$entry.descriptor] = [ordered]@{ expectedExplicitAllow = [int]$entry.allow; expectedExplicitDeny = [int]$entry.deny }
                }
            }
            foreach ($res in $existingRoles) {
                $desiredForRole = $DesiredByRole[$res.role]
                if (-not $desiredForRole) { continue }

                $currentAllow = 0
                $currentDeny = 0
                if ($AclSnapshot -and $AclSnapshot.descriptors.PSObject.Properties[$res.descriptor]) {
                    $currentAllow = [int]$AclSnapshot.descriptors.($res.descriptor).explicitAllow
                    $currentDeny = [int]$AclSnapshot.descriptors.($res.descriptor).explicitDeny
                }

                $recomputed = Get-AdoPermissionsRecomputedAceBits -CurrentAllow $currentAllow -CurrentDeny $currentDeny -ManagedMask $desiredForRole.ManagedMask -DesiredAllow $desiredForRole.DesiredAllow -DesiredDeny $desiredForRole.DesiredDeny
                # La clave del diccionario y el campo 'descriptor' van en
                # la forma COMPUESTA que realmente usa la API de Security
                # (ver ConvertTo-AdoPermissionsSecurityAceDescriptor) --
                # nunca el descriptor de Graph desnudo. El resto de este
                # plan (preconditionDescriptors, deferredAfterCreation,
                # etc.) sigue usando $res.descriptor tal cual: es solo
                # bookkeeping interno nuestro, nunca se envia a Azure
                # DevOps directamente.
                $aceDescriptor = ConvertTo-AdoPermissionsSecurityAceDescriptor -GraphDescriptor $res.descriptor
                $acesDictionary[$aceDescriptor] = [ordered]@{ descriptor = $aceDescriptor; allow = $recomputed.NewAllow; deny = $recomputed.NewDeny }
                $preconditionDescriptors[$res.descriptor] = [ordered]@{ expectedExplicitAllow = $currentAllow; expectedExplicitDeny = $currentDeny }
            }
            if ($acesDictionary.Count -eq 0) { return $null }

            $inheritPermissions = if ($AclSnapshot -and $null -ne $AclSnapshot.inheritPermissions) { $AclSnapshot.inheritPermissions } else { $true }
            $aceUri = "$coreBase/_apis/accesscontrollists/$($namespaceId)?api-version=$($script:AdoPermissionsCoreApiVersion)"
            $aceBody = [ordered]@{
                value = @(
                    [ordered]@{ inheritPermissions = $inheritPermissions; token = $Token; acesDictionary = $acesDictionary }
                )
            }
            $acePrecondition = [ordered]@{ token = $Token; namespaceId = $namespaceId; descriptors = $preconditionDescriptors }
            return New-AdoPermissionsApprovedOperationEntry -OperationType 'set-git-permissions-ace' -Uri $aceUri -Body $aceBody -Precondition $acePrecondition -IdPrefix "ace-$IdSuffix"
        }

        function Get-AdoPermissionsDesiredBitsByRole {
            param([psobject]$LabelValues, [string[]]$Labels)
            $result = @{}
            foreach ($res in $existingRoles) {
                $roleKey = if ($res.role -eq 'developmentTeam') { 'DevelopmentTeam' } else { 'CodeReviewers' }
                $managedMask = 0
                $desiredAllow = 0
                $desiredDeny = 0
                foreach ($label in $Labels) {
                    $bit = [int]$resolvedBits.$label
                    $managedMask = $managedMask -bor $bit
                    $value = $LabelValues.$label.$roleKey
                    if ($value -eq 'Allow') { $desiredAllow = $desiredAllow -bor $bit }
                    elseif ($value -eq 'Deny') { $desiredDeny = $desiredDeny -bor $bit }
                }
                $result[$res.role] = [PSCustomObject]@{ ManagedMask = $managedMask; DesiredAllow = $desiredAllow; DesiredDeny = $desiredDeny }
            }
            return $result
        }

        $allRepoLabels = @($matrix.AllRepositories.PSObject.Properties.Name)
        $allRepoDesired = Get-AdoPermissionsDesiredBitsByRole -LabelValues $matrix.AllRepositories -Labels $allRepoLabels
        $projectToken = ConvertTo-AdoPermissionsProjectToken -ProjectId ([string]$projInv.projectId)
        $allRepoOp = Get-AdoPermissionsAceOperationForToken -Token $projectToken -AclSnapshot $projInv.acl.allRepositories -DesiredByRole $allRepoDesired -IdSuffix 'allrepos'
        if ($allRepoOp) { $approvedOperations.Add($allRepoOp) }

        foreach ($repo in $projInv.repositories) {
            $repoAcl = $null
            if ($projInv.acl.byRepository.PSObject.Properties[$repo.repositoryId]) {
                $repoAcl = $projInv.acl.byRepository.($repo.repositoryId)
            }
            foreach ($nodeKey in $matrix.BranchNodeKeys) {
                if ($nodeKey -ne 'feature' -and -not $repo.branchExists.$nodeKey) {
                    $notes.Add("Proyecto '$projectName' / repo '$($repo.name)': la rama '$nodeKey' no existe -- no se genera ACE para ella.")
                    continue
                }
                $branchDesired = Get-AdoPermissionsDesiredBitsByRole -LabelValues $matrix.BranchLevel.$nodeKey -Labels $matrix.BranchPermissionLabels
                $branchToken = if ($nodeKey -eq 'feature') {
                    ConvertTo-AdoPermissionsGitToken -ProjectId ([string]$projInv.projectId) -RepositoryId $repo.repositoryId -RefSegments @('feature')
                }
                else {
                    ConvertTo-AdoPermissionsGitToken -ProjectId ([string]$projInv.projectId) -RepositoryId $repo.repositoryId -RefSegments @($nodeKey)
                }
                $branchAclSnapshot = if ($repoAcl -and $repoAcl.PSObject.Properties[$nodeKey]) { $repoAcl.$nodeKey } else { $null }
                $branchOp = Get-AdoPermissionsAceOperationForToken -Token $branchToken -AclSnapshot $branchAclSnapshot -DesiredByRole $branchDesired -IdSuffix "$($repo.name)-$nodeKey"
                if ($branchOp) { $approvedOperations.Add($branchOp) }
            }
        }
    }

    $projectPlans.Add([PSCustomObject]@{
            name             = $projectName
            developmentTeam  = [PSCustomObject]$devResolution
            codeReviewers    = [PSCustomObject]$crResolution
        })
}

$plan = [PSCustomObject]@{
    schemaVersion          = 1
    operationKind          = 'non-destructive'
    generatedAtUtc         = (Get-Date).ToUniversalTime().ToString('o')
    organization           = 'Shared-Service-GM'
    projects               = @($projectPlans)
    descriptionMode        = $DescriptionMode
    membershipMode         = 'additive'
    currentIdentityDescriptor = $CurrentIdentityDescriptor
    inventoryPath           = (Resolve-Path -LiteralPath $InventoryPath).ProviderPath
    inventoryGeneratedAtUtc = [string]$inventory.generatedAtUtc
    inventoryHash           = $inventoryHash
    lockoutAcknowledgements = @($lockoutAcknowledgements)
    approvedOperations      = @($approvedOperations)
    deferredAfterCreation   = @($deferredAfterCreation)
    notes                   = @($notes)
    validationBlockers      = @($blockers)
    validated               = $false
    lastValidatedAtUtc      = $null
    validationWarnings      = @()
    validationEvidence      = $null
    validationHash          = $null
}

if (-not $OutPath) {
    $projectRoot = if ($env:REPO_ROOT) { $env:REPO_ROOT } else { (Get-Location).Path }
    $plansDir = Join-Path $projectRoot '.local\azure-devops-permissions\plans'
    if (-not (Test-Path -LiteralPath $plansDir)) { New-Item -ItemType Directory -Force -Path $plansDir | Out-Null }
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $safeName = ($targetProjects -join '-') -replace '[^A-Za-z0-9\-]', '-'
    $OutPath = Join-Path $plansDir "permissions-$safeName-$timestamp.json"
}

$plan | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $OutPath -Encoding utf8
Write-Host "Plan escrito en: $OutPath" -ForegroundColor Green
if ($blockers.Count -gt 0) {
    Write-Host "ATENCION: el plan tiene $($blockers.Count) bloqueo(s) -- no podra validarse hasta resolverlos:" -ForegroundColor Yellow
    $blockers | ForEach-Object { Write-Host "  - $_" -ForegroundColor Yellow }
}
return $OutPath
