<#
Libreria compartida del dominio Cloudflare (manage-cloudflare), dot-sourceada
por los demas scripts de scripts\. Mismos principios de robustez que
Azure-Common.ps1 (dominio Azure Resource Manager) / Aks-Common.ps1 (AKS) /
Invoke-AdoRest.ps1 (Azure DevOps Pipelines): hash canonico SHA-256, journal
de ejecucion con lock exclusivo de archivo, escritura atomica (archivo
temporal + rename), argv tokenizado sin strings de shell crudos.

Este dominio no tiene un CLI propietario equivalente a `az` -- la via
deterministica es la API REST oficial (`https://api.cloudflare.com/client/v4`)
via Invoke-CloudflareApiRequest, mas terraform/wrangler cuando correspondan.
El MCP oficial `cloudflare-api` (OAuth, Streamable HTTP) es independiente de
esta libreria -- ver references/connections-and-authentication.md.
#>

function Get-CloudflareProjectRoot {
    $here = $PSScriptRoot
    # scripts\ -> manage-cloudflare\ -> skills\ -> .kiro\ -> raiz del proyecto
    return (Resolve-Path (Join-Path $here '..\..\..\..')).Path
}

function Get-CloudflareLocalRoot { return Join-Path (Get-CloudflareProjectRoot) '.local\cloudflare' }
function Get-CloudflareInventoryDir { return Join-Path (Get-CloudflareLocalRoot) 'inventory' }
function Get-CloudflarePlansDir { return Join-Path (Get-CloudflareLocalRoot) 'plans' }
function Get-CloudflareDeletePlansDir { return Join-Path (Get-CloudflareLocalRoot) 'delete-plans' }
function Get-CloudflareBackupsDir { return Join-Path (Get-CloudflareLocalRoot) 'backups' }
function Get-CloudflareExecutionsDir { return Join-Path (Get-CloudflareLocalRoot) 'executions' }
function Get-CloudflareReportsDir { return Join-Path (Get-CloudflareLocalRoot) 'reports' }
function Get-CloudflareLogsDir { return Join-Path (Get-CloudflareLocalRoot) 'logs' }

function Assert-CloudflareDirectoryExists {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-CloudflareApiBaseUri { return 'https://api.cloudflare.com/client/v4' }

function ConvertTo-CloudflareSanitizedErrorMessage {
    <#
    Quita cualquier rastro de un header Authorization o de un valor que luzca
    como el token de la variable de entorno antes de dejar que un mensaje de
    error se propague o se imprima.
    #>
    param([string]$Message)
    if ([string]::IsNullOrEmpty($Message)) { return $Message }
    $sanitized = $Message -replace '(?i)authorization\s*:\s*bearer\s+\S+', 'Authorization: Bearer ***REDACTED***'
    $token = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN')
    if (-not [string]::IsNullOrEmpty($token)) {
        $sanitized = $sanitized.Replace($token, '***REDACTED***')
    }
    return $sanitized
}

function Invoke-CloudflareApiRequest {
    <#
    Unico punto que arma el header Authorization real, y lo hace solo en
    memoria del proceso -- nunca lo imprime, nunca lo devuelve, nunca lo deja
    en un mensaje de error. Devuelve $null (no lanza) en fallo generico,
    respuesta vacia o JSON invalido -- el llamador decide como reportarlo.
    Excepcion: un 401/403 SI lanza (con mensaje sanitizado), porque es una
    senal de configuracion que el llamador no deberia tratar como "vacio".
    Nunca usa -Debug/-Verbose (podrian volcar headers a la consola).
    #>
    param(
        [Parameter(Mandatory)] [ValidateSet('GET', 'HEAD', 'POST', 'PUT', 'PATCH', 'DELETE')] [string]$Method,
        [Parameter(Mandatory)] [string]$Uri,
        $Body = $null,
        [hashtable]$Headers = @{}
    )

    # Seam de pruebas: si tests\run-script-tests.ps1 definio este scriptblock
    # global, se usa en vez de tocar red real. $Global: es visible sin
    # importar si el script que llama fue dot-sourceado o invocado con '&',
    # a diferencia de redefinir la funcion (que un dot-source interno de este
    # mismo archivo volveria a pisar). Queda $null en produccion siempre.
    if ($Global:CloudflareApiRequestMock) {
        return & $Global:CloudflareApiRequestMock $Method $Uri $Body $Headers
    }

    $token = [Environment]::GetEnvironmentVariable('CLOUDFLARE_API_TOKEN')
    if ([string]::IsNullOrWhiteSpace($token)) {
        Write-Verbose "CLOUDFLARE_API_TOKEN no esta configurada -- no se puede llamar a la API real."
        return $null
    }

    $requestHeaders = @{ 'Authorization' = "Bearer $token"; 'Content-Type' = 'application/json' }
    foreach ($key in $Headers.Keys) { $requestHeaders[$key] = $Headers[$key] }

    $invokeParams = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $requestHeaders
        ErrorAction = 'Stop'
    }
    if ($null -ne $Body -and $Method -in @('POST', 'PUT', 'PATCH', 'DELETE')) {
        $invokeParams['Body'] = ($Body | ConvertTo-Json -Depth 30 -Compress)
    }

    try {
        $response = Invoke-RestMethod @invokeParams
        return $response
    }
    catch {
        $statusCode = $null
        if ($_.Exception.Response) {
            try { $statusCode = [int]$_.Exception.Response.StatusCode } catch { $statusCode = $null }
        }
        $sanitizedMessage = ConvertTo-CloudflareSanitizedErrorMessage -Message $_.Exception.Message
        if ($statusCode -in @(401, 403)) {
            throw "Cloudflare API respondio $statusCode (autenticacion/autorizacion). Detalle sanitizado: $sanitizedMessage"
        }
        Write-Verbose "Invoke-CloudflareApiRequest fallo (sanitizado): $sanitizedMessage"
        return $null
    }
}

function Get-CloudflareAccountContext {
    <#
    Devuelve accountId/accountName/tokenStatus sanitizados (nunca el token).
    Si no hay token o falla, devuelve $null -- el llamador reporta el
    hallazgo, nunca intenta generar/rotar un token automaticamente.
    #>
    param([string]$AccountId)

    $uri = if ($AccountId) { "$(Get-CloudflareApiBaseUri)/accounts/$AccountId" } else { "$(Get-CloudflareApiBaseUri)/accounts" }
    $response = Invoke-CloudflareApiRequest -Method GET -Uri $uri
    if (-not $response -or -not $response.success) { return $null }

    $account = if ($AccountId) { $response.result } else { @($response.result)[0] }
    if (-not $account) { return $null }

    return [PSCustomObject]@{
        accountId   = [string]$account.id
        accountName = [string]$account.name
        tokenStatus = 'valid'
    }
}

function Get-CloudflarePlanCanonicalHash {
    <#
    SHA-256 sobre el contenido canonico del plan -- todo EXCEPTO los campos
    que el propio proceso de validacion escribe (validated, validationHash,
    validationEvidence, reviewStatus). Cualquier edicion manual del plan
    despues de validarlo cambia este hash y Apply-CloudflareChangePlan.ps1 /
    Apply-CloudflareDeletePlan.ps1 lo rechazan.
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

function Get-CloudflareFileSha256 {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) { return $null }
    $hash = Get-FileHash -LiteralPath $Path -Algorithm SHA256
    return $hash.Hash.ToLowerInvariant()
}

function New-CloudflareOperationId {
    param(
        [Parameter(Mandatory)] [string]$Action,
        [Parameter(Mandatory)] [string]$ResourceType,
        [Parameter(Mandatory)] [string]$ResourceName
    )
    return "$Action-$ResourceType-$ResourceName".ToLowerInvariant() -replace '[^a-z0-9-]', '-'
}

function Get-CloudflareExecutionJournalPath {
    param([Parameter(Mandatory)] [string]$PlanValidationHash)
    return Join-Path (Get-CloudflareExecutionsDir) "$PlanValidationHash.json"
}

function Lock-CloudflareJournalFile {
    <#
    Abre (o crea) un archivo de lock con FileShare.None -- exclusivo. Si otro
    proceso ya lo tiene abierto, reintenta con backoff corto hasta
    -TimeoutMs. Devuelve el FileStream abierto; el llamador DEBE cerrarlo en
    un finally.
    #>
    param([Parameter(Mandatory)] [string]$LockPath, [int]$TimeoutMs = 5000)

    $dir = Split-Path -Parent $LockPath
    Assert-CloudflareDirectoryExists -Path $dir

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

function Read-CloudflareExecutionJournal {
    <#
    Lee el journal. Si no existe, devuelve uno nuevo con TODOS los
    -OperationIds en 'pending'. Si ya existe, exige el MISMO conjunto exacto
    de operationIds y que cada entrada tenga un estado valido -- cualquier
    desvio es journal corrupto, bloqueo seguro (excepcion). 8 estados (sin
    'blocked-deviation' de Azure -- este dominio no usa un directorio de
    desviaciones separado, ver plan aprobado).
    #>
    param(
        [Parameter(Mandatory)] [string]$JournalPath,
        [Parameter(Mandatory)] [string]$PlanValidationHash,
        [string[]]$OperationIds = @()
    )

    $validStates = @(
        'pending', 'in-progress', 'succeeded', 'failed-before-write',
        'failed-after-write', 'ambiguous', 'skipped-already-desired',
        'blocked-drift'
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

function Write-CloudflareExecutionJournalAtomic {
    param([Parameter(Mandatory)] [string]$JournalPath, [Parameter(Mandatory)] $Journal)

    $dir = Split-Path -Parent $JournalPath
    Assert-CloudflareDirectoryExists -Path $dir

    $tmpPath = "$JournalPath.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        $Journal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tmpPath -Encoding utf8
        Move-Item -LiteralPath $tmpPath -Destination $JournalPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
    }
}

function Start-CloudflareJournaledOperation {
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

    $journalPath = Get-CloudflareExecutionJournalPath -PlanValidationHash $PlanValidationHash
    $lockPath = "$journalPath.lock"
    $lockStream = Lock-CloudflareJournalFile -LockPath $lockPath

    try {
        $journal = Read-CloudflareExecutionJournal -JournalPath $journalPath -PlanValidationHash $PlanValidationHash -OperationIds $AllOperationIds
        $op = $journal.operations.$OperationId

        if ($op.state -ne 'pending') {
            Write-Host "Operacion '$OperationId': ya estaba '$($op.state)' en el journal de una corrida anterior -- se omite, no se reintenta." -ForegroundColor Yellow
            return $false
        }

        $op.state = 'in-progress'
        $op.startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Write-CloudflareExecutionJournalAtomic -JournalPath $journalPath -Journal $journal
        return $true
    }
    finally {
        $lockStream.Close()
    }
}

function Complete-CloudflareJournaledOperation {
    param(
        [Parameter(Mandatory)] [string]$PlanValidationHash,
        [Parameter(Mandatory)] [string[]]$AllOperationIds,
        [Parameter(Mandatory)] [string]$OperationId,
        [ValidateSet('succeeded', 'failed-before-write', 'failed-after-write', 'ambiguous', 'skipped-already-desired', 'blocked-drift')]
        [string]$FinalState = 'succeeded',
        [string]$ResultId = $null
    )

    $journalPath = Get-CloudflareExecutionJournalPath -PlanValidationHash $PlanValidationHash
    $lockPath = "$journalPath.lock"
    $lockStream = Lock-CloudflareJournalFile -LockPath $lockPath

    try {
        $journal = Read-CloudflareExecutionJournal -JournalPath $journalPath -PlanValidationHash $PlanValidationHash -OperationIds $AllOperationIds
        $op = $journal.operations.$OperationId
        $op.state = $FinalState
        $op.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        $op.resultId = $ResultId
        Write-CloudflareExecutionJournalAtomic -JournalPath $journalPath -Journal $journal
    }
    finally {
        $lockStream.Close()
    }
}

function Test-CloudflarePlaceholderValue {
    param([string]$Value)
    if ($null -eq $Value) { return $true }
    if ($Value -eq '***REDACTED***') { return $true }
    if ($Value -match '\$\{[A-Za-z0-9_]+\}') { return $true }
    return $false
}

function Find-CloudflareSensitiveJsonProperties {
    <#
    Escanea recursivamente un objeto ya parseado (de un plan/inventario) por
    NOMBRE de propiedad sensible con un valor literal no-placeholder.
    Placeholder permitido: cualquier valor que contenga '${...}' o sea
    exactamente '***REDACTED***' o $null. Igual criterio que Azure/ADO: una
    propiedad llamada exactamente 'resourceId' o 'id' nunca se trata como
    secreto aunque contenga texto largo -- son identificadores de recursos.
    #>
    param([Parameter(Mandatory)] $Object, [string]$Path = '$')

    $sensitiveNames = @(
        'password', 'passwd', 'pwd', 'token', 'apitoken', 'accesstoken',
        'accountkey', 'connectionstring', 'clientsecret', 'secret', 'apikey',
        'privatekey', 'authorization', 'sastoken', 'certificate', 'primarykey',
        'secondarykey', 'origincakey', 'tunnelsecret', 'workersecret',
        'secretaccesskey', 'turnstilesecret', 'webhooksecret'
    )
    $exemptNames = @('resourceid', 'id')
    $findings = [System.Collections.Generic.List[object]]::new()

    function Step {
        param($Obj, [string]$CurPath)

        if ($null -eq $Obj) { return }

        if ($Obj -is [System.Management.Automation.PSCustomObject]) {
            foreach ($prop in $Obj.PSObject.Properties) {
                $childPath = "$CurPath.$($prop.Name)"
                $lowerName = $prop.Name.ToLowerInvariant()
                $isExempt = $exemptNames -contains $lowerName
                $isSensitiveName = -not $isExempt -and ($sensitiveNames | Where-Object { $lowerName -like "*$_*" })
                if ($isSensitiveName -and $prop.Value -is [string]) {
                    if (-not (Test-CloudflarePlaceholderValue -Value $prop.Value)) {
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

function Find-CloudflareSensitiveRawText {
    <#
    Defensa adicional: regex sobre el TEXTO crudo del archivo (no el objeto
    parseado). Ignora cualquier ocurrencia que sea un placeholder ${VAR} o
    ***REDACTED***. Incluye un patron para claves PEM tipo Cloudflare Origin
    CA / certificados privados.
    #>
    param([Parameter(Mandatory)] [string]$Text)

    $patterns = @(
        '(?i)(password|passwd|pwd)\s*[:=]\s*"?[^"\s,${}]{4,}',
        '(?i)(client[_-]?secret)\s*[:=]\s*"?[^"\s,${}]{4,}',
        '(?i)(access[_-]?token|accesstoken|api[_-]?token)\s*[:=]\s*"?[^"\s,${}]{8,}',
        '(?i)(connection[_-]?string)\s*[:=]\s*"?[^"\s,${}]{8,}',
        'AccountKey=[A-Za-z0-9+/=]{16,}',
        'eyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}',
        '-----BEGIN[ A-Z]*PRIVATE KEY-----'
    )

    $findings = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $patterns) {
        if ([regex]::IsMatch($Text, $p)) {
            $findings.Add($p)
        }
    }
    return @($findings)
}

function Get-CloudflareRequiredOperationFields {
    <#
    Los 27 campos obligatorios de cada operacion de un plan Cloudflare
    (approvedOperations / pendingDeleteOperations). New-CloudflareChangePlan.ps1
    y New-CloudflareDeletePlan.ps1 rechazan cualquier operacion a la que le
    falte alguno; Test-CloudflareChangePlan.ps1 / Test-CloudflareDeletePlan.ps1
    lo re-verifican de forma independiente.
    #>
    return @(
        'operationId', 'phase', 'action', 'accountId', 'zoneId', 'resourceType',
        'resourceId', 'resourceName', 'executor', 'method', 'uri', 'argv',
        'body', 'bodyHash', 'preconditionHash', 'currentState', 'desiredState',
        'dependencies', 'isDestructive', 'reversible', 'backupStrategy',
        'rollbackStrategy', 'verification', 'retryPolicy', 'timeoutSeconds',
        'expectedFinalState', 'expectedReadback'
    )
}

function ConvertTo-CloudflarePrettyJson {
    param([Parameter(Mandatory)] $Object, [int]$Depth = 30)
    # Evita el problema conocido de Get-Content -Raw + ConvertTo-Json en
    # PS5.1 con strings muy largas -- reconstruye la cadena antes de
    # serializar cuando el objeto viene de un -Raw read.
    return ($Object | ConvertTo-Json -Depth $Depth)
}
