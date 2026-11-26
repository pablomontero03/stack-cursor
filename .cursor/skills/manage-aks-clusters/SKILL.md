---
name: manage-aks-clusters
description: Administra, diagnostica y opera clusteres AKS/Kubernetes/Helm mediante kubectl, Helm y Azure CLI para pods, deployments, servicios, ingress, namespaces, node pools, autoscaling, RBAC y Secrets.
triggers: [aks, kubernetes, kubectl, helm, cluster, namespace, pod, deployment, ingress]
always: false
---

# Manage AKS Clusters

Dominio separado de Azure DevOps Pipelines (que despliega HACIA AKS desde
un pipeline), Azure DevOps Permissions, Schema Sync y `manage-linux-servers`
— sin scripts, hooks, agentes, memoria ni datos transitorios compartidos
con ninguno de ellos.

## Regla de oro de este dominio

Toda base de datos SQL sigue siendo de solo lectura para todo el proyecto
(regla global de `CLAUDE.md`) — este dominio no la toca nunca, ni
indirectamente. Dentro de AKS: lectura/inventario/diagnóstico/simulación
son automáticos; toda escritura real o eliminación exige aprobación
explícita; nada queda prohibido de forma permanente salvo lo listado en
`.cursor/rules/aks/security.md` § Prohibido permanentemente — un comando o
tool MCP no reconocido siempre resuelve a "preguntar", nunca a "denegar".

## Cargar solamente el contexto necesario

No cargar todas las referencias de una. Cargar según el modo (tabla
abajo). Nunca duplicar su contenido en este archivo ni en la respuesta al
usuario — referenciarlas por ruta.

## Enrutamiento de modos

| Modo | Cuándo | Referencia a cargar |
|------|--------|----------------------|
| `classify` | Decidir si un comando/tool concreto es automático o exige aprobación | `references/command-classification.md` |
| `connect` | Resolver kubeconfig, contexto, o decidir si `az aks get-credentials` hace falta | `references/kubeconfig-and-contexts.md` |
| `diagnose` | Un pod/deployment/servicio/nodo falla o se comporta raro | `references/diagnostics.md` (delegar a `aks-diagnoser`) |
| `change` | Aplicar/parchear/escalar/eliminar un recurso real | `references/change-workflow.md` (delegar a `aks-operator`, revisar con `aks-reviewer`) |
| `rollback` | Deshacer un cambio ya aplicado | `references/backup-and-rollback.md` |
| `capacity` | Confirmar margen de pods/capacidad antes de un rollout (usado también por `orchestrate-application-pipeline-cycle`) | `references/capacity-validation.md` |
| `mcp` | Instalar/verificar/actualizar el servidor MCP `aks`, o clasificar una tool MCP nueva | `references/aks-mcp.md` |

## Flujo de decisión rápido

1. ¿Es lectura/inventario/diagnóstico/`diff`/`--dry-run=server`? →
   ejecutar directo, sin pedir aprobación (ver
   `references/command-classification.md`).
2. ¿Es una eliminación? → siempre su propia aprobación, nunca agrupada
   (ver `references/change-workflow.md` § Eliminaciones).
3. ¿Es cualquier otra escritura real (apply/patch/scale/rollout/exec/
   port-forward/helm install-upgrade-rollback-uninstall/`az aks`
   mutable/tool MCP CRUD)? → flujo completo de
   `references/change-workflow.md`, o el atajo de "cambio chico" si el
   alcance es mínimo — en ambos casos, aprobación explícita antes de
   ejecutar.
4. ¿Involucra un valor de `Secret`, un token, un certificado, o
   `kubectl config view --raw`? → preguntar siempre, sin excepción.
5. ¿El comando o la tool MCP no encaja claramente en ninguna categoría
   anterior? → preguntar. Nunca asumir lectura, nunca bloquear
   permanentemente.

## Agentes de este dominio

- **`aks-operator`** (`.cursor/agents/aks-operator.md`): inventario,
  planificación y ejecución aprobada de cambios.
- **`aks-diagnoser`** (`.cursor/agents/aks-diagnoser.md`): diagnóstico
  de solo lectura; deriva cualquier corrección al flujo de aprobación.
- **`aks-reviewer`** (`.cursor/agents/aks-reviewer.md`): revisión
  independiente de un plan antes de aplicarlo; nunca aprueba en nombre del
  usuario.

## Scripts (`scripts/`)

| Script | Uso | Requiere aprobación |
|--------|-----|----------------------|
| `Aks-Common.ps1` | Librería compartida (hash de plan, journal, resolución de kubeconfig) — dot-sourced, nunca se ejecuta directo | — |
| `Test-AksEnvironment.ps1` | Diagnóstico de herramientas/kubeconfig/contexto/MCP | No |
| `Get-AksInventory.ps1` | Inventario sanitizado de un contexto/namespace | No |
| `Invoke-AksRead.ps1` | Wrapper de un subcomando kubectl de solo lectura | No |
| `New-AksChangePlan.ps1` | Genera un plan de cambio inmutable (sin validar) | No |
| `Test-AksChangePlan.ps1` | Valida un plan (secretos, impacto, evidencia de inventario) y lo marca `validated=true` | No |
| `Apply-AksChangePlan.ps1` | **Único** script que escribe de verdad contra el clúster | **Sí** — el hook pregunta por su nombre |
| `Test-AksPostChange.ps1` | Readback tras aplicar un plan | No |
| `Invoke-AksRollback.ps1` | Prepara y muestra (nunca ejecuta) una propuesta de rollback | No — pero ejecutar el rollback vuelve a exigir el flujo completo con aprobación nueva |
| `Test-AksDeploymentCapacity.ps1` | Verificación mínima de capacidad antes de un rollout (`allocatable.pods`, margen para `maxSurge`/`maxUnavailable`); modo `-Live` o fixtures JSON | No |

## Rutas locales (`.local/aks/`, no versionado)

`inventory/`, `plans/`, `backups/`, `executions/` (journal de
aplicación), `tools/` (binario del MCP), `logs/`. `cluster/` (en la raíz
del repo) es distinto: manifiestos Kubernetes **sanitizados y
versionables** — nunca kubeconfigs, secretos reales ni respaldos de
producción (ver `.cursor/rules/aks/security.md`).

## Fuentes de verdad de este dominio

- Autorización y seguridad: `.cursor/rules/aks/authorization.md` y
  `.cursor/rules/aks/security.md`.
- Arquitectura completa: `docs/aks/AKS-AUTOMATION-ARCHITECTURE.md`.
- MCP: `references/aks-mcp.md` (versión, hash, flags, tools reales
  confirmadas tras el reload de sesión).
