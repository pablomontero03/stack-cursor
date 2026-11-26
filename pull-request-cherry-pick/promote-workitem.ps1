[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# =========================
# Logging helpers
# =========================
function Write-Log {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[INFO ] $Message"
}

function Write-Success {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[ OK  ] $Message"
}

function Write-WarnLog {
    param([Parameter(Mandatory = $true)][string]$Message)
    Write-Host "[WARN ] $Message"
}

function Stop-WithError {
    param(
        [Parameter(Mandatory = $true)][string]$Message,
        [int]$Code = 1
    )
    throw "[ERROR] $Message"
}

# =========================
# Pipeline variable output
# =========================
function Set-PipelineVar {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [AllowEmptyString()][string]$Value
    )
    Write-Host "##vso[task.setvariable variable=$Name]$Value"
}

# =========================
# Env helpers
# =========================
function Get-EnvValue {
    param(
        [Parameter(Mandatory = $true)][string]$Name,
        [bool]$Required = $true,
        [string]$DefaultValue = ''
    )

    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        if ($Required) {
            Stop-WithError "La variable requerida '$Name' no está definida o viene vacía."
        }
        return $DefaultValue
    }
    return $value.Trim()
}

function To-Bool {
    param(
        [string]$Value,
        [bool]$Default = $false
    )

    if ([string]::IsNullOrWhiteSpace($Value)) {
        return $Default
    }

    switch ($Value.Trim().ToLowerInvariant()) {
        '1' { return $true }
        'true' { return $true }
        'yes' { return $true }
        'y' { return $true }
        'on' { return $true }
        '0' { return $false }
        'false' { return $false }
        'no' { return $false }
        'n' { return $false }
        'off' { return $false }
        default { return $Default }
    }
}

function Normalize-BranchName {
    param([Parameter(Mandatory = $true)][string]$Branch)

    $clean = $Branch.Trim()
    if ($clean.StartsWith('refs/heads/')) { return $clean.Substring('refs/heads/'.Length) }
    if ($clean.StartsWith('origin/'))     { return $clean.Substring('origin/'.Length) }
    return $clean
}

function Sanitize-Text {
    param(
        [Parameter(Mandatory = $true)][string]$Text,
        [int]$MaxLength = 180
    )

    $s = $Text -replace '[\r\n\t]+', ' '
    $s = $s -replace '\s{2,}', ' '
    $s = $s -replace '[\u0000-\u001F]', ''
    $s = $s.Trim()

    if ($s.Length -gt $MaxLength) {
        $s = $s.Substring(0, $MaxLength).Trim()
    }

    return $s
}

# =========================
# REST helpers
# =========================
function Invoke-AdoRest {
    param(
        [Parameter(Mandatory = $true)][ValidateSet('GET','POST','PATCH','PUT','DELETE')][string]$Method,
        [Parameter(Mandatory = $true)][string]$Uri,
        [object]$Body = $null,
        [hashtable]$ExtraHeaders = @{}
    )

    $token = Get-EnvValue -Name 'SYSTEM_ACCESSTOKEN'
    $headers = @{
        Authorization = "Bearer $token"
        Accept        = 'application/json'
    }

    foreach ($k in $ExtraHeaders.Keys) {
        $headers[$k] = $ExtraHeaders[$k]
    }

    try {
        Write-Log "Invocando API [$Method] $Uri"
        if ($null -ne $Body) {
            $json = $Body | ConvertTo-Json -Depth 50
            return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers -ContentType 'application/json' -Body $json
        }
        return Invoke-RestMethod -Method $Method -Uri $Uri -Headers $headers
    }
    catch {
        $detail = $_.Exception.Message
        if ($_.ErrorDetails -and $_.ErrorDetails.Message) {
            $detail = $_.ErrorDetails.Message
        }
        Stop-WithError "Falló llamada REST [$Method] $Uri. Detalle: $detail"
    }
}

# =========================
# Git helpers
# =========================
function Exec-Git {
    param(
        [Parameter(Mandatory = $true)][string[]]$Args,
        [switch]$AllowFailure
    )

    Write-Log ("Ejecutando: git " + ($Args -join ' '))
    $output = & git @Args 2>&1
    $exitCode = $LASTEXITCODE

    if ($output) {
        $output | ForEach-Object { Write-Host "       $_" }
    }

    if (-not $AllowFailure -and $exitCode -ne 0) {
        Stop-WithError "Falló comando git: git $($Args -join ' ')"
    }

    return [PSCustomObject]@{
        ExitCode = $exitCode
        Output   = @($output)
    }
}

function Ensure-GitIdentity {
    $nameResult = Exec-Git -Args @('config','user.name') -AllowFailure
    if ($nameResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($nameResult.Output -join ''))) {
        Exec-Git -Args @('config','user.name','AzureDevOps-Promotion-Bot') | Out-Null
    }

    $emailResult = Exec-Git -Args @('config','user.email') -AllowFailure
    if ($emailResult.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($emailResult.Output -join ''))) {
        Exec-Git -Args @('config','user.email','ado-promotion-bot@local') | Out-Null
    }

    Write-Success 'Identidad de git configurada correctamente.'
}

function Ensure-RemoteHasAuth {
    param(
        [Parameter(Mandatory = $true)][string]$OrganizationUrl,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$RepositoryName
    )

    $token = Get-EnvValue -Name 'SYSTEM_ACCESSTOKEN'
    $safeOrg = $OrganizationUrl.TrimEnd('/')
    $remoteUrl = "$safeOrg/$Project/_git/$RepositoryName"
    $authRemoteUrl = $remoteUrl -replace '^https://', "https://:$token@"

    Exec-Git -Args @('remote','set-url','origin',$authRemoteUrl) | Out-Null
    Write-Success "Remote 'origin' configurado con autenticación para push."
}

function Test-CommitExistsLocally {
    param([Parameter(Mandatory = $true)][string]$CommitId)

    $result = Exec-Git -Args @('cat-file','-e',"$CommitId^{commit}") -AllowFailure
    return ($result.ExitCode -eq 0)
}

function Get-ArtifactDetailsFromRelationUrl {
    param([Parameter(Mandatory = $true)][string]$RelationUrl)

    if ($RelationUrl -notmatch 'vstfs:///Git/Commit/') {
        return $null
    }

    $lastSegment = $RelationUrl.Substring($RelationUrl.LastIndexOf('/') + 1)
    $decoded = [System.Uri]::UnescapeDataString($lastSegment)
    $parts = $decoded -split '/'

    if ($parts.Count -lt 3) {
        return $null
    }

    return [PSCustomObject]@{
        ProjectId    = $parts[0]
        RepositoryId = $parts[1]
        CommitId     = $parts[2]
    }
}

function Add-WorkItemComment {
    param(
        [Parameter(Mandatory = $true)][string]$OrganizationUrl,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$WorkItemId,
        [Parameter(Mandatory = $true)][string]$Text,
        [switch]$DryRun
    )

    if ($DryRun) {
        Write-WarnLog "DRY-RUN: no se agregará comentario al Work Item $WorkItemId."
        return
    }

    $uri = "$($OrganizationUrl.TrimEnd('/'))/$Project/_apis/wit/workItems/$WorkItemId/comments?api-version=7.1-preview.4"
    $body = @{ text = $Text }
    Invoke-AdoRest -Method POST -Uri $uri -Body $body | Out-Null
    Write-Success "Comentario agregado al Work Item $WorkItemId."
}

function Resolve-ReviewerIdentities {
    param(
        [Parameter(Mandatory = $true)][string]$OrganizationUrl,
        [Parameter(Mandatory = $true)][string]$ReviewerNamesCsv
    )

    $names = $ReviewerNamesCsv.Split(',') | ForEach-Object { $_.Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
    $resolved = @()

    foreach ($name in $names) {
        try {
            $uri = "$($OrganizationUrl.TrimEnd('/'))/_apis/identities?searchFilter=General&filterValue=$([System.Uri]::EscapeDataString($name))&queryMembership=None&api-version=7.1-preview.1"
            $resp = Invoke-AdoRest -Method GET -Uri $uri
            if ($resp -and $resp.value -and $resp.value.Count -gt 0) {
                $candidate = $resp.value | Where-Object {
                    $_.providerDisplayName -eq $name -or $_.displayName -eq $name -or $_.customDisplayName -eq $name
                } | Select-Object -First 1

                if (-not $candidate) {
                    $candidate = $resp.value | Select-Object -First 1
                }

                if ($candidate -and $candidate.id) {
                    $resolved += [PSCustomObject]@{
                        InputName = $name
                        Id        = $candidate.id
                        Display   = $(if ($candidate.providerDisplayName) { $candidate.providerDisplayName } elseif ($candidate.displayName) { $candidate.displayName } else { $name })
                    }
                    Write-Success "Reviewer resuelto: '$name' => '$($candidate.id)'"
                }
                else {
                    Write-WarnLog "No se pudo resolver reviewer: '$name'"
                }
            }
            else {
                Write-WarnLog "No se encontraron identidades para reviewer: '$name'"
            }
        }
        catch {
            Write-WarnLog "Error resolviendo reviewer '$name'. Se omitirá. Detalle: $($_.Exception.Message)"
        }
    }

    return $resolved
}

function Add-ReviewersToPr {
    param(
        [Parameter(Mandatory = $true)][string]$OrganizationUrl,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$RepositoryId,
        [Parameter(Mandatory = $true)][string]$PullRequestId,
        [Parameter(Mandatory = $true)][object[]]$ReviewerIdentities,
        [switch]$DryRun
    )

    foreach ($reviewer in $ReviewerIdentities) {
        if ($DryRun) {
            Write-WarnLog "DRY-RUN: no se agregará reviewer '$($reviewer.Display)' al PR $PullRequestId."
            continue
        }

        try {
            $uri = "$($OrganizationUrl.TrimEnd('/'))/$Project/_apis/git/repositories/$RepositoryId/pullRequests/$PullRequestId/reviewers/$($reviewer.Id)?api-version=7.1"
            Invoke-AdoRest -Method PUT -Uri $uri -Body @{} | Out-Null
            Write-Success "Reviewer agregado al PR: $($reviewer.Display)"
        }
        catch {
            Write-WarnLog "No se pudo agregar reviewer '$($reviewer.Display)' al PR. Detalle: $($_.Exception.Message)"
        }
    }
}

function Get-AuthenticatedUserId {
    param([Parameter(Mandatory = $true)][string]$OrganizationUrl)

    $uri = "$($OrganizationUrl.TrimEnd('/'))/_apis/connectionData?connectOptions=1&lastChangeId=-1&lastChangeId64=-1"
    $resp = Invoke-AdoRest -Method GET -Uri $uri
    if ($resp -and $resp.authenticatedUser -and $resp.authenticatedUser.id) {
        return $resp.authenticatedUser.id
    }
    Stop-WithError 'No se pudo resolver el usuario autenticado para configurar auto-complete/completion del PR.'
}

function Set-PrAutoComplete {
    param(
        [Parameter(Mandatory = $true)][string]$OrganizationUrl,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$RepositoryId,
        [Parameter(Mandatory = $true)][string]$PullRequestId,
        [Parameter(Mandatory = $true)][string]$CurrentUserId,
        [switch]$DryRun,
        [bool]$DeleteSourceBranch = $false
    )

    if ($DryRun) {
        Write-WarnLog "DRY-RUN: no se configurará auto-complete en el PR $PullRequestId."
        return
    }

    $uri = "$($OrganizationUrl.TrimEnd('/'))/$Project/_apis/git/repositories/$RepositoryId/pullRequests/$PullRequestId?api-version=7.1"
    $body = @{
        autoCompleteSetBy = @{ id = $CurrentUserId }
        completionOptions = @{
            mergeStrategy               = 'squash'
            deleteSourceBranch          = $DeleteSourceBranch
            transitionWorkItems         = $false
            bypassPolicy                = $false
            bypassReason                = ''
            mergeCommitMessage          = ''
            triggerAutoCompleteOnSourceUpdate = $true
        }
    }

    Invoke-AdoRest -Method PATCH -Uri $uri -Body $body | Out-Null
    Write-Success "PR configurado con auto-complete."
}

function Complete-PrNow {
    param(
        [Parameter(Mandatory = $true)][string]$OrganizationUrl,
        [Parameter(Mandatory = $true)][string]$Project,
        [Parameter(Mandatory = $true)][string]$RepositoryId,
        [Parameter(Mandatory = $true)][string]$PullRequestId,
        [switch]$DryRun,
        [bool]$DeleteSourceBranch = $false
    )

    if ($DryRun) {
        Write-WarnLog "DRY-RUN: no se completará automáticamente el PR $PullRequestId."
        return
    }

    $uri = "$($OrganizationUrl.TrimEnd('/'))/$Project/_apis/git/repositories/$RepositoryId/pullRequests/$PullRequestId?api-version=7.1"
    $body = @{
        status = 'completed'
        completionOptions = @{
            mergeStrategy      = 'squash'
            deleteSourceBranch = $DeleteSourceBranch
            transitionWorkItems = $false
            bypassPolicy        = $false
            bypassReason        = ''
            mergeCommitMessage  = ''
        }
    }

    Invoke-AdoRest -Method PATCH -Uri $uri -Body $body | Out-Null
    Write-Success "Se solicitó completar automáticamente el PR."
}

# =========================
# Main
# =========================
$script:organizationUrl = ''
$script:project = ''
$script:repositoryName = ''
$script:workItemId = ''
$script:workItemTitle = ''
$script:targetBranch = ''
$script:tempBranchPrefix = ''
$script:tempBranchName = ''
$script:sourceRefName = ''
$script:targetRefName = ''
$script:linkedRepoId = ''
$script:prId = ''
$script:prWebUrl = ''
$script:prTitle = ''
$script:isDryRun = $false
$script:commentOnFailure = $true

try {
    # Variables del pipeline / library
    $script:organizationUrl  = Get-EnvValue -Name 'adoOrganizationUrl'
    $script:project          = Get-EnvValue -Name 'adoProject'
    $script:repositoryName   = Get-EnvValue -Name 'adoRepositoryName'
    $script:workItemId       = Get-EnvValue -Name 'workItemId'
    $script:targetBranch     = Normalize-BranchName (Get-EnvValue -Name 'targetBranch')
    $script:tempBranchPrefix = Get-EnvValue -Name 'tempBranchPrefix' -Required:$false -DefaultValue 'temp'

    $createDraftPr           = To-Bool (Get-EnvValue -Name 'createDraftPr' -Required:$false -DefaultValue 'true') $true
    $script:isDryRun         = To-Bool (Get-EnvValue -Name 'dryRun' -Required:$false -DefaultValue 'false') $false
    $commentWorkItem         = To-Bool (Get-EnvValue -Name 'commentWorkItem' -Required:$false -DefaultValue 'true') $true
    $script:commentOnFailure = To-Bool (Get-EnvValue -Name 'commentOnFailure' -Required:$false -DefaultValue 'true') $true
    $enableAutoComplete      = To-Bool (Get-EnvValue -Name 'enableAutoComplete' -Required:$false -DefaultValue 'false') $false
    $completePrImmediately   = To-Bool (Get-EnvValue -Name 'completePrImmediately' -Required:$false -DefaultValue 'false') $false
    $deleteSourceOnComplete  = To-Bool (Get-EnvValue -Name 'deleteSourceBranchOnComplete' -Required:$false -DefaultValue 'false') $false
    $prTitlePrefix           = Get-EnvValue -Name 'prTitlePrefix' -Required:$false -DefaultValue '[AUTO]'
    $adoReviewerNames        = Get-EnvValue -Name 'adoReviewerNames' -Required:$false -DefaultValue ''

    if (-not ($script:workItemId -match '^\d+$')) {
        Stop-WithError "La variable workItemId debe ser numérica. Valor recibido: '$($script:workItemId)'"
    }

    $token = Get-EnvValue -Name 'SYSTEM_ACCESSTOKEN'
    if ([string]::IsNullOrWhiteSpace($token)) {
        Stop-WithError "SYSTEM_ACCESSTOKEN no está disponible. Activa 'Allow scripts to access the OAuth token' en el pipeline."
    }

    $script:tempBranchName = "$($script:tempBranchPrefix)/$($script:targetBranch)/wi-$($script:workItemId)"
    $script:sourceRefName  = "refs/heads/$($script:tempBranchName)"
    $script:targetRefName  = "refs/heads/$($script:targetBranch)"

    Write-Log '========== INICIO PROMOCIÓN POR WORK ITEM =========='
    Write-Log "Organización              : $($script:organizationUrl)"
    Write-Log "Proyecto                  : $($script:project)"
    Write-Log "Repositorio               : $($script:repositoryName)"
    Write-Log "Work Item ID              : $($script:workItemId)"
    Write-Log "Rama destino              : $($script:targetBranch)"
    Write-Log "Rama temporal             : $($script:tempBranchName)"
    Write-Log "PR Draft                  : $createDraftPr"
    Write-Log "Dry Run                   : $($script:isDryRun)"
    Write-Log "Comment Work Item         : $commentWorkItem"
    Write-Log "Enable AutoComplete       : $enableAutoComplete"
    Write-Log "Complete PR Immediately   : $completePrImmediately"

    # Inicializar variables del pipeline
    Set-PipelineVar -Name 'Promote_PRId'          -Value ''
    Set-PipelineVar -Name 'Promote_PRUrl'         -Value ''
    Set-PipelineVar -Name 'Promote_SourceBranch'  -Value $script:tempBranchName
    Set-PipelineVar -Name 'Promote_TargetBranch'  -Value $script:targetBranch
    Set-PipelineVar -Name 'Promote_WorkItemId'    -Value $script:workItemId
    Set-PipelineVar -Name 'Promote_WorkItemTitle' -Value ''
    Set-PipelineVar -Name 'Promote_Result'        -Value 'STARTED'

    Ensure-GitIdentity
    Ensure-RemoteHasAuth -OrganizationUrl $script:organizationUrl -Project $script:project -RepositoryName $script:repositoryName

    Write-Log '--- Paso 1: Leer Work Item y relaciones ---'
    $wiUri = "$($script:organizationUrl.TrimEnd('/'))/$($script:project)/_apis/wit/workitems/$($script:workItemId)?`$expand=relations&api-version=7.1"
    $workItem = Invoke-AdoRest -Method GET -Uri $wiUri
    if ($null -eq $workItem) {
        Stop-WithError "No se pudo recuperar el Work Item $($script:workItemId)."
    }

    $script:workItemTitle = Sanitize-Text -Text $(if ($workItem.fields.'System.Title') { $workItem.fields.'System.Title' } else { "Work Item $($script:workItemId)" }) -MaxLength 140
    Set-PipelineVar -Name 'Promote_WorkItemTitle' -Value $script:workItemTitle
    Write-Success "Work Item leído correctamente: [$($script:workItemId)] $($script:workItemTitle)"

    if ($null -eq $workItem.relations -or $workItem.relations.Count -eq 0) {
        Stop-WithError "El Work Item $($script:workItemId) no tiene relaciones. No hay commits para promover."
    }

    Write-Log '--- Paso 2: Extraer y filtrar commits vinculados ---'
    $commitRelations = @()
    foreach ($relation in $workItem.relations) {
        if ($relation.rel -eq 'ArtifactLink' -and $relation.url -match 'vstfs:///Git/Commit/') {
            $details = Get-ArtifactDetailsFromRelationUrl -RelationUrl $relation.url
            if ($null -ne $details) {
                $commitRelations += $details
            }
        }
    }

    if ($commitRelations.Count -eq 0) {
        Stop-WithError "El Work Item $($script:workItemId) no tiene commits vinculados."
    }

    $uniqueCommitRelations = $commitRelations | Sort-Object CommitId -Unique
    Write-Success "Se encontraron $($uniqueCommitRelations.Count) commits únicos vinculados al Work Item."

    Write-Log '--- Paso 3: Validar mismo repositorio para todos los commits ---'
    $repoIds = $uniqueCommitRelations | Select-Object -ExpandProperty RepositoryId -Unique
    if ($repoIds.Count -ne 1) {
        Stop-WithError "Los commits vinculados pertenecen a más de un repositorio. Repos detectados: $($repoIds -join ', ')"
    }

    $script:linkedRepoId = $repoIds[0]
    $repoUri = "$($script:organizationUrl.TrimEnd('/'))/$($script:project)/_apis/git/repositories/$($script:linkedRepoId)?api-version=7.1"
    $linkedRepo = Invoke-AdoRest -Method GET -Uri $repoUri
    if ($null -eq $linkedRepo) {
        Stop-WithError 'No se pudo resolver el repositorio asociado a los commits.'
    }

    if ($linkedRepo.name -ne $script:repositoryName) {
        Stop-WithError "El repositorio indicado en variable ('$($script:repositoryName)') no coincide con el repositorio de los commits ('$($linkedRepo.name)')."
    }
    Write-Success "Todos los commits pertenecen al repositorio esperado: $($linkedRepo.name) [$($linkedRepo.id)]"

    Write-Log '--- Paso 4: Leer detalle de commits, validar existencia y ordenar cronológicamente ---'
    $commitDetails = @()
    foreach ($item in $uniqueCommitRelations) {
        $commitUri = "$($script:organizationUrl.TrimEnd('/'))/$($script:project)/_apis/git/repositories/$($script:linkedRepoId)/commits/$($item.CommitId)?api-version=7.1"
        $commit = Invoke-AdoRest -Method GET -Uri $commitUri
        if ($null -eq $commit) {
            Stop-WithError "No se pudo leer el detalle del commit $($item.CommitId)."
        }

        $commitDetails += [PSCustomObject]@{
            CommitId     = $commit.commitId
            Comment      = $(if ($commit.comment) { Sanitize-Text -Text (($commit.comment -split "`r?`n")[0]) -MaxLength 120 } else { '(sin comentario)' })
            AuthorName   = $commit.author.name
            AuthorEmail  = $commit.author.email
            AuthorDate   = [datetime]$commit.author.date
            RepositoryId = $script:linkedRepoId
        }
    }

    if ($commitDetails.Count -eq 0) {
        Stop-WithError 'No se logró resolver el detalle de los commits vinculados.'
    }

    $orderedCommits = $commitDetails | Sort-Object AuthorDate, CommitId
    Write-Success 'Commits ordenados cronológicamente:'
    foreach ($c in $orderedCommits) {
        Write-Host ("       {0} | {1:yyyy-MM-dd HH:mm:ss} | {2}" -f $c.CommitId, $c.AuthorDate, $c.Comment)
    }

    Write-Log '--- Paso 5: Preparar workspace git y validar ramas existentes ---'
    Exec-Git -Args @('status','--short') | Out-Null
    Exec-Git -Args @('fetch','--all','--prune') | Out-Null

    $targetBranchExists = Exec-Git -Args @('ls-remote','--heads','origin',$script:targetBranch) -AllowFailure
    if ($targetBranchExists.ExitCode -ne 0 -or [string]::IsNullOrWhiteSpace(($targetBranchExists.Output -join '').Trim())) {
        Stop-WithError "La rama destino 'origin/$($script:targetBranch)' no existe en el remoto."
    }
    Write-Success "Rama destino validada: origin/$($script:targetBranch)"

    # Validar si ya existe rama temporal para el mismo WI en cualquier destino
    $matchingRemoteBranches = Exec-Git -Args @('branch','-r','--list',"origin/$($script:tempBranchPrefix)/*/wi-$($script:workItemId)") -AllowFailure
    $existingTempBranches = @($matchingRemoteBranches.Output | ForEach-Object { $_.ToString().Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })
    if ($existingTempBranches.Count -gt 0) {
        Stop-WithError "Ya existe al menos una rama temporal para este Work Item en otro destino: $($existingTempBranches -join ', ')"
    }
    Write-Success 'No existe rama temporal previa para este Work Item en ningún destino.'

    # Validar que la rama temporal concreta tampoco exista en remoto
    $remoteTempExists = Exec-Git -Args @('ls-remote','--heads','origin',$script:tempBranchName) -AllowFailure
    if ($remoteTempExists.ExitCode -eq 0 -and -not [string]::IsNullOrWhiteSpace(($remoteTempExists.Output -join '').Trim())) {
        Stop-WithError "La rama temporal 'origin/$($script:tempBranchName)' ya existe. Por seguridad no se sobrescribirá."
    }
    Write-Success "La rama temporal no existe en remoto: origin/$($script:tempBranchName)"

    Exec-Git -Args @('checkout',$script:targetBranch) -AllowFailure | Out-Null
    Exec-Git -Args @('checkout','-B',$script:targetBranch,"origin/$($script:targetBranch)") | Out-Null
    Exec-Git -Args @('reset','--hard',"origin/$($script:targetBranch)") | Out-Null

    $localTempExists = Exec-Git -Args @('show-ref','--verify','--quiet',"refs/heads/$($script:tempBranchName)") -AllowFailure
    if ($localTempExists.ExitCode -eq 0) {
        Write-WarnLog "La rama local '$($script:tempBranchName)' ya existía. Se eliminará para recrearla limpia."
        Exec-Git -Args @('checkout',$script:targetBranch) | Out-Null
        Exec-Git -Args @('branch','-D',$script:tempBranchName) | Out-Null
        Write-Success 'Rama local temporal previa eliminada.'
    }

    # Validar que los commits existan localmente tras el fetch
    foreach ($commit in $orderedCommits) {
        if (-not (Test-CommitExistsLocally -CommitId $commit.CommitId)) {
            Stop-WithError "El commit $($commit.CommitId) no existe en el repo local tras el fetch. Verifica que el commit siga disponible en el historial remoto."
        }
    }
    Write-Success 'Todos los commits existen localmente y están listos para cherry-pick.'

    Write-Log '--- Paso 6: Crear rama temporal desde la rama destino ---'
    Exec-Git -Args @('checkout','-b',$script:tempBranchName,"origin/$($script:targetBranch)") | Out-Null
    Write-Success "Rama temporal creada: $($script:tempBranchName)"

    Write-Log '--- Paso 7: Cherry-pick de commits en orden cronológico ---'
    $appliedCommits = New-Object System.Collections.Generic.List[object]

    foreach ($commit in $orderedCommits) {
        Write-Log "Aplicando commit $($commit.CommitId) ..."
        $pickResult = Exec-Git -Args @('cherry-pick',$commit.CommitId) -AllowFailure

        if ($pickResult.ExitCode -ne 0) {
            $joined = ($pickResult.Output -join "`n")
            if ($joined -match 'previous cherry-pick is now empty' -or $joined -match 'nothing to commit') {
                Write-WarnLog "El cherry-pick del commit $($commit.CommitId) resultó vacío. Se omitirá este commit."
                Exec-Git -Args @('cherry-pick','--skip') -AllowFailure | Out-Null
                continue
            }

            Write-WarnLog "Se detectó conflicto o error al aplicar el commit $($commit.CommitId). Se abortará el cherry-pick."
            Exec-Git -Args @('cherry-pick','--abort') -AllowFailure | Out-Null
            Stop-WithError "Cherry-pick abortado. Falló al aplicar el commit $($commit.CommitId) sobre la rama $($script:tempBranchName)."
        }

        $appliedCommits.Add($commit)
        Write-Success "Commit aplicado correctamente: $($commit.CommitId)"
    }

    if ($appliedCommits.Count -eq 0) {
        Stop-WithError 'No se aplicó ningún commit nuevo. El proceso se detiene para evitar un PR vacío.'
    }

    Write-Success "Cherry-pick completado con éxito. Total aplicados: $($appliedCommits.Count)"

    Write-Log '--- Paso 8: Validar que la rama temporal tenga cambios reales respecto a la rama destino ---'
    $aheadCountResult = Exec-Git -Args @('rev-list','--count',"origin/$($script:targetBranch)..HEAD")
    $aheadCountText = ($aheadCountResult.Output -join '').Trim()
    [int]$aheadCount = 0
    if (-not [int]::TryParse($aheadCountText, [ref]$aheadCount)) {
        Stop-WithError "No se pudo interpretar el conteo de commits por delante de origin/$($script:targetBranch). Valor recibido: '$aheadCountText'"
    }

    $diffResult = Exec-Git -Args @('diff','--name-only',"origin/$($script:targetBranch)..HEAD")
    $changedFiles = @($diffResult.Output | ForEach-Object { $_.ToString().Trim() } | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

    if ($aheadCount -le 0 -or $changedFiles.Count -le 0) {
        Stop-WithError "La rama temporal no quedó con cambios nuevos respecto a origin/$($script:targetBranch). Se evita crear un PR vacío."
    }

    Write-Success "Validación correcta: la rama temporal quedó $aheadCount commit(s) por delante y con $($changedFiles.Count) archivo(s) afectados."

    Write-Log '--- Paso 9: Publicar rama temporal al remoto ---'
    if ($script:isDryRun) {
        Write-WarnLog "DRY-RUN: no se hará push de la rama temporal '$($script:tempBranchName)'."
    }
    else {
        Exec-Git -Args @('push','-u','origin',$script:tempBranchName) | Out-Null
        Write-Success "Rama temporal publicada: origin/$($script:tempBranchName)"
    }

    Write-Log '--- Paso 10: Crear Pull Request ---'
    $commitLines = foreach ($c in $appliedCommits) {
        "- $($c.CommitId) | $($c.AuthorDate.ToString('yyyy-MM-dd HH:mm:ss')) | $($c.Comment)"
    }

    $targetTag = '[' + ($script:targetBranch.ToUpperInvariant()) + ']'
    $safePrefix = Sanitize-Text -Text $prTitlePrefix -MaxLength 30
    $script:prTitle = Sanitize-Text -Text "$safePrefix$targetTag WI $($script:workItemId) - $($script:workItemTitle)" -MaxLength 220

    $prDescription = @"
Promoción automática generada desde Work Item.

Work Item:
- ID: $($script:workItemId)
- Título: $($script:workItemTitle)

Repositorio:
- $($script:repositoryName)

Rama origen:
- $($script:tempBranchName)

Rama destino:
- $($script:targetBranch)

Commits incluidos:
$($commitLines -join "`n")

Archivos modificados:
$((($changedFiles | ForEach-Object { "- $_" }) -join "`n"))

Notas:
- PR generado automáticamente por pipeline.
- Si existe política de squash en la rama destino, el merge final quedará consolidado según esa política.
- Dry Run: $($script:isDryRun)
"@

    if ($script:isDryRun) {
        Write-WarnLog 'DRY-RUN: no se creará el Pull Request.'
        $script:prId = 'DRY-RUN'
        $script:prWebUrl = '(no creado por dry-run)'
    }
    else {
        $prUri = "$($script:organizationUrl.TrimEnd('/'))/$($script:project)/_apis/git/repositories/$($script:linkedRepoId)/pullrequests?api-version=7.1"
        $prBody = @{
            sourceRefName = $script:sourceRefName
            targetRefName = $script:targetRefName
            title         = $script:prTitle
            description   = $prDescription
            isDraft       = $createDraftPr
            workItemRefs  = @(@{ id = $script:workItemId })
        }

        $prResponse = Invoke-AdoRest -Method POST -Uri $prUri -Body $prBody
        if ($null -eq $prResponse -or -not $prResponse.pullRequestId) {
            Stop-WithError 'No se recibió una respuesta válida al crear el Pull Request.'
        }

        $script:prId = [string]$prResponse.pullRequestId
        if ($prResponse._links -and $prResponse._links.web -and $prResponse._links.web.href) {
            $script:prWebUrl = $prResponse._links.web.href
        }
        elseif ($prResponse.remoteUrl) {
            $script:prWebUrl = $prResponse.remoteUrl
        }
        else {
            $script:prWebUrl = $prResponse.url
        }

        Write-Success "Pull Request creado correctamente. PR ID: $($script:prId)"

        if (-not [string]::IsNullOrWhiteSpace($adoReviewerNames)) {
            Write-Log '--- Paso 11: Resolver y agregar reviewers al PR ---'
            $reviewers = Resolve-ReviewerIdentities -OrganizationUrl $script:organizationUrl -ReviewerNamesCsv $adoReviewerNames
            if ($reviewers.Count -gt 0) {
                Add-ReviewersToPr -OrganizationUrl $script:organizationUrl -Project $script:project -RepositoryId $script:linkedRepoId -PullRequestId $script:prId -ReviewerIdentities $reviewers
            }
            else {
                Write-WarnLog 'No se resolvieron reviewers válidos. El PR quedará sin reviewers automáticos.'
            }
        }

        if ($enableAutoComplete) {
            Write-Log '--- Paso 12: Configurar auto-complete del PR ---'
            $currentUserId = Get-AuthenticatedUserId -OrganizationUrl $script:organizationUrl
            Set-PrAutoComplete -OrganizationUrl $script:organizationUrl -Project $script:project -RepositoryId $script:linkedRepoId -PullRequestId $script:prId -CurrentUserId $currentUserId -DeleteSourceBranch:$deleteSourceOnComplete
        }

        if ($completePrImmediately) {
            Write-Log '--- Paso 13: Solicitar completion inmediata del PR ---'
            Complete-PrNow -OrganizationUrl $script:organizationUrl -Project $script:project -RepositoryId $script:linkedRepoId -PullRequestId $script:prId -DeleteSourceBranch:$deleteSourceOnComplete
        }
    }

    if ($commentWorkItem) {
        Write-Log '--- Paso 14: Agregar comentario al Work Item con el resultado ---'
        $commentText = @"
Promoción automática creada correctamente.

Work Item: $($script:workItemId)
Título: $($script:workItemTitle)
Repositorio: $($script:repositoryName)
Rama origen: $($script:tempBranchName)
Rama destino: $($script:targetBranch)
Commits aplicados: $($appliedCommits.Count)
PR ID: $($script:prId)
PR URL: $($script:prWebUrl)
Dry Run: $($script:isDryRun)
"@
        Add-WorkItemComment -OrganizationUrl $script:organizationUrl -Project $script:project -WorkItemId $script:workItemId -Text $commentText -DryRun:$script:isDryRun
    }

    Set-PipelineVar -Name 'Promote_PRId'         -Value $script:prId
    Set-PipelineVar -Name 'Promote_PRUrl'        -Value $script:prWebUrl
    Set-PipelineVar -Name 'Promote_SourceBranch' -Value $script:tempBranchName
    Set-PipelineVar -Name 'Promote_TargetBranch' -Value $script:targetBranch
    Set-PipelineVar -Name 'Promote_Result'       -Value 'SUCCESS'

    Write-Host ''
    Write-Host '===================================================='
    Write-Host 'RESUMEN FINAL'
    Write-Host '===================================================='
    Write-Host "Work Item ID      : $($script:workItemId)"
    Write-Host "Work Item Title   : $($script:workItemTitle)"
    Write-Host "Repositorio       : $($script:repositoryName)"
    Write-Host "Rama origen       : $($script:tempBranchName)"
    Write-Host "Rama destino      : $($script:targetBranch)"
    Write-Host "PR ID             : $($script:prId)"
    Write-Host "PR Title          : $($script:prTitle)"
    Write-Host "PR URL            : $($script:prWebUrl)"
    Write-Host "Dry Run           : $($script:isDryRun)"
    Write-Host '===================================================='
    Write-Host ''

    Write-Success 'Proceso completado con éxito.'
    exit 0
}
catch {
    $errorMessage = $_.Exception.Message
    Write-Error $errorMessage

    Set-PipelineVar -Name 'Promote_Result' -Value 'FAILED'

    if ($script:commentOnFailure -and -not [string]::IsNullOrWhiteSpace($script:organizationUrl) -and -not [string]::IsNullOrWhiteSpace($script:project) -and -not [string]::IsNullOrWhiteSpace($script:workItemId)) {
        try {
            $failureComment = @"
La promoción automática falló.

Work Item: $($script:workItemId)
Repositorio: $($script:repositoryName)
Rama origen esperada: $($script:tempBranchName)
Rama destino: $($script:targetBranch)
PR ID: $($script:prId)
PR URL: $($script:prWebUrl)
Dry Run: $($script:isDryRun)
Detalle del error:
$errorMessage
"@
            Add-WorkItemComment -OrganizationUrl $script:organizationUrl -Project $script:project -WorkItemId $script:workItemId -Text $failureComment -DryRun:$script:isDryRun
        }
        catch {
            Write-WarnLog "No se pudo agregar comentario de error al Work Item. Detalle: $($_.Exception.Message)"
        }
    }

    exit 1
}
