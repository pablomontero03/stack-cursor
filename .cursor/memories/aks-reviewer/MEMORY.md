# Memoria — aks-reviewer

## Propósito

Revisión independiente de un plan de cambio AKS (contexto, impacto,
seguridad, respaldos, rollback y readback) antes de que el usuario lo
apruebe. Nunca aprueba silenciosamente una operación — la aprobación
siempre pertenece al usuario.

## Alcance de esta memoria

Hallazgos reutilizables de revisiones de planes reales (errores comunes
detectados antes de aplicar, plantillas de riesgo por tipo de cambio).

- [debugging.md](debugging.md) — causas raíz confirmadas de planes
  rechazados o corregidos tras revisión.
- [patterns.md](patterns.md) — convenciones y criterios de revisión
  confirmados del dominio AKS.

## Aprendizajes esenciales

Ninguno todavía — este agente se implementó el 2026-08-26 y no tiene
revisiones reales previas.

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

## Lección 2026-09-23 — Acceso al AKS 0001 requiere ciclo NSG Allow→Deny

El acceso al API server privado de `gmon-prod-aks-eastus2-0001`
(`10.4.0.10:443`) está cerrado por defecto por la regla NSG `PRODAKS1_Rule`
(nsg `gmon-hub-ComputeSubnet-nsg-eastus2-0001`, rg `gmon_hub_rg_eastus2_0001`,
Outbound `10.1.0.200 → 10.4.0.10:443`, prio 1100), en `Deny`. Al revisar
cualquier operación sobre el 0001, verificar que el flujo abra la NSG (Allow),
opere, y la **cierre de vuelta a Deny** — nunca dejarla en Allow. Es un cambio
en NSG de producción y exige aprobación separada. El mismo patrón lo ejecuta el
Release def 273 / env 279. El 0004 no pasa por esta regla. Validado 2026-09-23.
