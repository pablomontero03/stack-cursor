# Daily Ops Review

Cron diario que analiza los fallos del día, detecta patrones y genera sugerencias de fix.

## Horario

- **Ejecución:** 4:00 PM Costa Rica (22:00 UTC)
- **Job ID:** `639115d6`
- **Script:** `scripts/crons/daily_ops_review.py:run`

## Fuentes de datos

| Fuente | Ubicación | Qué aporta |
|--------|-----------|------------|
| Métricas de operaciones | `.local/metrics/operations-YYYY-MM.jsonl` | Fallos de Apply-*, SSH, etc. |
| MCP Health | `.local/mcp-health/status.json` | MCPs caídos durante el día |
| Estado de alertas Teams | `.local/teams-ops/alert-state.json` | Alertas que no se resolvieron |

## Comportamiento

1. **Corrida silenciosa** si no hay fallos, MCPs degradados ni alertas sin resolver
2. **ctx.notify()** al agente si hay algo que reportar

## Estructura del reporte

El reporte se guarda en `.local/metrics/daily-reviews/YYYY-MM-DD.json`:

```json
{
  "date": "2026-11-11",
  "generated_at": "2026-11-11T22:00:00+00:00",
  "summary": {
    "total_operations": 47,
    "successful": 44,
    "failures": 3,
    "mcps_degraded": 1,
    "alerts_unresolved": 2,
    "suggested_lessons": 2
  },
  "failures": {
    "total_failures": 3,
    "by_domain": {
      "linux-servers": {
        "count": 2,
        "by_resource": {"172.16.2.61": 2},
        "failures": [...]
      }
    },
    "patterns": [
      {
        "type": "repeated_failure",
        "domain": "linux-servers",
        "resource": "172.16.2.61",
        "count": 2,
        "error_categories": ["network"]
      }
    ]
  },
  "mcp_issues": [...],
  "unresolved_alerts": [...],
  "suggested_lessons": [...],
  "needs_attention": true
}
```

## Patrones detectados

- **repeated_failure:** Mismo recurso falla 2+ veces en el día
- *Extensible a más patrones según se identifiquen*

## Taxonomía de sugerencias (generadas por el agente)

| Tipo | Auto-aplicable | Ejemplo |
|------|----------------|---------|
| `config_update` | ✅ Con OK | Marcar base como heavy en databases.json |
| `whitelist_add` | ✅ Con OK | Agregar comando a allowed-commands.json |
| `timeout_adjust` | ✅ Con OK | Subir timeout de un workflow n8n |
| `retry_operation` | ✅ Con OK | Re-ejecutar un sync que falló por timeout |
| `manual_check` | ❌ Solo reporte | Verificar servidor físicamente |
| `code_fix` | ❌ Solo reporte | Bug en app, reportar al dev |
| `prod_change` | ❌ Solo reporte | Cambio en producción, espera decisión |
| `escalate` | ❌ Solo reporte | Problema fuera del alcance del stack |

## Integración con otros sistemas

- **MCP Health Monitor:** Lee el estado de los checks de MCPs
- **Teams Ops Triage:** Lee alertas no resueltas del canal de alertas
- **Métricas de Uso:** Lee todas las operaciones registradas

## Dominios instrumentados

Para que el Daily Ops Review capture fallos de un dominio, ese dominio debe llamar a las funciones de métricas.

### PowerShell (scripts Apply-*.ps1)

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

### Python (crons y scripts)

```python
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

## Dominios actualmente instrumentados

| Dominio | Instrumentado | Vía |
|---------|---------------|-----|
| `linux-servers` | ✅ | `Invoke-ServerCommand.ps1` |
| `mcp-health` | ✅ | Cron `mcp_health.py` (pendiente) |
| `teams-ops` | ✅ | Cron `teams_triage.py` (pendiente) |
| `schema-sync` | ⏳ Pendiente | — |
| `aks` | ⏳ Pendiente | — |
| `azure-devops-pipelines` | ⏳ Pendiente | — |
| `azure-devops-permissions` | ⏳ Pendiente | — |
| `azure` | ⏳ Pendiente | — |
| `cloudflare` | ⏳ Pendiente | — |
| `n8n` | ⏳ Pendiente | — |

## Historial de reviews

Los reportes diarios se guardan en `.local/metrics/daily-reviews/` con formato `YYYY-MM-DD.json`.

## Lecciones sugeridas (suggested_lessons)

A partir de 2026-11-11, el Daily Ops Review genera **lecciones sugeridas** basadas en patrones de fallo. Esto permite que el agente aprenda de los errores y mejore con el tiempo.

### Estructura de una lección

```json
{
  "rule": "La lección a aprender (qué hacer)",
  "negative": "Qué NO hacer (opcional)",
  "category": "knowledge|tool|preference",
  "applies": "always|on_topic",
  "confidence": "high|medium|low",
  "evidence": "Datos concretos que respaldan la sugerencia",
  "domain": "linux-servers",
  "resource": "172.16.2.61"
}
```

### Patrones que generan lecciones

| Patrón detectado | Tipo de lección | Confianza |
|------------------|-----------------|-----------|
| Conectividad recurrente (connection/timeout/network) | Verificar estado de red antes de operar | high si ≥3, medium si =2 |
| Errores de autenticación (auth/permission) | Verificar tokens/credenciales | medium |
| Errores de validación (validation) | Revisar parámetros/esquemas | medium |
| MCPs con problemas de conectividad | Usar fallback (CLI/REST) | medium |
| MCPs con problemas de auth (401/403) | Verificar tokens/OAuth | high |
| Alertas sin resolver >24h | Escalar o investigar | high |
| Alertas sin resolver >8h | Diagnóstico más profundo | medium |
| Dominio con ≥5 fallos en el día | Problema sistémico, diagnosticar causa raíz | high |

### Flujo de aprendizaje

1. **Cron detecta patrón** → genera `suggested_lessons` en el reporte
2. **Agente recibe notificación** con las lecciones pre-analizadas
3. **Agente revisa** cada lección y su confianza/evidencia
4. **Con aprobación de Pablo** → `learn_add` para guardar las que apliquen

### Ejemplo de uso

Si el reporte sugiere una lección con alta confianza:

```python
# El agente puede guardarla con:
learn_add(
    rule="El servidor 172.16.2.61 tiene problemas de conectividad recurrentes. Verificar estado de red antes de operaciones masivas.",
    negative="No asumir que 172.16.2.61 está disponible sin verificar primero con ping/healthcheck.",
    category="knowledge",
    applies="on_topic"
)
```

### Notas importantes

- **Las lecciones son sugerencias**: el agente NO guarda automáticamente; Pablo decide cuáles aplicar
- **Confianza guía la decisión**: `high` = muy probable que valga guardar; `low` = revisar con cuidado
- **Evidencia incluida**: cada lección incluye los datos concretos que la respaldan
