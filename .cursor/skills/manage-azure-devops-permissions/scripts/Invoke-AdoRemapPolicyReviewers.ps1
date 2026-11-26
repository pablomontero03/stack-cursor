<#
Reemplaza el grupo reviewer en las políticas de tipo "Required reviewers"
de un proyecto destino, cambiando un reviewer ID foráneo por el del grupo
Code-Reviewers del propio proyecto.

Caso de uso principal: después de replicar Branch Policies desde un proyecto
modelo (ej: Buklo), las políticas "Required reviewers" quedan apuntando al
Code-Reviewers del modelo — este script las corrige para que apunten al
Code-Reviewers del proyecto destino.

MODO AUTODETECT (recomendado — sin pasar OldReviewerId ni NewReviewerId):
  El script detecta automáticamente:
  - OldReviewerId: leyendo las políticas Required reviewers actuales del
    proyecto y tomando cualquier reviewer ID que NO pertenezca al propio
    proyecto (identity cuyo dominio no coincide con Project).
  - NewReviewerId: resolviendo el grupo "Code-Reviewers" del proyecto destino
    via Graph API (GET graph/groups?scopeDescriptor=<scope>) -> identities.

  pwsh -File Invoke-AdoRemapPolicyReviewers.ps1 -Project 'Database-Administration-and-Monitoring'

MODO EXPLICITO (cuando los IDs ya son conocidos):
  pwsh -File Invoke-AdoRemapPolicyReviewers.ps1 `
    -Project 'Database-Administration-and-Monitoring' `
    -OldReviewerId '5fcb8ce3-a8b0-4625-8dde-3d7fc4241389' `
    -NewReviewerId '2aef8f76-9f1b-49c7-99b9-8f2cb79af9f2'

Regla canónica: las políticas "Required reviewers" SIEMPRE deben referenciar
el grupo Code-Reviewers del MISMO proyecto donde viven los repos.
Nunca dejar un reviewer de otro proyecto (ej [Buklo]\Code-Reviewers) en repos
de otro proyecto. Confirmado y documentado 2026-09-17.
#>

param(
    [Parameter(Mandatory)] [string]$Project,
    [string]$OldReviewerId = '',
    [string]$NewReviewerId = '',
    [switch]$DryRun
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Resolver PAT
# ---------------------------------------------------------------------------
$pat = $env:AZURE_DEVOPS_PAT
if ([string]::IsNullOrWhiteSpace($pat)) {
    $envFile = Join-Path $PSScriptRoot '../../../../env/.env'
    if (-not (Test-Path $envFile)) {
        $envFile = (Get-ChildItem (Join-Path $PSScriptRoot '..') -Filter '.env' -Recurse -ErrorAction SilentlyContinue | Select-Object -First 1).FullName
    }
    if ($envFile -and (Test-Path $envFile)) {
        $pat = (Get-Content $envFile | Where-Object { $_ -match '^AZURE_DEVOPS_PAT=' }) -replace '^AZURE_DEVOPS_PAT=',''
    }
}
if ([string]::IsNullOrWhiteSpace($pat)) { throw "No se encontro AZURE_DEVOPS_PAT en entorno ni en env/.env" }

$auth    = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes(":$pat"))
$headers = @{ Authorization = "Basic $auth"; 'Content-Type' = 'application/json' }
$coreBase  = "https://dev.azure.com/Shared-Service-GM"
$graphBase = "https://vssps.dev.azure.com/Shared-Service-GM"
$policyBase = "$coreBase/$([uri]::EscapeDataString($Project))/_apis/policy"

Write-Host "Proyecto destino: $Project" -ForegroundColor Cyan
if ($DryRun) { Write-Host "[DRY-RUN — sin cambios en ADO]" -ForegroundColor Yellow }

# ---------------------------------------------------------------------------
# Obtener todas las políticas Required reviewers del proyecto
# ---------------------------------------------------------------------------
$all   = Invoke-RestMethod "$policyBase/configurations?api-version=7.1" -Headers $headers
$reqRev = @($all.value | Where-Object { $_.type.displayName -eq 'Required reviewers' })
Write-Host "Políticas 'Required reviewers' encontradas: $($reqRev.Count)" -ForegroundColor Cyan

if ($reqRev.Count -eq 0) {
    Write-Host "No hay políticas Required reviewers. Nada que corregir." -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# AUTODETECT: resolver OldReviewerId y NewReviewerId si no se pasaron
# ---------------------------------------------------------------------------
if ([string]::IsNullOrWhiteSpace($OldReviewerId) -or [string]::IsNullOrWhiteSpace($NewReviewerId)) {
    Write-Host "Modo autodetect activado..." -ForegroundColor Cyan

    # 1. Resolver el scope descriptor del proyecto destino
    $projResult   = Invoke-RestMethod "$coreBase/_apis/projects/$([uri]::EscapeDataString($Project))?api-version=7.1" -Headers $headers
    $projId       = $projResult.id
    $scopeResult  = Invoke-RestMethod "$graphBase/_apis/graph/descriptors/$projId?api-version=7.1-preview.1" -Headers $headers
    $scopeDesc    = $scopeResult.value
    Write-Host "  scopeDescriptor: $scopeDesc" -ForegroundColor Gray

    # 2. Listar grupos del proyecto destino y encontrar Code-Reviewers
    $groupsResult = Invoke-RestMethod "$graphBase/_apis/graph/groups?scopeDescriptor=$([uri]::EscapeDataString($scopeDesc))&api-version=7.1-preview.1" -Headers $headers
    $crGroup      = $groupsResult.value | Where-Object { $_.displayName -like '*Code-Reviewers*' } | Select-Object -First 1
    if (-not $crGroup) { throw "No se encontro el grupo Code-Reviewers en el proyecto '$Project'." }
    Write-Host "  Code-Reviewers grupo: $($crGroup.displayName) / descriptor: $($crGroup.descriptor)" -ForegroundColor Gray

    # 3. Resolver identity ID del Code-Reviewers destino (necesario para requiredReviewerIds)
    $identResult  = Invoke-RestMethod "$graphBase/_apis/identities?subjectDescriptors=$([uri]::EscapeDataString($crGroup.descriptor))&api-version=7.1-preview.1" -Headers $headers
    if (-not $identResult.value -or $identResult.value.Count -eq 0) {
        throw "No se pudo resolver el identity ID del grupo Code-Reviewers de '$Project'."
    }
    $detectedNewId = [string]$identResult.value[0].id

    # 4. Detectar OldReviewerId: cualquier ID en las políticas que NO sea el destino
    $allReviewerIds = @($reqRev | ForEach-Object { $_.settings.requiredReviewerIds } | Select-Object -Unique)
    $foreignIds     = @($allReviewerIds | Where-Object { $_ -ne $detectedNewId })

    if ([string]::IsNullOrWhiteSpace($NewReviewerId)) {
        $NewReviewerId = $detectedNewId
        Write-Host "  NewReviewerId autodetectado: $NewReviewerId" -ForegroundColor Green
    }

    if ([string]::IsNullOrWhiteSpace($OldReviewerId)) {
        if ($foreignIds.Count -eq 0) {
            Write-Host "Todos los reviewer IDs ya coinciden con Code-Reviewers del proyecto destino. Nada que corregir." -ForegroundColor Green
            exit 0
        }
        if ($foreignIds.Count -gt 1) {
            Write-Host "Multiples IDs foraneos detectados: $($foreignIds -join ', ')" -ForegroundColor Yellow
            Write-Host "Se corregiran TODOS los IDs foraneos (reemplazados por $NewReviewerId)." -ForegroundColor Yellow
        }
        # Procesar todos los foraneos
        $OldReviewerIds = $foreignIds
        Write-Host "  OldReviewerIds autodetectados: $($OldReviewerIds -join ', ')" -ForegroundColor Green
    } else {
        $OldReviewerIds = @($OldReviewerId)
    }
} else {
    $OldReviewerIds = @($OldReviewerId)
    Write-Host "Modo explicito: Old=$OldReviewerId -> New=$NewReviewerId" -ForegroundColor Cyan
}

# ---------------------------------------------------------------------------
# Filtrar políticas que tienen algún ID foráneo
# ---------------------------------------------------------------------------
$toFix = @($reqRev | Where-Object {
    $policy = $_
    @($OldReviewerIds | Where-Object { $_ -in @($policy.settings.requiredReviewerIds) }).Count -gt 0
})

Write-Host "Políticas a corregir: $($toFix.Count) / $($reqRev.Count)" -ForegroundColor Yellow

if ($toFix.Count -eq 0) {
    Write-Host "Nada que corregir." -ForegroundColor Green
    exit 0
}

# ---------------------------------------------------------------------------
# Aplicar remapeo
# ---------------------------------------------------------------------------
$ok = 0; $fail = @()
foreach ($p in $toFix) {
    $newIds = @($p.settings.requiredReviewerIds | Where-Object { $_ -notin $OldReviewerIds })
    if ($NewReviewerId -notin $newIds) { $newIds += $NewReviewerId }
    $p.settings.requiredReviewerIds = $newIds

    if ($DryRun) {
        Write-Host "  [DRY] id=$($p.id) branch=$($p.settings.scope[0].refName) repoId=$($p.settings.scope[0].repositoryId)"
        $ok++
        continue
    }

    $body = $p | ConvertTo-Json -Depth 10 -Compress
    try {
        Invoke-RestMethod "$policyBase/configurations/$($p.id)?api-version=7.1" -Method PUT -Headers $headers -Body $body | Out-Null
        $ok++
    } catch {
        $fail += "id=$($p.id): $($_.Exception.Message.Substring(0,[Math]::Min(80,$_.Exception.Message.Length)))"
    }
}

Write-Host "Actualizadas: $ok / $($toFix.Count)" -ForegroundColor Green
if ($fail.Count -gt 0) {
    Write-Host "Fallidas: $($fail.Count)" -ForegroundColor Red
    $fail | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    exit 1
}
