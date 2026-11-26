# Matriz de permisos — referencia de solo lectura

**Ojo — esta matriz cubre ÚNICAMENTE el namespace "Git Repositories".**
No incluye "View project-level information" (namespace `Project`,
`GENERIC_READ`) — un grupo puede tener esta matriz perfecta y aun así
bloquear el acceso a TODO el proyecto (401) si esa permission está en Not
set. Ver `references/ado-security-api-map.md` § "Namespace 'Project'" y
`.claude/agent-memory/ado-permissions-builder/patterns.md` § "View
project-level information..." (caso real confirmado 2026-09-03).

**Esta página es una copia legible para humanos. La fuente de verdad
ejecutable es
`scripts/Invoke-AdoPermissionsRest.ps1::Get-AdoPermissionsMatrixDefinition`
(y `Get-AdoPermissionsManagedActionCatalog` para el mapeo a acciones del
security namespace). Si algo acá no coincide con esa función, la función
tiene razón — corregir esta página, nunca al revés.**

## Nodo `All Repositories`

| Permiso de la UI | Development Team(s) | Code-Reviewers |
|---|---:|---:|
| Advanced Security: manage and dismiss alerts | Deny | Not set |
| Advanced Security: manage settings | Deny | Not set |
| Advanced Security: view alerts | Deny | Not set |
| Bypass policies when completing pull requests | Deny | Not set |
| Bypass policies when pushing | Deny | Not set |
| Contribute | Allow | Allow |
| Contribute to pull requests | Allow | Allow |
| Create branch | Allow | Allow |
| Create repository | Deny | Not set |
| Create tag | Allow | Not set |
| Delete or disable repository | Deny | Not set |
| Edit policies | Deny | Not set |
| Enterprise Live Migration: manage migrations | Not set | Not set |
| Force push (rewrite history, delete branches and tags) | Deny | Not set |
| Manage notes | Deny | Not set |
| Manage permissions | Deny | Not set |
| Read | Allow | Allow |
| Remove others' locks | Deny | Not set |
| Rename repository | Deny | Not set |

`Enterprise Live Migration: manage migrations` es `Not set`/`Not set` para
ambos grupos — no se administra en absoluto (no requiere resolver ninguna
acción del security namespace para esta fila).

## Nodo por rama / prefijo

Solo se administran estos 7 permisos por nodo de rama; todo lo demás queda
sin tocar en ese nodo.

| Nodo | Grupo | Bypass PR | Bypass push | Contribute | Edit policies | Force push | Manage permissions | Remove locks |
|---|---|---:|---:|---:|---:|---:|---:|---:|
| `feature/*` | Development Team(s) | Not set | Not set | Not set | Not set | Not set | Not set | Not set |
| `feature/*` | Code-Reviewers | Not set | Not set | Not set | Not set | Not set | Not set | Not set |
| `development` | Development Team(s) | Not set | Not set | **Deny** | Not set | Not set | Not set | Not set |
| `development` | Code-Reviewers | Not set | Not set | **Allow** | Not set | Not set | Not set | Not set |
| `uat` | Development Team(s) | Not set | Not set | **Deny** | Not set | Not set | Not set | Not set |
| `uat` | Code-Reviewers | Not set | Not set | **Allow** | Not set | Not set | Not set | Not set |
| `release` | Development Team(s) | Not set | Not set | **Deny** | Not set | Not set | Not set | Not set |
| `release` | Code-Reviewers | Not set | Not set | **Allow** | Not set | Not set | Not set | Not set |
| `main` | Development Team(s) | Not set | Not set | **Deny** | Not set | Not set | Not set | Not set |
| `main` | Code-Reviewers | Not set | Not set | Not set | Not set | Not set | Not set | Not set |

Actualizado 2026-09-02: `development` ahora deniega Contribute a
Development Team igual que uat/release/main (ninguna rama permite push
directo salvo `feature/*`), y `main`/Code-Reviewers pasó de Deny a `Not
set` para que puedan completar Pull Requests ahí. Ver
`INSTRUCCIONES-CLAUDE-AZURE-DEVOPS-PERMISOS (1).md` en la raíz del repo
para el detalle de la decisión.

Actualizado 2026-09-24: Code-Reviewers pasa de `Not set` a **Allow**
explícito en Contribute (bit 4) para `development`, `uat` y `release`.
Motivo: completar (mergear) un PR requiere Contribute sobre la rama
destino; la herencia desde All Repositories no bastaba porque un Deny
heredado de nivel superior ganaba (caso real tmora en Buklo/buklo-web
PR 13855: aprobaba pero no le aparecía el botón Complete). El Allow
explícito por rama es el ACE más específico y gana sobre el deny
heredado. `main` se deja en `Not set` (hereda Allow de All Repositories).
Development Team sigue en Deny en las 4 ramas (no completa PRs).

Actualizado 2026-10-16 (Buklo): para que **Development Team** complete sus
propios PRs en `development` + `uat`, se le aplicó **Contribute = Allow**
explícito (bit 4, `allow|=4` `deny&=~4` `merge=true`) en esas dos ramas de
7 repos del proyecto Buklo (backend, database-snapshot, database-sqlproject,
mailer, mobile, project, web). Mismo principio que tmora/Code-Reviewers: el
`Deny (inherited)` del grupo SÍ ganaba y ocultaba el botón Complete pese a
checks/aprobación en verde (evidencia: PR 14534 Darvin en
buklo-database-sqlproject/uat). El Allow explícito por rama lo vence.
EXCLUIDOS a propósito: `buklo-framework` y `buklo-knowledge-base` (bloqueo
estricto — devs NO completan solos; Required reviewers bloqueante +
`creatorVoteCounts=false`). `release`/`main` de todos quedan intactos.
Readback: `effectiveAllow=16438` Contribute=True. Detalle completo en
`docs/azure-devops-permissions/PERMISSIONS-AUTOMATION-ARCHITECTURE.md`
(sección "Homogeneización completa de los 9 repos de Buklo").

## Mapeo etiqueta de UI → acción estable del security namespace

Confirmado en vivo el 2026-08-26 contra
`GET https://dev.azure.com/{org}/_apis/securitynamespaces?api-version=7.1`
(namespace `Git Repositories`, id `2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87`).
El bit real usado en cada ACE **siempre** viene de esa consulta en vivo —
la columna "bit esperado" es solo para detectar si la API cambió algo.

| Etiqueta de UI | Nombre estable (`name`) | Bit esperado |
|---|---|---:|
| Read | `GenericRead` | 2 |
| Contribute | `GenericContribute` | 4 |
| Force push (rewrite history, delete branches and tags) | `ForcePush` | 8 |
| Create branch | `CreateBranch` | 16 |
| Create tag | `CreateTag` | 32 |
| Manage notes | `ManageNote` | 64 |
| Bypass policies when pushing | `PolicyExempt` | 128 |
| Create repository | `CreateRepository` | 256 |
| Delete or disable repository | `DeleteRepository` | 512 |
| Rename repository | `RenameRepository` | 1024 |
| Edit policies | `EditPolicies` | 2048 |
| Remove others' locks | `RemoveOthersLocks` | 4096 |
| Manage permissions | `ManagePermissions` | 8192 |
| Contribute to pull requests | `PullRequestContribute` | 16384 |
| Bypass policies when completing pull requests | `PullRequestBypassPolicy` | 32768 |
| Advanced Security: view alerts | `ViewAdvSecAlerts` | 65536 |
| Advanced Security: manage and dismiss alerts | `DismissAdvSecAlerts` | 131072 |
| Advanced Security: manage settings | `ManageAdvSecScanning` | 262144 |

**Ojo con 2 discrepancias reales confirmadas** entre el texto de la UI y el
`displayName` que devuelve hoy la API (por eso la resolución nunca usa
`displayName`, siempre `name`):

- UI "Delete or disable repository" → API `displayName` "Delete repository".
- UI "Force push (rewrite history, delete branches and tags)" → API
  `displayName` "Force push (rewrite history and delete branches)".
