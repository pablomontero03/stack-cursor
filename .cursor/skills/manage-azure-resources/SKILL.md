---
name: manage-azure-resources
description: Administra el plano de control de Microsoft Azure via Azure CLI y Resource Graph: VNets, NSG, VMs, App Service, ACR, Storage, Key Vault, RBAC, Policy, Monitor y AKS como recurso de Azure.
triggers: [azure, arm, resource group, az cli, vnet, nsg, vm, storage, keyvault, policy, rbac]
always: false
---

# Manage Azure Resources

Dominio separado de Azure DevOps Pipelines/Permissions, AKS/Kubernetes/
Helm, Schema Sync y `manage-linux-servers` — sin scripts, hooks, agentes,
memoria ni datos transitorios compartidos con ninguno de ellos.

## Regla de oro de este dominio

Toda base de datos SQL sigue siendo de solo lectura para todo el proyecto
(regla global de `CLAUDE.md`) — este dominio administra Azure SQL/SQL MI
únicamente en el **plano de infraestructura** (crear el servidor, la base
vacía, configurar firewall/redes/backup), nunca sus datos. Dentro de
Azure: lectura/inventario/diagnóstico/Resource Graph/what-if son
automáticos; toda escritura real o eliminación exige aprobación explícita;
nada queda prohibido de forma permanente salvo lo listado en
`.cursor/rules/azure/security.md` § Prohibido permanentemente — un comando
`az` o tool MCP no reconocido siempre resuelve a "preguntar", nunca a
"denegar".

## Alcance — dónde termina este dominio

| Si la solicitud es sobre... | Usar |
|---|---|
| Recursos de Azure (VMs, redes, Storage, Key Vault, App Service, ACR, Azure SQL como infraestructura, Monitor, Policy, RBAC, el propio clúster/node pools de AKS) | Este dominio (`manage-azure-resources`) |
| Objetos DENTRO de un clúster AKS ya existente (pods, Deployments, Services, Helm releases, kubectl) | `manage-aks-clusters` |
| Pipelines, Builds, Releases, Variable Groups de Azure DevOps | `manage-azure-devops-pipelines` |
| Grupos de seguridad, permisos Git, Branch Policies de Azure DevOps | `manage-azure-devops-permissions` |
| Datos dentro de una base SQL (siempre solo lectura, cualquier dominio) | Ver "Regla de oro" de `CLAUDE.md` — nunca se escribe |

Ver `references/scope-and-routing.md` para el detalle completo, incluido
el caso ambiguo de AKS (infraestructura del clúster vs. objetos internos).

## Estado del MCP `azure` — leer antes de asumir nada

El MCP oficial `azure` (`@azure/mcp`) está **diferido a propósito** — no
existe en `.mcp.json` (la única versión publicada hoy, 2026-09-03, es una
pre-release `3.0.0-beta.40`). Este dominio funciona 100% con Azure CLI +
Resource Graph + ARM REST controlado. Ver
`.cursor/rules/azure/authorization.md` § Estado del MCP `azure` antes de
proponer instalarlo.

## Cargar solamente el contexto necesario

No cargar todas las referencias de una. Cargar según el modo (tabla
abajo). Nunca duplicar su contenido en este archivo ni en la respuesta al
usuario — referenciarlas por ruta.

## Enrutamiento de modos

| Modo | Cuándo | Referencia a cargar |
|------|--------|----------------------|
| `route` | Decidir si la solicitud es de este dominio o de otro (AKS, ADO) | `references/scope-and-routing.md` |
| `auth` | Verificar sesión de `az`, tenant/suscripción activos, o decidir si hace falta `az login` | `references/authentication-and-context.md` |
| `classify` | Decidir si un comando `az`/tool concreto es automático o exige aprobación | `references/command-classification.md` |
| `inventory` | Inventariar recursos, correr una consulta Resource Graph | `references/inventory-and-resource-graph.md` |
| `plan` | Armar/validar un plan de cambio antes de aplicar | `references/change-plan-schema.md` (delegar a `azure-operator`, revisar con `azure-reviewer`) |
| `apply` | Aplicar un plan ya aprobado (no destructivo o destructivo), o hacer readback | `references/apply-readback-rollback.md` |
| `secrets` | Un plan toca un Key Vault, RBAC, un lock, o cualquier dato sensible | `references/secrets-rbac-locks.md` |
| `diagnose` | Un recurso falla o se comporta raro | delegar a `azure-diagnoser` (usa `inventory-and-resource-graph.md` + Activity Log) |

## Flujo de decisión rápido

1. ¿Es lectura/inventario/Resource Graph/Activity Log/what-if/validación?
   → ejecutar directo, sin pedir aprobación (ver
   `references/command-classification.md`).
2. ¿Es una eliminación? → siempre su propia aprobación, nunca agrupada con
   el plan principal; un Resource Group completo siempre aislado (ver
   `references/apply-readback-rollback.md` § Eliminaciones).
3. ¿Es cualquier otra escritura real (create/update/action, `az rest`
   POST/PUT/DELETE, deployment)? → flujo completo de
   `references/change-plan-schema.md` + `apply-readback-rollback.md` —
   aprobación explícita antes de ejecutar, cubre todo el lote no
   destructivo del plan.
4. ¿Involucra un Key Vault, una Storage Account key, un SAS token, RBAC, o
   un lock? → ver `references/secrets-rbac-locks.md` — preguntar siempre.
5. ¿El comando o la tool no encaja claramente en ninguna categoría
   anterior? → preguntar. Nunca asumir lectura, nunca bloquear
   permanentemente.

## Agentes de este dominio

- **`azure-operator`** (`.cursor/agents/azure-operator.md`):
  inventario, planificación y ejecución aprobada de cambios.
- **`azure-diagnoser`** (`.cursor/agents/azure-diagnoser.md`):
  diagnóstico de solo lectura; deriva cualquier corrección al flujo de
  aprobación.
- **`azure-reviewer`** (`.cursor/agents/azure-reviewer.md`):
  revisión independiente de un plan antes de aplicarlo; nunca aprueba en
  nombre del usuario.

## Scripts (`scripts/`)

| Script | Uso | Requiere aprobación |
|--------|-----|----------------------|
| `Azure-Common.ps1` | Librería compartida (hash de plan, journal, contexto de cuenta, escaneo de secretos) — dot-sourced, nunca se ejecuta directo | — |
| `Test-AzureEnvironment.ps1` | Diagnóstico de Azure CLI/sesión/Resource Graph/estado del MCP | No |
| `Get-AzureInventory.ps1` | Inventario sanitizado vía Resource Graph (fallback `az resource list`) | No |
| `Invoke-AzureRead.ps1` | Wrapper de un subcomando `az` de solo lectura | No |
| `Invoke-AzureWhatIf.ps1` | Diff actual→deseado (deployment what-if real, o diff manual) | No |
| `New-AzureChangePlan.ps1` | Genera un plan de cambio inmutable (sin validar) | No |
| `Test-AzureChangePlan.ps1` | Valida un plan (secretos, forma, drift de inventario, aislamiento de RG) y lo marca `validated=true` | No |
| `Apply-AzureChangePlan.ps1` | **Único** script que ejecuta escrituras reales no destructivas | **Sí** — el hook pregunta por su nombre (o reusa una aprobación visible ≤24h) |
| `Apply-AzureDeletePlan.ps1` | **Único** script que ejecuta eliminaciones reales | **Sí, siempre separada** de la del plan principal |
| `Test-AzurePostChange.ps1` | Readback tras aplicar (no destructivo o destructivo) | No |
| `New-AzureRollbackPlan.ps1` | Prepara y muestra (nunca ejecuta) una propuesta de rollback como plan nuevo | No — pero aplicar ese rollback exige el flujo completo con aprobación nueva |

## Rutas locales (`.local/azure/`, no versionado)

`inventory/`, `plans/`, `backups/` (respaldo pre-delete), `executions/`
(journal de aplicación), `logs/`, `deviations/` (reportes de desviación
del plan). Ver `.cursor/rules/azure/security.md` § Archivos locales para
la propuesta de `.gitignore` pendiente de aprobación.

## Fuentes de verdad de este dominio

- Autorización y seguridad: `.cursor/rules/azure/authorization.md` y
  `.cursor/rules/azure/security.md`.
- Arquitectura completa: `docs/azure/AZURE-AUTOMATION-ARCHITECTURE.md`.
- Especificación original: `INSTRUCCIONES-AUTOMATIZACION-AZURE.md` (raíz
  del proyecto).
