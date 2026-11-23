<#
Construye el snapshot canonico (hashes de exports, commits de ramas,
revisiones de definiciones, IDs de recursos ya consultados) de una
ejecucion del ciclo de pipeline de aplicacion, y compara contra un
snapshot anterior para decidir que evidencia sigue siendo reutilizable
(mismo hash/commit/revision) y que quedo obsoleta (drift). No consulta
Azure DevOps, Cloudflare ni AKS por si mismo -- recibe datos ya obtenidos
por las skills de dominio. Nunca escribe hacia esos sistemas.

Uso:
  powershell -File .\New-ApplicationCycleSnapshot.ps1 -SectionsJsonPath .\sections.json -OutputPath .\snapshot.json
  powershell -File .\New-ApplicationCycleSnapshot.ps1 -SectionsJsonPath .\sections-v2.json -PreviousSnapshotPath .\snapshot.json
#>

param(
    [string]$SectionsJsonPath,
    $Sections,
    [string]$OutputPath,
    [string]$PreviousSnapshotPath
)

$ErrorActionPreference = 'Stop'

function Get-ApplicationCycleCanonicalHash {
    <#
    SHA-256 sobre el JSON canonico (comprimido, orden estable de
    propiedades tal como llega) de $Sections. Determinista: el mismo
    contenido siempre produce el mismo hash, sin importar si $Sections es
    Hashtable, OrderedDictionary o PSCustomObject.
    #>
    param([Parameter(Mandatory)] $Sections)
    $json = $Sections | ConvertTo-Json -Depth 30 -Compress
    $bytes = [System.Text.Encoding]::UTF8.GetBytes($json)
    $sha256 = [System.Security.Cryptography.SHA256]::Create()
    try {
        $hashBytes = $sha256.ComputeHash($bytes)
    }
    finally {
        $sha256.Dispose()
    }
    return -join ($hashBytes | ForEach-Object { $_.ToString('x2') })
}

function New-ApplicationCycleSnapshotObject {
    <#
    Funcion pura. $Sections es un objeto libre cuyas claves de primer
    nivel son, por convencion, categorias como 'adoExports', 'branches',
    'dns', 'aksCapacity', 'resourceIds' -- el contenido exacto lo decide
    quien arma el snapshot; esta funcion solo lo envuelve y lo hashea.
    #>
    param([Parameter(Mandatory)] $Sections)
    return [PSCustomObject]@{
        generatedAtUtc = (Get-Date).ToUniversalTime().ToString('o')
        sections       = $Sections
        snapshotHash   = (Get-ApplicationCycleCanonicalHash -Sections $Sections)
    }
}

function Get-ApplicationCyclePropertyNames {
    param($Obj)
    if ($null -eq $Obj) { return @() }
    if ($Obj -is [System.Collections.IDictionary]) { return @($Obj.Keys) }
    return @($Obj.PSObject.Properties.Name)
}

function Get-ApplicationCyclePropertyValue {
    param($Obj, [string]$Name)
    if ($null -eq $Obj) { return $null }
    if ($Obj -is [System.Collections.IDictionary]) {
        if ($Obj.Contains($Name)) { return $Obj[$Name] } else { return $null }
    }
    $prop = $Obj.PSObject.Properties[$Name]
    if ($prop) { return $prop.Value }
    return $null
}

function Compare-ApplicationCycleSnapshot {
    <#
    Compara 2 snapshots seccion por seccion (nivel superior de
    .sections). Cada seccion cuyo JSON canonico coincide se marca
    reusable=true (evidencia estatica reutilizable); si difiere o es
    nueva, reusable=false (drift -- refrescar antes de escribir). Nunca
    decide POR SI SOLA si el drift bloquea una escritura -- eso es del
    flujo de aprobacion (ver references/approval-envelope.md § Desviacion
    del plan); esta funcion solo informa el diff.
    #>
    param([Parameter(Mandatory)] $PreviousSnapshot, [Parameter(Mandatory)] $NewSnapshot)

    $previousSections = $PreviousSnapshot.sections
    $newSections = $NewSnapshot.sections
    $allKeys = @(Get-ApplicationCyclePropertyNames -Obj $previousSections) + @(Get-ApplicationCyclePropertyNames -Obj $newSections) | Select-Object -Unique

    $comparisons = [System.Collections.Generic.List[object]]::new()
    foreach ($key in $allKeys) {
        $previousValue = Get-ApplicationCyclePropertyValue -Obj $previousSections -Name $key
        $newValue = Get-ApplicationCyclePropertyValue -Obj $newSections -Name $key

        $previousJson = if ($null -ne $previousValue) { $previousValue | ConvertTo-Json -Depth 30 -Compress } else { $null }
        $newJson = if ($null -ne $newValue) { $newValue | ConvertTo-Json -Depth 30 -Compress } else { $null }

        $reusable = ($null -ne $previousJson) -and ($previousJson -ceq $newJson)
        $comparisons.Add([PSCustomObject]@{
                section  = $key
                reusable = $reusable
                reason   = if ($null -eq $previousJson) { 'seccion nueva, sin evidencia previa' } elseif ($reusable) { 'hash/commit/revision sin cambios' } else { 'contenido distinto del snapshot anterior (drift)' }
            })
    }

    return [PSCustomObject]@{
        previousHash = $PreviousSnapshot.snapshotHash
        newHash      = $NewSnapshot.snapshotHash
        unchanged    = ($PreviousSnapshot.snapshotHash -ceq $NewSnapshot.snapshotHash)
        sections     = @($comparisons)
    }
}

if ($MyInvocation.InvocationName -ne '.') {
    if (-not $Sections) {
        if (-not $SectionsJsonPath) {
            throw "New-ApplicationCycleSnapshot rechazado: indicar -SectionsJsonPath o -Sections."
        }
        if (-not (Test-Path -LiteralPath $SectionsJsonPath)) {
            throw "New-ApplicationCycleSnapshot rechazado: no existe '$SectionsJsonPath'."
        }
        $Sections = Get-Content -LiteralPath $SectionsJsonPath -Raw | ConvertFrom-Json
    }

    $snapshot = New-ApplicationCycleSnapshotObject -Sections $Sections

    if ($PreviousSnapshotPath) {
        if (-not (Test-Path -LiteralPath $PreviousSnapshotPath)) {
            throw "New-ApplicationCycleSnapshot rechazado: no existe el snapshot anterior '$PreviousSnapshotPath'."
        }
        $previous = Get-Content -LiteralPath $PreviousSnapshotPath -Raw | ConvertFrom-Json
        $comparison = Compare-ApplicationCycleSnapshot -PreviousSnapshot $previous -NewSnapshot $snapshot
        $snapshot | Add-Member -NotePropertyName 'comparisonToPrevious' -NotePropertyValue $comparison
    }

    if ($OutputPath) {
        $snapshot | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $OutputPath -Encoding utf8
    }

    $snapshot | ConvertTo-Json -Depth 30
}
