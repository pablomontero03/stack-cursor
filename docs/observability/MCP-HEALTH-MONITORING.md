# MCP Health Monitoring

## Descripción

Monitoreo automatizado de la disponibilidad de los servicios/MCPs externos que el stack consume. Corre cada 15 minutos y notifica **solo cuando hay degradación nueva** (no al recuperar, para evitar ruido).

## Servicios monitoreados

| Servicio | Descripción | Check | Crítico |
|----------|-------------|-------|---------|
| `kubectl-local` | kubectl CLI disponible | `kubectl version --client` | ✅ |
| `az-cli` | Azure CLI autenticado | `az account show` | ✅ |
| `k3s-dev` | Cluster k3s-dev accesible | `kubectl cluster-info` | ✅ |
| `prod-onprem-01` | Cluster prod-onprem-01 accesible | `kubectl cluster-info` | ✅ |
| `n8n-interno` | n8n interno (172.16.2.60:5678) | HTTP /healthz | ✅ |
| `n8n-productivo` | n8n productivo | HTTPS /healthz | ✅ |
| `teams-mcp-token` | Token de Teams MCP válido | File exists | ⚠️ |
| `aks-mcp-binary` | Binario aks-mcp presente | File exists | ✅ |
| `ado-pat-env` | Variable AZURE_DEVOPS_PAT definida | Env var | ✅ |

## Archivos

| Archivo | Descripción |
|---------|-------------|
| `scripts/crons/mcp_health.py` | Script del cron |
| `.local/mcp-health/status.json` | Estado actual de todos los checks |
| `.local/mcp-health/history.jsonl` | Historial de checks (append-only) |

## Estado JSON

```json
{
  "checks": {
    "kubectl-local": {
      "name": "kubectl-local",
      "description": "kubectl CLI disponible",
      "critical": true,
      "status": "ok",
      "latency_ms": 150,
      "timestamp": "2026-11-11T16:00:00Z"
    },
    ...
  },
  "last_run": "2026-11-11T16:00:00Z",
  "last_alert": null,
  "critical_failures": [],
  "non_critical_failures": []
}
```

## Historial JSONL

Cada línea es un registro de la corrida:

```json
{"timestamp": "2026-11-11T16:00:00Z", "critical_failures": 0, "non_critical_failures": 0, "total_checks": 9, "new_failures": [], "recoveries": []}
```

## Notificaciones

El cron notifica **solo en degradación nueva**:

- 🔴 `MCP Health: N servicio(s) CRÍTICO(s) caído(s): nombre1, nombre2`
- ⚠️ `MCP Health: N servicio(s) no crítico(s) con problemas: nombre1`

No notifica:
- Cuando todo está OK
- Cuando un servicio se recupera (silencioso para evitar ruido)
- Cuando un fallo ya estaba presente en la corrida anterior

## Agregar un nuevo servicio

Editar `MCP_CHECKS` en `mcp_health.py`:

```python
{
    "name": "nuevo-servicio",
    "description": "Descripción del servicio",
    "check_type": "command",  # o "file_exists" o "env_var"
    "check_cmd": ["curl", "-sf", "http://..."],
    "timeout": 10,
    "critical": True,  # False para no-críticos
},
```

## Dashboard Widget (futuro)

El widget de dashboard lee `status.json` y muestra:
- Estado verde/rojo por servicio
- Latencia promedio
- Historial de las últimas 24h

## Cron Job

```bash
# Registrado con cron_add:
# - name: "MCP Health Monitor"
# - every: 900 (15 min)
# - script: scripts/crons/mcp_health.py:run
# - minimal_context: true
```
