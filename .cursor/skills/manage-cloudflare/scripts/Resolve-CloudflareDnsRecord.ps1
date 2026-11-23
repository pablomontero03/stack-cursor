<#
Resolucion determinista de un registro DNS deseado contra el estado real
de Cloudflare -- de solo lectura, nunca escribe. Implementa
references/dns-and-certificates.md § Resolucion determinista:

  1. Resuelve la zona correcta por el FQDN (coincidencia de sufijo mas
     larga entre las zonas de la cuenta).
  2. Busca un registro existente con ese nombre exacto.
  3. Clasifica: 'to_create' (no existe), 'reuse' (existe y coincide en
     tipo/contenido/proxied/ttl) o 'conflict' (existe y difiere en algun
     campo) -- nunca sugiere sobrescribir en silencio.
  4. Propone el comentario a partir del nombre de cluster confirmado
     (-ClusterName), nunca a partir de un candidato sin confirmar.

Uso:
  powershell -File .\Resolve-CloudflareDnsRecord.ps1 -AccountId <id> -Fqdn app.example.com -Type A -Content 1.2.3.4 -Proxied:$false -Ttl auto -ClusterName gmon-prod-aks-eastus2-0004
#>

param(
    [Parameter(Mandatory)] [string]$AccountId,
    [Parameter(Mandatory)] [string]$Fqdn,
    [Parameter(Mandatory)] [string]$Type,
    [Parameter(Mandatory)] [string]$Content,
    [bool]$Proxied = $false,
    [string]$Ttl = 'auto',
    [string]$ClusterName = $null
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'Cloudflare-Common.ps1')

function ConvertTo-CloudflareTtlApiValue {
    <#
    La API de Cloudflare representa TTL "Auto" como el entero 1 -- nunca
    la cadena literal 'auto'.
    #>
    param([string]$Ttl)
    if ([string]::IsNullOrWhiteSpace($Ttl) -or $Ttl -eq 'auto') { return 1 }
    return [int]$Ttl
}

$zonesResponse = Invoke-CloudflareApiRequest -Method GET -Uri "$(Get-CloudflareApiBaseUri)/zones?account.id=$AccountId&per_page=50"
if (-not $zonesResponse -or -not $zonesResponse.success) {
    throw "Resolve-CloudflareDnsRecord rechazado: no se pudo listar zonas de la cuenta '$AccountId'."
}

$fqdnLower = $Fqdn.ToLowerInvariant().TrimEnd('.')
$matchingZone = $null
foreach ($zone in @($zonesResponse.result)) {
    $zoneName = ([string]$zone.name).ToLowerInvariant()
    if ($fqdnLower -eq $zoneName -or $fqdnLower.EndsWith(".$zoneName")) {
        if ($null -eq $matchingZone -or $zoneName.Length -gt ([string]$matchingZone.name).Length) {
            $matchingZone = $zone
        }
    }
}
if (-not $matchingZone) {
    throw "Resolve-CloudflareDnsRecord rechazado: ningun zona de la cuenta '$AccountId' es sufijo de '$Fqdn'."
}

$recordsResponse = Invoke-CloudflareApiRequest -Method GET -Uri "$(Get-CloudflareApiBaseUri)/zones/$($matchingZone.id)/dns_records?name=$fqdnLower&type=$Type"
if (-not $recordsResponse -or -not $recordsResponse.success) {
    throw "Resolve-CloudflareDnsRecord rechazado: no se pudo consultar registros DNS de la zona '$($matchingZone.name)'."
}

$existingRecord = @($recordsResponse.result) | Select-Object -First 1
$desiredTtlApiValue = ConvertTo-CloudflareTtlApiValue -Ttl $Ttl
$comment = if ($ClusterName) { "cluster: $ClusterName" } else { $null }

if (-not $existingRecord) {
    $classification = 'to_create'
    $diff = @()
}
else {
    $diffFields = [System.Collections.Generic.List[string]]::new()
    if (([string]$existingRecord.type) -ne $Type) { $diffFields.Add('type') }
    if (([string]$existingRecord.content) -ne $Content) { $diffFields.Add('content') }
    if ([bool]$existingRecord.proxied -ne $Proxied) { $diffFields.Add('proxied') }
    if ([int]$existingRecord.ttl -ne $desiredTtlApiValue -and -not ($existingRecord.proxied -and $desiredTtlApiValue -eq 1)) { $diffFields.Add('ttl') }
    $diff = @($diffFields)
    $classification = if ($diff.Count -eq 0) { 'reuse' } else { 'conflict' }
}

$report = [PSCustomObject]@{
    generatedAtUtc  = (Get-Date).ToUniversalTime().ToString('o')
    fqdn            = $fqdnLower
    zoneId          = $matchingZone.id
    zoneName        = $matchingZone.name
    desired         = [PSCustomObject]@{ type = $Type; content = $Content; proxied = $Proxied; ttl = $desiredTtlApiValue; comment = $comment }
    existingRecord  = if ($existingRecord) { [PSCustomObject]@{ id = $existingRecord.id; type = $existingRecord.type; content = $existingRecord.content; proxied = $existingRecord.proxied; ttl = $existingRecord.ttl; comment = $existingRecord.comment } } else { $null }
    classification  = $classification
    diffFields      = $diff
    recommendation  = switch ($classification) {
        'to_create' { 'Crear el registro nuevo con los valores declarados.' }
        'reuse' { 'Reutilizar el registro existente; no crear uno duplicado.' }
        'conflict' { 'No sobrescribir en silencio: mostrar el conflicto en el plan y esperar decision explicita.' }
    }
}

$report | ConvertTo-Json -Depth 10
