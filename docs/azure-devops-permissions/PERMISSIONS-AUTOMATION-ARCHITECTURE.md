# Arquitectura — Azure DevOps Permissions Administration

Dominio separado de `manage-azure-devops-pipelines` (ver
`docs/azure-devops/PIPELINE-AUTOMATION-ARCHITECTURE.md` para el
equivalente de ese dominio). Administra grupos de seguridad de proyecto,
membresías y permisos Git en `Shared-Service-GM`, montado 2026-08-26.

## Componentes

```
.claude/skills/manage-azure-devops-permissions/
  scripts/Invoke-AdoPermissionsRest.ps1   -- foundation: hosts permitidos,
    tabla de operationTypes (create/update/add/set + delete-* separados),
    matrices (fuente única), catálogo de acciones del namespace, hash
    canónico, journal de ejecución, construcción/validación de tokens,
    Invoke-AdoPermissionsApplyPhases e Invoke-AdoPermissionsDeleteApplyPhase
    (fases de aplicación, testeables con red mockeada)
  scripts/Export-AdoPermissionsSecurityInventory.ps1  -- GET puro
  scripts/New-AdoPermissionsPlan.ps1      -- genera plan (validated=false)
  scripts/Test-AdoPermissionsPlan.ps1     -- valida, re-deriva blockers
  scripts/Apply-AdoPermissionsPlan.ps1    -- aplica (rechaza destructivo)
  scripts/Test-AdoPermissionsReadback.ps1 -- compara plan vs estado real
  scripts/New-/Test-/Apply-AdoPermissionsDeletePlan.ps1 -- trío de borrado
  scripts/tests/run-script-tests.ps1      -- arnés offline sin Pester

.cursor/agents/ado-permissions-*/   -- builder/reviewer/diagnoser
.cursor/memories/ado-permissions-*/   -- memoria independiente c/u
.cursor/rules/azure-devops.mdc          -- reglas de autorización y seguridad
.cursor/hooks/azure-devops-permissions/   -- gate, post-validate, stop-validate
```

## Por qué el plan guarda el `body` completo (no solo `bodyHash`)

A diferencia de Pipelines (donde `approvedOperations` solo guarda
`bodyHash`, y `Apply-AdoClassicPlan.ps1` reconstruye el body real en
memoria vía funciones compartidas de `New-AdoClassicPayloads.ps1`), acá
el documento fuente exige explícitamente `body sanitizado` + `bodyHash`
como campos separados del plan. Esto resuelve limpio un problema real de
este dominio: varias operaciones (agregar miembro a un grupo recién
creado, fijar ACE de un grupo recién creado) referencian un descriptor que
no existe hasta después de aplicar una operación ANTERIOR del mismo plan
— la única forma segura de manejar esto sin inventar un mecanismo de
sustitución post-hash (como `${ADO_SECRET_*}` en Pipelines, pensado para
secretos, no para ids dependientes) es **no incluir esas operaciones en el
mismo plan en absoluto** cuando el grupo es nuevo — quedan en
`deferredAfterCreation`, resueltas en un plan posterior una vez el grupo
existe de verdad.

## Por qué las matrices y la lógica de tokens viven en `Invoke-AdoPermissionsRest.ps1`

El árbol de archivos del documento fuente no incluye un archivo adicional
tipo `New-AdoClassicPayloads.ps1` de Pipelines. Para lograr "una sola
fuente de verdad, sin duplicaciones" sin agregar un archivo fuera del
árbol pedido, las matrices (`Get-AdoPermissionsMatrixDefinition`), el
catálogo de acciones (`Get-AdoPermissionsManagedActionCatalog`), la
construcción de tokens y las 2 fases de aplicación viven en el mismo
helper foundation que ya se dot-sourcea desde todos los demás scripts.

## Resolución de acciones por nombre estable, no por `displayName`

Confirmado en vivo (2026-08-26) contra la API real: al menos 2 etiquetas
de UI del documento fuente NO coinciden textualmente con el `displayName`
que devuelve hoy `GET _apis/securitynamespaces` para la misma acción
("Delete or disable repository" vs "Delete repository"; "Force push
(rewrite history, delete branches and tags)" vs "Force push (rewrite
history and delete branches)"). Resolver por `displayName` habría
producido falsos bloqueos permanentes. La resolución usa el campo `name`
(estable), con el bit real siempre tomado de la respuesta en vivo — ver
`references/permission-matrix.md`.

## Testing de las fases de aplicación — nunca contra la organización real

`$env:AZURE_DEVOPS_PAT` está configurada de forma persistente en este
entorno (compartida con Pipelines). Una invocación directa de
`Apply-AdoPermissionsPlan.ps1`/`Apply-AdoPermissionsDeletePlan.ps1`, aunque
sea con datos de prueba ficticios, llega a la organización real (se
confirmó esto durante la construcción: varias llamadas GET y un intento de
POST real llegaron a `Shared-Service-GM` antes de fallar por recursos
inexistentes). Por eso `Invoke-AdoPermissionsApplyPhases` e
`Invoke-AdoPermissionsDeleteApplyPhase` viven separadas de los scripts
ejecutables — se prueban dot-sourceando el foundation y reemplazando
`Invoke-AdoPermissionsRest` por una función mockeada antes de llamarlas,
nunca invocando los scripts `Apply-*.ps1` de punta a punta.

## Gotcha de codificación encontrado durante la construcción

`New-AdoPermissionsPlan.ps1` contiene literales en español con tildes
(las 2 descripciones estándar). Windows PowerShell 5.1 lee un `.ps1` sin
BOM UTF-8 usando la codepage ANSI del sistema — un archivo guardado como
UTF-8 sin BOM con esos caracteres se lee mal y corrompe el texto al
volcarlo a JSON (mojibake tipo "Ã­" en vez de "í"). El archivo se guardó
con BOM UTF-8 explícito para evitarlo; cualquier `.ps1` nuevo de este
dominio que incluya caracteres no-ASCII literales debe hacer lo mismo.

## Excepción puntual — Buklo: Development Team completa sus propios PRs (2026-09-29)

> **Esto es una EXCEPCIÓN en vivo solo para el proyecto Buklo. NO cambia la
> matriz canónica (`Get-AdoPermissionsMatrixDefinition`), ni el generador
> estándar, ni `permission-matrix.md`.** El estándar sigue siendo:
> `Development Team` con `Contribute=Deny` en ramas protegidas (el dev crea el
> PR desde `feature/*`, el Code-Reviewer completa). Esta concesión aplica
> únicamente a Buklo y no debe replicarse como patrón en futuras corridas del
> generador.

**Pedido:** que `[Buklo]\Development Team` pueda **crear, aprobar y completar**
sus propios PRs en `development` y `uat`.

**Aplicado (dos partes, override en vivo):**

1. **Permisos Git — `Contribute` (bit 4) = Allow explícito** para
   `[Buklo]\Development Team` en `development` y `uat` de todos los repos de
   Buklo **excepto `buklo-framework`** (dejado intacto por pedido). Los demás
   bits (Read+CreateBranch+CreateTag+PRContribute) se preservaron por herencia;
   `effectiveAllow` quedó en `16438`. `buklo-mailer` no tiene esas ramas.
   Repos afectados: knowledge-base, database-sqlproject, backend, mobile, web,
   database-snapshot (9 ACE, HTTP 204).
   - El plan de excepción se generó y aplicó **sin** el generador de matriz
     (que reafirmaría Deny): un plan `set-git-permissions-ace` a mano con las
     funciones oficiales del helper (`ConvertTo-AdoPermissionsGitToken`,
     `ConvertTo-AdoPermissionsSecurityAceDescriptor`,
     `Get-AdoPermissionsRecomputedAceBits`, `Get-AdoPermissionsBodyCanonicalHash`),
     validado por `Test-AdoPermissionsPlan.ps1` (que verifica hash/precondición/
     lockout pero **no** re-deriva bits contra la matriz) y aplicado por
     `Apply-AdoPermissionsPlan.ps1` (guardia dura anti-borrado en vivo intacta:
     ambas identidades del ACE, Development Team + Code-Reviewers, preservadas).
   - Andamiaje en `.local/azure-devops-permissions/`:
     `New-BukloDevTeamContributeExceptionPlan.ps1` y
     `plans/buklo-devteam-contribute-exception.json`.

2. **Branch Policies — auto-aprobación** en `development`/`uat`. Se desactivó
   `blockLastPusherVote` (True→False) y se puso `creatorVoteCounts=True` en las
   3 políticas "Minimum number of reviewers" bloqueantes que impedían que el
   autor aprobara su propio PR: id **1326** (backend/uat), id **1346**
   (mobile/development), id **1372** (web/uat). Las demás ramas ya lo permitían
   o no tenían política de mínimo de revisores. PUT vía `Invoke-RestMethod` a
   `policy/configurations/{id}` (el helper no expone ese endpoint; curl a ADO
   tumba el gateway).

**Efecto neto:** en `development`/`uat` de todos los repos de Buklo salvo
`buklo-framework`, un miembro de Development Team puede crear, aprobar y
completar sus propios PRs sin depender de otra persona. Aplica a **cualquier**
autor de esas ramas (el flag de política no distingue por grupo).

**Respaldos / rollback** (en `.local/azure-devops-permissions/`, no versionado):
- Inventario pre-cambio: `exports/inventory-permissions-Buklo-20260929-150852.json`.
- Políticas pre-cambio: `backups/policy-{1326,1346,1372}-backup-20260929-152439.json`.
- Rollback permisos: volver `Contribute` a Deny (allow=0/deny=4) en las 9 ACE.
- Rollback políticas: PUT restaurando `blockLastPusherVote=True` +
  `creatorVoteCounts=False` desde los backups.


## Regla general — revisar TODAS las membresías del usuario al conceder/verificar permisos

Add-only (2026-09-30). No cambia nada canónico; es una regla de proceso para cualquier
concesión o verificación de permisos Git de un usuario, en cualquier proyecto.

**Regla:** al conceder o verificar que un usuario puede aprobar/completar PRs (o cualquier
permiso Git por rama), NO basta con confirmar que pertenece al grupo objetivo (p.ej.
`Development Team`). Hay que enumerar **todas** sus membresías de grupo y evaluar el
**permiso efectivo**, porque el modelo de ACL de ADO combina los ACE de todos los grupos:

1. **Un `Deny` explícito gana sobre cualquier `Allow`**, incluido el `Allow` del grupo
   objetivo. Si el usuario está en otro grupo que tiene `Contribute=Deny` explícito en esa
   rama, el permiso efectivo será `Deny` aunque `Development Team` lo tenga en `Allow`.
2. Un grupo en **`Not set`** (sin ACE explícito) no aporta ni resta nada: sacar al usuario
   de él no cambia el permiso efectivo.
3. La verificación concluyente es el **permiso efectivo resuelto** con el descriptor legado
   del usuario (`permissionevaluationbatch`, bit `Contribute=4`), no la teoría de herencia.

**Cómo revisar (solo lectura):**
- Resolver el usuario: `graph/subjectquery` (subjectKind `User`).
- Membresías: `graph/memberships/{descriptor}?direction=up` → resolver cada
  `containerDescriptor` con `graph/groups/{descriptor}`.
- Por cada grupo sospechoso: leer el ACE en el token de rama
  (`accesscontrollists/{ns}?token=repoV2/{proj}/{repo}/refs/heads/<hex>`) y ver `allow`/`deny`.
- Efectivo final: `permissionevaluationbatch` con el descriptor legado
  (`Microsoft.IdentityModel.Claims.ClaimsIdentity;<tenant>\<upn>`).

**Ejemplo real — Miguel Esquivel Castrillo (`mesquivelc@grupomontecristo.com`), 2026-09-30:**
- Es miembro de 11 grupos; en Buklo: `[Buklo]\Development Team` **y** `[Buklo]\Buklo GM Cotizador`.
- La excepción de Buklo (Contribute=Allow al grupo `Development Team`) le dio Contribute
  efectivo=`True` en `development`/`uat` de los repos — verificado con `permissionevaluationbatch`.
- Antes de sacarlo de `Buklo GM Cotizador` se verificó que ese grupo está en **`Not set`**
  (sin ACE) en todas las ramas destino → sacarlo NO afecta su permiso efectivo, y sobre todo
  **no metía ningún `Deny`**. Si hubiera tenido `Deny`, habría bloqueado el merge pese al
  `Allow` de Development Team.

### Excepción puntual — Buklo / `buklo-project` (+ grupo anidado Team-Proyects) (2026-10-07)

> **No cambia nada canónico.** Igual que las excepciones Buklo/CORE-PLT previas: PUT/ACE en vivo
> solo sobre `buklo-project`, sin tocar la matriz canónica, el generador estándar ni
> `permission-matrix.md`.

**Contexto del grupo anidado:** se pidió que "cada quien pueda aprobar y completar sus PRs" para
`[Shared-Service-GM]\Team-Proyects`, que **está contenido en** `[Buklo]\Development Team`. Al revisar
TODAS sus membresías (regla general documentada arriba) se halló que Team-Proyects también estaba en
**`[Shared-Service-GM]\Project Collection Administrators`** — lo que le daba Contribute en TODAS las
ramas por vía administrativa (privilegio muchísimo más amplio del necesario). El usuario lo **sacó de
Collection Administrators**; tras eso el grupo quedó sin Contribute efectivo en `buklo-project` (estado
base), confirmando que el permiso debía concederse por la vía acotada de rama.

**Aplicado en `buklo-project` (repo id `f2a03223-...`):**

1. **Contribute = Allow** al grupo `[Buklo]\Development Team` en `development` + `uat` (ACE directo,
   `allow|=4`, `deny&=~4`, `merge=true`). Readback por ACE efectivo: `effAllow=16438`,
   `effDeny=1032136` (bit 4 removido del deny heredado) → Contribute NET = True. Team-Proyects lo
   **hereda** por estar contenido en Development Team (sin ACE propio).

2. **21 políticas de rama creadas desde cero** (buklo-project no tenía ninguna), replicando
   `buklo-web` por rama:
   - **development/uat (ids 2415-2424):** con la excepción — MinReviewers
     (`blockLastPusherVote=false` + `creatorVoteCounts=true` = auto-aprobación) y Required-reviewers
     `[Buklo]\Code-Reviewers` **opcional** (`isBlocking=false`). Más Work item linking, Comment
     requirements y Merge strategy (squash en dev, noFastForward en uat).
   - **release/main (ids 2425-2435):** **estrictas / bloqueantes** (Producción, NO la excepción) —
     Code-Reviewers (`blocking=true`), `Production-Deployment-Approvers` (release) y
     `Release Executers` (main) bloquean el Complete. Gate de Producción intacto, idéntico a buklo-web.
   - **Política Build OMITIDA** en las 4 ramas: la de buklo-web apunta a `buildDefinitionId=629`
     (pipeline de buklo-web) y `buklo-project` no tiene build pipeline propio (verificado: 0
     definitions). Copiarla dispararía el build de otro repo. Se agregará si buklo-project llega a
     tener pipeline propio.

**Efecto neto:** en `buklo-project`, un miembro de Development Team / Team-Proyects crea, aprueba y
completa sus propios PRs a `development`/`uat`; `release`/`main` conservan el control estricto.

**Respaldos / rollback** (`.local/azure-devops-permissions/bukloproject-backups/`): `acl-devuat-*.json`
(ACL pre-Contribute), `created-policies-*.json` (dev/uat), `created-policies-relmain-*.json`
(release/main). Rollback: borrar los ids creados / revertir el ACE Contribute.

### Homogeneización completa de los 9 repos de Buklo — excepción vs bloqueo estricto (2026-10-16)

> Extensión del caso `buklo-project`: se auditó y homogeneizó la excepción "cada dev completa su
> propio PR" en **development + uat de los 9 repos** del proyecto Buklo, con dos modos deliberados.

**Repos del proyecto Buklo (9):** buklo-backend, buklo-database-snapshot, buklo-database-sqlproject,
buklo-framework, buklo-knowledge-base, buklo-mailer, buklo-mobile, buklo-project, buklo-web.

**Modo A — EXCEPCIÓN (auto-aprobación) en dev + uat — 7 repos:** buklo-backend, buklo-database-snapshot,
buklo-database-sqlproject, buklo-mailer, buklo-mobile, buklo-project, buklo-web.

**Modo B — BLOQUEO ESTRICTO en dev + uat — 2 repos:** buklo-framework, buklo-knowledge-base
(decisión explícita de Pablo: en estos dos los devs NO deben completar solos).

#### Las DOS mitades de la excepción (ambas hacen falta)

La capacidad de que un dev **cree, apruebe y complete** su propio PR en dev/uat depende de DOS ejes
independientes — verificado en vivo que ambos son necesarios:

1. **Políticas de rama** (patrón `buklo-web`, 5 por rama):
   - **Minimum reviewers**: `minimumApproverCount=1`, `creatorVoteCounts=true`,
     `blockLastPusherVote=false` → **auto-aprobación** (su propio voto cuenta).
   - **Required reviewers = `[Buklo]\Code-Reviewers`** (`isBlocking=false`, opcional).
   - **Merge strategy** (dev=squash, uat=noFastForward), **Work item linking**, **Comment requirements**.
   - Política Build OMITIDA (la de buklo-web apunta a `buildDefinitionId=629`; cada repo con pipeline
     propio lleva su Policy Build aparte).

2. **Contribute del grupo `[Buklo]\Development Team`** = **Allow explícito** en la rama (ACE directo,
   `allow|=4`, `deny&=~4`, `merge=true`, namespace Git `2e9eb7ed-...`). **Esto fue el corregido el
   2026-10-16**: inicialmente se asumió que bastaban las políticas (porque buklo-web "funcionaba"), pero
   la evidencia de campo (PR 14534 de Darvin en buklo-database-sqlproject/uat: checks verdes, mergeStatus
   succeeded, políticas en verde, y AUN ASÍ la UI no mostraba "Complete") demostró que **el `Deny
   (inherited)` de Contribute del grupo SÍ bloqueaba** para esas identidades. El Allow explícito en la
   rama vence al Deny heredado y destraba el botón Complete.

   SID real de Development Team:
   `Microsoft.TeamFoundation.Identity;S-1-9-1551374245-2697738344-693361735-2808067267-2127622907-1-58883461-1312947276-2826811426-972539471`.

   **Gotcha de lectura:** el readback INMEDIATO tras el POST del ACE puede mostrar `effectiveAllow=16434`
   (bit 4 ausente) como artefacto de propagación/lectura; una verificación limpia posterior confirma
   `effectiveAllow=16438` (16434|4), `effectiveDeny=1032136` (1032140 con bit 4 removido), `allow`
   explícito=4 → **Contribute NET = True**. No concluir "no se aplicó" por el primer readback.

**Aplicado 2026-10-16 (Modo A, los 7 repos):** Contribute=Allow a Development Team en development+uat →
readback 14/14 pares repo/rama con `effectiveAllow=16438` Contribute=True. Respaldo:
`.local/azure-devops-permissions/bukloproject-backups/contribute-backup-20261016-193442.json`
(allow/deny previos por rama).

#### Modo B — bloqueo estricto (buklo-framework, buklo-knowledge-base)

En dev + uat de estos dos repos la excepción fue REEMPLAZADA por control estricto:
- **Minimum reviewers**: `creatorVoteCounts=false` + `blockLastPusherVote=true` (el voto del autor NO
  cuenta).
- **Required reviewers = Code-Reviewers**: `isBlocking=true` (el Complete exige aprobación de un
  Code-Reviewer distinto del autor).
- Higiene (Work item / Comment / Merge strategy) se mantiene bloqueante.
- **No** se les aplicó Contribute=Allow (quedan con el Deny heredado del grupo).
Respaldo de ids: `.local/azure-devops-permissions/bukloproject-backups/strict-fw-kb-20261016-164133.json`.

#### Nota operativa — PRs `[AUTO][UAT]` del Build Service

Los PR `[AUTO][UAT]` los crea **Project Collection Build Service** vía pipeline, pero el pipeline NO les
activa auto-complete → nacen con `completionOptions=null`, por lo que la UI no muestra "Complete" hasta
fijar la estrategia de merge. Destrabar puntual: activar auto-complete por API con la estrategia que
exige la política de la rama destino (uat de sqlproject = `noFastForward`). Fix de raíz: que el pipeline
los cree con auto-complete.

**release / main de TODOS los repos: intactos** — gate de Producción con control estricto sin cambios.
