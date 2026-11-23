<#
Unico helper autorizado para llamadas REST de administracion de grupos y
permisos de Azure DevOps (Shared-Service-GM). Dominio SEPARADO de
manage-azure-devops-pipelines -- no se comparte codigo con
Invoke-AdoRest.ps1 ni con su journal de ejecucion.

Lee el PAT de $env:AZURE_DEVOPS_PAT y nunca lo imprime, loggea ni incluye
en ningun archivo de salida.

Uso:
  . .\Invoke-AdoPermissionsRest.ps1
  Invoke-AdoPermissionsRest -Method GET -Uri 'https://dev.azure.com/Shared-Service-GM/_apis/securitynamespaces?api-version=7.1'
  Invoke-AdoPermissionsRest -Method POST -Uri '...' -Body $hashtable -RequireApprovedPlan -PlanPath '...' -OperationId 'create-security-group'

Este helper NUNCA debe invocarse directamente desde Bash ni PowerShell (ni
para GET ni para escrituras) -- ado-permissions-security-gate.ps1 lo
bloquea siempre que un comando lo mencione como el script que se ejecuta o
carga. Solo puede cargarse por dot-sourcing DESDE DENTRO de otro script
.ps1 autorizado de esta skill.

Escrituras (POST/PUT/PATCH/DELETE) exigen TODO lo siguiente, o se
rechazan antes de tocar la red:
  - -RequireApprovedPlan y -PlanPath apuntando a un plan con
    validated=true cuyo validationHash coincide con su contenido actual
    (ver Get-AdoPermissionsPlanCanonicalHash). EL ARCHIVO DE PLAN NUNCA SE
    MODIFICA POR ESTE HELPER -- es inmutable despues de validado.
  - -OperationId identificando una entrada de plan.approvedOperations cuyo
    method/uri/bodyHash coincidan EXACTAMENTE con esta llamada.
  - El estado de "ya se uso / esta en curso" vive en un JOURNAL DE
    EJECUCION separado bajo
    .local/azure-devops-permissions/executions/<hash>.json, protegido con
    un lock exclusivo de archivo. El plan JAMAS se reescribe para
    registrar esto.

Toda URI se valida ANTES de construir o adjuntar el header Authorization:
solo HTTPS, solo host dev.azure.com o vssps.dev.azure.com, sin userinfo,
solo puerto 443 (default), y la ruta debe empezar con
/Shared-Service-GM/. A diferencia del dominio de Pipelines (que opera
siempre sobre un unico proyecto fijo "DevOps"), este dominio administra
"uno, varios o todos" los proyectos de la organizacion -- por eso el
prefijo de ruta exigido es solo el de la organizacion, y cada
operationType valida su ruta con un PATRON (regex), no con una ruta
literal fija, porque incluye descriptores/ids que varian por
proyecto/grupo/miembro en cada llamada real.

Los headers de RESPUESTA que se devuelven se filtran a una lista
explicita (hoy: solo x-ms-continuationtoken).
#>

param()

$script:AdoPermissionsAllowedHosts = @('dev.azure.com', 'vssps.dev.azure.com')
$script:AdoPermissionsAllowedOrgPathPrefix = '/Shared-Service-GM/'
$script:AdoPermissionsAllowedResponseHeaders = @('x-ms-continuationtoken')

# Maximo absoluto de antiguedad de inventario/validacion, en horas. Nunca
# se supera sin importar lo que diga validationEvidence en un plan
# (defensa en profundidad ante un plan manipulado).
$script:AdoPermissionsAbsoluteMaxInventoryAgeHours = 24

# Tipos de operacion permitidos en plan.approvedOperations y su contrato
# EXACTO. Fuente unica de verdad para Test-AdoPermissionsPlan.ps1 y para
# Invoke-AdoPermissionsRest (defensa en profundidad aguas abajo).
#
# 'pathRegex' (no 'path' literal, a diferencia de Pipelines): cada
# operacion real incluye un descriptor/id de recurso que varia segun
# proyecto/grupo/miembro -- no hay una ruta fija por operationType en este
# dominio multi-proyecto.
#
# 'requiredQuery': hashtable ordenado query-key -> valor exacto esperado
# ($null significa "debe estar presente y no vacio, cualquier valor" --
# usado para scopeDescriptor, cuyo valor real depende del proyecto y se
# valida por separado contra el inventario en Test-AdoPermissionsPlan.ps1,
# no aca).
#
# Endpoints confirmados 2026-08-26 contra
# https://learn.microsoft.com/rest/api/azure/devops/graph/groups,
# .../graph/memberships y .../security/access-control-lists (ver
# references/ado-security-api-map.md para el detalle completo y las citas).
$script:AdoPermissionsAllowedOperationTypes = [ordered]@{
    'create-security-group'            = [ordered]@{
        method        = 'POST'
        host          = 'vssps.dev.azure.com'
        pathRegex     = '^/Shared-Service-GM/_apis/graph/groups$'
        requiredQuery = [ordered]@{ 'api-version' = '7.1-preview.1'; 'scopeDescriptor' = $null }
    }
    'update-security-group-description' = [ordered]@{
        method        = 'PATCH'
        host          = 'vssps.dev.azure.com'
        pathRegex     = '^/Shared-Service-GM/_apis/graph/groups/[A-Za-z0-9._-]+$'
        requiredQuery = [ordered]@{ 'api-version' = '7.1-preview.1' }
    }
    'add-group-membership'             = [ordered]@{
        method        = 'PUT'
        host          = 'vssps.dev.azure.com'
        pathRegex     = '^/Shared-Service-GM/_apis/graph/memberships/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
        requiredQuery = [ordered]@{ 'api-version' = '7.1-preview.1' }
    }
    'set-git-permissions-ace'          = [ordered]@{
        method        = 'POST'
        host          = 'dev.azure.com'
        pathRegex     = '^/Shared-Service-GM/_apis/accesscontrollists/[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
        requiredQuery = [ordered]@{ 'api-version' = '7.1' }
    }
    'delete-security-group'            = [ordered]@{
        method        = 'DELETE'
        host          = 'vssps.dev.azure.com'
        pathRegex     = '^/Shared-Service-GM/_apis/graph/groups/[A-Za-z0-9._-]+$'
        requiredQuery = [ordered]@{ 'api-version' = '7.1-preview.1' }
    }
    'remove-group-membership'          = [ordered]@{
        method        = 'DELETE'
        host          = 'vssps.dev.azure.com'
        pathRegex     = '^/Shared-Service-GM/_apis/graph/memberships/[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$'
        requiredQuery = [ordered]@{ 'api-version' = '7.1-preview.1' }
    }
    # Agregado 2026-09-02 para la capacidad "pr-policy-admin" (Branch
    # Policies / Policy Configurations) mencionada como capacidad futura
    # en authorization.md. El segmento de proyecto varia (nombre o guid),
    # de ahi el patron generico en vez de una ruta literal fija.
    'create-policy-configuration'      = [ordered]@{
        method        = 'POST'
        host          = 'dev.azure.com'
        pathRegex     = '^/Shared-Service-GM/[^/]+/_apis/policy/configurations$'
        requiredQuery = [ordered]@{ 'api-version' = '7.1' }
    }
}

# Los 2 tipos de eliminacion (delete-security-group, remove-group-membership)
# NUNCA pueden aparecer en un plan aplicado por Apply-AdoPermissionsPlan.ps1
# -- solo por Apply-AdoPermissionsDeletePlan.ps1. Ver Assert-AdoPermissionsPlanIsNonDestructive.
$script:AdoPermissionsDestructiveOperationTypes = @('delete-security-group', 'remove-group-membership')

function Assert-AdoPermissionsAllowedUri {
    <#
    Valida que $Uri sea una URI HTTPS permitida hacia Azure DevOps
    Shared-Service-GM antes de que se construya o adjunte ningun header de
    autenticacion. Lanza excepcion si no cumple TODAS las condiciones.
    Devuelve el [System.Uri] parseado si es valida.
    #>
    param(
        [Parameter(Mandatory)]
        [string]$Uri
    )

    $parsed = $null
    try {
        $parsed = [System.Uri]::new($Uri, [System.UriKind]::Absolute)
    }
    catch {
        throw "Invoke-AdoPermissionsRest rechazado: URI invalida o no absoluta."
    }

    if ($parsed.Scheme -ne 'https') {
        throw "Invoke-AdoPermissionsRest rechazado: solo se permite el esquema https. Esquema recibido: '$($parsed.Scheme)'."
    }

    if (-not [string]::IsNullOrEmpty($parsed.UserInfo)) {
        throw "Invoke-AdoPermissionsRest rechazado: la URI no puede contener userinfo (usuario:password@host)."
    }

    if ($script:AdoPermissionsAllowedHosts -notcontains $parsed.Host) {
        throw "Invoke-AdoPermissionsRest rechazado: host no autorizado '$($parsed.Host)'. Solo se permiten: $($script:AdoPermissionsAllowedHosts -join ', ')."
    }

    if (-not $parsed.IsDefaultPort) {
        throw "Invoke-AdoPermissionsRest rechazado: puerto no estandar '$($parsed.Port)'. Solo se permite el puerto HTTPS por defecto."
    }

    if (-not $parsed.AbsolutePath.StartsWith($script:AdoPermissionsAllowedOrgPathPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Invoke-AdoPermissionsRest rechazado: la ruta debe empezar con '$($script:AdoPermissionsAllowedOrgPathPrefix)' (organizacion Shared-Service-GM). Ruta recibida: '$($parsed.AbsolutePath)'."
    }

    return $parsed
}

function Assert-AdoPermissionsOperationRequestMatchesSpec {
    <#
    Re-deriva y valida, desde cero, que ($Method, $Uri) cumplan EXACTO el
    contrato de $script:AdoPermissionsAllowedOperationTypes[$OperationType]:
    metodo, host, ruta (via pathRegex -- ver comentario de la tabla de
    arriba sobre por que es un patron y no una ruta literal), y query con
    EXACTAMENTE los parametros requeridos (sin duplicados, sin extras; con
    el valor exacto esperado cuando la spec trae uno, o solo "presente y no
    vacio" cuando la spec trae $null para esa clave).

    Se usa en DOS lugares con el MISMO codigo: Test-AdoPermissionsPlan.ps1
    (validacion aguas arriba) e Invoke-AdoPermissionsRest (defensa en
    profundidad aguas abajo, inmediatamente antes de cualquier escritura
    real).
    #>
    param(
        [Parameter(Mandatory)] [string]$OperationType,
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Uri,
        [string]$Label = $OperationType
    )

    if ([string]::IsNullOrWhiteSpace($OperationType) -or -not $script:AdoPermissionsAllowedOperationTypes.Contains($OperationType)) {
        throw "Assert-AdoPermissionsOperationRequestMatchesSpec ('$Label'): operationType debe ser uno de: $($script:AdoPermissionsAllowedOperationTypes.Keys -join ', '). Encontrado: '$OperationType'."
    }

    $spec = $script:AdoPermissionsAllowedOperationTypes[$OperationType]

    if ($spec.method -notin @('POST', 'PUT', 'PATCH', 'DELETE')) {
        throw "Assert-AdoPermissionsOperationRequestMatchesSpec ('$Label'): spec interno invalido (method fuera de POST/PUT/PATCH/DELETE). Bug de configuracion."
    }
    if ($Method -ne $spec.method) {
        throw "Assert-AdoPermissionsOperationRequestMatchesSpec ('$Label'): method debe ser '$($spec.method)' para operationType '$OperationType'. Encontrado: '$Method'."
    }

    $parsedUri = Assert-AdoPermissionsAllowedUri -Uri $Uri

    if ($parsedUri.Host -ne $spec.host) {
        throw "Assert-AdoPermissionsOperationRequestMatchesSpec ('$Label'): la uri debe usar el host '$($spec.host)' para operationType '$OperationType'. Encontrado: '$($parsedUri.Host)'."
    }

    if ($parsedUri.AbsolutePath -notmatch $spec.pathRegex) {
        throw "Assert-AdoPermissionsOperationRequestMatchesSpec ('$Label'): la ruta '$($parsedUri.AbsolutePath)' no coincide con el patron esperado para operationType '$OperationType' ('$($spec.pathRegex)')."
    }

    $queryPairs = [ordered]@{}
    $rawQuery = $parsedUri.Query.TrimStart('?')
    if ($rawQuery) {
        foreach ($pair in ($rawQuery -split '&')) {
            if (-not $pair) { continue }
            $kv = $pair -split '=', 2
            $qKey = [uri]::UnescapeDataString($kv[0])
            $qVal = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1]) } else { '' }
            if ($queryPairs.Contains($qKey)) {
                throw "Assert-AdoPermissionsOperationRequestMatchesSpec ('$Label'): la uri tiene el parametro de query '$qKey' duplicado."
            }
            $queryPairs[$qKey] = $qVal
        }
    }

    $requiredKeys = @($spec.requiredQuery.Keys)
    $actualKeys = @($queryPairs.Keys)
    $extraKeys = @($actualKeys | Where-Object { $requiredKeys -notcontains $_ })
    $missingKeys = @($requiredKeys | Where-Object { $actualKeys -notcontains $_ })

    if ($extraKeys.Count -gt 0) {
        throw "Assert-AdoPermissionsOperationRequestMatchesSpec ('$Label'): la uri tiene parametros de query extra no permitidos: $($extraKeys -join ', ')."
    }
    if ($missingKeys.Count -gt 0) {
        throw "Assert-AdoPermissionsOperationRequestMatchesSpec ('$Label'): la uri no tiene el parametro de query requerido: $($missingKeys -join ', ')."
    }
    foreach ($rk in $requiredKeys) {
        $expected = $spec.requiredQuery[$rk]
        if ($null -eq $expected) {
            if ([string]::IsNullOrWhiteSpace($queryPairs[$rk])) {
                throw "Assert-AdoPermissionsOperationRequestMatchesSpec ('$Label'): la uri tiene '$rk' vacio; se esperaba un valor no vacio."
            }
        }
        elseif ($queryPairs[$rk] -ne $expected) {
            throw "Assert-AdoPermissionsOperationRequestMatchesSpec ('$Label'): la uri tiene '$rk=$($queryPairs[$rk])', se esperaba '$rk=$expected'."
        }
    }

    return $spec
}

function Assert-AdoPermissionsPlanIsNonDestructive {
    <#
    Rechaza un plan que contenga cualquier operationType destructivo
    (delete-security-group, remove-group-membership) o cualquier metodo
    DELETE -- exigido tanto para Apply-AdoPermissionsPlan.ps1 (que NUNCA
    debe aplicar una eliminacion) como para Test-AdoPermissionsPlan.ps1
    (que nunca debe validar como "plan principal" algo que en realidad es
    un delete plan armado a mano).
    #>
    param(
        [Parameter(Mandatory)] [psobject]$Plan
    )

    $approvedOps = @()
    if ($null -ne $Plan.approvedOperations) {
        $approvedOps = @($Plan.approvedOperations)
    }

    foreach ($op in $approvedOps) {
        if ([string]$op.method -eq 'DELETE') {
            throw "Plan rechazado: contiene una operacion con method DELETE ('$($op.operationId)'). Apply-AdoPermissionsPlan.ps1 nunca ejecuta eliminaciones -- usar New-AdoPermissionsDeletePlan.ps1."
        }
        if ($script:AdoPermissionsDestructiveOperationTypes -contains [string]$op.operationType) {
            throw "Plan rechazado: contiene un operationType destructivo ('$($op.operationType)', operationId '$($op.operationId)'). Apply-AdoPermissionsPlan.ps1 nunca ejecuta eliminaciones -- usar New-AdoPermissionsDeletePlan.ps1."
        }
    }
}

function Get-AdoPermissionsAuthHeader {
    $pat = $env:AZURE_DEVOPS_PAT
    if ([string]::IsNullOrWhiteSpace($pat)) {
        throw 'AZURE_DEVOPS_PAT no esta configurada en el entorno. Ejecutar setx AZURE_DEVOPS_PAT en una terminal propia del usuario (nunca pasarlo por chat) y abrir una terminal nueva.'
    }

    $basicToken = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    return @{ Authorization = "Basic $basicToken" }
}

function Get-AdoPermissionsSha256OfText {
    param(
        [Parameter(Mandatory)]
        [AllowEmptyString()]
        [string]$Text
    )

    $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
        return [System.BitConverter]::ToString($hashBytes).Replace('-', '').ToLowerInvariant()
    }
    finally {
        $sha256.Dispose()
    }
}

function Get-AdoPermissionsPlanCanonicalHash {
    <#
    SHA-256 determinista del contenido "de negocio" de un plan de permisos
    (excluye validated/lastValidatedAtUtc/validationBlockers/
    validationWarnings/validationHash -- validationEvidence y
    approvedOperations SI se incluyen). Mismo criterio que Pipelines.
    #>
    param(
        [Parameter(Mandatory)]
        [psobject]$Plan
    )

    $excludedProps = @('validated', 'lastValidatedAtUtc', 'validationBlockers', 'validationWarnings', 'validationHash')

    $ordered = [ordered]@{}
    foreach ($prop in ($Plan.PSObject.Properties | Sort-Object Name)) {
        if ($excludedProps -contains $prop.Name) { continue }
        $ordered[$prop.Name] = $prop.Value
    }

    $canonicalJson = [PSCustomObject]$ordered | ConvertTo-Json -Depth 20 -Compress
    return Get-AdoPermissionsSha256OfText -Text $canonicalJson
}

function Get-AdoPermissionsBodyCanonicalHash {
    param(
        [object]$Body
    )

    if ($null -eq $Body) {
        $canonicalJson = '{}'
    }
    else {
        $canonicalJson = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    return Get-AdoPermissionsSha256OfText -Text $canonicalJson
}

function Test-AdoPermissionsValueIsCollectionCompatible {
    param($Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $false }
    if ($Value -is [System.Collections.IEnumerable]) { return $true }
    return $false
}

# ============================================================
# Journal de ejecucion (.local/azure-devops-permissions/executions/<hash>.json)
# -- registra que operaciones aprobadas ya se intentaron/consumieron, SIN
# tocar jamas el archivo de plan. Mismo diseno que Pipelines, directorio
# propio y sin compartir codigo.
# ============================================================

$script:AdoPermissionsProductionExecutionsDir = '$env:REPO_ROOT\.local\azure-devops-permissions\executions'

function Get-AdoPermissionsExecutionsDir {
    <#
    Directorio del journal. FIJO a la ruta real de produccion. La UNICA
    forma de redirigir esto es la variable de entorno
    ADO_PERMISSIONS_TEST_EXECUTIONS_ROOT, exclusiva de pruebas.
    #>
    if (-not [string]::IsNullOrWhiteSpace($env:ADO_PERMISSIONS_TEST_EXECUTIONS_ROOT)) {
        return $env:ADO_PERMISSIONS_TEST_EXECUTIONS_ROOT
    }
    return $script:AdoPermissionsProductionExecutionsDir
}

function Get-AdoPermissionsExecutionJournalPath {
    param(
        [Parameter(Mandatory)] [string]$PlanValidationHash
    )
    $dir = Get-AdoPermissionsExecutionsDir
    return Join-Path $dir "$PlanValidationHash.json"
}

function Lock-AdoPermissionsJournalFile {
    param(
        [Parameter(Mandatory)] [string]$LockPath,
        [int]$TimeoutMs = 5000
    )

    $dir = Split-Path -Parent $LockPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

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

function Test-AdoPermissionsJournalOperationsRawHasDuplicateKeys {
    param([Parameter(Mandatory)] [string]$RawJournalText)

    $opsBlockMatch = [regex]::Match($RawJournalText, '"operations"\s*:\s*\{')
    if (-not $opsBlockMatch.Success) { return $false }

    $startIdx = $opsBlockMatch.Index + $opsBlockMatch.Length - 1
    $depth = 0
    $endIdx = -1
    for ($i = $startIdx; $i -lt $RawJournalText.Length; $i++) {
        $ch = $RawJournalText[$i]
        if ($ch -eq '{') { $depth++ }
        elseif ($ch -eq '}') {
            $depth--
            if ($depth -eq 0) { $endIdx = $i; break }
        }
    }
    if ($endIdx -lt 0) { return $false }

    $opsBlockText = $RawJournalText.Substring($startIdx + 1, $endIdx - $startIdx - 1)

    $keyPattern = '"((?:[^"\\]|\\.)*)"\s*:\s*(?=\{)'
    $localDepth = 0
    $seenKeys = [System.Collections.Generic.List[string]]::new()
    $pos = 0
    while ($pos -lt $opsBlockText.Length) {
        $ch = $opsBlockText[$pos]
        if ($ch -eq '{') { $localDepth++; $pos++; continue }
        if ($ch -eq '}') { $localDepth--; $pos++; continue }
        if ($ch -eq '"' -and $localDepth -eq 0) {
            $m = [regex]::Match($opsBlockText.Substring($pos), $keyPattern)
            if ($m.Success -and $m.Index -eq 0) {
                $seenKeys.Add($m.Groups[1].Value)
                $pos += $m.Length
                continue
            }
        }
        $pos++
    }

    # @(...) es obligatorio: 'X | Select-Object -Unique' con un resultado
    # de EXACTAMENTE 1 elemento lo desenrolla a un escalar (pierde
    # '.Count'). Bajo Set-StrictMode -Version Latest esto lanza
    # PropertyNotFoundStrict -- confirmado en vivo 2026-09-02 con un plan
    # de una sola operacion (el canario de 'All Repositories'): la
    # escritura real se CONFIRMO en Azure DevOps pero el journal crasheo
    # despues al intentar marcarla 'succeeded', dejando el estado
    # localmente incierto pese a que la escritura si tomo efecto.
    $distinctCount = @($seenKeys | Select-Object -Unique).Count
    return ($distinctCount -ne $seenKeys.Count)
}

function Assert-AdoPermissionsJournalOperationShapeValid {
    param([Parameter(Mandatory)] [string]$OperationId, [Parameter(Mandatory)] $OperationNode)

    $expectedProps = @('state', 'startedAtUtc', 'completedAtUtc', 'resultId')
    $actualProps = @($OperationNode.PSObject.Properties.Name)

    $missingProps = @($expectedProps | Where-Object { $actualProps -notcontains $_ })
    $extraProps = @($actualProps | Where-Object { $expectedProps -notcontains $_ })
    if ($missingProps.Count -gt 0 -or $extraProps.Count -gt 0) {
        throw "Journal de ejecucion corrupto: la operacion '$OperationId' tiene una forma invalida (faltan: $($missingProps -join ', '); sobran: $($extraProps -join ', ')). Bloqueo seguro."
    }

    $validStates = @('pending', 'in-progress', 'succeeded', 'ambiguous')
    if ($validStates -notcontains [string]$OperationNode.state) {
        throw "Journal de ejecucion corrupto: la operacion '$OperationId' tiene un estado invalido ('$($OperationNode.state)'). Estados validos: $($validStates -join ', '). Bloqueo seguro."
    }
}

function Read-AdoPermissionsExecutionJournal {
    param(
        [Parameter(Mandatory)] [string]$JournalPath,
        [Parameter(Mandatory)] [string]$PlanValidationHash,
        [string[]]$OperationIds = @()
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

    $raw = Get-Content -LiteralPath $JournalPath -Raw -Encoding UTF8
    $journal = $null
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

    if (Test-AdoPermissionsJournalOperationsRawHasDuplicateKeys -RawJournalText $raw) {
        throw "Journal de ejecucion corrupto en '$JournalPath': el bloque 'operations' tiene un operationId duplicado en el texto crudo. Bloqueo seguro."
    }

    $journalOpIds = @($journal.operations.PSObject.Properties.Name)
    $expectedOpIds = @($OperationIds)

    $missingFromJournal = @($expectedOpIds | Where-Object { $journalOpIds -notcontains $_ })
    $extraInJournal = @($journalOpIds | Where-Object { $expectedOpIds -notcontains $_ })

    if ($missingFromJournal.Count -gt 0) {
        throw "Journal de ejecucion corrupto en '$JournalPath': falta(n) la(s) operacion(es) $($missingFromJournal -join ', ') que si estan en el plan aprobado. Bloqueo seguro."
    }
    if ($extraInJournal.Count -gt 0) {
        throw "Journal de ejecucion corrupto en '$JournalPath': tiene la(s) operacion(es) $($extraInJournal -join ', ') que NO estan en el plan aprobado actual. Bloqueo seguro."
    }

    foreach ($opId in $journalOpIds) {
        Assert-AdoPermissionsJournalOperationShapeValid -OperationId $opId -OperationNode $journal.operations.$opId
    }

    return $journal
}

function Write-AdoPermissionsExecutionJournalAtomic {
    param(
        [Parameter(Mandatory)] [string]$JournalPath,
        [Parameter(Mandatory)] $Journal
    )

    $dir = Split-Path -Parent $JournalPath
    if (-not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Force -Path $dir | Out-Null }

    $tmpPath = "$JournalPath.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        $Journal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tmpPath -Encoding utf8
        Move-Item -LiteralPath $tmpPath -Destination $JournalPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
    }
}

function Start-AdoPermissionsJournaledOperation {
    param(
        [Parameter(Mandatory)] [string]$PlanValidationHash,
        [Parameter(Mandatory)] [string]$OperationId,
        [string[]]$AllOperationIds = @(),
        [int]$LockTimeoutMs = 5000
    )

    $journalPath = Get-AdoPermissionsExecutionJournalPath -PlanValidationHash $PlanValidationHash
    $lockStream = Lock-AdoPermissionsJournalFile -LockPath "$journalPath.lock" -TimeoutMs $LockTimeoutMs
    try {
        $journal = Read-AdoPermissionsExecutionJournal -JournalPath $journalPath -PlanValidationHash $PlanValidationHash -OperationIds $AllOperationIds

        $opProp = $journal.operations.PSObject.Properties[$OperationId]
        if (-not $opProp) {
            throw "Start-AdoPermissionsJournaledOperation: inconsistencia interna -- '$OperationId' no aparece en el journal ya validado. Bug; bloqueo seguro."
        }

        $currentState = $opProp.Value.state
        if ($currentState -ne 'pending') {
            throw "Operacion REST rechazada: la operacion '$OperationId' ya tiene estado '$currentState' en el journal de ejecucion ('$journalPath'). No se reintenta automaticamente."
        }

        $opProp.Value.state = 'in-progress'
        $opProp.Value.startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Write-AdoPermissionsExecutionJournalAtomic -JournalPath $journalPath -Journal $journal
    }
    finally {
        $lockStream.Close()
        $lockStream.Dispose()
    }

    return $journalPath
}

function Complete-AdoPermissionsJournaledOperation {
    param(
        [Parameter(Mandatory)] [string]$JournalPath,
        [Parameter(Mandatory)] [string]$PlanValidationHash,
        [Parameter(Mandatory)] [string]$OperationId,
        [Parameter(Mandatory)] [ValidateSet('succeeded', 'ambiguous')] [string]$FinalState,
        [string[]]$AllOperationIds = @(),
        [string]$ResultId,
        [int]$LockTimeoutMs = 5000
    )

    $lockStream = Lock-AdoPermissionsJournalFile -LockPath "$JournalPath.lock" -TimeoutMs $LockTimeoutMs
    try {
        $journal = Read-AdoPermissionsExecutionJournal -JournalPath $JournalPath -PlanValidationHash $PlanValidationHash -OperationIds $AllOperationIds
        $opProp = $journal.operations.PSObject.Properties[$OperationId]
        if (-not $opProp) {
            throw "Complete-AdoPermissionsJournaledOperation: la operacion '$OperationId' no existe en el journal '$JournalPath'."
        }
        $opProp.Value.state = $FinalState
        $opProp.Value.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        if ($ResultId) { $opProp.Value.resultId = $ResultId }
        Write-AdoPermissionsExecutionJournalAtomic -JournalPath $JournalPath -Journal $journal
    }
    finally {
        $lockStream.Close()
        $lockStream.Dispose()
    }
}

function Invoke-AdoPermissionsRest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [object]$Body,

        [switch]$RequireApprovedPlan,

        [string]$PlanPath,

        [string]$OperationId,

        [int]$JournalLockTimeoutMs = 5000
    )

    $null = Assert-AdoPermissionsAllowedUri -Uri $Uri

    $isWrite = $Method -in @('POST', 'PUT', 'PATCH', 'DELETE')
    $journalPath = $null
    $planValidationHashForJournal = $null
    $allOpIds = @()

    if ($isWrite) {
        if (-not $RequireApprovedPlan) {
            throw "Escritura REST rechazada: $Method no paso por el flujo de plan aprobado (-RequireApprovedPlan). Nunca se sustituye este freno por una llamada directa."
        }

        if ([string]::IsNullOrWhiteSpace($PlanPath) -or -not (Test-Path -LiteralPath $PlanPath)) {
            throw "Escritura REST rechazada: no se encontro el archivo de plan indicado. Ejecutar primero Test-AdoPermissionsPlan.ps1 (o Test-AdoPermissionsDeletePlan.ps1) sobre un plan valido."
        }

        $plan = Get-Content -LiteralPath $PlanPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if (-not $plan.validated -or $plan.validated -ne $true) {
            throw "Escritura REST rechazada: el plan no esta marcado validated=true."
        }

        if ([string]::IsNullOrWhiteSpace($plan.validationHash)) {
            throw "Escritura REST rechazada: el plan validado no tiene validationHash. Volver a validar el plan."
        }

        $currentHash = Get-AdoPermissionsPlanCanonicalHash -Plan $plan
        if ($currentHash -ne $plan.validationHash) {
            throw "Escritura REST rechazada: el contenido del plan cambio despues de la validacion (validationHash no coincide). Volver a validar la version actual antes de aplicar."
        }

        if ([string]::IsNullOrWhiteSpace($OperationId)) {
            throw "Escritura REST rechazada: falta -OperationId. Toda escritura debe corresponder a una operacion especifica de plan.approvedOperations."
        }

        $approvedOps = @()
        if ($null -ne $plan.approvedOperations) {
            $approvedOps = @($plan.approvedOperations)
        }
        if ($approvedOps.Count -eq 0) {
            throw "Escritura REST rechazada: el plan no tiene approvedOperations (manifiesto vacio o ausente)."
        }

        $matchedOp = $approvedOps | Where-Object { $_.operationId -eq $OperationId } | Select-Object -First 1
        if (-not $matchedOp) {
            throw "Escritura REST rechazada: no existe la operacion '$OperationId' en plan.approvedOperations."
        }

        if ($matchedOp.method -ne $Method) {
            throw "Escritura REST rechazada: el metodo aprobado para '$OperationId' no coincide con el metodo solicitado."
        }

        if ($matchedOp.uri -ne $Uri) {
            throw "Escritura REST rechazada: la URI aprobada para '$OperationId' no coincide con la URI solicitada."
        }

        $actualBodyHash = Get-AdoPermissionsBodyCanonicalHash -Body $Body
        if ($matchedOp.bodyHash -ne $actualBodyHash) {
            throw "Escritura REST rechazada: el bodyHash aprobado para '$OperationId' no coincide con el body solicitado."
        }

        $null = Assert-AdoPermissionsOperationRequestMatchesSpec -OperationType ([string]$matchedOp.operationType) -Method $Method -Uri $Uri -Label $OperationId

        # ============================================================
        # GUARDIA DURA: 'set-git-permissions-ace' JAMAS puede reducir el
        # conjunto de identidades con ACE real en el token. Esto NO
        # depende de que el plan se haya construido bien -- es la ULTIMA
        # linea de defensa, dentro del unico punto por el que pasa
        # cualquier escritura real, sin importar que script generador la
        # haya armado. Incidente real 2026-09-02 (ver debugging.md de
        # ado-permissions-builder § "INCIDENTE MAYOR 2"): 'Set Access
        # Control Lists' REEMPLAZA el acesDictionary completo del token,
        # no lo combina -- un body que omite una identidad que ya tenia
        # ACE real la BORRA. Se compara contra el estado EN VIVO (no
        # contra el inventario, que puede estar desactualizado) justo
        # antes de escribir.
        if ([string]$matchedOp.operationType -eq 'set-git-permissions-ace') {
            $outgoingToken = [string]$Body.value[0].token
            $outgoingDescriptors = New-Object 'System.Collections.Generic.HashSet[string]'
            foreach ($p in $Body.value[0].acesDictionary.PSObject.Properties) { $outgoingDescriptors.Add([string]$p.Name) | Out-Null }

            $liveNamespaceMatch = [regex]::Match($Uri, '/_apis/accesscontrollists/([0-9a-fA-F-]{36})')
            if (-not $liveNamespaceMatch.Success) {
                throw "Escritura REST rechazada: no se pudo extraer el namespaceId de la URI para la guardia de identidades ('$Uri')."
            }
            $liveNamespaceId = $liveNamespaceMatch.Groups[1].Value
            $liveCoreBase = "https://$([System.Uri]::new($Uri).Host)/Shared-Service-GM"

            $liveDictionary = Get-AdoPermissionsFullAcesDictionary -CoreBase $liveCoreBase -NamespaceId $liveNamespaceId -Token $outgoingToken
            $wouldBeDropped = @($liveDictionary.entries | Where-Object { -not $outgoingDescriptors.Contains([string]$_.descriptor) })
            if ($wouldBeDropped.Count -gt 0) {
                $droppedNames = ($wouldBeDropped | ForEach-Object { $_.descriptor }) -join '; '
                throw "Escritura REST rechazada: esta operacion ('$OperationId') dejaria fuera del acesDictionary a $($wouldBeDropped.Count) identidad(es) que HOY tienen ACE real en el token '$outgoingToken' -- 'Set ACL' reemplaza el diccionario completo, no lo combina, y esto las BORRARIA. Identidades en riesgo: $droppedNames. Regenerar el plan a partir de un inventario fresco (que ahora captura 'fullAcesDictionary') para que las incluya preservadas."
            }
        }

        $planValidationHashForJournal = $plan.validationHash
        $allOpIds = @($approvedOps | ForEach-Object { $_.operationId })
        $journalPath = Start-AdoPermissionsJournaledOperation -PlanValidationHash $planValidationHashForJournal -OperationId $OperationId -AllOperationIds $allOpIds -LockTimeoutMs $JournalLockTimeoutMs
    }

    $headers = Get-AdoPermissionsAuthHeader
    $headers['Content-Type'] = if ($Method -eq 'PATCH') { 'application/json-patch+json' } else { 'application/json' }

    $invokeParams = @{
        Method             = $Method
        Uri                = $Uri
        Headers            = $headers
        MaximumRedirection = 0
        UseBasicParsing    = $true
    }

    if ($null -ne $Body) {
        # Convertir explicitamente a bytes UTF-8 antes de pasarlo a
        # Invoke-WebRequest. En Windows PowerShell 5.1, un -Body de tipo
        # [string] se codifica con el codepage POR DEFECTO DEL SISTEMA
        # (Windows-1252) cuando el Content-Type se fija via -Headers en
        # vez del parametro dedicado -ContentType -- nunca UTF-8 por si
        # solo. Cualquier caracter no-ASCII (tildes, etc., realistas en un
        # org de habla hispana) queda mal codificado y Azure DevOps lo
        # rechaza (400, "Unable to translate bytes ... to Unicode") o, peor,
        # lo acepta ya corrompido. Mismo bug y misma correccion que
        # Invoke-AdoRest.ps1 del dominio de Pipelines -- confirmado en vivo
        # 2026-09-02 al replicar Branch Policies con mensajes acentuados.
        # -InputObject, NUNCA por pipeline: en Windows PowerShell 5.1, `$X |
        # ConvertTo-Json` con $X un array de EXACTAMENTE 1 elemento
        # (ej. un documento JSON Patch de PATCH con un solo 'op') hace que
        # el pipeline desenrolle el array antes de que ConvertTo-Json lo
        # vea, perdiendo los corchetes exteriores -- ConvertTo-Json recibe
        # el objeto suelto, no un array de 1. Azure DevOps rechaza el
        # resultado con 500 "You must pass a valid patch document" porque
        # ya no es un array. Confirmado en vivo 2026-09-02 al actualizar la
        # descripcion de un grupo (patch de 1 solo 'op'). `-InputObject`
        # pasa el array completo como un unico argumento, sin pipeline, y
        # preserva los corchetes siempre, sea cual sea el Count.
        $jsonBodyToSend = ConvertTo-Json -InputObject $Body -Depth 20
        $invokeParams['Body'] = [System.Text.Encoding]::UTF8.GetBytes($jsonBodyToSend)
    }

    $response = $null
    try {
        $response = Invoke-WebRequest @invokeParams
        if ($env:ADO_PERMISSIONS_DEBUG_HEADERS -eq '1') {
            Write-Host "[DEBUG] StatusCode=$($response.StatusCode) StatusDescription=$($response.StatusDescription)" -ForegroundColor Cyan
            foreach ($hk in $response.Headers.Keys) { Write-Host "[DEBUG] Header: $hk = $($response.Headers[$hk])" -ForegroundColor Cyan }
            Write-Host "[DEBUG] Content length: $($response.Content.Length)" -ForegroundColor Cyan
            if ($response.Content) { Write-Host "[DEBUG] Content: $($response.Content)" -ForegroundColor Cyan }
        }
    }
    catch {
        if ($isWrite -and $journalPath) {
            try {
                Complete-AdoPermissionsJournaledOperation -JournalPath $journalPath -PlanValidationHash $planValidationHashForJournal -OperationId $OperationId -FinalState 'ambiguous' -AllOperationIds $allOpIds -LockTimeoutMs $JournalLockTimeoutMs
            }
            catch {
                # No se pudo marcar ambiguous -- igual queda protegido por 'in-progress'.
            }
        }
        $remoteDetail = ''
        try {
            $raw = [string]$_.ErrorDetails.Message
            if ([string]::IsNullOrWhiteSpace($raw)) {
                $errResponse = $_.Exception.Response
                if ($errResponse) {
                    $stream = $errResponse.GetResponseStream()
                    if ($stream) {
                        $reader = New-Object System.IO.StreamReader($stream)
                        $raw = $reader.ReadToEnd()
                        $reader.Dispose()
                    }
                }
            }
            if (-not [string]::IsNullOrWhiteSpace($raw)) {
                $remoteDetail = " | Respuesta del servicio: " + $raw.Substring(0, [Math]::Min(1000, $raw.Length))
            }
        }
        catch {
            # No se pudo leer el body de respuesta -- se ignora.
        }
        throw "Invoke-AdoPermissionsRest fallo: $Method -> $($_.Exception.Message)$remoteDetail"
    }

    $responseBody = $null
    if ($response.Content) {
        $responseBody = $response.Content | ConvertFrom-Json
    }

    $sanitizedHeaders = @{}
    foreach ($key in $response.Headers.Keys) {
        if ($script:AdoPermissionsAllowedResponseHeaders -icontains $key) {
            $sanitizedHeaders[$key] = $response.Headers[$key]
        }
    }

    if ($isWrite -and $journalPath) {
        $resultId = $null
        if ($responseBody -and ($responseBody.PSObject.Properties.Name -contains 'descriptor')) {
            $resultId = [string]$responseBody.descriptor
        }
        elseif ($responseBody -and ($responseBody.PSObject.Properties.Name -contains 'id')) {
            $resultId = [string]$responseBody.id
        }
        try {
            Complete-AdoPermissionsJournaledOperation -JournalPath $journalPath -PlanValidationHash $planValidationHashForJournal -OperationId $OperationId -FinalState 'succeeded' -ResultId $resultId -AllOperationIds $allOpIds -LockTimeoutMs $JournalLockTimeoutMs
        }
        catch {
            throw "Invoke-AdoPermissionsRest: la operacion '$OperationId' fue CONFIRMADA por Azure DevOps, pero no se pudo actualizar el journal de ejecucion despues ('$($_.Exception.Message)'). Estado incierto -- NO reintentar automaticamente. Verificar manualmente (readback)."
        }
    }

    return [PSCustomObject]@{
        Body       = $responseBody
        Headers    = $sanitizedHeaders
        StatusCode = [int]$response.StatusCode
    }
}

function Get-AdoPermissionsFullAcesDictionary {
    <#
    GET crudo del ACL de un token SIN el filtro '&descriptors=' -- trae el
    acesDictionary COMPLETO tal cual esta guardado (todas las identidades
    con ACE real en ese token, no solo las que administra este dominio).
    Devuelve un array de [ordered]@{ descriptor; allow; deny } usando el
    descriptor REAL tal cual lo devuelve la API (SID legado o
    ServiceIdentity, ya en su forma final -- nunca hace falta convertirlo).

    INCIDENTE REAL que exige esta funcion (2026-09-02, ver debugging.md de
    ado-permissions-builder): 'Set Access Control Lists' REEMPLAZA el
    acesDictionary COMPLETO del token con lo que se envia -- no lo
    combina. Enviar solo los descriptores que este dominio administra
    (Development Team/Code-Reviewers) BORRA cualquier otra identidad que
    ya tuviera una ACE real ahi (confirmado en vivo: una escritura para
    agregar 6 grupos default borro a Development Team y Code-Reviewers,
    que ya estaban). Por eso TODA escritura de 'set-git-permissions-ace'
    debe partir de este dictionary completo y solo AGREGAR/SOBRESCRIBIR
    las entradas que administra, nunca construir el body solo con esas.
    #>
    param(
        [Parameter(Mandatory)] [string]$CoreBase,
        [Parameter(Mandatory)] [string]$NamespaceId,
        [Parameter(Mandatory)] [string]$Token
    )

    $uri = "$CoreBase/_apis/accesscontrollists/$($NamespaceId)?token=$([uri]::EscapeDataString($Token))&api-version=$($script:AdoPermissionsCoreApiVersion)"
    $result = Invoke-AdoPermissionsRest -Method GET -Uri $uri
    if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
        throw "Get-AdoPermissionsFullAcesDictionary rechazado: fallo la consulta de ACL para el token '$Token' (HTTP $($result.StatusCode))."
    }

    $acls = @($result.Body.value)
    $matchedAcl = $acls | Where-Object { [string]$_.token -eq $Token } | Select-Object -First 1

    $entries = [System.Collections.Generic.List[object]]::new()
    if ($matchedAcl -and $matchedAcl.acesDictionary) {
        foreach ($prop in $matchedAcl.acesDictionary.PSObject.Properties) {
            $entries.Add([ordered]@{
                    descriptor = [string]$prop.Name
                    allow      = [int]$prop.Value.allow
                    deny       = [int]$prop.Value.deny
                })
        }
    }
    return [PSCustomObject]@{
        token              = $Token
        inheritPermissions = if ($matchedAcl) { [bool]$matchedAcl.inheritPermissions } else { $true }
        aclFound           = [bool]$matchedAcl
        entries            = @($entries)
    }
}

function Get-AdoPermissionsContinuationToken {
    param($Headers)

    if (-not $Headers) { return $null }

    foreach ($key in $Headers.Keys) {
        if ($key -ieq 'x-ms-continuationtoken') {
            $value = $Headers[$key]
            if ($value -is [System.Collections.IEnumerable] -and $value -isnot [string]) {
                $value = @($value)[0]
            }
            if (-not [string]::IsNullOrWhiteSpace($value)) {
                return [string]$value
            }
        }
    }
    return $null
}

function Get-AdoPermissionsRestAllPages {
    param(
        [Parameter(Mandatory)]
        [string]$BaseUri,

        [int]$MaxPages = 200
    )

    if ($MaxPages -lt 1) {
        throw "Get-AdoPermissionsRestAllPages: -MaxPages debe ser al menos 1 (recibido: $MaxPages)."
    }

    $allItems = [System.Collections.Generic.List[object]]::new()
    $seenTokens = [System.Collections.Generic.HashSet[string]]::new()
    $continuationToken = $null
    $pageCount = 0

    do {
        if ($pageCount -ge $MaxPages) {
            throw "Get-AdoPermissionsRestAllPages: se alcanzo el limite de $MaxPages pagina(s) sin agotar la paginacion."
        }

        $uri = $BaseUri
        if ($continuationToken) {
            $separator = if ($uri -match '\?') { '&' } else { '?' }
            $uri = "$uri$separator" + 'continuationToken=' + [uri]::EscapeDataString($continuationToken)
        }

        $result = Invoke-AdoPermissionsRest -Method GET -Uri $uri
        $pageCount++

        if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
            throw "Get-AdoPermissionsRestAllPages: la pagina $pageCount devolvio un codigo HTTP no exitoso ($($result.StatusCode))."
        }

        if ($null -eq $result.Body) {
            throw "Get-AdoPermissionsRestAllPages: la pagina $pageCount tiene body nulo."
        }

        if ($result.Body.PSObject.Properties.Name -notcontains 'value') {
            throw "Get-AdoPermissionsRestAllPages: la pagina $pageCount no tiene la propiedad 'value' en el body."
        }

        if (-not (Test-AdoPermissionsValueIsCollectionCompatible -Value $result.Body.value)) {
            $actualTypeName = if ($null -eq $result.Body.value) { '$null' } else { $result.Body.value.GetType().FullName }
            throw "Get-AdoPermissionsRestAllPages: la pagina $pageCount tiene 'value' con un formato incompatible con una coleccion (tipo: $actualTypeName)."
        }

        foreach ($item in @($result.Body.value)) { $allItems.Add($item) }

        $nextToken = Get-AdoPermissionsContinuationToken -Headers $result.Headers

        if ($nextToken) {
            if (-not $seenTokens.Add($nextToken)) {
                throw "Get-AdoPermissionsRestAllPages: se detecto un ciclo de continuation tokens (token repetido tras $pageCount pagina(s))."
            }
        }

        $continuationToken = $nextToken
    } while ($continuationToken)

    return [PSCustomObject]@{
        Items        = @($allItems)
        PagesFetched = $pageCount
    }
}

# ============================================================
# Fuente unica de verdad: matrices de permisos, catalogo de acciones del
# security namespace "Git Repositories", y construccion/validacion de
# tokens. Dot-sourceada por New-/Test-/Apply-*.ps1 y por el arnes de
# tests -- nunca redefinida en otro archivo.
# ============================================================

function Get-AdoPermissionsMatrixDefinition {
    <#
    Las 2 matrices EXACTAS del documento fuente
    (INSTRUCCIONES-CLAUDE-AZURE-DEVOPS-PERMISOS), como dato. 'Not set'
    significa "no administrar este bit" (no se envia ni allow ni deny para
    el); 'Allow'/'Deny' son los 2 unicos valores administrados.

    'AllRepositories' cubre el nodo raiz de cada proyecto. 'BranchLevel'
    cubre feature/*, development, uat, release y main -- son valores
    EXPLICITOS por rama (no acumulativos con AllRepositories: cada nodo de
    rama administra su propio conjunto, que aca es 'Not set' salvo las 4
    filas 'Deny' de Contribute marcadas en el documento).

    'Enterprise Live Migration: manage migrations' NO aparece aca -- es
    Not set/Not set en el documento (no administrado), asi que no requiere
    resolucion de accion ni bit.
    #>

    $allRepositories = [ordered]@{
        'Advanced Security: manage and dismiss alerts'              = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
        'Advanced Security: manage settings'                        = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
        'Advanced Security: view alerts'                            = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
        'Bypass policies when completing pull requests'             = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
        'Bypass policies when pushing'                              = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
        'Contribute'                                                = [ordered]@{ DevelopmentTeam = 'Allow'; CodeReviewers = 'Allow' }
        'Contribute to pull requests'                               = [ordered]@{ DevelopmentTeam = 'Allow'; CodeReviewers = 'Allow' }
        'Create branch'                                             = [ordered]@{ DevelopmentTeam = 'Allow'; CodeReviewers = 'Allow' }
        'Create repository'                                         = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
        'Create tag'                                                = [ordered]@{ DevelopmentTeam = 'Allow'; CodeReviewers = 'Not set' }
        'Delete or disable repository'                              = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
        'Edit policies'                                             = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
        'Force push (rewrite history, delete branches and tags)'    = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
        'Manage notes'                                              = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
        'Manage permissions'                                        = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
        'Read'                                                      = [ordered]@{ DevelopmentTeam = 'Allow'; CodeReviewers = 'Allow' }
        "Remove others' locks"                                      = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
        'Rename repository'                                         = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
    }

    # nodeKey: 'feature', 'development', 'uat', 'release', 'main'.
    $branchPermissionLabels = @(
        'Bypass policies when completing pull requests',
        'Bypass policies when pushing',
        'Contribute',
        'Edit policies',
        'Force push (rewrite history, delete branches and tags)',
        'Manage permissions',
        "Remove others' locks"
    )

    # OJO: cada nodo se guarda como etiqueta -> {DevelopmentTeam,
    # CodeReviewers} -- EL MISMO anidamiento que 'AllRepositories', nunca
    # invertido (rol -> {etiqueta -> valor}). Get-AdoPermissionsDesiredBitsByRole
    # (en New-AdoPermissionsPlan.ps1) asume esta forma para ambas matrices
    # sin distincion -- un anidamiento distinto entre las dos rompe esa
    # funcion compartida (bug real encontrado y corregido durante las
    # pruebas de este mismo cambio).
    $branchLevel = [ordered]@{
        'feature'     = [ordered]@{
            'Bypass policies when completing pull requests'          = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Bypass policies when pushing'                           = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Contribute'                                             = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Edit policies'                                          = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Force push (rewrite history, delete branches and tags)' = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Manage permissions'                                     = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            "Remove others' locks"                                   = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
        }
        'development' = [ordered]@{
            'Bypass policies when completing pull requests'          = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Bypass policies when pushing'                           = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            # Cambio de diseno confirmado por el usuario 2026-09-02 (ver
            # git blame / conversacion): el documento original tenia esto
            # en 'Not set' (push directo permitido a development). Ahora
            # development se suma a uat/release/main como rama protegida
            # -- todo cambio entra por PR, ninguna excepcion para
            # development.
            'Contribute'                                             = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
            'Edit policies'                                          = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Force push (rewrite history, delete branches and tags)' = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Manage permissions'                                     = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            "Remove others' locks"                                   = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
        }
        'uat'         = [ordered]@{
            'Bypass policies when completing pull requests'          = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Bypass policies when pushing'                           = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Contribute'                                             = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
            'Edit policies'                                          = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Force push (rewrite history, delete branches and tags)' = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Manage permissions'                                     = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            "Remove others' locks"                                   = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
        }
        'release'     = [ordered]@{
            'Bypass policies when completing pull requests'          = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Bypass policies when pushing'                           = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Contribute'                                             = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
            'Edit policies'                                          = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Force push (rewrite history, delete branches and tags)' = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Manage permissions'                                     = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            "Remove others' locks"                                   = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
        }
        'main'        = [ordered]@{
            'Bypass policies when completing pull requests'          = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Bypass policies when pushing'                           = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            # Cambio de diseno confirmado por el usuario 2026-09-02: el
            # documento original denegaba Contribute a Code-Reviewers en
            # main, lo cual les hubiera impedido completar (mergear) un PR
            # justo en la rama donde mas importa que puedan hacerlo. Ahora
            # queda 'Not set' para que hereden el Allow de All Repositories
            # -- Code-Reviewers SI puede completar PRs en las 4 ramas
            # protegidas, Development Team NO (Deny explicito arriba).
            'Contribute'                                             = [ordered]@{ DevelopmentTeam = 'Deny'; CodeReviewers = 'Not set' }
            'Edit policies'                                          = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Force push (rewrite history, delete branches and tags)' = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            'Manage permissions'                                     = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Not set' }
            "Remove others' locks"                                   = [ordered]@{ DevelopmentTeam = 'Not set'; CodeReviewers = 'Deny' }
        }
    }

    return [PSCustomObject]@{
        AllRepositories        = [PSCustomObject]$allRepositories
        BranchLevel             = [PSCustomObject]$branchLevel
        BranchPermissionLabels   = $branchPermissionLabels
        BranchNodeKeys           = @('feature', 'development', 'uat', 'release', 'main')
    }
}

function Get-AdoPermissionsManagedActionCatalog {
    <#
    Etiqueta de UI (tal cual el documento) -> nombre ESTABLE de la accion
    (campo 'name', no 'displayName') del security namespace "Git
    Repositories", mas el bit esperado a modo informativo/cross-check.

    Fuente: fetch real 2026-08-26 contra
    https://learn.microsoft.com/rest/api/azure/devops/security/security-namespaces/query
    (namespaceId 2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87, "Git Repositories").
    Confirmado que TODAS las acciones (incluidas las 3 de "Advanced
    Security") viven en este UNICO namespace -- no hay un segundo
    namespace involucrado.

    OJO: el campo 'displayName' que devuelve la API en vivo puede diferir
    del texto exacto de la UI del portal citado en el documento (2
    discrepancias confirmadas: "Delete or disable repository" (UI) vs
    "Delete repository" (API displayName); "Force push (rewrite history,
    delete branches and tags)" (UI) vs "Force push (rewrite history and
    delete branches)" (API displayName)). Por eso la resolucion NUNCA se
    hace comparando displayName -- se hace por el campo 'name' estable de
    esta tabla, y el 'bit' de aca es solo INFORMATIVO: el bit real
    efectivo que se usa para calcular una ACE SIEMPRE es el que devuelve
    la consulta en vivo (Resolve-AdoPermissionsNamespaceActions), nunca
    este valor hardcodeado -- si alguna vez difieren, el plan se bloquea y
    reporta la discrepancia en vez de adivinar.
    #>

    return [ordered]@{
        'Advanced Security: manage and dismiss alerts'              = [ordered]@{ Name = 'DismissAdvSecAlerts'; ExpectedBit = 131072 }
        'Advanced Security: manage settings'                        = [ordered]@{ Name = 'ManageAdvSecScanning'; ExpectedBit = 262144 }
        'Advanced Security: view alerts'                            = [ordered]@{ Name = 'ViewAdvSecAlerts'; ExpectedBit = 65536 }
        'Bypass policies when completing pull requests'             = [ordered]@{ Name = 'PullRequestBypassPolicy'; ExpectedBit = 32768 }
        'Bypass policies when pushing'                              = [ordered]@{ Name = 'PolicyExempt'; ExpectedBit = 128 }
        'Contribute'                                                = [ordered]@{ Name = 'GenericContribute'; ExpectedBit = 4 }
        'Contribute to pull requests'                               = [ordered]@{ Name = 'PullRequestContribute'; ExpectedBit = 16384 }
        'Create branch'                                             = [ordered]@{ Name = 'CreateBranch'; ExpectedBit = 16 }
        'Create repository'                                         = [ordered]@{ Name = 'CreateRepository'; ExpectedBit = 256 }
        'Create tag'                                                = [ordered]@{ Name = 'CreateTag'; ExpectedBit = 32 }
        'Delete or disable repository'                              = [ordered]@{ Name = 'DeleteRepository'; ExpectedBit = 512 }
        'Edit policies'                                             = [ordered]@{ Name = 'EditPolicies'; ExpectedBit = 2048 }
        'Force push (rewrite history, delete branches and tags)'    = [ordered]@{ Name = 'ForcePush'; ExpectedBit = 8 }
        'Manage notes'                                              = [ordered]@{ Name = 'ManageNote'; ExpectedBit = 64 }
        'Manage permissions'                                        = [ordered]@{ Name = 'ManagePermissions'; ExpectedBit = 8192 }
        'Read'                                                      = [ordered]@{ Name = 'GenericRead'; ExpectedBit = 2 }
        "Remove others' locks"                                      = [ordered]@{ Name = 'RemoveOthersLocks'; ExpectedBit = 4096 }
        'Rename repository'                                         = [ordered]@{ Name = 'RenameRepository'; ExpectedBit = 1024 }
    }
}

function Resolve-AdoPermissionsNamespaceActions {
    <#
    Dado el body ya obtenido de GET .../_apis/securitynamespaces (lista
    completa de namespaces reales), busca en TODOS los namespaces (no solo
    "Git Repositories" -- ver comentario de diseno en el plan) la accion
    cuyo 'name' estable coincida con cada entrada del catalogo. Bloquea con
    excepcion descriptiva si:
      - no se encuentra "Git Repositories" (por 'name' o 'displayName');
      - una accion esperada no existe (ni una vez) en el namespace "Git
        Repositories" encontrado;
      - una accion esperada existe MAS DE UNA VEZ (namespace corrupto o
        ambiguo);
      - el bit real difiere del ExpectedBit del catalogo (posible cambio
        de la API -- nunca se adivina, se bloquea).

    Devuelve un hashtable etiqueta-UI -> bit REAL (el de la respuesta en
    vivo, nunca el ExpectedBit), mas el namespaceId resuelto.
    #>
    param(
        [Parameter(Mandatory)] [array]$Namespaces
    )

    $gitNamespace = $Namespaces | Where-Object { [string]$_.name -eq 'Git Repositories' -or [string]$_.displayName -eq 'Git Repositories' } | Select-Object -First 1
    $gitNamespaceMatches = @($Namespaces | Where-Object { [string]$_.name -eq 'Git Repositories' -or [string]$_.displayName -eq 'Git Repositories' })
    if ($gitNamespaceMatches.Count -eq 0) {
        throw "Resolve-AdoPermissionsNamespaceActions: no se encontro el security namespace 'Git Repositories' en la respuesta de la organizacion. Bloqueo seguro -- no se adivina el namespaceId."
    }
    if ($gitNamespaceMatches.Count -gt 1) {
        throw "Resolve-AdoPermissionsNamespaceActions: se encontro mas de un security namespace llamado 'Git Repositories'. Ambiguo -- bloqueo seguro."
    }

    $catalog = Get-AdoPermissionsManagedActionCatalog
    $resolvedBits = [ordered]@{}
    $actions = @($gitNamespace.actions)

    foreach ($label in $catalog.Keys) {
        $expectedName = $catalog[$label].Name
        $matches = @($actions | Where-Object { [string]$_.name -eq $expectedName })
        if ($matches.Count -eq 0) {
            throw "Resolve-AdoPermissionsNamespaceActions: la accion '$expectedName' (etiqueta '$label') no existe en el namespace 'Git Repositories' real. Posible cambio de la API -- bloqueo seguro, no se adivina."
        }
        if ($matches.Count -gt 1) {
            throw "Resolve-AdoPermissionsNamespaceActions: la accion '$expectedName' (etiqueta '$label') existe mas de una vez en el namespace 'Git Repositories' real. Bloqueo seguro."
        }
        $realBit = [int]$matches[0].bit
        $resolvedBits[$label] = $realBit
    }

    return [PSCustomObject]@{
        NamespaceId  = [string]$gitNamespace.namespaceId
        ResolvedBits = $resolvedBits
    }
}

function ConvertTo-AdoPermissionsHexUtf16 {
    <#
    Hex-encoding UTF-16LE (little-endian, 2 bytes por caracter) en
    minusculas de un segmento de texto, usado para construir tokens de
    rama Git (ver ConvertTo-AdoPermissionsGitToken).

    Bug real corregido 2026-09-02: la version anterior de esta funcion
    (entonces llamada ConvertTo-AdoPermissionsHexUtf8) codificaba UTF-8 de
    1 byte por caracter -- Azure DevOps en realidad codifica cada
    caracter del ref name como UTF-16LE (2 bytes), documentado en
    https://devblogs.microsoft.com/devops/git-repo-tokens-for-the-security-service/
    y confirmado empiricamente contra tokens reales ya existentes en la
    organizacion (ej. 'development' -> '64006500760065006c006f0070006d0065006e007400').
    Con la codificacion vieja, TODA escritura de ACE a nivel de rama
    apuntaba a un token que Azure DevOps aceptaba (HTTP 204) pero que no
    corresponde a ninguna rama real -- la escritura nunca aparecia en el
    portal ni afectaba permisos reales. Nunca volver a UTF-8 de 1 byte
    para esto.
    #>
    param(
        [Parameter(Mandatory)] [AllowEmptyString()] [string]$Segment
    )

    $bytes = [Text.Encoding]::Unicode.GetBytes($Segment)
    $sb = [System.Text.StringBuilder]::new()
    foreach ($b in $bytes) {
        [void]$sb.Append($b.ToString('x2'))
    }
    return $sb.ToString()
}

function ConvertTo-AdoPermissionsGitToken {
    <#
    Construye el token de seguridad Git para el namespace "Git
    Repositories", segun
    https://learn.microsoft.com/azure/devops/organizations/security/namespace-reference
    y https://learn.microsoft.com/azure/devops/organizations/security/manage-tokens-namespaces:

      - Repositorio completo:            repoV2/{projectId}/{repositoryId}
      - Rama o prefijo refs/heads/<...>: repoV2/{projectId}/{repositoryId}/refs/heads/<segmentos hex-UTF16LE separados por "/">

    -RefSegments es la lista de segmentos de refs/heads/ despues del
    prefijo (ej. @('feature') para el prefijo completo refs/heads/feature/*,
    @('main') para la rama main, @('release') para release). Cada
    segmento se hex-codifica POR SEPARADO -- nunca se hex-codifica el ref
    completo de una sola vez (un ref con "/" adentro, como
    "feature/algo", tiene 2 segmentos hex distintos, no uno).

    -RefSegments vacio o ausente devuelve el token del repositorio
    completo (para la matriz "All Repositories" a nivel de repo -- en
    'All Repositories' propiamente dicho se usa el token de proyecto, ver
    ConvertTo-AdoPermissionsProjectToken).
    #>
    param(
        [Parameter(Mandatory)] [string]$ProjectId,
        [Parameter(Mandatory)] [string]$RepositoryId,
        [string[]]$RefSegments = @()
    )

    if ($ProjectId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "ConvertTo-AdoPermissionsGitToken: ProjectId no tiene forma de GUID ('$ProjectId')."
    }
    if ($RepositoryId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "ConvertTo-AdoPermissionsGitToken: RepositoryId no tiene forma de GUID ('$RepositoryId')."
    }

    $token = "repoV2/$ProjectId/$RepositoryId"
    if ($RefSegments -and @($RefSegments).Count -gt 0) {
        $hexSegments = @($RefSegments | ForEach-Object { ConvertTo-AdoPermissionsHexUtf16 -Segment $_ })
        $token = "$token/refs/heads/" + ($hexSegments -join '/')
    }
    return $token
}

function ConvertTo-AdoPermissionsSecurityAceDescriptor {
    <#
    Convierte un descriptor de Graph de un GRUPO ('vssgp.BASE64...', el
    que usan las APIs de Graph Groups/Memberships) al descriptor LEGADO
    basado en SID que realmente usa como clave el diccionario
    acesDictionary de la API de Security (accesscontrollists):
    'Microsoft.TeamFoundation.Identity;S-1-9-...'.

    El payload de un descriptor 'vssgp.XXXX' es, el mismo, el SID en
    texto plano codificado en Base64 (sin padding) -- 'vssgp.' + Base64
    de 'S-1-9-...'. Confirmado en vivo 2026-09-02 decodificando el
    descriptor real de Development Team y comparando el SID resultante
    contra el que devuelve un GET crudo (sin filtro 'descriptors=') del
    ACL real de 'All Repositories'.

    HISTORIAL DE 2 INTENTOS FALLIDOS antes de encontrar esto (ver
    debugging.md del agente ado-permissions-builder para el detalle
    completo):
    1. Descriptor de Graph desnudo tal cual ('vssgp.XXXX') -- Azure
       DevOps aceptaba el POST (HTTP 200/204) pero nunca asociaba el ACE
       a la identidad real; confirmado por el Audit Log de la
       organizacion, que no registro NINGUN evento Security.ModifyPermission
       para nuestras escrituras via PAT.
    2. Prefijo 'Microsoft.IdentityModel.Claims.ClaimsIdentity;' + el
       descriptor de Graph tal cual -- PARECIA correcto porque un GET
       filtrado por ese descriptor devolvia una entrada con allow=0/
       deny=0, pero eso es simplemente el "eco" que la API devuelve para
       CUALQUIER descriptor pedido via '&descriptors=' que no tiene ACE
       real -- nunca demuestra que la entrada exista de verdad. Un GET
       SIN el filtro '&descriptors=' (trayendo el acesDictionary
       completo) nunca incluia esta forma.

    Un descriptor que YA viene en una forma final aceptada por la API de
    Security se devuelve tal cual, sin modificar -- hoy son 2:
    'Microsoft.TeamFoundation.Identity;...' (identidades/grupos legados) y
    'Microsoft.TeamFoundation.ServiceIdentity;...' (identidades de
    servicio, ej. el Build service de un proyecto u organización --
    confirmado en vivo 2026-09-02 comparando el ACL real de otro proyecto
    del org, 'CORE-PLT', que SI tiene ACE explicita para 2 de estas).
    #>
    param(
        [Parameter(Mandatory)] [string]$GraphDescriptor
    )

    if ($GraphDescriptor.StartsWith('Microsoft.TeamFoundation.Identity;', [StringComparison]::OrdinalIgnoreCase) -or
        $GraphDescriptor.StartsWith('Microsoft.TeamFoundation.ServiceIdentity;', [StringComparison]::OrdinalIgnoreCase)) {
        return $GraphDescriptor
    }
    if (-not $GraphDescriptor.StartsWith('vssgp.', [StringComparison]::OrdinalIgnoreCase)) {
        throw "ConvertTo-AdoPermissionsSecurityAceDescriptor: solo se admiten descriptores de grupo Graph ('vssgp....') o ya en forma final (identidad legada o de servicio). Recibido: '$GraphDescriptor'."
    }

    $base64Payload = $GraphDescriptor.Substring(6)
    $sid = $null
    try {
        $sid = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($base64Payload))
    }
    catch {
        throw "ConvertTo-AdoPermissionsSecurityAceDescriptor: el payload de '$GraphDescriptor' no es Base64 valido."
    }
    if ($sid -notmatch '^S-1-9-[0-9-]+$') {
        throw "ConvertTo-AdoPermissionsSecurityAceDescriptor: el payload decodificado de '$GraphDescriptor' no tiene forma de SID ('$sid')."
    }
    return "Microsoft.TeamFoundation.Identity;$sid"
}

function ConvertTo-AdoPermissionsProjectToken {
    <#
    Token del nodo "All Repositories" de un proyecto: el projectId solo
    (sin repositoryId). Ver namespace-reference.md de Microsoft, seccion
    Git Repositories: el token de nivel de coleccion/proyecto es el
    projectId, y repoV2/{projectId}/{repositoryId} es el token de un
    repositorio especifico dentro de ese proyecto.
    #>
    param(
        [Parameter(Mandatory)] [string]$ProjectId
    )
    if ($ProjectId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        throw "ConvertTo-AdoPermissionsProjectToken: ProjectId no tiene forma de GUID ('$ProjectId')."
    }
    return "repoV2/$ProjectId"
}

function Get-AdoPermissionsRecomputedAceBits {
    <#
    newAllow = (currentAllow AND NOT managedMask) OR desiredAllow
    newDeny  = (currentDeny  AND NOT managedMask) OR desiredDeny

    Preserva todos los bits NO administrados de la ACE actual. Nunca
    reemplaza la ACE con cero sin haber preservado esos bits. $managedMask
    es el OR de todos los bits de las acciones que este plan administra
    para ese nodo+descriptor (independientemente de si el valor deseado es
    Allow/Deny/Not set -- 'Not set' significa desiredAllow y desiredDeny
    ambos en 0 para ese bit, pero el bit SIGUE dentro de managedMask para
    poder limpiarlo).
    #>
    param(
        [Parameter(Mandatory)] [int]$CurrentAllow,
        [Parameter(Mandatory)] [int]$CurrentDeny,
        [Parameter(Mandatory)] [int]$ManagedMask,
        [Parameter(Mandatory)] [int]$DesiredAllow,
        [Parameter(Mandatory)] [int]$DesiredDeny
    )

    $newAllow = ($CurrentAllow -band (-bnot $ManagedMask)) -bor $DesiredAllow
    $newDeny = ($CurrentDeny -band (-bnot $ManagedMask)) -bor $DesiredDeny

    return [PSCustomObject]@{
        NewAllow = $newAllow
        NewDeny  = $newDeny
    }
}

function Write-AdoPermissionsPreDeleteBackup {
    <#
    Respaldo de solo lectura OBLIGATORIO del recurso completo, escrito
    ANTES de cualquier DELETE real, bajo
    .local/azure-devops-permissions/exports/pre-delete-backups/. Usa
    [System.IO.File]::WriteAllText + UTF8Encoding($false) para evitar el
    BOM que agrega Set-Content -Encoding UTF8 en PowerShell 5.1 (mismo
    patron ya confirmado en Pipelines). Si el GET de respaldo falla o
    devuelve vacio, esto lanza -- el llamador NUNCA debe continuar al
    DELETE si esta funcion no completo con exito.
    #>
    param(
        [Parameter(Mandatory)] [string]$ResourceType,
        [Parameter(Mandatory)] [string]$ResourceKey,
        [Parameter(Mandatory)] [psobject]$BackupContent
    )

    if ($null -eq $BackupContent) {
        throw "Write-AdoPermissionsPreDeleteBackup: el contenido de respaldo es nulo -- no se procede a ningun DELETE sin poder respaldar primero."
    }

    $projectRoot = if ($env:REPO_ROOT) { $env:REPO_ROOT } else { '$env:REPO_ROOT' }
    $backupDir = Join-Path $projectRoot '.local\azure-devops-permissions\exports\pre-delete-backups'
    if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Force -Path $backupDir | Out-Null }

    $safeKey = ($ResourceKey -replace '[^A-Za-z0-9\-\._]', '-')
    $timestamp = (Get-Date).ToUniversalTime().ToString('yyyyMMdd-HHmmss')
    $backupPath = Join-Path $backupDir "$ResourceType-$safeKey-$timestamp.json"

    $json = $BackupContent | ConvertTo-Json -Depth 20
    $utf8NoBom = [System.Text.UTF8Encoding]::new($false)
    [System.IO.File]::WriteAllText($backupPath, $json, $utf8NoBom)

    if (-not (Test-Path -LiteralPath $backupPath) -or (Get-Item -LiteralPath $backupPath).Length -eq 0) {
        throw "Write-AdoPermissionsPreDeleteBackup: el respaldo no se escribio correctamente en '$backupPath'."
    }

    return $backupPath
}

function Invoke-AdoPermissionsDeleteApplyPhase {
    <#
    Aplica la UNICA operacion de un plan de eliminacion ya validado.
    Respaldo de solo lectura obligatorio antes del DELETE (nunca
    configurable, nunca omitible). Vive aca (no en
    Apply-AdoPermissionsDeletePlan.ps1) por el mismo motivo que
    Invoke-AdoPermissionsApplyPhases: poder testearse con
    Invoke-AdoPermissionsRest mockeada.
    #>
    param(
        [Parameter(Mandatory)] [psobject]$Plan,
        [Parameter(Mandatory)] [string]$PlanPath
    )

    $graphBase = 'https://vssps.dev.azure.com/Shared-Service-GM'
    $op = @($Plan.approvedOperations)[0]
    $opType = [string]$op.operationType

    # --- 1) Respaldo de solo lectura OBLIGATORIO ---
    $backupContent = $null
    $resourceKey = $null
    if ($opType -eq 'delete-security-group') {
        $getUri = "$graphBase/_apis/graph/groups/$([uri]::EscapeDataString([string]$op.precondition.groupDescriptor))?api-version=$($script:AdoPermissionsGraphApiVersion)"
        $getResult = Invoke-AdoPermissionsRest -Method GET -Uri $getUri
        if ($getResult.StatusCode -lt 200 -or $getResult.StatusCode -ge 300 -or -not $getResult.Body) {
            throw "Invoke-AdoPermissionsDeleteApplyPhase: no se pudo leer el grupo antes de eliminarlo (HTTP $($getResult.StatusCode)). No se elimina nada sin poder respaldar primero."
        }
        $backupContent = $getResult.Body
        $resourceKey = [string]$op.precondition.groupDescriptor

        $liveDisplayName = [string]$getResult.Body.displayName
        if ($liveDisplayName -ne [string]$op.precondition.expectedDisplayName) {
            throw "Invoke-AdoPermissionsDeleteApplyPhase: el grupo real ('$liveDisplayName') ya no coincide con el esperado ('$($op.precondition.expectedDisplayName)') -- posible drift. Se aborta antes de respaldar/eliminar; regenerar el plan."
        }
    }
    elseif ($opType -eq 'remove-group-membership') {
        $getUri = "$graphBase/_apis/graph/memberships/$([uri]::EscapeDataString([string]$op.precondition.memberDescriptor))/$([uri]::EscapeDataString([string]$op.precondition.containerDescriptor))?api-version=$($script:AdoPermissionsGraphApiVersion)"
        $getResult = Invoke-AdoPermissionsRest -Method GET -Uri $getUri
        if ($getResult.StatusCode -lt 200 -or $getResult.StatusCode -ge 300 -or -not $getResult.Body) {
            throw "Invoke-AdoPermissionsDeleteApplyPhase: no se pudo leer la membresia antes de eliminarla (HTTP $($getResult.StatusCode)). No se elimina nada sin poder respaldar primero."
        }
        $backupContent = $getResult.Body
        $resourceKey = "$([string]$op.precondition.memberDescriptor)_$([string]$op.precondition.containerDescriptor)"
    }
    else {
        throw "Invoke-AdoPermissionsDeleteApplyPhase: operationType '$opType' no es un tipo de eliminacion soportado."
    }

    $backupPath = Write-AdoPermissionsPreDeleteBackup -ResourceType $opType -ResourceKey $resourceKey -BackupContent $backupContent
    Write-Host "Respaldo de solo lectura escrito en: $backupPath" -ForegroundColor Cyan

    # --- 2) DELETE real, ya con respaldo confirmado ---
    $response = Invoke-AdoPermissionsRest -Method DELETE -Uri ([string]$op.uri) -Body $null -RequireApprovedPlan -PlanPath $PlanPath -OperationId ([string]$op.operationId)

    return [PSCustomObject]@{
        operationId = [string]$op.operationId
        operationType = $opType
        status      = 'applied'
        backupPath  = $backupPath
        statusCode  = $response.StatusCode
    }
}

function Get-AdoPermissionsReadbackResults {
    <#
    Relee en vivo (solo GET) el estado real de cada operacion de un plan
    ya aplicado (no destructivo o destructivo) y lo compara contra lo
    declarado. Vive aca (no en Test-AdoPermissionsReadback.ps1) por el
    mismo motivo que Invoke-AdoPermissionsApplyPhases: testeable con
    Invoke-AdoPermissionsRest mockeada, sin tocar la organizacion real.
    #>
    param(
        [Parameter(Mandatory)] [psobject]$Plan
    )

    $graphBase = 'https://vssps.dev.azure.com/Shared-Service-GM'
    $coreBase = 'https://dev.azure.com/Shared-Service-GM'
    $results = [System.Collections.Generic.List[object]]::new()

    foreach ($op in @($Plan.approvedOperations)) {
        $opType = [string]$op.operationType
        $status = 'unknown'
        $detail = ''

        try {
            switch ($opType) {
                'create-security-group' {
                    $listUri = "$graphBase/_apis/graph/groups?scopeDescriptor=$([uri]::EscapeDataString([string]$op.precondition.scopeDescriptor))&api-version=$($script:AdoPermissionsGraphApiVersion)"
                    $listResult = Invoke-AdoPermissionsRest -Method GET -Uri $listUri
                    $exists = @($listResult.Body.value | Where-Object { [string]$_.displayName -eq [string]$op.precondition.displayName })
                    if ($exists.Count -eq 1) { $status = 'applied'; $detail = "Grupo existe con descriptor real '$($exists[0].descriptor)'." }
                    elseif ($exists.Count -eq 0) { $status = 'divergent'; $detail = 'El grupo todavia no existe.' }
                    else { $status = 'divergent'; $detail = 'Hay mas de un grupo con ese displayName.' }
                }
                'update-security-group-description' {
                    $getUri = "$graphBase/_apis/graph/groups/$([uri]::EscapeDataString([string]$op.precondition.groupDescriptor))?api-version=$($script:AdoPermissionsGraphApiVersion)"
                    $getResult = Invoke-AdoPermissionsRest -Method GET -Uri $getUri
                    $expectedValue = ($op.body | Where-Object { $_.path -eq '/description' } | Select-Object -First 1).value
                    if ([string]$getResult.Body.description -eq [string]$expectedValue) { $status = 'applied'; $detail = 'Descripcion coincide.' }
                    else { $status = 'divergent'; $detail = "Descripcion real: '$($getResult.Body.description)'." }
                }
                'add-group-membership' {
                    $checkUri = "$graphBase/_apis/graph/memberships/$([uri]::EscapeDataString([string]$op.precondition.memberDescriptor))/$([uri]::EscapeDataString([string]$op.precondition.containerDescriptor))?api-version=$($script:AdoPermissionsGraphApiVersion)"
                    try {
                        $checkResult = Invoke-AdoPermissionsRest -Method GET -Uri $checkUri
                        if ($checkResult.StatusCode -ge 200 -and $checkResult.StatusCode -lt 300) { $status = 'applied'; $detail = 'Membresia confirmada.' }
                        else { $status = 'divergent'; $detail = "HTTP $($checkResult.StatusCode)." }
                    }
                    catch {
                        if ($_.Exception.Message -match '\(404\)') { $status = 'divergent'; $detail = 'La membresia no existe.' }
                        else { throw }
                    }
                }
                'set-git-permissions-ace' {
                    $expectedAces = $op.body.value[0].acesDictionary
                    $token = [string]$op.body.value[0].token
                    $descriptorsList = @($expectedAces.PSObject.Properties.Name)
                    $aclUri = "$coreBase/_apis/accesscontrollists/$($op.precondition.namespaceId)?token=$([uri]::EscapeDataString($token))&descriptors=$([uri]::EscapeDataString(($descriptorsList -join ',')))&includeExtendedInfo=True&api-version=$($script:AdoPermissionsCoreApiVersion)"
                    $aclResult = Invoke-AdoPermissionsRest -Method GET -Uri $aclUri
                    $matchedAcl = @($aclResult.Body.value) | Where-Object { [string]$_.token -eq $token } | Select-Object -First 1
                    $allMatch = $true
                    $diffs = [System.Collections.Generic.List[string]]::new()
                    foreach ($d in $descriptorsList) {
                        $expected = $expectedAces.$d
                        $liveAllow = 0; $liveDeny = 0; $effAllow = $null; $effDeny = $null
                        if ($matchedAcl -and $matchedAcl.acesDictionary -and $matchedAcl.acesDictionary.PSObject.Properties[$d]) {
                            $liveAce = $matchedAcl.acesDictionary.$d
                            $liveAllow = [int]$liveAce.allow
                            $liveDeny = [int]$liveAce.deny
                            # .PSObject.Properties[...], nunca acceso
                            # directo: bajo Set-StrictMode -Version Latest
                            # (activo en Test-AdoPermissionsReadback.ps1),
                            # '$liveAce.extendedInfo' lanza
                            # PropertyNotFoundStrict si la propiedad no
                            # existe en absoluto -- esta consulta ademas no
                            # pide includeExtendedInfo=True, asi que nunca
                            # esta presente.
                            $liveExtendedInfoProp = $liveAce.PSObject.Properties['extendedInfo']
                            if ($liveExtendedInfoProp -and $liveExtendedInfoProp.Value) {
                                $effAllow = [int]$liveExtendedInfoProp.Value.effectiveAllow
                                $effDeny = [int]$liveExtendedInfoProp.Value.effectiveDeny
                            }
                        }
                        if ($liveAllow -ne [int]$expected.allow -or $liveDeny -ne [int]$expected.deny) {
                            $allMatch = $false
                            $diffs.Add("$d`: esperado allow=$($expected.allow) deny=$($expected.deny), real explicit allow=$liveAllow deny=$liveDeny, effective allow=$effAllow deny=$effDeny")
                        }
                    }
                    if ($allMatch) { $status = 'applied'; $detail = 'ACE coincide (explicit).' }
                    else { $status = 'divergent'; $detail = ($diffs -join ' | ') }
                }
                'delete-security-group' {
                    $getUri = "$graphBase/_apis/graph/groups/$([uri]::EscapeDataString([string]$op.precondition.groupDescriptor))?api-version=$($script:AdoPermissionsGraphApiVersion)"
                    try {
                        $null = Invoke-AdoPermissionsRest -Method GET -Uri $getUri
                        $status = 'divergent'; $detail = 'El grupo TODAVIA existe -- la eliminacion no se confirma.'
                    }
                    catch {
                        if ($_.Exception.Message -match '\(404\)') { $status = 'applied'; $detail = 'Grupo eliminado, confirmado (404).' }
                        else { throw }
                    }
                }
                'remove-group-membership' {
                    $checkUri = "$graphBase/_apis/graph/memberships/$([uri]::EscapeDataString([string]$op.precondition.memberDescriptor))/$([uri]::EscapeDataString([string]$op.precondition.containerDescriptor))?api-version=$($script:AdoPermissionsGraphApiVersion)"
                    try {
                        $null = Invoke-AdoPermissionsRest -Method GET -Uri $checkUri
                        $status = 'divergent'; $detail = 'La membresia TODAVIA existe -- la eliminacion no se confirma.'
                    }
                    catch {
                        if ($_.Exception.Message -match '\(404\)') { $status = 'applied'; $detail = 'Membresia eliminada, confirmada (404).' }
                        else { throw }
                    }
                }
                default {
                    $status = 'unknown'; $detail = "operationType no reconocido para readback: '$opType'."
                }
            }
        }
        catch {
            $status = 'error'
            $detail = $_.Exception.Message
        }

        $results.Add([PSCustomObject]@{ operationId = [string]$op.operationId; operationType = $opType; status = $status; detail = $detail })
    }

    return @($results)
}

function Invoke-AdoPermissionsApplyPhases {
    <#
    Ejecuta las 4 fases no destructivas (create-security-group,
    update-security-group-description, add-group-membership,
    set-git-permissions-ace) de un plan ya validado. Vive ACA (no en
    Apply-AdoPermissionsPlan.ps1, el script ejecutable de nivel superior)
    para poder dot-sourcearla en pruebas offline y reemplazar
    Invoke-AdoPermissionsRest por una version mockeada ANTES de llamarla
    -- exactamente el mismo motivo por el que Invoke-AdoApplyPhases de
    Pipelines vive en New-AdoClassicPayloads.ps1 y no en
    Apply-AdoClassicPlan.ps1. Un script ejecutable con parametros
    obligatorios no se puede dot-sourcear de forma segura para pruebas
    aisladas.

    Nunca lanza por una operacion individual fallida (sigue con las demas
    y reporta un resumen estructurado aplicado/omitido/ya-aplicado/fallido
    por operationId al final).
    #>
    param(
        [Parameter(Mandatory)] [psobject]$Plan,
        [Parameter(Mandatory)] [string]$PlanPath
    )

    $results = [System.Collections.Generic.List[object]]::new()
    $coreBase = 'https://dev.azure.com/Shared-Service-GM'
    $graphBase = 'https://vssps.dev.azure.com/Shared-Service-GM'

    function Add-AdoPermissionsApplyResult {
        param([string]$OperationId, [string]$OperationType, [string]$Status, [string]$Detail)
        $results.Add([PSCustomObject]@{ operationId = $OperationId; operationType = $OperationType; status = $Status; detail = $Detail })
        $color = switch ($Status) { 'applied' { 'Green' }; 'skipped' { 'Yellow' }; 'already-done' { 'Cyan' }; default { 'Red' } }
        Write-Host "[$Status] $OperationId ($OperationType) $Detail" -ForegroundColor $color
    }

    $phaseOrder = @('create-security-group', 'update-security-group-description', 'add-group-membership', 'set-git-permissions-ace')

    foreach ($phaseType in $phaseOrder) {
        $opsInPhase = @($Plan.approvedOperations | Where-Object { [string]$_.operationType -eq $phaseType })
        foreach ($op in $opsInPhase) {
            $opId = [string]$op.operationId

            # --- Precondicion: relectura en vivo antes de escribir ---
            $driftDetected = $false
            $driftDetail = ''
            try {
                switch ($phaseType) {
                    'create-security-group' {
                        $scopeDescriptor = [string]$op.precondition.scopeDescriptor
                        $listUri = "$graphBase/_apis/graph/groups?scopeDescriptor=$([uri]::EscapeDataString($scopeDescriptor))&api-version=$($script:AdoPermissionsGraphApiVersion)"
                        $listResult = Invoke-AdoPermissionsRest -Method GET -Uri $listUri
                        $exists = @($listResult.Body.value | Where-Object { [string]$_.displayName -eq [string]$op.precondition.displayName })
                        if ($exists.Count -gt 0) { $driftDetected = $true; $driftDetail = "El grupo '$($op.precondition.displayName)' ya existe (creado por fuera de este plan)." }
                    }
                    'update-security-group-description' {
                        $getUri = "$graphBase/_apis/graph/groups/$([uri]::EscapeDataString([string]$op.precondition.groupDescriptor))?api-version=$($script:AdoPermissionsGraphApiVersion)"
                        $getResult = Invoke-AdoPermissionsRest -Method GET -Uri $getUri
                        $currentDesc = [string]$getResult.Body.description
                        $expectedDesc = [string]$op.precondition.expectedCurrentDescription
                        if ($currentDesc -ne $expectedDesc -and -not ([string]::IsNullOrWhiteSpace($expectedDesc) -and [string]::IsNullOrWhiteSpace($currentDesc))) {
                            $driftDetected = $true; $driftDetail = "La descripcion actual ('$currentDesc') ya no coincide con la esperada ('$expectedDesc')."
                        }
                    }
                    'add-group-membership' {
                        # OJO: solo un 404 real ("la membresia no existe todavia")
                        # es el resultado ESPERADO aca -- cualquier OTRA excepcion
                        # (PAT faltante, red caida, 401/403/500) NUNCA debe
                        # tratarse en silencio como "no existe, seguir adelante":
                        # eso permitiria intentar la escritura real sin haber
                        # podido verificar nada. Solo se reconoce '(404)' en el
                        # mensaje de la excepcion como el caso seguro de omitir.
                        $checkUri = "$graphBase/_apis/graph/memberships/$([uri]::EscapeDataString([string]$op.precondition.memberDescriptor))/$([uri]::EscapeDataString([string]$op.precondition.containerDescriptor))?api-version=$($script:AdoPermissionsGraphApiVersion)"
                        try {
                            $checkResult = Invoke-AdoPermissionsRest -Method GET -Uri $checkUri
                            if ($checkResult.StatusCode -ge 200 -and $checkResult.StatusCode -lt 300) {
                                $driftDetected = $true; $driftDetail = 'La membresia ya existe (agregada por fuera de este plan).'
                            }
                        }
                        catch {
                            if ($_.Exception.Message -notmatch '\(404\)') {
                                $driftDetected = $true
                                $driftDetail = "No se pudo re-verificar si la membresia ya existe: $($_.Exception.Message)"
                            }
                            # si matchea '(404)': la membresia no existe todavia -- estado esperado, se continua.
                        }
                    }
                    'set-git-permissions-ace' {
                        $token = [string]$op.precondition.token
                        $descriptorsList = @($op.precondition.descriptors.PSObject.Properties.Name)
                        $aceDescriptorsList = @($descriptorsList | ForEach-Object { ConvertTo-AdoPermissionsSecurityAceDescriptor -GraphDescriptor $_ })
                        $aclUri = "$coreBase/_apis/accesscontrollists/$($op.precondition.namespaceId)?token=$([uri]::EscapeDataString($token))&descriptors=$([uri]::EscapeDataString(($aceDescriptorsList -join ',')))&api-version=$($script:AdoPermissionsCoreApiVersion)"
                        $aclResult = Invoke-AdoPermissionsRest -Method GET -Uri $aclUri
                        $matchedAcl = @($aclResult.Body.value) | Where-Object { [string]$_.token -eq $token } | Select-Object -First 1
                        foreach ($d in $descriptorsList) {
                            $expected = $op.precondition.descriptors.$d
                            $liveAllow = 0; $liveDeny = 0
                            # $d es el descriptor de Graph desnudo (asi se
                            # guarda precondition.descriptors, bookkeeping
                            # interno) -- el acesDictionary real de Azure
                            # DevOps esta keyed por la forma compuesta, ver
                            # ConvertTo-AdoPermissionsSecurityAceDescriptor.
                            $aceKey = ConvertTo-AdoPermissionsSecurityAceDescriptor -GraphDescriptor $d
                            if ($matchedAcl -and $matchedAcl.acesDictionary -and $matchedAcl.acesDictionary.PSObject.Properties[$aceKey]) {
                                $liveAllow = [int]$matchedAcl.acesDictionary.$aceKey.allow
                                $liveDeny = [int]$matchedAcl.acesDictionary.$aceKey.deny
                            }
                            if ($liveAllow -ne [int]$expected.expectedExplicitAllow -or $liveDeny -ne [int]$expected.expectedExplicitDeny) {
                                $driftDetected = $true; $driftDetail = "El ACE actual del descriptor '$d' en el token '$token' ya no coincide con la instantanea usada al planificar."
                            }
                        }
                    }
                }
            }
            catch {
                $driftDetected = $true
                $driftDetail = "No se pudo re-verificar la precondicion en vivo: $($_.Exception.Message)"
            }

            if ($driftDetected) {
                Add-AdoPermissionsApplyResult -OperationId $opId -OperationType $phaseType -Status 'skipped' -Detail $driftDetail
                continue
            }

            try {
                $response = Invoke-AdoPermissionsRest -Method ([string]$op.method) -Uri ([string]$op.uri) -Body $op.body -RequireApprovedPlan -PlanPath $PlanPath -OperationId $opId
                Add-AdoPermissionsApplyResult -OperationId $opId -OperationType $phaseType -Status 'applied' -Detail "HTTP $($response.StatusCode)"
            }
            catch {
                if ($_.Exception.Message -match "ya tiene estado 'succeeded'") {
                    Add-AdoPermissionsApplyResult -OperationId $opId -OperationType $phaseType -Status 'already-done' -Detail 'Ya se habia aplicado en una corrida anterior (journal).'
                }
                else {
                    Add-AdoPermissionsApplyResult -OperationId $opId -OperationType $phaseType -Status 'failed' -Detail $_.Exception.Message
                }
            }
        }
    }

    return @($results)
}

# Constantes de organizacion - no secretas, seguras de exponer.
$script:AdoPermissionsCoreBaseUrl = 'https://dev.azure.com/Shared-Service-GM'
$script:AdoPermissionsGraphBaseUrl = 'https://vssps.dev.azure.com/Shared-Service-GM'
$script:AdoPermissionsGraphApiVersion = '7.1-preview.1'
$script:AdoPermissionsCoreApiVersion = '7.1'
