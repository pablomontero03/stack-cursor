<#
.SYNOPSIS
    Módulo común para métricas de operaciones del stack.
    
.DESCRIPTION
    Provee funciones para instrumentar scripts Apply-* y registrar
    métricas de éxito/fallo por dominio. Los datos se guardan en
    .local/metrics/ como archivos JSONL (append-only).
    
.NOTES
    Uso:
        . $PSScriptRoot/../common/Metrics-Common.ps1
        $metric = Start-OperationMetric -Domain "azure-devops-pipelines" -Operation "apply_classic_plan"
        try {
            # ... operación ...
            Complete-OperationMetric -Metric $metric -Status "success"
        } catch {
            Complete-OperationMetric -Metric $metric -Status "failure" -ErrorCategory (Get-ErrorCategory $_)
            throw
        }
#>

$script:REPO_ROOT = $env:REPO_ROOT
if (-not $script:REPO_ROOT) {
    $script:REPO_ROOT = "/home/cursor/stack-cursor"
}
$script:METRICS_DIR = Join-Path $script:REPO_ROOT ".local/metrics"

function Start-OperationMetric {
    <#
    .SYNOPSIS
        Inicia el tracking de una operación.
    .PARAMETER Domain
        Dominio del stack (azure, aks, azure-devops-pipelines, etc.)
    .PARAMETER Operation
        Nombre de la operación (apply_classic_plan, apply_permissions, etc.)
    .PARAMETER SessionId
        ID de sesión opcional para correlacionar
    #>
    param(
        [Parameter(Mandatory=$true)]
        [ValidateSet(
            "azure", "aks", "azure-devops-pipelines", "azure-devops-permissions",
            "cloudflare", "n8n", "schema-sync", "linux-servers", "windows-servers"
        )]
        [string]$Domain,
        
        [Parameter(Mandatory=$true)]
        [string]$Operation,
        
        [string]$SessionId = "",
        
        [hashtable]$Metadata = @{}
    )
    
    return @{
        domain = $Domain
        operation = $Operation
        session_id = $SessionId
        started = (Get-Date).ToUniversalTime().ToString("o")
        metadata = $Metadata
    }
}

function Complete-OperationMetric {
    <#
    .SYNOPSIS
        Completa y guarda una métrica de operación.
    .PARAMETER Metric
        Objeto retornado por Start-OperationMetric
    .PARAMETER Status
        Estado final: success, failure, partial, skipped
    .PARAMETER ErrorCategory
        Categoría del error si Status=failure
    .PARAMETER ErrorMessage
        Mensaje de error opcional (truncado a 500 chars)
    #>
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Metric,
        
        [Parameter(Mandatory=$true)]
        [ValidateSet("success", "failure", "partial", "skipped")]
        [string]$Status,
        
        [ValidateSet("validation", "network", "auth", "timeout", "permission", "resource_not_found", "unknown")]
        [string]$ErrorCategory = "",
        
        [string]$ErrorMessage = ""
    )
    
    $endTime = (Get-Date).ToUniversalTime()
    $startTime = [datetime]::Parse($Metric.started)
    $durationMs = [int]($endTime - $startTime).TotalMilliseconds
    
    $record = @{
        domain = $Metric.domain
        operation = $Metric.operation
        status = $Status
        duration_ms = $durationMs
        timestamp = $endTime.ToString("o")
        session_id = $Metric.session_id
    }
    
    if ($ErrorCategory) {
        $record.error_category = $ErrorCategory
    }
    if ($ErrorMessage) {
        $record.error_message = $ErrorMessage.Substring(0, [Math]::Min(500, $ErrorMessage.Length))
    }
    if ($Metric.metadata.Count -gt 0) {
        $record.metadata = $Metric.metadata
    }
    
    # Guardar en archivo JSONL mensual
    Save-MetricRecord -Record $record
    
    return $record
}

function Save-MetricRecord {
    <#
    .SYNOPSIS
        Guarda un registro de métrica en el archivo JSONL mensual.
    #>
    param(
        [Parameter(Mandatory=$true)]
        [hashtable]$Record
    )
    
    # Asegurar directorio existe
    if (-not (Test-Path $script:METRICS_DIR)) {
        New-Item -ItemType Directory -Path $script:METRICS_DIR -Force | Out-Null
    }
    
    # Archivo mensual: operations-YYYY-MM.jsonl
    $month = (Get-Date).ToUniversalTime().ToString("yyyy-MM")
    $filePath = Join-Path $script:METRICS_DIR "operations-$month.jsonl"
    
    # Append al archivo
    $json = $Record | ConvertTo-Json -Compress
    Add-Content -Path $filePath -Value $json -Encoding UTF8
}

function Get-ErrorCategory {
    <#
    .SYNOPSIS
        Clasifica un error en una categoría conocida.
    .PARAMETER Error
        Objeto de error de PowerShell
    #>
    param(
        [Parameter(Mandatory=$true)]
        $Error
    )
    
    $msg = $Error.Exception.Message.ToLower()
    
    if ($msg -match "timeout|timed out") { return "timeout" }
    if ($msg -match "401|403|unauthorized|forbidden|authentication|login") { return "auth" }
    if ($msg -match "404|not found|does not exist") { return "resource_not_found" }
    if ($msg -match "network|connection|socket|dns") { return "network" }
    if ($msg -match "permission|access denied") { return "permission" }
    if ($msg -match "validation|invalid|schema") { return "validation" }
    
    return "unknown"
}

function Get-MetricsSummary {
    <#
    .SYNOPSIS
        Genera un resumen de métricas para un período.
    .PARAMETER StartDate
        Fecha de inicio (inclusive)
    .PARAMETER EndDate
        Fecha de fin (inclusive)
    .PARAMETER Domain
        Filtrar por dominio (opcional)
    #>
    param(
        [datetime]$StartDate = (Get-Date).AddDays(-7),
        [datetime]$EndDate = (Get-Date),
        [string]$Domain = ""
    )
    
    $records = @()
    
    # Leer archivos del período
    $months = @()
    $current = $StartDate
    while ($current -le $EndDate) {
        $months += $current.ToString("yyyy-MM")
        $current = $current.AddMonths(1)
    }
    $months = $months | Select-Object -Unique
    
    foreach ($month in $months) {
        $filePath = Join-Path $script:METRICS_DIR "operations-$month.jsonl"
        if (Test-Path $filePath) {
            Get-Content $filePath | ForEach-Object {
                try {
                    $r = $_ | ConvertFrom-Json
                    $ts = [datetime]::Parse($r.timestamp)
                    if ($ts -ge $StartDate -and $ts -le $EndDate) {
                        if (-not $Domain -or $r.domain -eq $Domain) {
                            $records += $r
                        }
                    }
                } catch { }
            }
        }
    }
    
    # Agrupar por dominio
    $byDomain = @{}
    foreach ($r in $records) {
        if (-not $byDomain.ContainsKey($r.domain)) {
            $byDomain[$r.domain] = @{
                total = 0
                success = 0
                failure = 0
                partial = 0
                skipped = 0
                avg_duration_ms = 0
                durations = @()
            }
        }
        $byDomain[$r.domain].total++
        $byDomain[$r.domain]."$($r.status)"++
        $byDomain[$r.domain].durations += $r.duration_ms
    }
    
    # Calcular promedios
    foreach ($domain in $byDomain.Keys) {
        $durations = $byDomain[$domain].durations
        if ($durations.Count -gt 0) {
            $byDomain[$domain].avg_duration_ms = [int]($durations | Measure-Object -Average).Average
        }
        $byDomain[$domain].Remove("durations")
    }
    
    # Top errores
    $errors = $records | Where-Object { $_.status -eq "failure" -and $_.error_category } | 
              Group-Object error_category | 
              Sort-Object Count -Descending |
              Select-Object -First 5 |
              ForEach-Object { @{ category = $_.Name; count = $_.Count } }
    
    return @{
        period = @{
            start = $StartDate.ToString("yyyy-MM-dd")
            end = $EndDate.ToString("yyyy-MM-dd")
        }
        total_operations = $records.Count
        by_domain = $byDomain
        top_errors = $errors
    }
}

# Funciones disponibles cuando se dot-source este archivo:
# - Start-OperationMetric
# - Complete-OperationMetric
# - Get-ErrorCategory
# - Get-MetricsSummary
# - Save-MetricRecord
