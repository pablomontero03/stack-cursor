# Watch-PbiGateway.ps1
# Recupera PBIEgwService si esta caido o ahogado (Mashup/WebView2).
# Stop + kill huerfanos + Start. El registro del gateway se conserva.
$ErrorActionPreference = 'Continue'
$logDir = 'C:\ProgramData\GatewayWatchdog'
$log = Join-Path $logDir 'watchdog.log'
$stampFile = Join-Path $logDir 'last-restart.txt'
$thresholdWv = 80
# RAM baja sola NO reinicia: un refresh MySQL/Elastic en 4 GB puede bajar de 400 MB
# y SpooledOperationMissing si cortamos a medias. Solo RAM critica + fuga WebView2.
$criticalFreeMb = 80
$cooldownMin = 20

function Write-Log($msg) {
  $line = '{0:yyyy-MM-dd HH:mm:ss} {1}' -f (Get-Date), $msg
  Add-Content -Path $log -Value $line -Encoding UTF8
}

function Get-GatewayOrphans {
  Get-CimInstance Win32_Process | Where-Object {
    $n = $_.Name
    $c = [string]$_.CommandLine
    ($n -match 'msedgewebview2|Microsoft.Mashup') -and (
      $c -match 'PBIEgwService|MashupContainer|MashupProvider|Microsoft.Mashup.Container'
    )
  }
}

function Reset-GatewayService {
  Write-Log 'Stop PBIEgwService'
  Stop-Service -Name 'PBIEgwService' -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 5
  $orphans = @(Get-GatewayOrphans)
  Write-Log ("Kill orphans count={0}" -f $orphans.Count)
  foreach ($p in $orphans) {
    try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop } catch {}
  }
  Get-Process -Name 'Microsoft.Mashup.Container.NetFX45','Microsoft.Mashup.Container','msmdsrv' -ErrorAction SilentlyContinue |
    Stop-Process -Force -ErrorAction SilentlyContinue
  Start-Sleep -Seconds 8
  Start-Service -Name 'PBIEgwService' -ErrorAction Stop
  Start-Sleep -Seconds 15
}

function Test-InCooldown {
  if (-not (Test-Path $stampFile)) { return $false }
  $last = (Get-Content $stampFile -ErrorAction SilentlyContinue | Select-Object -First 1)
  $lastDt = [datetime]::MinValue
  if ($last -and [datetime]::TryParse($last, [ref]$lastDt)) {
    return ((Get-Date) - $lastDt -lt [timespan]::FromMinutes($cooldownMin))
  }
  return $false
}

$wv = @(Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue)
$wvCount = $wv.Count
$os = Get-CimInstance Win32_OperatingSystem
$freeMb = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
$svc = Get-Service -Name 'PBIEgwService' -ErrorAction SilentlyContinue

Write-Log "Check: service=$($svc.Status) webview2=$wvCount freeMB=$freeMb"

$need = $false
$why = ''
if (-not $svc -or $svc.Status -ne 'Running') {
  $need = $true; $why = "service=$($svc.Status)"
} elseif ($wvCount -ge $thresholdWv) {
  $need = $true; $why = "webview2=$wvCount"
} elseif ($freeMb -lt $criticalFreeMb -and $wvCount -ge 20) {
  $need = $true; $why = "freeMB=$freeMb webview2=$wvCount"
} elseif ($freeMb -lt 400) {
  Write-Log "RAM baja ($freeMb MB) pero sin fuga WebView2: no reiniciar (posible refresh en curso)"
}

# Stopped: actuar ya. WebView2/RAM: respetar cooldown para no ciclar.
if ($need -and $why -notlike 'service=*' -and (Test-InCooldown)) {
  Write-Log "Skip recover ($why): cooldown ${cooldownMin} min"
  exit 0
}

if (-not $need) { exit 0 }

Write-Log "Recover PBIEgwService because $why"
try {
  Reset-GatewayService
  $svc2 = Get-Service -Name 'PBIEgwService'
  $wv2 = @(Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue).Count
  $os2 = Get-CimInstance Win32_OperatingSystem
  $free2 = [math]::Round($os2.FreePhysicalMemory / 1KB, 0)
  Write-Log "After recover: service=$($svc2.Status) webview2=$wv2 freeMB=$free2"
  Set-Content -Path $stampFile -Value ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Encoding ASCII
} catch {
  Write-Log "ERROR recover: $($_.Exception.Message)"
  exit 1
}
