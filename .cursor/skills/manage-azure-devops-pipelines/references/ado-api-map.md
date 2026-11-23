# Mapa de API REST — brechas de pipelines clásicos

Este mapa cubre **únicamente** las operaciones que el MCP oficial
`@azure-devops/mcp` no expone hoy para armar de punta a punta un pipeline
clásico (Variable Group, Build clásico, Release clásico). Para todo lo
demás (proyectos, repos, ramas, builds, releases, logs, artefactos,
ejecución/creación de pipelines YAML) usar primero el MCP — ver
`SKILL.md` §"Decisión técnica: MCP primero, REST solo para brechas".

Todas las llamadas de este mapa deben pasar por
`scripts/Invoke-AdoRest.ps1`. Nunca invocar estas rutas directamente desde
Bash/PowerShell sueltos.

## Bases

| Familia | Base URL |
|---------|----------|
| Core / Build / Distributed Task (Variable Groups, Task Groups) | `https://dev.azure.com/Shared-Service-GM` |
| Release Management | `https://vsrm.dev.azure.com/Shared-Service-GM` |

API version por defecto: `7.1` (usar la que exponga la organización si
una llamada puntual falla por versión no soportada).

## Endpoints de solo lectura (sin aprobación adicional)

| Recurso | Método | Ruta | Notas |
|---------|--------|------|-------|
| Proyectos | GET | `/_apis/projects?api-version=7.1` | Confirmar que existe `DevOps` |
| Definiciones de Build | GET | `/{project}/_apis/build/definitions?api-version=7.1` | Listar / buscar por nombre |
| Definición de Build por id | GET | `/{project}/_apis/build/definitions/{definitionId}?api-version=7.1` | Incluye variables, steps, triggers |
| Definiciones de Release | GET | `https://vsrm.../{project}/_apis/release/definitions?api-version=7.1` | Listar / buscar por nombre |
| Definición de Release por id | GET | `https://vsrm.../{project}/_apis/release/definitions/{definitionId}?api-version=7.1` | |
| Variable Groups | GET | `/{project}/_apis/distributedtask/variablegroups?api-version=7.1` | Nunca leer `secretValues` |
| Variable Group por id | GET | `/{project}/_apis/distributedtask/variablegroups/{groupId}?api-version=7.1` | Idem |
| Task Groups | GET | `/{project}/_apis/distributedtask/taskgroups?api-version=7.1` | Solo metadatos + revisión vigente |
| Service Connections | GET | `/{project}/_apis/serviceendpoint/endpoints?api-version=7.1` | Nunca leer datos de autorización |
| Agent Pools / Queues | GET | `/_apis/distributedtask/pools?api-version=7.1` | |
| Repos | GET | `/{project}/_apis/git/repositories?api-version=7.1` | |
| Builds (ejecuciones) | GET | `/{project}/_apis/build/builds?api-version=7.1` | |
| Logs de un Build | GET | `/{project}/_apis/build/builds/{buildId}/logs?api-version=7.1` | |

## Endpoints de escritura (brecha clásica — exigen plan aprobado)

Todos requieren pasar por `Apply-AdoClassicPlan.ps1` (script separado de
`Invoke-AdoClassicPlan.ps1`, que es dry-run exclusivo) y una
aprobación explícita previa por operación atómica (ver
`approval-matrix.md`). Ninguno se llama nunca directamente. Además, cada
llamada exige una entrada exacta en `plan.approvedOperations` con
`operationType` uno de los 8 tipos permitidos (actualizado 2026-08-26 —
ver `$script:AdoAllowedOperationTypes` en `Invoke-AdoRest.ps1`, fuente
única de verdad): los 3 `create-*` (POST, sin id de recurso), los 2
`update-*` (PUT, agregados 2026-08-25, exigen id numérico al final de la
ruta) y los 3 `delete-*` (DELETE, agregados 2026-08-26, también exigen id
numérico al final y nunca llevan body), `method` exacto según el tipo,
`uri` EXACTA (organización `Shared-Service-GM`, proyecto `DevOps`, sin
parámetros de query extra al `api-version=7.1` requerido) y `bodyHash` —
un manifiesto vacío (el estado por defecto de todo plan generado hoy, ya
que los payloads de Build/Release clásico no están confirmados) bloquea
toda escritura. `Test-AdoClassicPlan.ps1` (crear/actualizar) o
`Test-AdoClassicDeletePlan.ps1` (borrar) validan esta forma exacta;
`Invoke-AdoRest.ps1` la vuelve a exigir antes de cualquier llamada real.
Qué operación ya se intentó/completó se rastrea en un journal de
ejecución separado (`.local/azure-devops/executions/<validationHash>.json`)
— el archivo de plan nunca se reescribe para esto.

| Recurso | Método | Ruta | Referencia oficial |
|---------|--------|------|---------------------|
| Crear Variable Group | POST | `/{project}/_apis/distributedtask/variablegroups?api-version=7.1` | [API Variable Groups](https://learn.microsoft.com/rest/api/azure/devops/distributedtask/variablegroups/add?view=azure-devops-rest-7.1) |
| Crear definición de Build | POST | `/{project}/_apis/build/definitions?api-version=7.1` | [API Build Definitions](https://learn.microsoft.com/rest/api/azure/devops/build/definitions/create?view=azure-devops-rest-7.1) |
| Crear definición de Release | POST | `https://vsrm.../{project}/_apis/release/definitions?api-version=7.1` | [API Release Definitions](https://learn.microsoft.com/rest/api/azure/devops/release/definitions/create?view=azure-devops-rest-7.1) |
| Actualizar definición de Build (2026-08-25) | PUT | `/{project}/_apis/build/definitions/{id}?api-version=7.1` | [API Build Definitions](https://learn.microsoft.com/rest/api/azure/devops/build/definitions/update?view=azure-devops-rest-7.1) |
| Actualizar definición de Release (2026-08-25) | PUT | `https://vsrm.../{project}/_apis/release/definitions/{id}?api-version=7.1` | [API Release Definitions](https://learn.microsoft.com/rest/api/azure/devops/release/definitions/update?view=azure-devops-rest-7.1) |
| Borrar Variable Group (2026-08-26) | DELETE | `/{project}/_apis/distributedtask/variablegroups/{id}?api-version=7.1` | [API Variable Groups](https://learn.microsoft.com/rest/api/azure/devops/distributedtask/variablegroups/delete?view=azure-devops-rest-7.1) — respaldo de solo lectura obligatorio antes, ver `security.md` |
| Borrar definición de Build (2026-08-26) | DELETE | `/{project}/_apis/build/definitions/{id}?api-version=7.1` | [API Build Definitions](https://learn.microsoft.com/rest/api/azure/devops/build/definitions/delete?view=azure-devops-rest-7.1) — respaldo de solo lectura obligatorio antes, ver `security.md` |
| Borrar definición de Release (2026-08-26) | DELETE | `https://vsrm.../{project}/_apis/release/definitions/{id}?api-version=7.1` | [API Release Definitions](https://learn.microsoft.com/rest/api/azure/devops/release/definitions/delete?view=azure-devops-rest-7.1) — respaldo de solo lectura obligatorio antes, ver `security.md` |
| Listar Task Groups (para referenciar por id/revisión) | GET | `/{project}/_apis/distributedtask/taskgroups?api-version=7.1` | [API Task Groups](https://learn.microsoft.com/rest/api/azure/devops/distributedtask/taskgroups/list?view=azure-devops-rest-7.1) — solo lectura, nunca se crean/modifican task groups desde este flujo |

Fuera de alcance de este flujo (no implementar aunque el REST lo permita):
encolar un Build (`POST .../build/builds`), crear una instancia real de
Release (`POST .../release/releases`), aprobar un stage, cambiar service
connections/pools/task groups compartidos. Modificar y borrar una
definición existente SÍ están en alcance desde 2026-08-25/26
respectivamente (ver tabla arriba), cada uno con su propia aprobación
separada — no se agrupan bajo la "primera tarea autorizada" de crear.

## Autenticación

`Invoke-AdoRest.ps1` arma `Authorization: Basic` en memoria a partir de
`$env:AZURE_DEVOPS_PAT` (usuario vacío + PAT como password, esquema
estándar de Azure DevOps). Nunca se escribe el token a disco, log, ni se
incluye en el cuerpo de ninguna solicitud.
