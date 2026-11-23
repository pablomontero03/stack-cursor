<#
Libreria compartida del dominio Azure Resource Manager (manage-azure-resources),
dot-sourceada por los demas scripts de scripts\. Mismos principios de robustez
que Aks-Common.ps1 (dominio AKS) e Invoke-AdoRest.ps1 (dominio Azure DevOps
Pipelines): hash canonico SHA-256, journal de ejecucion con lock exclusivo de
archivo, escritura atomica (archivo temporal + rename), argv tokenizado sin
strings de shell crudos.

El MCP oficial `azure` (@azure/mcp) NO esta instalado todavia -- ver
.kiro/rules/azure/authorization.md. Todo este dominio opera hoy
exclusivamente via Azure CLI (`az`), Azure Resource Graph (`az graph query`) y
ARM REST controlado (`az rest`), nunca via MCP. No asumir que
`mcp__azure__*` existe hasta que `.mcp.json` lo declare explicitamente.
#>

function Get-AzureProjectRoot {
    $here = $PSScriptRoot
    # scripts\ -> manage-azure-resources\ -> skills\ -> .kiro\ -> raiz del proyecto
    return (Resolve-Path (Join-Path $here '..\..\..\..')).Path
}

function Get-AzureLocalRoot { return Join-Path (Get-AzureProjectRoot) '.local\azure' }
function Get-AzureInventoryDir { return Join-Path (Get-AzureLocalRoot) 'inventory' }
function Get-AzurePlansDir { return Join-Path (Get-AzureLocalRoot) 'plans' }
function Get-AzureBackupsDir { return Join-Path (Get-AzureLocalRoot) 'backups' }
function Get-AzureExecutionsDir { return Join-Path (Get-AzureLocalRoot) 'executions' }
function Get-AzureLogsDir { return Join-Path (Get-AzureLocalRoot) 'logs' }
function Get-AzureDeviationsDir { return Join-Path (Get-AzureLocalRoot) 'deviations' }

function Assert-AzureDirectoryExists {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Invoke-AzureCliJson {
    <#
    Ejecuta `az` con argumentos tokenizados (nunca una linea de shell) y
    parsea la salida como JSON (`--output json` se agrega siempre). Nunca usa
    `--debug`. Devuelve $null si `az` no esta disponible o el comando falla;
    el llamador decide como reportar eso.
    #>
    param([Parameter(Mandatory)] [string[]]$Argv)

    $fullArgv = @($Argv) + @('--output', 'json')
    try {
        $raw = & az @fullArgv 2>$null
    }
    catch {
        return $null
    }
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace([string]($raw | Out-String))) {
        return $null
    }
    try {
        return ($raw | Out-String) | ConvertFrom-Json
    }
    catch {
        return $null
    }
}

function Get-AzureCliVersion {
    $v = Invoke-AzureCliJson -Argv @('version')
    return $v
}

function Get-AzureAccountContext {
    <#
    Devuelve tenantId/subscriptionId/subscriptionName/userName sanitizados
    (sin tokens). Si no hay sesion, devuelve $null -- el llamador debe pedir
    al usuario que corra `az login` manualmente; este dominio nunca lo
    ejecuta automaticamente.
    #>
    param([string]$SubscriptionId)

    $argv = @('account', 'show')
    if ($SubscriptionId) { $argv += @('--subscription', $SubscriptionId) }
    $acct = Invoke-AzureCliJson -Argv $argv
    if (-not $acct) { return $null }

    return [PSCustomObject]@{
        tenantId         = [string]$acct.tenantId
        subscriptionId   = [string]$acct.id
        subscriptionName = [string]$acct.name
        userName         = [string]$acct.user.name
        userType         = [string]$acct.user.type
        environmentName  = [string]$acct.environmentName
        isDefault        = [bool]$acct.isDefault
    }
}

function Get-AzurePlanCanonicalHash {
    <#
    SHA-256 sobre el contenido canonico del plan -- todo EXCEPTO los campos
    que el propio proceso de validacion escribe (validated, validationHash,
    validationEvidence, reviewStatus). Cualquier edicion manual del plan
    despues de validarlo cambia este hash y Apply-AzureChangePlan.ps1 lo
    rechaza.
    #>
    param([Parameter(Mandatory)] $Plan)

    $clone = $Plan | Select-Object * -ExcludeProperty validated, validationHash, validationEvidence, reviewStatus
    $json = $clone | ConvertTo-Json -Depth 30 -Compress
    $bytes = [Text.Encoding]::UTF8.GetBytes($json)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    return -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
}

function Get-AzureFileSha256 {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
    return $hash.Hash.ToLowerInvariant()
}

function New-AzureOperationId {
    param(
        [Parameter(Mandatory)] [string]$Action,
        [Parameter(Mandatory)] [string]$ResourceType,
        [Parameter(Mandatory)] [string]$ResourceName
    )
    return "$Action-$ResourceType-$ResourceName".ToLowerInvariant() -replace '[^a-z0-9-]', '-'
}

function Get-AzureExecutionJournalPath {
    param([Parameter(Mandatory)] [string]$PlanValidationHash)
    return Join-Path (Get-AzureExecutionsDir) "$PlanValidationHash.json"
}

function Lock-AzureJournalFile {
    <#
    Abre (o crea) un archivo de lock con FileShare.None -- exclusivo. Si otro
    proceso ya lo tiene abierto, reintenta con backoff corto hasta
    -TimeoutMs. Devuelve el FileStream abierto; el llamador DEBE cerrarlo en
    un finally.
    #>
    param([Parameter(Mandatory)] [string]$LockPath, [int]$TimeoutMs = 5000)

    $dir = Split-Path -Parent $LockPath
    Assert-AzureDirectoryExists -Path $dir

    $sw = [System.Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        try {
            return [System.IO.File]::Open($LockPath, [System.IO.FileMode]::OpenOrCreate, [System.IO.FileAccess]::ReadWrite, [System.IO.FileShare]::None)
        }
        catch [System.IO.IOException] {
            if ($sw.ElapsedMilliseconds -ge $TimeoutMs) {
                throw "No se pudo obtener el lock exclusivo del journal ('$LockPath') tras ${TimeoutMs}ms; otro proceso lo tiene tomado. Se rechaza esta llamada en vez de arriesgar una escritura duplicada."
            }
            Start-Sleep -Milliseconds 50
        }
    }
}

function Read-AzureExecutionJournal {
    <#
    Lee el journal. Si no existe, devuelve uno nuevo con TODOS los
    -OperationIds en 'pending'. Si ya existe, exige el MISMO conjunto exacto
    de operationIds y que cada entrada tenga un estado valido -- cualquier
    desvio es journal corrupto, bloqueo seguro (excepcion).
    #>
    param(
        [Parameter(Mandatory)] [string]$JournalPath,
        [Parameter(Mandatory)] [string]$PlanValidationHash,
        [string[]]$OperationIds = @()
    )

    $validStates = @(
        'pending', 'in-progress', 'succeeded', 'failed-before-write',
        'failed-after-write', 'ambiguous', 'skipped-already-desired',
        'blocked-drift', 'blocked-deviation'
    )

    if (-not (Test-Path -LiteralPath $JournalPath)) {
        $ops = [ordered]@{}
        foreach ($id in $OperationIds) {
            $ops[$id] = [ordered]@{ state = 'pending'; startedAtUtc = $null; completedAtUtc = $null; resultId = $null }
        }
        return [PSCustomObject]@{
            planValidationHash = $PlanValidationHash
            createdAtUtc       = (Get-Date).ToUniversalTime().ToString('o')
            operations         = [PSCustomObject]$ops
        }
    }

    $raw = Get-Content -LiteralPath $JournalPath -Raw
    try {
        $journal = $raw | ConvertFrom-Json
    }
    catch {
        throw "Journal de ejecucion corrupto en '$JournalPath' (JSON invalido). Bloqueo seguro."
    }

    if (-not $journal.planValidationHash -or $journal.planValidationHash -ne $PlanValidationHash) {
        throw "Journal de ejecucion en '$JournalPath' no coincide con este plan (planValidationHash distinto). Bloqueo seguro."
    }
    if (-not $journal.operations) {
        throw "Journal de ejecucion en '$JournalPath' no tiene bloque 'operations'. Bloqueo seguro."
    }

    $journalOpIds = @($journal.operations.PSObject.Properties.Name)
    $expectedOpIds = @($OperationIds)

    $missingFromJournal = @($expectedOpIds | Where-Object { $journalOpIds -notcontains $_ })
    $extraInJournal = @($journalOpIds | Where-Object { $expectedOpIds -notcontains $_ })

    if ($missingFromJournal.Count -gt 0) {
        throw "Journal de ejecucion corrupto en '$JournalPath': falta(n) $($missingFromJournal -join ', '). Bloqueo seguro."
    }
    if ($extraInJournal.Count -gt 0) {
        throw "Journal de ejecucion corrupto en '$JournalPath': tiene operacion(es) $($extraInJournal -join ', ') que no estan en el plan aprobado actual. Bloqueo seguro."
    }

    foreach ($opId in $journalOpIds) {
        $state = [string]$journal.operations.$opId.state
        if ($validStates -notcontains $state) {
            throw "Journal de ejecucion corrupto en '$JournalPath': la operacion '$opId' tiene un estado invalido ('$state'). Bloqueo seguro."
        }
    }

    return $journal
}

function Write-AzureExecutionJournalAtomic {
    param([Parameter(Mandatory)] [string]$JournalPath, [Parameter(Mandatory)] $Journal)

    $dir = Split-Path -Parent $JournalPath
    Assert-AzureDirectoryExists -Path $dir

    $tmpPath = "$JournalPath.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        $Journal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tmpPath -Encoding utf8
        Move-Item -LiteralPath $tmpPath -Destination $JournalPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
    }
}

function Start-AzureJournaledOperation {
    <#
    Bajo lock exclusivo: lee/crea el journal, exige que la operacion este
    'pending' (cualquier otro estado se omite -- nunca se reintenta
    automaticamente -- y devuelve $false), la marca 'in-progress' y persiste
    antes de devolver $true (el llamador recien ahi ejecuta la operacion
    real).
    #>
    param(
        [Parameter(Mandatory)] [string]$PlanValidationHash,
        [Parameter(Mandatory)] [string[]]$AllOperationIds,
        [Parameter(Mandatory)] [string]$OperationId
    )

    $journalPath = Get-AzureExecutionJournalPath -PlanValidationHash $PlanValidationHash
    $lockPath = "$journalPath.lock"
    $lockStream = Lock-AzureJournalFile -LockPath $lockPath

    try {
        $journal = Read-AzureExecutionJournal -JournalPath $journalPath -PlanValidationHash $PlanValidationHash -OperationIds $AllOperationIds
        $op = $journal.operations.$OperationId

        if ($op.state -ne 'pending') {
            Write-Host "Operacion '$OperationId': ya estaba '$($op.state)' en el journal de una corrida anterior -- se omite, no se reintenta." -ForegroundColor Yellow
            return $false
        }

        $op.state = 'in-progress'
        $op.startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Write-AzureExecutionJournalAtomic -JournalPath $journalPath -Journal $journal
        return $true
    }
    finally {
        $lockStream.Close()
    }
}

function Complete-AzureJournaledOperation {
    param(
        [Parameter(Mandatory)] [string]$PlanValidationHash,
        [Parameter(Mandatory)] [string[]]$AllOperationIds,
        [Parameter(Mandatory)] [string]$OperationId,
        [ValidateSet('succeeded', 'failed-before-write', 'failed-after-write', 'ambiguous', 'skipped-already-desired', 'blocked-drift', 'blocked-deviation')]
        [string]$FinalState = 'succeeded',
        [string]$ResultId = $null
    )

    $journalPath = Get-AzureExecutionJournalPath -PlanValidationHash $PlanValidationHash
    $lockPath = "$journalPath.lock"
    $lockStream = Lock-AzureJournalFile -LockPath $lockPath

    try {
        $journal = Read-AzureExecutionJournal -JournalPath $journalPath -PlanValidationHash $PlanValidationHash -OperationIds $AllOperationIds
        $op = $journal.operations.$OperationId
        $op.state = $FinalState
        $op.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        $op.resultId = $ResultId
        Write-AzureExecutionJournalAtomic -JournalPath $journalPath -Journal $journal
    }
    finally {
        $lockStream.Close()
    }
}

function Find-AzureSensitiveJsonProperties {
    <#
    Escanea recursivamente un objeto ya parseado (de un plan/inventario) por
    NOMBRE de propiedad sensible con un valor literal no-placeholder.
    Placeholder permitido: cualquier valor que contenga '${...}' o sea
    exactamente '***REDACTED***' o $null. Excepcion documentada (igual
    criterio que el dominio de permisos ADO): una propiedad llamada
    exactamente 'resourceId' o 'id' nunca se trata como secreto aunque
    contenga texto largo -- son identificadores de recursos, no secretos.
    #>
    param([Parameter(Mandatory)] $Object, [string]$Path = '$')

    # Nota: 'pat' se excluye deliberadamente -- como substring generico
    # produce falsos positivos frecuentes ('path', 'update', 'template',
    # 'compute'...). Los secretos reales de Azure no usan ese nombre
    # (se llaman clientSecret/accessToken/accountKey/sasToken, todos ya
    # cubiertos abajo).
    $sensitiveNames = @(
        'password', 'passwd', 'pwd', 'token', 'accesstoken', 'accountkey',
        'connectionstring', 'clientsecret', 'secret', 'apikey', 'privatekey',
        'authorization', 'sastoken', 'certificate', 'primarykey', 'secondarykey'
    )
    $findings = [System.Collections.Generic.List[object]]::new()

    function Test-AzurePlaceholderValue {
        param([string]$Value)
        if ($null -eq $Value) { return $true }
        if ($Value -eq '***REDACTED***') { return $true }
        if ($Value -match '\$\{[A-Za-z0-9_]+\}') { return $true }
        return $false
    }

    function Step {
        param($Obj, [string]$CurPath)

        if ($null -eq $Obj) { return }

        if ($Obj -is [System.Management.Automation.PSCustomObject]) {
            foreach ($prop in $Obj.PSObject.Properties) {
                $childPath = "$CurPath.$($prop.Name)"
                $lowerName = $prop.Name.ToLowerInvariant()
                $isSensitiveName = $sensitiveNames | Where-Object { $lowerName -like "*$_*" }
                if ($isSensitiveName -and $prop.Value -is [string]) {
                    if (-not (Test-AzurePlaceholderValue -Value $prop.Value)) {
                        $findings.Add([PSCustomObject]@{ path = $childPath; property = $prop.Name })
                    }
                }
                Step -Obj $prop.Value -CurPath $childPath
            }
        }
        elseif ($Obj -is [System.Collections.IEnumerable] -and -not ($Obj -is [string])) {
            $i = 0
            foreach ($item in $Obj) {
                Step -Obj $item -CurPath "$CurPath[$i]"
                $i++
            }
        }
    }

    Step -Obj $Object -CurPath $Path
    return @($findings)
}

function Find-AzureSensitiveRawText {
    <#
    Defensa adicional: regex sobre el TEXTO crudo del archivo (no el objeto
    parseado), por si un secreto aparece en una clave que el scan por nombre
    de propiedad no cubre (ej. dentro de un argv o un rawArgs). Ignora
    cualquier ocurrencia que sea un placeholder ${VAR} o ***REDACTED***.
    #>
    param([Parameter(Mandatory)] [string]$Text)

    $patterns = @(
        '(?i)(password|passwd|pwd)\s*[:=]\s*"?[^"\s,${}]{4,}',
        '(?i)(client[_-]?secret)\s*[:=]\s*"?[^"\s,${}]{4,}',
        '(?i)(access[_-]?token|accesstoken)\s*[:=]\s*"?[^"\s,${}]{8,}',
        '(?i)(connection[_-]?string)\s*[:=]\s*"?[^"\s,${}]{8,}',
        'AccountKey=[A-Za-z0-9+/=]{16,}',
        'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}'
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $patterns) {
        if ([regex]::IsMatch($Text, $p)) {
            $findings.Add($p)
        }
    }
    return @($findings)
}

function ConvertTo-AzurePrettyJson {
    param([Parameter(Mandatory)] $Object, [int]$Depth = 30)
    # Evita el problema conocido de Get-Content -Raw + ConvertTo-Json en
    # PS5.1 con strings muy largas -- reconstruye la cadena antes de
    # serializar cuando el objeto viene de un -Raw read.
    return ($Object | ConvertTo-Json -Depth $Depth)
}
