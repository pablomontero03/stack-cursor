# Memoria — aks-diagnoser

## Propósito

Diagnóstico de solo lectura de clústeres AKS: eventos, logs, métricas,
scheduling, red, DNS, almacenamiento, ingress, autoscaling, nodos y salud
general. Nunca aplica una corrección — si propone una, la deriva al flujo
de aprobación de `aks-operator`/`Apply-AksChangePlan.ps1`.

## Alcance de esta memoria

Causas raíz reutilizables de problemas de clúster ya diagnosticados
(scheduling, CrashLoopBackOff, DNS, ingress, PVC, autoscaling), y patrones
de diagnóstico que resultaron efectivos.

- [debugging.md](debugging.md) — síntomas, causas raíz confirmadas y
  comprobaciones seguras.
- [patterns.md](patterns.md) — convenciones y decisiones técnicas
  confirmadas del dominio AKS.

## Aprendizajes esenciales

Ninguno todavía — este agente se implementó el 2026-08-26 y no tiene
diagnósticos reales previos.

Última revisión: 2026-08-26 (creación inicial).

## Regla operacional: no ejecutar setup.sh de Kiro
Confirmado en producción 2026-09-21. No ejecutar `setup-kiro.sh`. `./setup-cursor.sh` no reinicia el worker.

**Siempre usar en sesiones activas de Crew:**
```bash
set -a; source /home/cursor/stack-cursor/env/.env; set +a
export REPO_ROOT=/home/cursor/stack-cursor
```
O con el flag seguro: `set -a; source env/.env; set +a`

No ejecutar `source ./setup.sh`. Para variables: `set -a; source env/.env; set +a`.

## Lección 2026-09-23 — AKS 0001: timeout es NSG en Deny, no auth

Un timeout al API server de `gmon-prod-aks-eastus2-0001` (`dial tcp
10.4.0.10:443: i/o timeout`) NO es problema de auth ni de `az login`: es la
regla NSG **`PRODAKS1_Rule`** (nsg `gmon-hub-ComputeSubnet-nsg-eastus2-0001`,
rg `gmon_hub_rg_eastus2_0001`, Outbound `10.1.0.200 → 10.4.0.10:443`, prio
1100) en **`Deny` por defecto**. Este host sale con `src 10.1.0.200` (misma
identidad de red del agente ADO). El 0004 no pasa por esta regla y conecta
directo. Diagnóstico rápido: `curl -sk --max-time 12 https://10.4.0.10:443/livez`
→ `http_code=000` (timeout) = NSG en Deny; `http_code=401` = red abierta,
servidor pidiendo auth. El operador la abre/cierra con el ciclo Allow→Deny
(ver steering aks.md y memoria del aks-operator). Validado 2026-09-23.

## Lección 2026-09-23 — Diagnóstico del MCP aks con 0 herramientas

Si el MCP `aks` sale `failed`/0 tools en `/mcp`, NO es sesión Azure: el binario
`aks-mcp` aborta con `Validation failed: cilium/hubble is not installed` cuando esos
binarios no están en PATH (no vienen en el clone). Para ver el error real, capturar
el handshake stdio a archivo con un `sleep` entre `initialize` y `tools/list` (el
probe one-shot por pipe cierra stdin antes del `tools/list` y no muestra nada). Fix:
`--enabled-components` sin cilium/hubble en `mcp.json`. Un 403 posterior al leer
clusters (`AuthorizationFailed`, client id distinto al SP) es la managed identity del
host sin rol, no el SP del `.env`. Ver `docs/IMPLEMENTACION-CREW-KIRO.md`.
