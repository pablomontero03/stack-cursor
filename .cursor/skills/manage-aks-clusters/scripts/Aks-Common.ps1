<#
Libreria compartida de este dominio (AKS/Kubernetes/Helm), dot-sourceada
por los demas scripts de scripts\. Mismos principios de robustez que
Invoke-AdoRest.ps1 del dominio Azure DevOps Pipelines (hash canonico,
journal con lock exclusivo de archivo, escritura atomica) adaptados a
planes de cambio sobre recursos Kubernetes.
#>

function Get-AksKubectlConnectionArgs {
    <#
    Arma los argumentos de conexion (--context, y --kubeconfig si se
    especifico uno) para anteponer a cualquier invocacion de kubectl. Los
    clusteres reales de este proyecto casi siempre requieren
    -KubeconfigPath explicito porque viven en kubeconfigs exportados por
    Lens, no en $env:USERPROFILE\.kube\config -- ver
    references/kubeconfig-and-contexts.md § Clusteres reales conocidos.
    #>
    param([Parameter(Mandatory)] [string]$Context, [string]$KubeconfigPath)

    $connArgs = @('--context', $Context)
    if ($KubeconfigPath) {
        $connArgs += @('--kubeconfig', $KubeconfigPath)
    }
    return $connArgs
}

function Get-AksProjectRoot {
    $here = $PSScriptRoot
    # scripts\ -> manage-aks-clusters\ -> skills\ -> .kiro\ -> raiz del proyecto
    return (Resolve-Path (Join-Path $here '..\..\..\..')).Path
}

function Get-AksLocalRoot {
    return Join-Path (Get-AksProjectRoot) '.local\aks'
}

function Get-AksInventoryDir { return Join-Path (Get-AksLocalRoot) 'inventory' }
function Get-AksPlansDir { return Join-Path (Get-AksLocalRoot) 'plans' }
function Get-AksBackupsDir { return Join-Path (Get-AksLocalRoot) 'backups' }
function Get-AksExecutionsDir { return Join-Path (Get-AksLocalRoot) 'executions' }
function Get-AksLogsDir { return Join-Path (Get-AksLocalRoot) 'logs' }

function Assert-AksDirectoryExists {
    param([Parameter(Mandatory)] [string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) {
        New-Item -ItemType Directory -Force -Path $Path | Out-Null
    }
}

function Get-AksResolvedKubeconfigPaths {
    <#
    Orden de resolucion (ver references/kubeconfig-and-contexts.md):
      1. $env:KUBECONFIG -- en Windows puede traer varias rutas separadas
         por ';'.
      2. Si no existe o esta vacio, fallback a
         $env:USERPROFILE\.kube\config.
    Devuelve un array de rutas (nunca su contenido).
    #>
    $envValue = $env:KUBECONFIG
    if (-not [string]::IsNullOrWhiteSpace($envValue)) {
        return @($envValue -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } | ForEach-Object { $_.Trim() })
    }

    $defaultPath = Join-Path $env:USERPROFILE '.kube\config'
    return @($defaultPath)
}

function Get-AksPlanCanonicalHash {
    <#
    SHA-256 sobre el contenido canonico del plan -- todo EXCEPTO los
    campos que el propio proceso de validacion escribe (validated,
    validationHash, validationEvidence). Cualquier edicion manual del plan
    despues de validarlo (incluida approvedOperations) cambia este hash,
    y Apply-AksChangePlan.ps1 lo rechaza.
    #>
    param([Parameter(Mandatory)] $Plan)

    $clone = $Plan | Select-Object * -ExcludeProperty validated, validationHash, validationEvidence
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

function New-AksOperationId {
    param([Parameter(Mandatory)] [string]$Kind, [Parameter(Mandatory)] [string]$ResourceKind, [Parameter(Mandatory)] [string]$ResourceName, [string]$Namespace = '')
    $suffix = if ($Namespace) { "$Namespace-$ResourceName" } else { $ResourceName }
    return "$Kind-$ResourceKind-$suffix".ToLowerInvariant() -replace '[^a-z0-9-]', '-'
}

function Get-AksExecutionJournalPath {
    param([Parameter(Mandatory)] [string]$PlanValidationHash)
    return Join-Path (Get-AksExecutionsDir) "$PlanValidationHash.json"
}

function Lock-AksJournalFile {
    <#
    Abre (o crea) un archivo de lock con FileShare.None -- exclusivo. Si
    otro proceso ya lo tiene abierto, reintenta con backoff corto hasta
    -TimeoutMs. Devuelve el FileStream abierto; el llamador DEBE cerrarlo
    en un finally para liberar el lock.
    #>
    param([Parameter(Mandatory)] [string]$LockPath, [int]$TimeoutMs = 5000)

    $dir = Split-Path -Parent $LockPath
    Assert-AksDirectoryExists -Path $dir

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

function Read-AksExecutionJournal {
    <#
    Lee el journal. Si no existe, devuelve uno nuevo con TODOS los
    -OperationIds en 'pending'. Si ya existe, exige el MISMO conjunto
    exacto de operationIds (ni falta ni sobra ninguno) y que cada entrada
    tenga forma y estado validos -- cualquier desvio es journal corrupto,
    bloqueo seguro (excepcion).
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

    $validStates = @('pending', 'in-progress', 'succeeded', 'ambiguous')
    foreach ($opId in $journalOpIds) {
        $state = [string]$journal.operations.$opId.state
        if ($validStates -notcontains $state) {
            throw "Journal de ejecucion corrupto en '$JournalPath': la operacion '$opId' tiene un estado invalido ('$state'). Bloqueo seguro."
        }
    }

    return $journal
}

function Write-AksExecutionJournalAtomic {
    <#
    Escribe el journal de forma atomica: archivo temporal + Move-Item
    -Force (rename atomico dentro del mismo volumen en Windows).
    #>
    param([Parameter(Mandatory)] [string]$JournalPath, [Parameter(Mandatory)] $Journal)

    $dir = Split-Path -Parent $JournalPath
    Assert-AksDirectoryExists -Path $dir

    $tmpPath = "$JournalPath.tmp-$([Guid]::NewGuid().ToString('N'))"
    try {
        $Journal | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath $tmpPath -Encoding utf8
        Move-Item -LiteralPath $tmpPath -Destination $JournalPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $tmpPath) { Remove-Item -LiteralPath $tmpPath -Force -ErrorAction SilentlyContinue }
    }
}

function Start-AksJournaledOperation {
    <#
    Bajo lock exclusivo: lee/crea el journal, exige que la operacion este
    'pending' (si esta succeeded/in-progress/ambiguous, se omite -- "no
    reintentar automaticamente" -- y devuelve $false), la marca
    'in-progress' y persiste antes de devolver $true (el llamador recien
    ahi ejecuta la operacion real).
    #>
    param(
        [Parameter(Mandatory)] [string]$PlanValidationHash,
        [Parameter(Mandatory)] [string[]]$AllOperationIds,
        [Parameter(Mandatory)] [string]$OperationId
    )

    $journalPath = Get-AksExecutionJournalPath -PlanValidationHash $PlanValidationHash
    $lockPath = "$journalPath.lock"
    $lockStream = Lock-AksJournalFile -LockPath $lockPath

    try {
        $journal = Read-AksExecutionJournal -JournalPath $journalPath -PlanValidationHash $PlanValidationHash -OperationIds $AllOperationIds
        $op = $journal.operations.$OperationId

        if ($op.state -ne 'pending') {
            Write-Host "Operacion '$OperationId': ya estaba '$($op.state)' en el journal de una corrida anterior -- se omite, no se reintenta." -ForegroundColor Yellow
            return $false
        }

        $op.state = 'in-progress'
        $op.startedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        Write-AksExecutionJournalAtomic -JournalPath $journalPath -Journal $journal
        return $true
    }
    finally {
        $lockStream.Close()
    }
}

function ConvertTo-AksIntOrPercent {
    <#
    Normaliza un valor de maxSurge/maxUnavailable (entero absoluto o
    porcentaje 'NN%', igual que el campo `RollingUpdateDeployment` de
    Kubernetes) a un entero absoluto sobre $Total. Redondeo hacia arriba
    para maxSurge, hacia abajo para maxUnavailable -- mismo criterio que el
    controller de Deployments de Kubernetes.
    #>
    param(
        [Parameter(Mandatory)] $Value,
        [Parameter(Mandatory)] [int]$Total,
        [Parameter(Mandatory)] [ValidateSet('up', 'down')] [string]$Rounding
    )
    if ($null -eq $Value -or [string]::IsNullOrWhiteSpace([string]$Value)) { return 0 }
    $s = ([string]$Value).Trim()
    if ($s -match '^(\d+)\s*%$') {
        $pct = [double]$Matches[1]
        $raw = ($Total * $pct) / 100.0
        if ($Rounding -eq 'up') { return [int][Math]::Ceiling($raw) } else { return [int][Math]::Floor($raw) }
    }
    return [int]$s
}

function Get-AksCapacityAssessment {
    <#
    Evaluacion pura y determinista de capacidad de pods antes de un
    rollout -- no invoca kubectl; recibe objetos ya obtenidos (p. ej. de
    `kubectl get nodes -o json`, `kubectl get pods -A -o json` y
    `kubectl get deployment ... -o json`, ya deserializados con
    ConvertFrom-Json) para que sea 100% mockeable en pruebas offline. Ver
    references/capacity-validation.md para la formula completa.

    Devuelve un objeto con: capacityOk (bool), requiredExtraPods,
    availableFreeSlots, perNode (detalle por nodo elegible), y reasons
    (lista de motivos cuando capacityOk es $false).
    #>
    param(
        [Parameter(Mandatory)] [array]$Nodes,
        [Parameter(Mandatory)] [array]$Pods,
        [Parameter(Mandatory)] $Deployment
    )

    $desiredReplicas = [int]$Deployment.spec.replicas
    if ($desiredReplicas -le 0) { $desiredReplicas = 1 }

    $strategy = $Deployment.spec.strategy
    $rollingUpdate = if ($strategy -and $strategy.type -eq 'RollingUpdate') { $strategy.rollingUpdate } else { $null }
    $maxSurgeRaw = if ($rollingUpdate -and $null -ne $rollingUpdate.maxSurge) { $rollingUpdate.maxSurge } else { '25%' }
    $maxUnavailableRaw = if ($rollingUpdate -and $null -ne $rollingUpdate.maxUnavailable) { $rollingUpdate.maxUnavailable } else { '25%' }

    $maxSurge = ConvertTo-AksIntOrPercent -Value $maxSurgeRaw -Total $desiredReplicas -Rounding 'up'
    $maxUnavailable = ConvertTo-AksIntOrPercent -Value $maxUnavailableRaw -Total $desiredReplicas -Rounding 'down'

    # Requisito minimo del controller: si ambos redondean a 0, maxSurge se
    # fuerza a 1 (evita un deployment que nunca puede progresar).
    if ($maxSurge -eq 0 -and $maxUnavailable -eq 0) { $maxSurge = 1 }

    $desiredNodeSelector = $Deployment.spec.template.spec.nodeSelector
    $desiredTolerationKeys = @($Deployment.spec.template.spec.tolerations | ForEach-Object { [string]$_.key } | Where-Object { $_ })

    $eligibleNodes = @()
    foreach ($node in $Nodes) {
        $ready = $false
        foreach ($cond in @($node.status.conditions)) {
            if ($cond.type -eq 'Ready' -and $cond.status -eq 'True') { $ready = $true }
        }
        if (-not $ready) { continue }

        $matchesSelector = $true
        if ($desiredNodeSelector) {
            foreach ($key in $desiredNodeSelector.PSObject.Properties.Name) {
                $expected = [string]$desiredNodeSelector.$key
                $actual = [string]$node.metadata.labels.$key
                if ($actual -ne $expected) { $matchesSelector = $false; break }
            }
        }
        if (-not $matchesSelector) { continue }

        $nodeTaintKeys = @($node.spec.taints | Where-Object { $_.effect -in @('NoSchedule', 'NoExecute') } | ForEach-Object { [string]$_.key })
        $untoleratedTaints = @($nodeTaintKeys | Where-Object { $desiredTolerationKeys -notcontains $_ })
        if ($untoleratedTaints.Count -gt 0) { continue }

        $allocatablePods = [int]$node.status.allocatable.pods
        $nonTerminalPodCount = @($Pods | Where-Object {
                $_.spec.nodeName -eq $node.metadata.name -and $_.status.phase -notin @('Succeeded', 'Failed')
            }).Count
        $freeSlots = $allocatablePods - $nonTerminalPodCount

        $eligibleNodes += [PSCustomObject]@{
            node                 = [string]$node.metadata.name
            allocatablePods      = $allocatablePods
            nonTerminalPodCount  = $nonTerminalPodCount
            freeSlots            = $freeSlots
        }
    }

    $totalFreeSlots = ($eligibleNodes | Measure-Object -Property freeSlots -Sum).Sum
    if ($null -eq $totalFreeSlots) { $totalFreeSlots = 0 }

    $reasons = [System.Collections.Generic.List[string]]::new()
    if ($eligibleNodes.Count -eq 0) {
        $reasons.Add('Ningun nodo Ready cumple el nodeSelector/tolerations del Deployment.')
    }
    $capacityOk = ($eligibleNodes.Count -gt 0) -and ($totalFreeSlots -ge $maxSurge)
    if (-not $capacityOk -and $eligibleNodes.Count -gt 0) {
        $reasons.Add("Margen insuficiente: se requieren $maxSurge pod(s) adicionales (maxSurge) y solo hay $totalFreeSlots slot(s) libre(s) en nodos elegibles.")
    }
    if ($maxUnavailable -eq 0) {
        $reasons.Add('maxUnavailable=0: el/los pod(s) nuevo(s) deben poder programarse ANTES de retirar cualquier pod anterior.')
    }

    return [PSCustomObject]@{
        desiredReplicas       = $desiredReplicas
        maxSurge              = $maxSurge
        maxUnavailable        = $maxUnavailable
        requiredExtraPods     = $maxSurge
        availableFreeSlots    = $totalFreeSlots
        eligibleNodeCount     = $eligibleNodes.Count
        perNode               = $eligibleNodes
        capacityOk            = $capacityOk
        reasons               = @($reasons)
    }
}

function Get-AksRolloutClassification {
    <#
    Clasificacion determinista del estado de un rollout ya leido (readback)
    contra los 4 estados de Kubernetes de la tabla obligatoria del ciclo de
    pipeline de aplicacion (ver
    ..\..\orchestrate-application-pipeline-cycle\references\status-timing-and-memory.md):
    'Despliegue completado', 'Despliegue incompleto', 'Despliegue fallido',
    y el flag independiente `previousVersionServing`.
    #>
    param(
        [Parameter(Mandatory)] [int]$DesiredReplicas,
        [Parameter(Mandatory)] [int]$UpdatedReplicas,
        [Parameter(Mandatory)] [int]$ReadyReplicas,
        [Parameter(Mandatory)] [int]$AvailableReplicas,
        [string]$ExpectedImage,
        [string[]]$NewPodImages = @(),
        [int]$PendingNewPods = 0,
        [switch]$TimedOut
    )

    $imagesMatch = $true
    if ($ExpectedImage -and $NewPodImages.Count -gt 0) {
        $imagesMatch = -not (@($NewPodImages | Where-Object { $_ -ne $ExpectedImage })).Count
    }

    $previousVersionServing = ($AvailableReplicas -gt 0) -and ($UpdatedReplicas -lt $DesiredReplicas -or $ReadyReplicas -lt $UpdatedReplicas)

    $completed = ($UpdatedReplicas -eq $DesiredReplicas) -and ($ReadyReplicas -eq $DesiredReplicas) -and ($AvailableReplicas -eq $DesiredReplicas) -and $imagesMatch -and ($PendingNewPods -eq 0)

    if ($completed) {
        $state = 'Despliegue completado'
    }
    elseif ($TimedOut -or $PendingNewPods -gt 0 -or $UpdatedReplicas -lt $DesiredReplicas) {
        $state = if ($TimedOut) { 'Despliegue incompleto' } else { 'Despliegue incompleto' }
    }
    else {
        $state = 'Despliegue fallido'
    }

    return [PSCustomObject]@{
        state                   = $state
        previousVersionServing  = $previousVersionServing
        imagesMatch             = $imagesMatch
    }
}

function Complete-AksJournaledOperation {
    param(
        [Parameter(Mandatory)] [string]$PlanValidationHash,
        [Parameter(Mandatory)] [string[]]$AllOperationIds,
        [Parameter(Mandatory)] [string]$OperationId,
        [ValidateSet('succeeded', 'ambiguous')] [string]$FinalState = 'succeeded',
        [string]$ResultId = $null
    )

    $journalPath = Get-AksExecutionJournalPath -PlanValidationHash $PlanValidationHash
    $lockPath = "$journalPath.lock"
    $lockStream = Lock-AksJournalFile -LockPath $lockPath

    try {
        $journal = Read-AksExecutionJournal -JournalPath $journalPath -PlanValidationHash $PlanValidationHash -OperationIds $AllOperationIds
        $op = $journal.operations.$OperationId
        $op.state = $FinalState
        $op.completedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        $op.resultId = $ResultId
        Write-AksExecutionJournalAtomic -JournalPath $journalPath -Journal $journal
    }
    finally {
        $lockStream.Close()
    }
}
