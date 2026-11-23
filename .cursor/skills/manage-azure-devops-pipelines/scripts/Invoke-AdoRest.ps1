<#
Unico helper autorizado para llamadas REST clasicas a Azure DevOps
(Shared-Service-GM). Lee el PAT de $env:AZURE_DEVOPS_PAT y nunca lo
imprime, loggea ni incluye en ningun archivo de salida.

Uso:
  . .\Invoke-AdoRest.ps1
  Invoke-AdoRest -Method GET -Uri 'https://dev.azure.com/Shared-Service-GM/_apis/projects?api-version=7.1'
  Invoke-AdoRest -Method POST -Uri '...' -Body $hashtable -RequireApprovedPlan -PlanPath '...' -OperationId 'create-variable-group'

Este helper NUNCA debe invocarse directamente desde Bash (ni para GET ni
para escrituras) -- ado-security-gate.ps1 lo bloquea siempre que un
comando lo mencione como el script que se ejecuta o carga. Solo puede
cargarse por dot-sourcing DESDE DENTRO de otro script .ps1 autorizado de
esta skill (Export-AdoClassicInventory.ps1, Test-AdoCreatedResources.ps1,
Invoke-AdoClassicPlan.ps1, Apply-AdoClassicPlan.ps1).

Escrituras (POST/PUT/DELETE) exigen TODO lo siguiente, o se rechazan
antes de tocar la red:
  - -RequireApprovedPlan y -PlanPath apuntando a un plan con
    validated=true cuyo validationHash coincide con su contenido actual
    (ver Get-AdoPlanCanonicalHash). EL ARCHIVO DE PLAN NUNCA SE
    MODIFICA POR ESTE HELPER -- es inmutable despues de validado.
  - -OperationId identificando una entrada de plan.approvedOperations
    cuyo method/uri/bodyHash coincidan EXACTAMENTE con esta llamada. Un
    plan sin approvedOperations, o con approvedOperations vacio, rechaza
    toda escritura -- hoy ningun generador de planes puebla ese
    manifiesto (los payloads de Build/Release clasico no estan
    confirmados todavia), asi que las escrituras quedan bloqueadas de
    hecho, no solo por el freno de fases de Apply-AdoClassicPlan.ps1.
  - El estado de "ya se uso / esta en curso" vive en un JOURNAL DE
    EJECUCION separado bajo .local/azure-devops/executions/<hash>.json
    (ver funciones *-AdoJournaledOperation mas abajo), protegido con un
    lock exclusivo de archivo para dos procesos concurrentes. El plan
    JAMAS se reescribe para registrar esto.

Esto no es una garantia criptografica contra un atacante con acceso al
proceso, es un freno deliberado: el llamador (scripts de esta skill) es
quien decide invocar con esas banderas despues del flujo de aprobacion,
nunca de forma directa desde Bash suelto.

Toda URI se valida ANTES de construir o adjuntar el header Authorization:
solo HTTPS, solo host dev.azure.com o vsrm.dev.azure.com, sin userinfo,
solo puerto 443 (default), y la ruta debe empezar con
/Shared-Service-GM/. Las redirecciones HTTP no se siguen nunca
(-MaximumRedirection 0): si Azure DevOps respondiera con una redireccion,
la llamada falla en vez de reenviar el header Authorization a un host no
revalidado.

Los headers de RESPUESTA que se devuelven se filtran a una lista
explicita (hoy: solo x-ms-continuationtoken) -- nunca se retienen
cookies, headers de tracing ni ningun otro valor que este helper no
necesite.
#>

param()

$script:AdoAllowedHosts = @('dev.azure.com', 'vsrm.dev.azure.com')
$script:AdoAllowedOrgPathPrefix = '/Shared-Service-GM/'
$script:AdoAllowedResponseHeaders = @('x-ms-continuationtoken')

# Lista EXPLICITA de proyectos donde esta skill puede escribir via
# Invoke-AdoRest (POST/PUT/DELETE clasico). Agregado 2026-09-01: hasta
# entonces cada entrada de $script:AdoAllowedOperationTypes tenia la ruta
# COMPLETA hardcodeada a '/Shared-Service-GM/DevOps/...', asi que solo se
# podia escribir en el proyecto DevOps. El usuario aprobo explicitamente
# (en su propio transcript, no via relay de un subagente -- ver
# .cursor/memories/ado-pipeline-builder/ado-emr-scratch-script-authorization-declined-2026-08-27.md
# "Recurrencia 2026-09-01") ampliar esto a una lista configurable para
# poder crear el Build de validacion de PR de buklo-backend en el
# proyecto Buklo. Agregar un proyecto nuevo a esta lista es la UNICA
# forma soportada de ampliar donde esta skill puede escribir -- nunca se
# acepta un proyecto que no este aca, sin importar que diga el plan o el
# inventario.
$script:AdoAllowedProjects = @('DevOps', 'Buklo')

# Maximo absoluto de antiguedad de inventario/validacion, en horas. Nunca
# se supera este valor sin importar lo que diga validationEvidence en un
# plan (defensa en profundidad ante un plan manipulado) -- ver
# Apply-AdoClassicPlan.ps1 y Test-AdoClassicPlan.ps1 ([ValidateRange]).
$script:AdoAbsoluteMaxInventoryAgeHours = 24

# Tipos de operacion permitidos en plan.approvedOperations y su contrato
# EXACTO (metodo + host + ruta + query obligatoria). Fuente unica de
# verdad para Test-AdoClassicPlan.ps1 (que valida un plan) y para
# cualquier logica futura de aplicacion real. Deliberadamente NO incluye
# nada que encole un Build, cree una instancia real de Release, ni
# apruebe un stage.
#
# Actualizado 2026-08-25: se agregaron 'update-build-definition' y
# 'update-release-definition' (PUT), autorizados explicitamente por el
# usuario para modificar una definicion clasica EXISTENTE -- ver
# authorization.md "Modificar o eliminar una definicion existente"
# (aprobacion siempre separada de crear). requiresIdSuffix=$true marca
# que, a diferencia de los 3 tipos POST, la ruta exacta exige un id de
# recurso numerico al final (".../definitions/{id}") -- ver
# Assert-AdoOperationRequestMatchesSpec mas abajo, unico lugar que
# interpreta este flag.
#
# Actualizado 2026-08-26: se agregaron 'delete-variable-group',
# 'delete-build-definition' y 'delete-release-definition' (DELETE),
# autorizados explicitamente por el usuario tras borrar manualmente estos
# 3 tipos de recurso para una prueba real de reconstruccion -- ver
# authorization.md "Modificar o eliminar una definicion existente" (mismo
# nivel de aprobacion separada que update-*, nunca agrupable con crear).
# Los 3 usan requiresIdSuffix=$true (igual que update-*, un DELETE
# siempre apunta a un recurso puntual por id) y nunca llevan body (ver
# Invoke-AdoApplyPhases, Fase 6: el respaldo de solo lectura antes de
# borrar es OBLIGATORIO, no opcional -- decision explicita del usuario).
$script:AdoAllowedOperationTypes = [ordered]@{
    'create-variable-group'    = [ordered]@{
        method        = 'POST'
        host          = 'dev.azure.com'
        pathSuffix    = '/_apis/distributedtask/variablegroups'
        requiredQuery = [ordered]@{ 'api-version' = '7.1' }
    }
    'create-build-definition'  = [ordered]@{
        method        = 'POST'
        host          = 'dev.azure.com'
        pathSuffix    = '/_apis/build/definitions'
        requiredQuery = [ordered]@{ 'api-version' = '7.1' }
    }
    'create-release-definition' = [ordered]@{
        method        = 'POST'
        host          = 'vsrm.dev.azure.com'
        pathSuffix    = '/_apis/release/definitions'
        requiredQuery = [ordered]@{ 'api-version' = '7.1' }
    }
    'update-build-definition'  = [ordered]@{
        method           = 'PUT'
        host             = 'dev.azure.com'
        pathSuffix       = '/_apis/build/definitions'
        requiredQuery    = [ordered]@{ 'api-version' = '7.1' }
        requiresIdSuffix = $true
    }
    'update-release-definition' = [ordered]@{
        method           = 'PUT'
        host             = 'vsrm.dev.azure.com'
        pathSuffix       = '/_apis/release/definitions'
        requiredQuery    = [ordered]@{ 'api-version' = '7.1' }
        requiresIdSuffix = $true
    }
    'delete-variable-group'    = [ordered]@{
        method           = 'DELETE'
        host             = 'dev.azure.com'
        pathSuffix       = '/_apis/distributedtask/variablegroups'
        requiredQuery    = [ordered]@{ 'api-version' = '7.1' }
        requiresIdSuffix = $true
    }
    'delete-build-definition'  = [ordered]@{
        method           = 'DELETE'
        host             = 'dev.azure.com'
        pathSuffix       = '/_apis/build/definitions'
        requiredQuery    = [ordered]@{ 'api-version' = '7.1' }
        requiresIdSuffix = $true
    }
    'delete-release-definition' = [ordered]@{
        method           = 'DELETE'
        host             = 'vsrm.dev.azure.com'
        pathSuffix       = '/_apis/release/definitions'
        requiredQuery    = [ordered]@{ 'api-version' = '7.1' }
        requiresIdSuffix = $true
    }
}

function Assert-AdoAllowedUri {
    <#
    Valida que $Uri sea una URI HTTPS permitida hacia Azure DevOps
    Shared-Service-GM antes de que se construya o adjunte ningun header de
    autenticacion. Lanza una excepcion (nunca retorna $false en silencio)
    si la URI no cumple TODAS las condiciones. Devuelve el [System.Uri]
    parseado si es valida.
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
        throw "Invoke-AdoRest rechazado: URI invalida o no absoluta."
    }

    if ($parsed.Scheme -ne 'https') {
        throw "Invoke-AdoRest rechazado: solo se permite el esquema https. Esquema recibido: '$($parsed.Scheme)'."
    }

    if (-not [string]::IsNullOrEmpty($parsed.UserInfo)) {
        throw "Invoke-AdoRest rechazado: la URI no puede contener userinfo (usuario:password@host)."
    }

    if ($script:AdoAllowedHosts -notcontains $parsed.Host) {
        throw "Invoke-AdoRest rechazado: host no autorizado '$($parsed.Host)'. Solo se permiten: $($script:AdoAllowedHosts -join ', ')."
    }

    if (-not $parsed.IsDefaultPort) {
        throw "Invoke-AdoRest rechazado: puerto no estandar '$($parsed.Port)'. Solo se permite el puerto HTTPS por defecto."
    }

    if (-not $parsed.AbsolutePath.StartsWith($script:AdoAllowedOrgPathPrefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "Invoke-AdoRest rechazado: la ruta debe empezar con '$($script:AdoAllowedOrgPathPrefix)' (organizacion Shared-Service-GM). Ruta recibida: '$($parsed.AbsolutePath)'."
    }

    return $parsed
}

function Assert-AdoOperationRequestMatchesSpec {
    <#
    Re-deriva y valida, desde cero, que ($Method, $Uri) cumplan EXACTO el
    contrato de $script:AdoAllowedOperationTypes[$OperationType]: metodo
    POST, host, ruta exacta (sin id de recurso, sin '/' extra al final),
    y query con EXACTAMENTE los parametros requeridos (sin duplicados, sin
    extras, con el valor exacto esperado). Nunca confia en un 'method'/
    'uri' ya guardados en otro lado (plan.approvedOperations, etc.) --
    todo se recalcula aca desde los argumentos recibidos.

    Se usa en DOS lugares con el MISMO codigo (una sola fuente de verdad):
      - Test-AdoClassicPlan.ps1, seccion de forma de approvedOperations
        (validacion "aguas arriba", al aprobar el plan).
      - Invoke-AdoRest, INMEDIATAMENTE antes de cualquier escritura real
        (defensa en profundidad "aguas abajo": si por lo que sea un plan
        con approvedOperations invalido llegara igual hasta aca -- bug en
        Test-AdoClassicPlan.ps1, plan armado por otro camino -- esta
        segunda validacion independiente corta la escritura antes de
        tocar la red).

    Lanza una excepcion descriptiva (nunca devuelve $false en silencio) en
    el primer problema encontrado. Devuelve el spec ($script:
    AdoAllowedOperationTypes[$OperationType]) si todo es valido.
    #>
    param(
        [Parameter(Mandatory)] [string]$OperationType,
        [Parameter(Mandatory)] [string]$Method,
        [Parameter(Mandatory)] [string]$Uri,
        [string]$Label = $OperationType,
        # Proyecto esperado (normalmente plan.project). Si se provee, la
        # uri debe apuntar EXACTAMENTE a este proyecto -- nunca alcanza
        # con que el proyecto de la uri este en $script:AdoAllowedProjects
        # en general, tiene que coincidir con el proyecto declarado del
        # plan que se esta validando/ejecutando (evita que un plan
        # declarado para 'Buklo' cuele una operacion real contra 'DevOps',
        # o viceversa).
        [string]$ExpectedProject
    )

    if ([string]::IsNullOrWhiteSpace($OperationType) -or -not $script:AdoAllowedOperationTypes.Contains($OperationType)) {
        throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): operationType debe ser uno de: $($script:AdoAllowedOperationTypes.Keys -join ', '). Encontrado: '$OperationType'."
    }

    $spec = $script:AdoAllowedOperationTypes[$OperationType]

    # Nunca se acepta otro metodo que POST/PUT/DELETE (los 3 unicos
    # permitidos hoy en el manifiesto), incluso si por algun motivo
    # $spec.method trajera otra cosa (defensa adicional: nunca confiar
    # solo en la tabla).
    if ($spec.method -notin @('POST', 'PUT', 'DELETE')) {
        throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): spec interno invalido (method distinto de POST/PUT/DELETE para operationType permitido). Esto es un bug de configuracion, nunca deberia pasar."
    }
    if ($Method -ne $spec.method) {
        throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): method debe ser '$($spec.method)' para operationType '$OperationType'. Encontrado: '$Method'."
    }

    $parsedUri = Assert-AdoAllowedUri -Uri $Uri

    if ($parsedUri.Host -ne $spec.host) {
        throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): la uri debe usar el host '$($spec.host)' para operationType '$OperationType'. Encontrado: '$($parsedUri.Host)'."
    }

    # Extraer el segmento de proyecto de la ruta ('/Shared-Service-GM/<project>/...')
    # y validarlo contra $script:AdoAllowedProjects ANTES de comparar el
    # resto de la ruta -- nunca se acepta un proyecto fuera de esa lista,
    # sin importar que diga el resto de la uri.
    if ($parsedUri.AbsolutePath -notmatch '^/Shared-Service-GM/([^/]+)(/.*)$') {
        throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): no se pudo extraer el proyecto de la ruta '$($parsedUri.AbsolutePath)'."
    }
    $projectInUri = $Matches[1]
    if ($script:AdoAllowedProjects -notcontains $projectInUri) {
        throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): el proyecto '$projectInUri' no esta en la lista de proyectos permitidos para escritura ($($script:AdoAllowedProjects -join ', '))."
    }
    if (-not [string]::IsNullOrWhiteSpace($ExpectedProject) -and $projectInUri -ne $ExpectedProject) {
        throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): la uri apunta al proyecto '$projectInUri', pero se esperaba '$ExpectedProject' (proyecto declarado del plan)."
    }

    $expectedPath = "/Shared-Service-GM/$projectInUri$($spec.pathSuffix)"

    if ([bool]$spec.requiresIdSuffix) {
        # Tipos 'update-*' (PUT): la ruta exige EXACTAMENTE un segmento
        # numerico de id de recurso al final (".../definitions/622"),
        # nunca vacio, nunca no-numerico, nunca con segmentos extra
        # despues del id.
        if ($parsedUri.AbsolutePath -notmatch "^$([regex]::Escape($expectedPath))/(\d+)$") {
            throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): la uri debe tener exactamente la ruta '$expectedPath/<id numerico>' para operationType '$OperationType'. Encontrada: '$($parsedUri.AbsolutePath)'."
        }
    }
    else {
        # Tipos 'create-*' (POST): comparacion EXACTA de ruta -- sin
        # TrimEnd('/'): una ruta con '/' adicional al final
        # ('.../definitions/') se rechaza, nunca se tolera en silencio
        # (podria usarse para disimular un segmento extra).
        if ($parsedUri.AbsolutePath -ne $expectedPath) {
            throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): la uri debe tener exactamente la ruta '$expectedPath' (sin id de recurso, sin '/' adicional, sin segmentos extra) para operationType '$OperationType'. Encontrada: '$($parsedUri.AbsolutePath)'."
        }
    }

    # Query: se exige EXACTAMENTE spec.requiredQuery, sin duplicados, sin
    # parametros extra. Los duplicados se detectan aca mismo (no en un
    # hashtable, que silenciosamente se quedaria con el ultimo valor).
    $queryPairs = [ordered]@{}
    $rawQuery = $parsedUri.Query.TrimStart('?')
    if ($rawQuery) {
        foreach ($pair in ($rawQuery -split '&')) {
            if (-not $pair) { continue }
            $kv = $pair -split '=', 2
            $qKey = [uri]::UnescapeDataString($kv[0])
            $qVal = if ($kv.Count -gt 1) { [uri]::UnescapeDataString($kv[1]) } else { '' }
            if ($queryPairs.Contains($qKey)) {
                throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): la uri tiene el parametro de query '$qKey' duplicado."
            }
            $queryPairs[$qKey] = $qVal
        }
    }

    $requiredKeys = @($spec.requiredQuery.Keys)
    $actualKeys = @($queryPairs.Keys)
    $extraKeys = @($actualKeys | Where-Object { $requiredKeys -notcontains $_ })
    $missingKeys = @($requiredKeys | Where-Object { $actualKeys -notcontains $_ })

    if ($extraKeys.Count -gt 0) {
        throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): la uri tiene parametros de query extra no permitidos: $($extraKeys -join ', ')."
    }
    if ($missingKeys.Count -gt 0) {
        throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): la uri no tiene el parametro de query requerido: $($missingKeys -join ', ')."
    }
    foreach ($rk in $requiredKeys) {
        if ($queryPairs[$rk] -ne $spec.requiredQuery[$rk]) {
            throw "Assert-AdoOperationRequestMatchesSpec ('$Label'): la uri tiene '$rk=$($queryPairs[$rk])', se esperaba '$rk=$($spec.requiredQuery[$rk])'."
        }
    }

    return $spec
}

function Get-AdoAuthHeader {
    $pat = $env:AZURE_DEVOPS_PAT
    if ([string]::IsNullOrWhiteSpace($pat)) {
        throw 'AZURE_DEVOPS_PAT no esta configurada en el entorno. Ejecutar setx AZURE_DEVOPS_PAT en una terminal propia del usuario (nunca pasarlo por chat) y abrir una terminal nueva.'
    }

    $basicToken = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
    return @{ Authorization = "Basic $basicToken" }
}

function Get-AdoSha256OfText {
    <#
    SHA-256 generico de un texto (UTF-8), en hex minuscula. Building
    block reutilizado por Get-AdoPlanCanonicalHash y por el hash de
    inventario (validationEvidence.inventoryHash).
    #>
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

function Get-AdoPlanCanonicalHash {
    <#
    Calcula un hash SHA-256 determinista del contenido "de negocio" de un
    plan (excluye los campos de metadatos de validacion que cambian con
    cada corrida de Test-AdoClassicPlan.ps1 -- validationEvidence y
    approvedOperations SI se incluyen, porque son parte del contrato
    protegido). Se usa para detectar si un plan fue editado despues de
    haber sido validado. El plan NUNCA se modifica despues de esto -- el
    estado de ejecucion vive en un journal separado, no en el plan.
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
    return Get-AdoSha256OfText -Text $canonicalJson
}

function Get-AdoBodyCanonicalHash {
    <#
    SHA-256 canonico del body de una escritura REST, para comparar contra
    approvedOperations[].bodyHash. $null/ausente se trata como objeto
    vacio (mismo hash siempre para "sin body"), para que una operacion
    sin body tenga un bodyHash estable y comparable.
    #>
    param(
        [object]$Body
    )

    if ($null -eq $Body) {
        $canonicalJson = '{}'
    }
    else {
        $canonicalJson = $Body | ConvertTo-Json -Depth 20 -Compress
    }
    return Get-AdoSha256OfText -Text $canonicalJson
}

function Test-AdoValueIsCollectionCompatible {
    <#
    Devuelve $true solo si $Value es algo razonable para un campo 'value'
    de una respuesta paginada de Azure DevOps: un array/coleccion no-
    string (incluida una coleccion vacia). Rechaza strings (son
    IEnumerable de chars -- facil de confundir), numeros, booleanos y
    objetos escalares sueltos.
    #>
    param($Value)

    if ($null -eq $Value) { return $false }
    if ($Value -is [string]) { return $false }
    if ($Value -is [System.Collections.IEnumerable]) { return $true }
    return $false
}

# ============================================================
# Journal de ejecucion (.local/azure-devops/executions/<hash>.json) --
# registra que operaciones aprobadas ya se intentaron/consumieron, SIN
# tocar jamas el archivo de plan (que queda inmutable despues de
# validado, protegiendo validationHash indefinidamente).
# ============================================================

$script:AdoProductionExecutionsDir = if ([string]::IsNullOrWhiteSpace($env:REPO_ROOT)) {
    # Sin REPO_ROOT en el entorno: derivar la raiz del repo desde la
    # ubicacion de este script (.../.cursor/skills/manage-azure-devops-pipelines/scripts).
    Join-Path (Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')).Path (Join-Path '.local' 'azure-devops' 'executions')
} else {
    Join-Path $env:REPO_ROOT (Join-Path '.local' 'azure-devops' 'executions')
}

function Get-AdoExecutionsDir {
    <#
    Directorio del journal de ejecucion. FIJO a la ruta real de produccion
    -- ningun llamador de produccion puede cambiarlo (no hay parametro
    -ProjectRoot en esta funcion ni en ninguna de las que dependen de
    ella: eso era exactamente el hueco que permitia obtener un journal
    "nuevo" apuntando a otro directorio y saltarse la deduplicacion real).

    La UNICA forma de redirigir esto es la variable de entorno
    ADO_TEST_EXECUTIONS_ROOT, deliberadamente nombrada para que sea
    obvio que es un mecanismo exclusivo de pruebas: un llamador de
    produccion no la setea nunca, y no existe ningun parametro publico
    que un caller normal pueda usar para lograr el mismo efecto.
    #>
    if (-not [string]::IsNullOrWhiteSpace($env:ADO_TEST_EXECUTIONS_ROOT)) {
        return $env:ADO_TEST_EXECUTIONS_ROOT
    }
    return $script:AdoProductionExecutionsDir
}

function Get-AdoExecutionJournalPath {
    param(
        [Parameter(Mandatory)] [string]$PlanValidationHash
    )
    $dir = Get-AdoExecutionsDir
    return Join-Path $dir "$PlanValidationHash.json"
}

function Lock-AdoJournalFile {
    <#
    Abre (o crea) el archivo de lock con FileShare.None -- exclusivo. Si
    otro proceso ya lo tiene abierto, reintenta con backoff corto hasta
    -TimeoutMs. Devuelve el FileStream abierto; el llamador DEBE cerrarlo
    en un finally para liberar el lock.
    #>
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

function Test-AdoJournalOperationsRawHasDuplicateKeys {
    <#
    ConvertFrom-Json colapsa en silencio una clave JSON duplicada (se
    queda con el ultimo valor) -- eso significa que, una vez parseado, ya
    no hay forma de detectar que 'operations' tenia dos entradas con el
    mismo operationId. Por eso esto opera sobre el TEXTO CRUDO del bloque
    "operations": { ... } (el nivel exacto que escribe siempre
    Write-AdoExecutionJournalAtomic), contando cuantas veces aparece cada
    clave de primer nivel dentro de ese bloque. Un journal legitimo,
    escrito siempre por este mismo modulo, nunca produce una clave
    duplicada -- esto es defensa contra un archivo editado a mano o
    corrupto de otra forma.
    #>
    param([Parameter(Mandatory)] [string]$RawJournalText)

    $opsBlockMatch = [regex]::Match($RawJournalText, '"operations"\s*:\s*\{')
    if (-not $opsBlockMatch.Success) { return $false }

    # Escanea balanceando llaves desde la apertura de "operations": { ...
    # hasta su cierre correspondiente, para aislar exactamente ese bloque
    # (que puede contener sub-objetos anidados por cada operacion).
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

    # Claves de PRIMER NIVEL dentro del bloque: un "nombre": { a la
    # profundidad 0 relativa a este bloque (evita contar claves internas
    # de cada operacion, como "state" o "resultId", como si fueran ids).
    # OJO: el patron usa un lookahead (?=\{) para el '{' de apertura --
    # NUNCA lo consume -- para que la SIGUIENTE iteracion del while sea
    # la que lo vea y recien ahi incremente $localDepth. Consumirlo como
    # parte del match (con \{ sin lookahead) es un bug real: el escaneo
    # entraria al objeto anidado de esa operacion sin haber incrementado
    # la profundidad, así que su ' primera clave interna (por ejemplo
    # "state") pasaria a evaluarse en profundidad 0 y, peor, el '}' que
    # cierra esa operacion decrementaria una profundidad que nunca se
    # incremento -- rompiendo el conteo para todo lo que sigue.
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

    $distinctCount = ($seenKeys | Select-Object -Unique).Count
    return ($distinctCount -ne $seenKeys.Count)
}

function Assert-AdoJournalOperationShapeValid {
    <#
    Valida la FORMA de una entrada individual del journal: debe tener
    exactamente las 4 propiedades esperadas (state/startedAtUtc/
    completedAtUtc/resultId, ni de mas ni de menos) y 'state' debe ser uno
    de los 4 valores validos. Cualquier desvio es journal corrupto.
    #>
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

function Read-AdoExecutionJournal {
    <#
    Lee el journal. Si no existe, devuelve uno nuevo con TODAS las
    -OperationIds (el manifiesto completo de approvedOperations, no solo
    la que se esta por iniciar) en 'pending'.

    Si el journal YA EXISTE, se exige que contenga EXACTAMENTE el mismo
    conjunto de operationIds que -OperationIds (ni falta ninguna, ni sobra
    ninguna, ninguna duplicada), y que cada entrada tenga forma y estado
    validos. Cualquier desvio es JOURNAL CORRUPTO -- bloqueo seguro, se
    lanza excepcion. Esto reemplaza el comportamiento anterior (que
    agregaba en silencio como 'pending' cualquier operationId ausente del
    journal existente): ese comportamiento permitia que un journal
    parcialmente borrado o editado a mano resucitara operaciones ya
    completadas como si nunca se hubieran intentado -- el riesgo de
    duplicado real que esta funcion existe para cerrar.

    JSON invalido o journal de OTRO plan (planValidationHash distinto)
    tambien son bloqueo seguro, como antes.
    #>
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

    $raw = Get-Content -LiteralPath $JournalPath -Raw
    $journal = $null
    try {
        $journal = $raw | ConvertFrom-Json
    }
    catch {
        throw "Journal de ejecucion corrupto en '$JournalPath' (JSON invalido). Bloqueo seguro: no se puede confirmar el estado de ninguna operacion sin arriesgar una escritura duplicada."
    }

    if (-not $journal.planValidationHash -or $journal.planValidationHash -ne $PlanValidationHash) {
        throw "Journal de ejecucion en '$JournalPath' no coincide con este plan (planValidationHash distinto). Bloqueo seguro: podria ser el journal de otro plan."
    }

    if (-not $journal.operations) {
        throw "Journal de ejecucion en '$JournalPath' no tiene bloque 'operations'. Bloqueo seguro."
    }

    if (Test-AdoJournalOperationsRawHasDuplicateKeys -RawJournalText $raw) {
        throw "Journal de ejecucion corrupto en '$JournalPath': el bloque 'operations' tiene un operationId duplicado en el texto crudo. Bloqueo seguro."
    }

    $journalOpIds = @($journal.operations.PSObject.Properties.Name)
    $expectedOpIds = @($OperationIds)

    $missingFromJournal = @($expectedOpIds | Where-Object { $journalOpIds -notcontains $_ })
    $extraInJournal = @($journalOpIds | Where-Object { $expectedOpIds -notcontains $_ })

    if ($missingFromJournal.Count -gt 0) {
        throw "Journal de ejecucion corrupto en '$JournalPath': falta(n) la(s) operacion(es) $($missingFromJournal -join ', ') que si estan en el plan aprobado. Bloqueo seguro -- nunca se re-agrega como 'pending' una operacion desaparecida de un journal existente (eso permitiria reintentar como si fuera nueva una operacion que ya pudo haberse ejecutado)."
    }
    if ($extraInJournal.Count -gt 0) {
        throw "Journal de ejecucion corrupto en '$JournalPath': tiene la(s) operacion(es) $($extraInJournal -join ', ') que NO estan en el plan aprobado actual. Bloqueo seguro."
    }

    foreach ($opId in $journalOpIds) {
        Assert-AdoJournalOperationShapeValid -OperationId $opId -OperationNode $journal.operations.$opId
    }

    return $journal
}

function Write-AdoExecutionJournalAtomic {
    <#
    Escribe el journal de forma atomica: archivo temporal + Move-Item
    -Force (rename atomico dentro del mismo volumen en Windows). Nunca
    dos escritores pueden dejar el archivo a medio escribir.
    #>
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

function Start-AdoJournaledOperation {
    <#
    Bajo lock exclusivo: lee/crea el journal, exige que la operacion este
    'pending' (rechaza sin reintentar si esta succeeded/in-progress/
    ambiguous -- eso es "no reintentar automaticamente"), la marca
    'in-progress' y persiste atomicamente. El archivo de PLAN nunca se
    toca. Devuelve la ruta del journal para usarla luego con
    Complete-AdoJournaledOperation.
    #>
    param(
        [Parameter(Mandatory)] [string]$PlanValidationHash,
        [Parameter(Mandatory)] [string]$OperationId,
        [string[]]$AllOperationIds = @(),
        [int]$LockTimeoutMs = 5000
    )

    $journalPath = Get-AdoExecutionJournalPath -PlanValidationHash $PlanValidationHash
    $lockStream = Lock-AdoJournalFile -LockPath "$journalPath.lock" -TimeoutMs $LockTimeoutMs
    try {
        # Read-AdoExecutionJournal ya garantiza (o lanza) que, si el
        # journal existia, contiene EXACTAMENTE $AllOperationIds -- nunca
        # hace falta (ni se permite) agregar $OperationId aca si no
        # aparecio: eso era precisamente el hueco que revivia una
        # operacion desaparecida como 'pending'.
        $journal = Read-AdoExecutionJournal -JournalPath $journalPath -PlanValidationHash $PlanValidationHash -OperationIds $AllOperationIds

        $opProp = $journal.operations.PSObject.Properties[$OperationId]
        if (-not $opProp) {
            throw "Start-AdoJournaledOperation: inconsistencia interna -- '$OperationId' no aparece en el journal ya validado como exacto contra AllOperationIds. Esto no deberia pasar (bug); bloqueo seguro, no se agrega en silencio."
        }

        $currentState = $opProp.Value.state
        if ($currentState -ne 'pending') {
            throw "Operacion REST rechazada: la operacion '$OperationId' ya tiene estado '$currentState' en el journal de ejecucion ('$journalPath'). No se reintenta automaticamente; una operacion 'ambiguous' exige readback y aprobacion explicita del usuario."
        }

        $opProp.Value.state = 'in-progress'
        $opProp.Value.startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Write-AdoExecutionJournalAtomic -JournalPath $journalPath -Journal $journal
    }
    finally {
        $lockStream.Close()
        $lockStream.Dispose()
    }

    return $journalPath
}

function Complete-AdoJournaledOperation {
    <#
    Bajo lock exclusivo: marca la operacion 'succeeded' o 'ambiguous' y
    persiste atomicamente. Si esta funcion misma falla (no se pudo
    escribir el journal), la operacion queda en 'in-progress' en disco --
    que YA bloquea cualquier reintento automatico por diseno de
    Start-AdoJournaledOperation. El llamador (Invoke-AdoRest) debe tratar
    un fallo aca como estado incierto y nunca reintentar en silencio.
    #>
    param(
        [Parameter(Mandatory)] [string]$JournalPath,
        [Parameter(Mandatory)] [string]$PlanValidationHash,
        [Parameter(Mandatory)] [string]$OperationId,
        [Parameter(Mandatory)] [ValidateSet('succeeded', 'ambiguous')] [string]$FinalState,
        [string[]]$AllOperationIds = @(),
        [string]$ResultId,
        [int]$LockTimeoutMs = 5000
    )

    $lockStream = Lock-AdoJournalFile -LockPath "$JournalPath.lock" -TimeoutMs $LockTimeoutMs
    try {
        # -AllOperationIds debe ser el MISMO conjunto que uso Start- para
        # este mismo journal -- Read-AdoExecutionJournal exige coincidencia
        # exacta contra un journal ya existente (que a esta altura siempre
        # existe: Start- ya lo creo/valido antes de llegar aca).
        $journal = Read-AdoExecutionJournal -JournalPath $JournalPath -PlanValidationHash $PlanValidationHash -OperationIds $AllOperationIds
        $opProp = $journal.operations.PSObject.Properties[$OperationId]
        if (-not $opProp) {
            throw "Complete-AdoJournaledOperation: la operacion '$OperationId' no existe en el journal '$JournalPath'."
        }
        $opProp.Value.state = $FinalState
        $opProp.Value.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        if ($ResultId) { $opProp.Value.resultId = $ResultId }
        Write-AdoExecutionJournalAtomic -JournalPath $JournalPath -Journal $journal
    }
    finally {
        $lockStream.Close()
        $lockStream.Dispose()
    }
}

function Invoke-AdoRest {
    param(
        [Parameter(Mandatory)]
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')]
        [string]$Method,

        [Parameter(Mandatory)]
        [string]$Uri,

        [object]$Body,

        [switch]$RequireApprovedPlan,

        [string]$PlanPath,

        [string]$OperationId,

        [int]$JournalLockTimeoutMs = 5000,

        # Referencias de secretos controladas (ver security.md
        # "Referencias de secretos controladas") -- array de
        # @{ Path='...value'; EnvVarName='ADO_SECRET_...' }. Solo tiene
        # efecto en una escritura ya aprobada: TODAS las validaciones de
        # arriba (bodyHash, spec, journal) corren sobre $Body TAL CUAL
        # (con el placeholder) antes de que esto se use. Depende de
        # New-AdoBodyWithResolvedSecrets (New-AdoClassicPayloads.ps1) ya
        # estar cargada en la sesion -- Apply-AdoClassicPlan.ps1 siempre
        # dot-sourcea ambos archivos antes de llamar Invoke-AdoRest.
        [array]$SecretReferences
    )

    # 1) Validar la URI ANTES de tocar credenciales o construir headers.
    $null = Assert-AdoAllowedUri -Uri $Uri

    $isWrite = $Method -in @('POST', 'PUT', 'DELETE')
    $journalPath = $null
    $planValidationHashForJournal = $null

    if ($isWrite) {
        if (-not $RequireApprovedPlan) {
            throw "Escritura REST rechazada: $Method no paso por el flujo de plan aprobado (-RequireApprovedPlan). Nunca se sustituye este freno por una llamada directa."
        }

        if ([string]::IsNullOrWhiteSpace($PlanPath) -or -not (Test-Path -LiteralPath $PlanPath)) {
            throw "Escritura REST rechazada: no se encontro el archivo de plan indicado. Ejecutar primero Test-AdoClassicPlan.ps1 sobre un plan valido."
        }

        # El plan se LEE, nunca se escribe -- ver Get-AdoPlanCanonicalHash.
        $plan = Get-Content -LiteralPath $PlanPath -Raw | ConvertFrom-Json
        if (-not $plan.validated -or $plan.validated -ne $true) {
            throw "Escritura REST rechazada: el plan no esta marcado validated=true por Test-AdoClassicPlan.ps1."
        }

        if ([string]::IsNullOrWhiteSpace($plan.validationHash)) {
            throw "Escritura REST rechazada: el plan validado no tiene validationHash. Volver a correr Test-AdoClassicPlan.ps1 (version desactualizada del plan)."
        }

        $currentHash = Get-AdoPlanCanonicalHash -Plan $plan
        if ($currentHash -ne $plan.validationHash) {
            throw "Escritura REST rechazada: el contenido del plan cambio despues de la validacion (validationHash no coincide). Volver a correr Test-AdoClassicPlan.ps1 sobre la version actual antes de aplicar."
        }

        # Manifiesto de operaciones aprobadas: una escritura solo procede
        # si coincide EXACTAMENTE (method + uri + bodyHash) con una
        # entrada de plan.approvedOperations. Un plan sin ese manifiesto
        # (o vacio) rechaza toda escritura.
        if ([string]::IsNullOrWhiteSpace($OperationId)) {
            throw "Escritura REST rechazada: falta -OperationId. Toda escritura debe corresponder a una operacion especifica de plan.approvedOperations."
        }

        # OJO doble con arrays de 1 elemento en Windows PowerShell 5.1:
        #  1) @($plan.approvedOperations) cuando la propiedad no existe
        #     devuelve un array de 1 elemento CONTENIENDO $null (no un
        #     array vacio) -- se comprueba $null primero.
        #  2) "$x = if (cond) {@()} else {@($y)}" COLAPSA un array de 1
        #     elemento al escalar que contiene -- por eso NO se usa
        #     if/else como expresion aca.
        $approvedOps = @()
        if ($null -ne $plan.approvedOperations) {
            $approvedOps = @($plan.approvedOperations)
        }
        if ($approvedOps.Count -eq 0) {
            throw "Escritura REST rechazada: el plan no tiene approvedOperations (manifiesto vacio o ausente). No hay ninguna operacion aprobada para escribir."
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

        $actualBodyHash = Get-AdoBodyCanonicalHash -Body $Body
        if ($matchedOp.bodyHash -ne $actualBodyHash) {
            throw "Escritura REST rechazada: el bodyHash aprobado para '$OperationId' no coincide con el body solicitado (el body pudo haber sido modificado)."
        }

        # Defensa en profundidad: re-deriva y valida desde CERO (metodo,
        # host, ruta exacta, query exacta) que esta escritura cumple el
        # contrato de $matchedOp.operationType, sin confiar en que
        # Test-AdoClassicPlan.ps1 ya lo haya validado -- misma funcion
        # que usa ese validador, ver Assert-AdoOperationRequestMatchesSpec.
        $null = Assert-AdoOperationRequestMatchesSpec -OperationType ([string]$matchedOp.operationType) -Method $Method -Uri $Uri -Label $OperationId -ExpectedProject ([string]$plan.project)

        # A partir de aca, "ya se uso / esta en curso" se decide con el
        # JOURNAL, nunca con el plan (que sigue sin tocarse). Si esto
        # lanza (estado != pending, o no se pudo tomar el lock), NO se
        # llega a la red -- cero POST.
        $planValidationHashForJournal = $plan.validationHash
        $allOpIds = @($approvedOps | ForEach-Object { $_.operationId })
        $journalPath = Start-AdoJournaledOperation -PlanValidationHash $planValidationHashForJournal -OperationId $OperationId -AllOperationIds $allOpIds -LockTimeoutMs $JournalLockTimeoutMs
    }

    $headers = Get-AdoAuthHeader
    $headers['Content-Type'] = 'application/json'

    $invokeParams = @{
        Method             = $Method
        Uri                = $Uri
        Headers            = $headers
        MaximumRedirection = 0
        UseBasicParsing    = $true
    }

    if ($null -ne $Body) {
        # $bodyToSend es SIEMPRE $Body salvo que -SecretReferences traiga
        # algo que resolver -- en cuyo caso se arma una COPIA con los
        # valores reales sustituidos en memoria (ver
        # New-AdoBodyWithResolvedSecrets). $Body en si NUNCA se muta: es
        # lo unico que ya se hasheo/comparo mas arriba, y debe seguir
        # siendo exactamente eso para cualquier chequeo futuro. La copia
        # resuelta jamas se hashea, jamas se escribe a disco ni a un
        # mensaje de error -- solo se usa para ESTA llamada de red.
        $bodyToSend = $Body
        if ($SecretReferences -and @($SecretReferences).Count -gt 0) {
            $bodyToSend = New-AdoBodyWithResolvedSecrets -Body $Body -SecretReferences @($SecretReferences)
        }
        # Convertir explicitamente a bytes UTF-8 antes de pasarlo a
        # Invoke-WebRequest. En Windows PowerShell 5.1, un -Body de tipo
        # [string] se codifica con el codepage POR DEFECTO DEL SISTEMA
        # (aca Windows-1252) cuando el Content-Type se fija via -Headers
        # en vez de via el parametro dedicado -ContentType -- nunca UTF-8
        # por si solo. Cualquier caracter no-ASCII (tildes, guion largo,
        # etc., realistas en un org de habla hispana) queda mal codificado:
        # a veces Azure DevOps lo rechaza de entrada (400, deserializacion
        # fallida -- el caso "con suerte"), y a veces el resultado sigue
        # siendo JSON valido pero con el caracter YA CORROMPIDO, sin error
        # alguno. Pasar un byte[] evita que Invoke-WebRequest reinterprete
        # la codificacion: se transmite tal cual.
        $jsonBodyToSend = $bodyToSend | ConvertTo-Json -Depth 20
        $invokeParams['Body'] = [System.Text.Encoding]::UTF8.GetBytes($jsonBodyToSend)
    }

    # La llamada de red vive en SU PROPIO try/catch, separado de la
    # actualizacion del journal a 'succeeded'. Esto es deliberado: si la
    # red falla, el catch de aca abajo marca 'ambiguous' (estado real
    # incierto). Pero si la red SI tuvo exito y es la actualizacion del
    # journal a 'succeeded' la que falla despues (ver mas abajo), esa
    # excepcion NO debe caer de vuelta en este mismo catch -- si lo
    # hiciera, este bloque la reclasificaria como 'ambiguous' y
    # sobrescribiria el 'in-progress' que ya es la evidencia correcta de
    # "la red confirmo, pero no se pudo registrar" (mezclar ambos casos
    # bajo el mismo catch fue un bug real encontrado por las pruebas de
    # este mismo cambio).
    $response = $null
    try {
        # Se usa Invoke-WebRequest (no Invoke-RestMethod) para poder leer
        # los headers de RESPUESTA (paginacion via
        # x-ms-continuationtoken), sin exponer nunca el header
        # Authorization de la SOLICITUD que enviamos.
        $response = Invoke-WebRequest @invokeParams
    }
    catch {
        if ($isWrite -and $journalPath) {
            # No se puede determinar con certeza si Azure DevOps recibio o
            # proceso la solicitud (podria haber fallado antes de llegar,
            # durante, o solo la respuesta se perdio) -- se marca
            # 'ambiguous', que exige readback y aprobacion explicita antes
            # de cualquier otro intento. Si ni siquiera esto se puede
            # escribir, la entrada queda en 'in-progress', que tambien
            # bloquea reintentos automaticos.
            try {
                Complete-AdoJournaledOperation -JournalPath $journalPath -PlanValidationHash $planValidationHashForJournal -OperationId $OperationId -FinalState 'ambiguous' -AllOperationIds $allOpIds -LockTimeoutMs $JournalLockTimeoutMs
            }
            catch {
                # Silenciosamente no se pudo marcar ambiguous -- igual
                # queda protegido por el estado 'in-progress' ya escrito.
            }
        }
        # No incluir $headers ni el cuerpo de la solicitud en el mensaje de
        # error. El BODY DE RESPUESTA de Azure DevOps (no la solicitud) es
        # el mensaje de validacion del propio servicio (ej. "TF400xxx: ...")
        # -- no contiene el Authorization ni el body que enviamos, asi que
        # es seguro incluirlo (truncado) para poder diagnosticar un 400/409
        # real sin tener que repetir la escritura a ciegas. Si no se puede
        # leer (ej. fallo de red real, sin respuesta HTTP), se ignora en
        # silencio y el mensaje original de $_.Exception.Message alcanza.
        $remoteDetail = ''
        try {
            # En Windows PowerShell 5.1, Invoke-WebRequest ya deja el body de
            # respuesta de un error HTTP en $_.ErrorDetails.Message (mas
            # confiable que leer el stream a mano, que puede venir ya
            # consumido/cerrado). Se intenta primero eso; el stream manual
            # queda como fallback por si ErrorDetails viene vacio.
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
            # No se pudo leer el body de respuesta -- se ignora, el mensaje
            # original ya se va a lanzar igual.
        }
        throw "Invoke-AdoRest fallo: $Method -> $($_.Exception.Message)$remoteDetail"
    }

    # Si llegamos aca, la llamada de red SI tuvo exito -- fuera del
    # try/catch de arriba a proposito (ver comentario mas arriba).
    $responseBody = $null
    if ($response.Content) {
        try {
            $responseBody = $response.Content | ConvertFrom-Json
        }
        catch {
            # Algunos endpoints de solo lectura (ej. logs de tareas de
            # Release clasico) devuelven texto plano, no JSON. Nunca es un
            # endpoint de escritura (esos siempre son JSON) -- degradar a
            # devolver el texto crudo tal cual, en vez de fallar la
            # lectura completa por un formato de respuesta distinto.
            $responseBody = $response.Content
        }
    }

    # Allowlist explicita de headers de respuesta a conservar -- nunca se
    # retiene un header que este helper no necesite (cookies, tracing,
    # etc.), aunque Authorization tampoco viene nunca en la respuesta.
    $sanitizedHeaders = @{}
    foreach ($key in $response.Headers.Keys) {
        if ($script:AdoAllowedResponseHeaders -icontains $key) {
            $sanitizedHeaders[$key] = $response.Headers[$key]
        }
    }

    if ($isWrite -and $journalPath) {
        $resultId = $null
        if ($responseBody -and ($responseBody.PSObject.Properties.Name -contains 'id')) {
            $resultId = [string]$responseBody.id
        }
        # Sin try/catch propio alrededor de este bloque en el scope de la
        # funcion: si esto lanza, la excepcion sale de Invoke-AdoRest tal
        # cual, SIN pasar por el catch de la llamada de red de arriba
        # (ese catch ya termino). La entrada del journal quedo
        # 'in-progress' (escrita ANTES de la llamada de red), que ya
        # bloquea cualquier reintento automatico -- no hace falta (ni se
        # quiere) reclasificarla como 'ambiguous' aca.
        try {
            Complete-AdoJournaledOperation -JournalPath $journalPath -PlanValidationHash $planValidationHashForJournal -OperationId $OperationId -FinalState 'succeeded' -ResultId $resultId -AllOperationIds $allOpIds -LockTimeoutMs $JournalLockTimeoutMs
        }
        catch {
            throw "Invoke-AdoRest: la operacion '$OperationId' fue CONFIRMADA por Azure DevOps, pero no se pudo actualizar el journal de ejecucion despues ('$($_.Exception.Message)'). Estado incierto -- NO reintentar automaticamente. Verificar manualmente (readback) y corregir el journal antes de cualquier otra accion."
        }
    }

    return [PSCustomObject]@{
        Body       = $responseBody
        Headers    = $sanitizedHeaders
        StatusCode = [int]$response.StatusCode
    }
}

function Get-AdoContinuationToken {
    <#
    Extrae el continuation token de los headers de respuesta de
    Invoke-AdoRest (case-insensitive; distintos endpoints de Azure DevOps
    usan 'x-ms-continuationtoken'). Devuelve $null si no hay mas paginas.
    #>
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

function Get-AdoRestAllPages {
    <#
    Consume todas las paginas que Azure DevOps ANUNCIE mediante el header
    de respuesta 'x-ms-continuationtoken' para el endpoint dado. Para un
    endpoint que no documenta paginacion (nunca devuelve ese header), esto
    procesa una unica pagina con la respuesta completa segun el contrato
    de esa API -- no se asume que agregar un continuationToken convierta
    automaticamente cualquier endpoint en paginado.

    Se corta con excepcion (nunca en silencio, nunca aceptando una
    pagina como valida "por si acaso") si:
      - la respuesta no trae codigo HTTP de exito (2xx);
      - el body es $null;
      - el body no tiene la propiedad 'value';
      - 'value' no es un formato compatible con una coleccion (string,
        numero, booleano, objeto escalar suelto -- SI se acepta un array
        vacio '[]', que es una coleccion valida sin items);
      - se alcanzaria una pagina mas alla de -MaxPages (el limite se
        verifica ANTES de pedir la siguiente pagina, nunca despues: con
        MaxPages=3 nunca se hace una 4a llamada);
      - se detecta un continuation token repetido (ciclo).

    Nunca hace mas llamadas de red de las necesarias. Cada llamada pasa
    por Invoke-AdoRest (misma validacion de URI, sin excepciones).
    #>
    param(
        [Parameter(Mandatory)]
        [string]$BaseUri,

        [int]$MaxPages = 200
    )

    if ($MaxPages -lt 1) {
        throw "Get-AdoRestAllPages: -MaxPages debe ser al menos 1 (recibido: $MaxPages)."
    }

    $allItems = [System.Collections.Generic.List[object]]::new()
    $seenTokens = [System.Collections.Generic.HashSet[string]]::new()
    $continuationToken = $null
    $pageCount = 0

    do {
        # Verificar el limite ANTES de pedir la siguiente pagina -- con
        # MaxPages=3 esto corta despues de la 3a llamada exitosa, nunca
        # se llega a hacer una 4a.
        if ($pageCount -ge $MaxPages) {
            throw "Get-AdoRestAllPages: se alcanzo el limite de $MaxPages pagina(s) sin agotar la paginacion (habia mas contenido pendiente). Posible bucle o comportamiento inesperado de la API; se corta ANTES de pedir una pagina adicional."
        }

        $uri = $BaseUri
        if ($continuationToken) {
            $separator = if ($uri -match '\?') { '&' } else { '?' }
            $uri = "$uri$separator" + 'continuationToken=' + [uri]::EscapeDataString($continuationToken)
        }

        $result = Invoke-AdoRest -Method GET -Uri $uri
        $pageCount++

        if ($result.StatusCode -lt 200 -or $result.StatusCode -ge 300) {
            throw "Get-AdoRestAllPages: la pagina $pageCount devolvio un codigo HTTP no exitoso ($($result.StatusCode))."
        }

        if ($null -eq $result.Body) {
            throw "Get-AdoRestAllPages: la pagina $pageCount tiene body nulo. No se acepta como pagina vacia valida."
        }

        if ($result.Body.PSObject.Properties.Name -notcontains 'value') {
            throw "Get-AdoRestAllPages: la pagina $pageCount no tiene la propiedad 'value' en el body. No se acepta como pagina vacia valida."
        }

        if (-not (Test-AdoValueIsCollectionCompatible -Value $result.Body.value)) {
            $actualTypeName = if ($null -eq $result.Body.value) { '$null' } else { $result.Body.value.GetType().FullName }
            throw "Get-AdoRestAllPages: la pagina $pageCount tiene 'value' con un formato incompatible con una coleccion (tipo: $actualTypeName)."
        }

        foreach ($item in @($result.Body.value)) { $allItems.Add($item) }

        $nextToken = Get-AdoContinuationToken -Headers $result.Headers

        if ($nextToken) {
            if (-not $seenTokens.Add($nextToken)) {
                throw "Get-AdoRestAllPages: se detecto un ciclo de continuation tokens (token repetido tras $pageCount pagina(s)). Se corta para evitar un bucle infinito; esto indica una API inesperada o una respuesta simulada incorrecta."
            }
        }

        $continuationToken = $nextToken
    } while ($continuationToken)

    return [PSCustomObject]@{
        Items        = @($allItems)
        PagesFetched = $pageCount
    }
}

# Constantes de organizacion - no secretas, seguras de exponer.
$script:AdoCoreBaseUrl = 'https://dev.azure.com/Shared-Service-GM'
$script:AdoReleaseBaseUrl = 'https://vsrm.dev.azure.com/Shared-Service-GM'
$script:AdoProject = 'DevOps'
$script:AdoApiVersion = '7.1'
