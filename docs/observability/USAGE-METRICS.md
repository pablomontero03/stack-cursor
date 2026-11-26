# Métricas de Uso por Dominio

## Descripción

Sistema de tracking de operaciones exitosas/fallidas por dominio para identificar áreas de mejora y medir adopción del stack.

## Cómo registrar operaciones

### Desde PowerShell (scripts .ps1)

```powershell
. "$REPO_ROOT/scripts/common/Metrics-Common.ps1"

$metric = Start-OperationMetric -Domain "aks" -Operation "kubectl_apply" -Metadata @{
    namespace = "tools"
    resource = "deployment/myapp"
}

try {
    # ... operación ...
    Complete-OperationMetric -Metric $metric -Status "success"
} catch {
    Complete-OperationMetric -Metric $metric -Status "failure" `
        -ErrorCategory (Get-ErrorCategory $_) `
        -ErrorMessage $_.Exception.Message
    throw
}
```

### Desde Python (crons y scripts)

```python
import sys
sys.path.insert(0, "/home/cursor/stack-cursor/scripts/common")
from metrics_common import start_operation, complete_operation, get_error_category

metric = start_operation("schema-sync", "extract", metadata={"database": "core_ops"})

try:
    # ... operación ...
    complete_operation(metric, "success")
except Exception as e:
    complete_operation(metric, "failure", 
                      error_category=get_error_category(e),
                      error_message=str(e))
    raise
```

### Desde bash (CLI)

```bash
# Registrar éxito
python3 scripts/common/record-operation.py success aks kubectl_apply \
    --metadata '{"namespace": "tools", "resource": "deployment/myapp"}' \
    --duration-ms 1500

# Registrar fallo
python3 scripts/common/record-operation.py failure schema-sync extract \
    --error-category timeout \
    --error-message "Timeout after 40 minutes" \
    --metadata '{"database": "stg_hana"}'
```

## Arquitectura

```
Scripts Apply-*
       │
       ▼
┌─────────────────────────┐
│  Metrics-Common.ps1     │
│  Start-OperationMetric  │
│  Complete-OperationMetric│
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ .local/metrics/         │
│ operations-YYYY-MM.jsonl│
└───────────┬─────────────┘
            │ (cron semanal)
            ▼
┌─────────────────────────┐
│ aggregate-weekly.py     │
└───────────┬─────────────┘
            │
            ▼
┌─────────────────────────┐
│ weekly-summary.json     │
└─────────────────────────┘
```

## Dominios

| Dominio | Scripts instrumentados |
|---------|------------------------|
| `azure` | Apply-AzureChangePlan.ps1, Apply-AzureDeletePlan.ps1 |
| `aks` | Apply-AksChangePlan.ps1 |
| `azure-devops-pipelines` | Apply-AdoClassicPlan.ps1 |
| `azure-devops-permissions` | Apply-AdoPermissionsPlan.ps1 |
| `cloudflare` | (futuro) |
| `n8n` | (futuro) |
| `schema-sync` | (futuro) |
| `linux-servers` | (futuro) |
| `windows-servers` | (futuro) |

## Formato de registro

Cada operación se guarda como una línea JSON en `.local/metrics/operations-YYYY-MM.jsonl`:

```json
{
  "domain": "azure-devops-pipelines",
  "operation": "apply_classic_plan",
  "status": "success",
  "duration_ms": 12345,
  "timestamp": "2026-11-11T16:00:00Z",
  "session_id": "chat-abc123",
  "error_category": null,
  "error_message": null,
  "metadata": {
    "plan_hash": "abc123",
    "resources_affected": 3
  }
}
```

## Estados

| Estado | Descripción |
|--------|-------------|
| `success` | Operación completada exitosamente |
| `failure` | Operación falló |
| `partial` | Operación parcialmente exitosa |
| `skipped` | Operación omitida (dry-run, ya existía, etc.) |

## Categorías de error

| Categoría | Descripción |
|-----------|-------------|
| `validation` | Error de validación del plan |
| `network` | Error de red/conectividad |
| `auth` | Error de autenticación/autorización |
| `timeout` | Timeout de operación |
| `permission` | Permisos insuficientes |
| `resource_not_found` | Recurso no encontrado |
| `unknown` | Error no clasificado |

## Uso en scripts

```powershell
# Al inicio del script
. $PSScriptRoot/../common/Metrics-Common.ps1

# Iniciar tracking
$metric = Start-OperationMetric `
    -Domain "azure-devops-pipelines" `
    -Operation "apply_classic_plan" `
    -SessionId $env:KIRO_SESSION_ID `
    -Metadata @{ plan_hash = $plan.Hash }

try {
    # ... operación real ...
    
    Complete-OperationMetric -Metric $metric -Status "success"
}
catch {
    Complete-OperationMetric `
        -Metric $metric `
        -Status "failure" `
        -ErrorCategory (Get-ErrorCategory $_) `
        -ErrorMessage $_.Exception.Message
    throw
}
```

## Agregación

El script `aggregate-weekly.py` corre semanalmente y produce `weekly-summary.json`:

```json
{
  "generated_at": "2026-11-11T16:00:00Z",
  "period": {
    "start": "2026-10-14T00:00:00Z",
    "end": "2026-11-11T16:00:00Z",
    "weeks": 4
  },
  "total_operations": 142,
  "overall_success_rate": 94.4,
  "by_week": {
    "2026-W45": {
      "total": 42,
      "success": 40,
      "failure": 2,
      "success_rate": 95.2,
      "by_domain": {
        "azure-devops-pipelines": {
          "total": 25,
          "success": 24,
          "failure": 1,
          "avg_duration_ms": 8500
        }
      },
      "top_errors": [
        {"category": "validation", "count": 1}
      ]
    }
  }
}
```

## Cron de agregación

```bash
# Registrado con cron_add:
# - name: "Metrics Weekly Aggregation"
# - cron_expr: "0 6 * * 1"  # Lunes 6am
# - command: "python3 /home/cursor/stack-cursor/scripts/metrics/aggregate-weekly.py"
```

## Consultas útiles

### Ver operaciones de hoy
```bash
tail -100 .local/metrics/operations-$(date +%Y-%m).jsonl | \
  python3 -c "import json,sys; [print(f\"{json.loads(l)['domain']}: {json.loads(l)['status']}\") for l in sys.stdin]"
```

### Contar fallos por dominio
```bash
cat .local/metrics/operations-*.jsonl | \
  python3 -c "
import json,sys
from collections import Counter
c = Counter()
for l in sys.stdin:
    r = json.loads(l)
    if r['status'] == 'failure':
        c[r['domain']] += 1
for d,n in c.most_common(): print(f'{d}: {n}')
"
```

## Retención

- Archivos JSONL mensuales: 6 meses
- weekly-summary.json: solo la última ejecución
- Limpieza manual o por cron de mantenimiento
