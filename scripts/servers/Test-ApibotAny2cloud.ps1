# Test-ApibotAny2cloud.ps1 -- SOLO LECTURA. Ejecutar en CRSRVSISRDP (172.16.2.76) como Administrador.
# Valida los fixes del sitio IIS any2cloud / APIBOT y el Health local. Compatible con PowerShell 5.1.
Import-Module WebAdministration -ErrorAction Stop
$site='any2cloud'; $pool='any2cloud'; $app='/APIBOT'
$phys='X:\IIS\any2cloud'; $dll='X:\IIS\any2cloud\APIBOT\APIBOT.dll'
$hostName='api-bot-any2cloud.grupomontecristo.com'
$results=@()
function Add-Check($name,$ok,$detail){ $script:results += [pscustomobject]@{Check=$name;Estado=$(if($ok){'OK'}else{'FALLA'});Detalle=$detail} }

# Estado base
$ps=(Get-WebAppPoolState $pool).Value; Add-Check 'Pool iniciado' ($ps -eq 'Started') $ps
$ss=(Get-WebsiteState $site).Value;    Add-Check 'Sitio iniciado' ($ss -eq 'Started') $ss
$wp=Get-CimInstance Win32_Process -Filter "Name='w3wp.exe'" | Where-Object { $_.CommandLine -match $pool }
Add-Check 'Worker w3wp vivo' ($null -ne $wp) (($wp.ProcessId) -join ',')
$ln=Get-NetTCPConnection -LocalPort 6789 -State Listen -ErrorAction SilentlyContinue
Add-Check 'Puerto 6789 escuchando' ($null -ne $ln) ''

# Fix 1: 32 bits
$e32=(Get-ItemProperty "IIS:\AppPools\$pool").enable32BitAppOnWin64
Add-Check 'Fix1 enable32Bit=True' ($e32 -eq $true) "$e32"
$pm=(Get-ItemProperty "IIS:\AppPools\$pool").managedPipelineMode
Add-Check 'Pipeline Integrated (como UAT)' ($pm -eq 'Integrated') "$pm"

# Fix 2: ISAPI/CGI Restriction
$isapi=Get-WebConfiguration -Filter '/system.webServer/security/isapiCgiRestriction/add' -PSPath 'MACHINE/WEBROOT/APPHOST' |
  Where-Object { $_.path -ieq $dll }
Add-Check 'Fix2 ISAPI APIBOT.dll allowed' ($isapi -and "$($isapi.allowed)" -eq 'True') "$($isapi.path) allowed=$($isapi.allowed)"

# Fix 3: accessPolicy con Execute
$ap=(Get-WebConfigurationProperty -PSPath "MACHINE/WEBROOT/APPHOST/$site$app" -Filter '/system.webServer/handlers' -Name accessPolicy -ErrorAction SilentlyContinue)
Add-Check 'Fix3 accessPolicy incluye Execute' ("$ap" -match 'Execute') "$ap"
$wc="X:\IIS\any2cloud\APIBOT\web.config"
# Informativo: el web.config con handlers solo es problema si el sitio da 500.19
$wcInfo = if (Test-Path $wc) { "existe: " + ((Get-Content $wc -Raw) -replace '\s+',' ') } else { 'no existe' }
Add-Check 'web.config local (informativo)' $true $wcInfo

# Fix 4: vdir pass-through + NTFS al pool
$vd=Get-WebConfigurationProperty -Filter "/system.applicationHost/sites/site[@name='$site']/application[@path='/']/virtualDirectory[@path='/']" -PSPath 'MACHINE/WEBROOT/APPHOST' -Name userName
$vdUser = if ($vd -and $vd.PSObject.Properties['Value']) { "$($vd.Value)" } else { "$vd" }
Add-Check 'Fix4 vdir pass-through (sin userName)' ([string]::IsNullOrEmpty($vdUser)) "userName=[$vdUser]"
$acl=(Get-Acl $phys).Access | Where-Object { $_.IdentityReference -like "*AppPool\$pool" }
Add-Check 'Fix4 NTFS ReadAndExecute al app pool' ($null -ne $acl -and "$($acl.FileSystemRights)" -match 'ReadAndExecute|Read') "$($acl.FileSystemRights)"

# conn.cfg
$cfg='X:\IIS\any2cloud\APIBOT\conn.cfg'
$srv=(Get-Content $cfg -ErrorAction SilentlyContinue | Where-Object { $_ -match '^Server=' }) -join ''
Add-Check 'conn.cfg apunta a BD prod 172.16.16.50' ($srv -match '172\.16\.16\.50') $srv

# SQL TCP
$t=Test-NetConnection 172.16.16.50 -Port 1433 -WarningAction SilentlyContinue
Add-Check 'TCP a BD prod 1433' $t.TcpTestSucceeded "ping=$($t.PingSucceeded) ruta=$($t.SourceAddress.IPAddress)"

# Health local (127.0.0.1 + Host para SNI)
[Net.ServicePointManager]::ServerCertificateValidationCallback={$true}
$sw=[Diagnostics.Stopwatch]::StartNew()
try{
  $r=[Net.HttpWebRequest]::Create("https://127.0.0.1:6789/APIBOT/APIBOT.dll/api/bot/metodos/Health")
  $r.Host=$hostName; $r.Timeout=20000
  $x=$r.GetResponse(); $body=(New-Object IO.StreamReader($x.GetResponseStream())).ReadToEnd()
  Add-Check 'Health local 200 OK/OK' (([int]$x.StatusCode -eq 200) -and ($body -match '"status":"OK"') -and ($body -match '"database":"OK"')) "$([int]$x.StatusCode) $body $($sw.ElapsedMilliseconds)ms"
}catch{ Add-Check 'Health local 200 OK/OK' $false $_.Exception.Message }

# Ultimos eventos WAS (24h)
$ev=Get-WinEvent -FilterHashtable @{LogName='System';ProviderName='Microsoft-Windows-WAS';StartTime=(Get-Date).AddHours(-24)} -MaxEvents 5 -ErrorAction SilentlyContinue |
  ForEach-Object { "$($_.TimeCreated.ToString('MM-dd HH:mm')) id=$($_.Id)" }
Add-Check 'Eventos WAS 24h (informativo)' $true (($ev) -join ' | ')

$results | Format-Table -AutoSize -Wrap
$fails=($results | Where-Object Estado -eq 'FALLA').Count
if($fails -eq 0){ Write-Host 'RESULTADO: todo OK' -ForegroundColor Green } else { Write-Host "RESULTADO: $fails check(s) en FALLA" -ForegroundColor Red }
