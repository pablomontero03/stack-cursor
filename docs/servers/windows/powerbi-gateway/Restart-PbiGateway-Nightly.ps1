# Nightly: solo recupera si hay fuga o RAM baja. No reiniciar si esta sano
# (un restart a ciegas corta refreshes y genera SpooledOperationMissing).
$ErrorActionPreference = 'Continue'
$log = 'C:\ProgramData\GatewayWatchdog\watchdog.log'
function Write-Log($msg) {
  Add-Content $log ("{0:yyyy-MM-dd HH:mm:ss} {1}" -f (Get-Date), $msg) -Encoding UTF8
}

$wv = @(Get-Process -Name 'msedgewebview2' -ErrorAction SilentlyContinue).Count
$os = Get-CimInstance Win32_OperatingSystem
$freeMb = [math]::Round($os.FreePhysicalMemory / 1KB, 0)
$svc = Get-Service -Name 'PBIEgwService' -ErrorAction SilentlyContinue
Write-Log ("Nightly check service={0} webview2={1} freeMB={2}" -f $svc.Status, $wv, $freeMb)

$need = (-not $svc -or $svc.Status -ne 'Running' -or $wv -ge 80 -or ($freeMb -lt 80 -and $wv -ge 20))
if (-not $need) {
  Write-Log 'Nightly skip: gateway healthy, no restart'
  exit 0
}

Write-Log 'Nightly recover start'
Stop-Service -Name 'PBIEgwService' -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 5
Get-CimInstance Win32_Process | Where-Object {
  $c = [string]$_.CommandLine
  ($_.Name -match 'msedgewebview2|Microsoft.Mashup') -and ($c -match 'PBIEgwService|MashupContainer|MashupProvider|Microsoft.Mashup.Container')
} | ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }
Get-Process -Name 'Microsoft.Mashup.Container.NetFX45','Microsoft.Mashup.Container' -ErrorAction SilentlyContinue |
  Stop-Process -Force -ErrorAction SilentlyContinue
Start-Sleep -Seconds 8
Start-Service -Name 'PBIEgwService'
Start-Sleep -Seconds 15
$svc = Get-Service PBIEgwService
$wv = @(Get-Process msedgewebview2 -ErrorAction SilentlyContinue).Count
Write-Log ("Nightly done service={0} webview2={1}" -f $svc.Status, $wv)
Set-Content 'C:\ProgramData\GatewayWatchdog\last-restart.txt' ((Get-Date).ToString('yyyy-MM-dd HH:mm:ss')) -Encoding ASCII
