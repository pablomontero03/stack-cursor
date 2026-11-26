<#
.SYNOPSIS
    Ejecuta comandos SSH en servidores remotos con validación de whitelist.
    
.DESCRIPTION
    Wrapper seguro para ejecutar comandos SSH en servidores del catálogo.
    Valida que el comando esté en la whitelist antes de ejecutar.
    Registra métricas de la operación.
    
.PARAMETER ServerName
    Nombre del servidor del catálogo (docs/servers/servers.json o windows/servers.json)
    
.PARAMETER Command
    Comando a ejecutar en el servidor remoto
    
.PARAMETER TimeoutSeconds
    Timeout en segundos (default: 30)
    
.PARAMETER Force
    Omitir confirmación para comandos controlados (requiere aprobación previa del agente)
    
.EXAMPLE
    ./Invoke-ServerCommand.ps1 -ServerName "srv-desarrollo-5" -Command "systemctl status docker"
    
.EXAMPLE
    ./Invoke-ServerCommand.ps1 -ServerName "SRV-SFTP-TS" -Command "docker ps" -TimeoutSeconds 60
#>
param(
    [Parameter(Mandatory=$true)]
    [string]$ServerName,
    
    [Parameter(Mandatory=$true)]
    [string]$Command,
    
    [int]$TimeoutSeconds = 30,
    
    [switch]$Force
)

$ErrorActionPreference = "Stop"
$REPO_ROOT = $env:REPO_ROOT
if (-not $REPO_ROOT) {
    $REPO_ROOT = "/home/cursor/stack-cursor"
}

# Cargar módulo de métricas
. "$REPO_ROOT/scripts/common/Metrics-Common.ps1"

# Cargar catálogos de servidores
$linuxServersPath = Join-Path $REPO_ROOT "docs/servers/servers.json"
$windowsServersPath = Join-Path $REPO_ROOT "docs/servers/windows/servers.json"
$allowedCommandsPath = Join-Path $REPO_ROOT "docs/servers/allowed-commands.json"

function Get-ServerInfo {
    param([string]$Name)
    
    # Buscar en catálogo Linux
    # El catálogo usa: id (IP), host (IP), sshAlias, user, purpose
    if (Test-Path $linuxServersPath) {
        $linux = Get-Content $linuxServersPath | ConvertFrom-Json
        $server = $linux.servers | Where-Object { 
            $_.id -eq $Name -or 
            $_.host -eq $Name -or 
            $_.sshAlias -eq $Name -or
            $_.purpose -like "*$Name*"
        }
        if ($server) {
            return @{
                Name = $server.id
                IP = $server.host
                User = $server.user
                Port = if ($server.port) { $server.port } else { 22 }
                KeyFile = $null  # Las claves están en env/ si se necesitan
                OS = "linux"
                Purpose = $server.purpose
            }
        }
    }
    
    # Buscar en catálogo Windows
    if (Test-Path $windowsServersPath) {
        $windows = Get-Content $windowsServersPath | ConvertFrom-Json
        $server = $windows.servers | Where-Object { 
            $_.id -eq $Name -or 
            $_.host -eq $Name -or
            $_.name -eq $Name
        }
        if ($server) {
            return @{
                Name = if ($server.id) { $server.id } else { $server.name }
                IP = if ($server.host) { $server.host } else { $server.ip }
                User = $server.user
                Port = if ($server.port) { $server.port } else { 22 }
                KeyFile = $null
                OS = "windows"
                Purpose = $server.purpose
            }
        }
    }
    
    return $null
}

function Test-CommandAllowed {
    param(
        [string]$Command,
        [hashtable]$AllowedCommands
    )
    
    # Verificar si está prohibido
    foreach ($pattern in $AllowedCommands.prohibited.patterns) {
        $regex = "^" + ($pattern -replace '\*', '.*') + "$"
        if ($Command -match $regex) {
            return @{
                Allowed = $false
                Level = "prohibited"
                Reason = "Comando prohibido: $pattern"
            }
        }
    }
    
    # Verificar si es read-only
    foreach ($pattern in $AllowedCommands.read_only.commands) {
        $regex = "^" + ($pattern -replace '\*', '.*') + "$"
        if ($Command -match $regex) {
            return @{
                Allowed = $true
                Level = "read_only"
                Reason = "Comando de solo lectura"
            }
        }
    }
    
    # Verificar si es controlado
    foreach ($pattern in $AllowedCommands.controlled.commands) {
        $regex = "^" + ($pattern -replace '\*', '.*') + "$"
        if ($Command -match $regex) {
            return @{
                Allowed = $true
                Level = "controlled"
                Reason = "Comando controlado - requiere aprobación"
            }
        }
    }
    
    # No está en ninguna lista
    return @{
        Allowed = $false
        Level = "unknown"
        Reason = "Comando no reconocido en whitelist"
    }
}

# ---- Main ----

Write-Host "=== Invoke-ServerCommand ===" -ForegroundColor Cyan
Write-Host "Servidor: $ServerName"
Write-Host "Comando: $Command"
Write-Host ""

# 1. Obtener info del servidor
$serverInfo = Get-ServerInfo -Name $ServerName
if (-not $serverInfo) {
    Write-Error "Servidor '$ServerName' no encontrado en los catálogos"
    exit 1
}

Write-Host "Servidor encontrado:" -ForegroundColor Green
Write-Host "  IP: $($serverInfo.IP)"
Write-Host "  Puerto: $($serverInfo.Port)"
Write-Host "  Usuario: $($serverInfo.User)"
Write-Host "  OS: $($serverInfo.OS)"
Write-Host "  Propósito: $($serverInfo.Purpose)"
Write-Host ""

# 2. Validar comando contra whitelist
if (-not (Test-Path $allowedCommandsPath)) {
    Write-Error "Whitelist de comandos no encontrada: $allowedCommandsPath"
    exit 1
}

$allowedCommands = Get-Content $allowedCommandsPath | ConvertFrom-Json -AsHashtable
$validation = Test-CommandAllowed -Command $Command -AllowedCommands $allowedCommands

Write-Host "Validación de comando:" -ForegroundColor Yellow
Write-Host "  Nivel: $($validation.Level)"
Write-Host "  Permitido: $($validation.Allowed)"
Write-Host "  Razón: $($validation.Reason)"
Write-Host ""

if (-not $validation.Allowed) {
    Write-Error "Comando no permitido: $($validation.Reason)"
    exit 1
}

if ($validation.Level -eq "controlled" -and -not $Force) {
    Write-Warning "Este es un comando controlado que requiere aprobación."
    Write-Warning "Use -Force si ya tiene aprobación del agente principal."
    exit 1
}

# 3. Iniciar métrica
$metric = Start-OperationMetric `
    -Domain "linux-servers" `
    -Operation "ssh_command" `
    -Metadata @{
        server = $ServerName
        command = $Command
        level = $validation.Level
    }

# 4. Construir y ejecutar comando SSH
try {
    $sshArgs = @(
        "-o", "StrictHostKeyChecking=no",
        "-o", "ConnectTimeout=$TimeoutSeconds",
        "-o", "BatchMode=yes",
        "-p", "$($serverInfo.Port)"
    )
    
    if ($serverInfo.KeyFile -and (Test-Path $serverInfo.KeyFile)) {
        $sshArgs += @("-i", $serverInfo.KeyFile)
    }
    
    $sshTarget = "$($serverInfo.User)@$($serverInfo.IP)"
    $sshArgs += @($sshTarget, $Command)
    
    Write-Host "Ejecutando SSH..." -ForegroundColor Cyan
    Write-Host "ssh $($sshArgs -join ' ')" -ForegroundColor DarkGray
    Write-Host ""
    
    $result = & ssh @sshArgs 2>&1
    $exitCode = $LASTEXITCODE
    
    if ($exitCode -eq 0) {
        Write-Host "=== Resultado ===" -ForegroundColor Green
        Write-Host $result
        Complete-OperationMetric -Metric $metric -Status "success"
        
        return @{
            Success = $true
            Output = $result
            ExitCode = $exitCode
            Server = $ServerName
            Command = $Command
        }
    }
    else {
        Write-Host "=== Error (exit code: $exitCode) ===" -ForegroundColor Red
        Write-Host $result
        Complete-OperationMetric -Metric $metric -Status "failure" -ErrorCategory "unknown" -ErrorMessage "Exit code: $exitCode"
        
        return @{
            Success = $false
            Output = $result
            ExitCode = $exitCode
            Server = $ServerName
            Command = $Command
        }
    }
}
catch {
    Write-Error "Error ejecutando SSH: $_"
    Complete-OperationMetric -Metric $metric -Status "failure" -ErrorCategory (Get-ErrorCategory $_) -ErrorMessage $_.Exception.Message
    throw
}
