<#
Pruebas offline de Resolve-CloudflareDnsRecord.ps1. Mockea
Invoke-CloudflareApiRequest via el mismo seam global que
run-script-tests.ps1 -- cero llamadas de red reales.

Uso:
  pwsh -NoProfile -File .\run-dns-resolve-tests.ps1
#>

$ErrorActionPreference = 'Stop'
$scriptsRoot = Split-Path -Parent $PSScriptRoot
. (Join-Path $scriptsRoot 'Cloudflare-Common.ps1')
$resolveScript = Join-Path $scriptsRoot 'Resolve-CloudflareDnsRecord.ps1'

$results = [System.Collections.Generic.List[object]]::new()
function Add-Result {
    param([string]$Name, [bool]$Pass, [string]$Detail = '')
    $results.Add([PSCustomObject]@{ Name = $Name; Status = $(if ($Pass) { 'PASS' } else { 'FAIL' }); Detail = $Detail })
}

$TestAccountId = 'acct-test-0001'
$Global:MockExistingRecord = $null

$Global:CloudflareApiRequestMock = {
    param($Method, $Uri, $Body, $Headers)
    if ($Method -eq 'GET' -and $Uri -match '/zones\?account\.id=') {
        return [PSCustomObject]@{ success = $true; result = @(
                [PSCustomObject]@{ id = 'zone-example'; name = 'example.com' },
                [PSCustomObject]@{ id = 'zone-dev-example'; name = 'dev.example.com' }
            ) }
    }
    if ($Method -eq 'GET' -and $Uri -match '/dns_records\?name=') {
        if ($Global:MockExistingRecord) { return [PSCustomObject]@{ success = $true; result = @($Global:MockExistingRecord) } }
        return [PSCustomObject]@{ success = $true; result = @() }
    }
    return [PSCustomObject]@{ success = $false; result = $null }
}

# --- Escenario 7: DNS existente e identico -> reuse ---
$Global:MockExistingRecord = [PSCustomObject]@{ id = 'rec-1'; type = 'A'; content = '1.2.3.4'; proxied = $false; ttl = 1; comment = 'cluster: old' }
$reportJson7 = & $resolveScript -AccountId $TestAccountId -Fqdn 'app.example.com' -Type A -Content '1.2.3.4' -Proxied:$false -Ttl auto -ClusterName 'gmon-dev-aks' | Out-String
$report7 = $reportJson7 | ConvertFrom-Json
Add-Result 'Escenario 7: registro existente identico -> classification=reuse' ($report7.classification -eq 'reuse') $report7.classification
Add-Result 'Escenario 7: sin diffFields' (@($report7.diffFields).Count -eq 0) (@($report7.diffFields) -join ',')
Add-Result 'Escenario 7: resuelve la zona correcta por sufijo mas largo (example.com, no dev.example.com)' ($report7.zoneName -eq 'example.com') $report7.zoneName

# --- Escenario 8: DNS existente y diferente -> conflict ---
$Global:MockExistingRecord = [PSCustomObject]@{ id = 'rec-2'; type = 'A'; content = '9.9.9.9'; proxied = $false; ttl = 1; comment = 'cluster: old' }
$report8 = (& $resolveScript -AccountId $TestAccountId -Fqdn 'app.example.com' -Type A -Content '1.2.3.4' -Proxied:$false -Ttl auto -ClusterName 'gmon-dev-aks' | Out-String) | ConvertFrom-Json
Add-Result 'Escenario 8: registro existente con content distinto -> classification=conflict' ($report8.classification -eq 'conflict') $report8.classification
Add-Result 'Escenario 8: diffFields identifica "content"' (@($report8.diffFields) -contains 'content') (@($report8.diffFields) -join ',')
Add-Result 'Escenario 8: recomendacion no sugiere sobrescribir en silencio' ($report8.recommendation -match 'No sobrescribir') $report8.recommendation

# --- Caso: no existe -> to_create ---
$Global:MockExistingRecord = $null
$reportCreate = (& $resolveScript -AccountId $TestAccountId -Fqdn 'nuevo.example.com' -Type A -Content '1.2.3.4' -Proxied:$false -Ttl auto -ClusterName 'gmon-dev-aks' | Out-String) | ConvertFrom-Json
Add-Result 'Caso sin registro previo -> classification=to_create' ($reportCreate.classification -eq 'to_create') $reportCreate.classification
Add-Result 'Comentario propuesto usa el cluster confirmado, no un candidato' ($reportCreate.desired.comment -eq 'cluster: gmon-dev-aks') $reportCreate.desired.comment

# --- Resolucion de zona: subdominio debe resolver a la zona hija correcta ---
$Global:MockExistingRecord = $null
$reportSubzone = (& $resolveScript -AccountId $TestAccountId -Fqdn 'app.dev.example.com' -Type A -Content '1.2.3.4' -Proxied:$false -Ttl auto | Out-String) | ConvertFrom-Json
Add-Result 'Resolucion de zona: FQDN bajo zona hija resuelve a dev.example.com (mas especifica)' ($reportSubzone.zoneName -eq 'dev.example.com') $reportSubzone.zoneName

# =========================================================================
# Reporte final
# =========================================================================
$results | Format-Table -Property Name, Status -AutoSize | Out-String | Write-Host
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' })
Write-Host ""
Write-Host "Total: $($results.Count) - PASS: $($results.Count - $failed.Count) - FAIL: $($failed.Count)" -ForegroundColor $(if ($failed.Count -eq 0) { 'Green' } else { 'Red' })
if ($failed.Count -gt 0) {
    foreach ($f in $failed) { Write-Host "- $($f.Name): $($f.Detail)" -ForegroundColor Red }
}
$Global:CloudflareApiRequestMock = $null

if ($failed.Count -gt 0) { exit 1 } else { exit 0 }
