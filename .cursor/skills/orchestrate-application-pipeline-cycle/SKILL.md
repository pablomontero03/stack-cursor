---
name: orchestrate-application-pipeline-cycle
description: Coordina el ciclo completo de creacion/validacion de un pipeline de aplicacion cuando la solicitud involucra dos o mas de: Azure DevOps clasico, Cloudflare DNS, analisis de codigo/ramas, Kubernetes/AKS y ejecucion Desarrollo/UAT.
triggers: [ciclo completo, pipeline ciclo, orquestacion, multi-dominio, nueva aplicacion]
always: false
---

# Orchestrate Application Pipeline Cycle

Skill **coordinadora**, no de dominio. No tiene reglas de seguridad
propias en `.cursor/rules/orchestrate-application-pipeline-cycle/` más
allá de invariantes de coordinación (ver `authorization.md`/`security.md`
de ese dominio) — la seguridad real de cada escritura sigue viviendo en
los hooks y reglas de Azure DevOps Pipelines, Cloudflare y AKS. Este
archivo nunca duplica esos procedimientos; solo enruta hacia ellos.

## Cuándo activarse

Activarse cuando la solicitud es la creación/validación integral de un
pipeline de aplicación que cruza **2 o más** de estos dominios:

- Azure DevOps clásico (Build/Release/Variable Groups).
- Cloudflare DNS.
- Análisis de código o ramas.
- Kubernetes/AKS.
- Ejecución Desarrollo/UAT y preparación de Producción.

**No activarse** para una consulta aislada de un solo dominio (revisar un
DNS puntual, un Build existente, un pod) — esas siguen su skill de
dominio directamente (`manage-azure-devops-pipelines`,
`manage-cloudflare`, `manage-aks-clusters`).

## Cargar solamente el contexto necesario

No cargar las 4 referencias de una. Cargar según la fase:

| Fase | Cuándo | Referencia a cargar |
|------|--------|----------------------|
| `intake` | Leer y validar `INPUT` de la plantilla ligera | `references/input-contract.md` |
| `discover` / `plan` | Coordinar descubrimiento paralelo, construir el plan consolidado, envolvente de corrección, tratamiento de errores | `references/orchestration-flow.md` |
| `approve` | Presentar/verificar la Aprobación 1, Aprobación 2 y eliminaciones | `references/approval-envelope.md` |
| `execute` / `report` | Monitoreo activo, clasificación del resultado, tiempos, routing de memorias | `references/status-timing-and-memory.md` |
| `roadmap` | Consultar el plan futuro de operación desatendida/en background ("modo agéntico") — no implementado todavía | `references/agentic-mode-roadmap.md` |

## Principio rector

La skill coordinadora **orquesta, no duplica**. Cada procedimiento técnico
vive y se ejecuta en su dominio:

| Necesidad | Dominio que la resuelve |
|---|---|
| Exports canónicos, matriz de conservación, generador, Apply, Variable Groups, Build, Release, secreto ACR, polling de Build/Release | `manage-azure-devops-pipelines` (`ado-pipeline-builder`/`-reviewer`/`-diagnoser`) |
| DNS: resolución de zona, reuso/conflicto, readback | `manage-cloudflare` (`cloudflare-operator`/`-reviewer`/`-diagnoser`) |
| Capacidad de pods, rollout, readback K8s, clasificación del despliegue | `manage-aks-clusters` (`aks-operator`/`-reviewer`/`-diagnoser`) |
| Código: framework, Dockerfile, puertos, sondas, ramas | Lecturas directas vía `mcp__azure-devops__repo_file`/`repo_branch`/`repo_search_commits`, coordinadas por esta skill o por `ado-pipeline-builder`; no existe un agente de dominio dedicado a esto todavía |

## Flujo resumido

```text
1. Leer INPUT (plantilla ligera) → Test-ApplicationCycleInput.ps1
2. Snapshot inicial de hashes/commits/revisiones → New-ApplicationCycleSnapshot.ps1
3. Descubrimiento en paralelo (4 fuentes de solo lectura) — ver orchestration-flow.md
4. Consolidar plan único (todas las adaptaciones, matrices, pendientes)
5. Aprobación 1 (plan no productivo) — ver approval-envelope.md
6. Aplicar en el orden de dependencias (Azure DevOps/Cloudflare → Desarrollo → UAT)
7. Monitoreo activo de Build/Release/rollout — ver status-timing-and-memory.md
8. Preparar Producción sin ejecutar
9. Aprobación 2 (Producción) cuando el usuario decida continuar
10. Reporte final + routing de memorias
```

No saltear pasos. El paso 6 nunca incluye Producción ni ninguna
eliminación — esas requieren siempre su propia aprobación (paso 9, o el
flujo de eliminación de cada dominio).

## Scripts (`scripts/`)

Solo lo que es puramente coordinador y determinista — nada que ya exista
en una skill de dominio:

| Script | Uso | Requiere aprobación |
|--------|-----|----------------------|
| `Test-ApplicationCycleInput.ps1` | Valida el bloque `INPUT` (campos obligatorios, tipos, enums, coherencia interna) antes de iniciar el descubrimiento | No |
| `New-ApplicationCycleSnapshot.ps1` | Construye el snapshot canónico (hash) de hashes/commits/revisiones/IDs ya obtenidos por los dominios, para detectar reutilización válida vs. drift | No |

Ninguno de los dos llama a Azure DevOps, Cloudflare o AKS por sí mismo —
reciben datos ya obtenidos por las skills de dominio. Toda escritura real
sigue pasando exclusivamente por `Apply-AdoClassicPlan.ps1`,
`Apply-CloudflareChangePlan.ps1`/`Apply-CloudflareDeletePlan.ps1` y
`Apply-AksChangePlan.ps1` — esta skill nunca introduce una vía de
escritura alternativa.

## Fuentes de verdad de este dominio

- Autorización y seguridad (invariantes de coordinación, no
  procedimientos): `.cursor/rules/orchestrate-application-pipeline-cycle/authorization.md`
  y `security.md`.
- Plantilla ligera de una ejecución:
  `docs/PLANTILLA-CICLO-CREACION-PIPELINE-APLICACION-LIGERA.md`.
- Plantilla completa histórica (preservada, no reemplazada todavía):
  `docs/PLANTILLA-CICLO-CREACION-PIPELINE-APLICACION.md` — ver
  `references/orchestration-flow.md` § Migración para el estado de esa
  decisión.
- Especificación de este refactor:
  `docs/INSTRUCCIONES-REFACTORIZAR-CICLO-PIPELINE-APLICACION.md`.
