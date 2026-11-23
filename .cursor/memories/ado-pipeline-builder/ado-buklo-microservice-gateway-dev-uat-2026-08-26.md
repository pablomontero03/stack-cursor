---
name: ado-buklo-microservice-gateway-dev-uat-2026-08-26
description: "Full case: adding Desarrollo/UAT to Buklo Microservice Gateway's existing classic pipeline (Build 584 + Release 366), which was already live in Producción — 2 new VGs + update-build-definition + update-release-definition, no new Build/Release created. 3 real tool gaps found and fixed by the coordinator along the way."
metadata:
  type: project
---

## Contexto

Producción de `Build-buklo-microservice-gateway` (584) /
`Deploy-Desarrollo-UAT-Produccion-Buklo-Microservice-Gateway` (366) ya
funcionaba. Los environments Desarrollo/UAT existían en el Release pero
apuntaban a Variable Groups prestadas de OTRA app (`Desarrollo-Buklo-ontology-web`
383, `UAT-Buklo-ontology-web` 384 — residuo de un clon). Tarea: crear 2
Variable Groups reales para esta app, y re-linkear esos 2 environments,
sin tocar Producción (VG 391) ni crear un Build/Release nuevo.

## Resultado final

- VG `Desarrollo-Buklo-Microservice-Gateway` = **418**
- VG `UAT-Buklo-Microservice-Gateway` = **419**
- Build 584 → revisión **20** (2 File Creator steps con manifests dev/uat
  nuevos; `deployment.yml produccion` intacto)
- Release 366 → revisión **4** (`environments[Desarrollo].variableGroups`
  383→418, `environments[UAT].variableGroups` 384→419,
  `environments[Producción].variableGroups` permanece `[391]`)
- Los 3 environment ids del Release se renumeraron 452/453/454 →
  522/523/524 como efecto colateral ESPERADO de que el PUT quite el `id`
  propio de cada environment (documentado, ver
  `ado-put-update-field-stripping`) — nombres, orden, task groups,
  approvals, todo lo demás intacto, confirmado por readback.
- Cero Builds encolados, cero instancias de Release reales, cero
  despliegues.
- **Seguimiento mismo día**: Desarrollo/UAT tenían `conditions: []` (por
  eso no se veían conectados al artifact en el diagrama del editor de
  Azure DevOps) — 5to `update-release-definition` sobre este mismo
  Release, agregando las 2 conditions estándar (`ReleaseStarted` +
  artifact filter) con `sourceBranch` `development`/`uat` respectivamente
  (confirmado contra los 3 branches reales de CI del Build 584 vía GET
  fresco). Producción no se tocó (ya las tenía). Revisión 4→5, ids de
  environment renumerados otra vez (522/523/524→525/526/527, mismo efecto
  esperado). El usuario aprobó este seguimiento directamente sin pedir
  aprobación por-paso de nuevo ("puedes mapearlos") — no se re-preguntó
  por el bug de encoding ya resuelto ni se re-invocó al reviewer (cambio
  pequeño, mismo mecanismo ya revisado una vez ese mismo día).

- **3er seguimiento mismo día — agregar agrupación de merges +
  Reportar-resultado-HU a Build 584 y Release 366**, usando
  `Build-administracion-proyectos-web` (624)/`Deploy-...-Administracion-Proyectos-Web`
  (383) como plantilla REAL (GET fresco de ambos, no de memoria — sus ids
  de task group compartido confirmados: `Evaluar-ventana-agrupacion`
  `8c699091-35a9-475b-af9c-2d3386d6118c`, `Gana-el-mas-nuevo`
  `69c14633-6cac-4096-b70f-95736fdaae95`, `Reportar-resultado-HU`
  `cefd6b95-eb0f-4a3f-b63e-a2d669a53e55`). Usadas las funciones YA
  EXISTENTES (`New-AdoMergeBatchingPhases`/`New-AdoGanaElMasNuevoStep`/
  `New-AdoReportarResultadoHuBuildStep`) para generar los fragmentos, pero
  **splice quirúrgico manual sobre el GET fresco** en vez de
  `New-AdoBuildDefinitionPayload` completo — ese generador reconstruye
  TODO el Build desde un `Plan` y hubiera perdido los steps propios de
  esta app que no siguen la plantilla estándar (`File Creator dockerfile`,
  `Replace tokens`). Patrón: nuevo step al PRINCIPIO
  (`Gana-el-mas-nuevo`), steps existentes intactos en su mismo orden
  relativo, nuevo step al FINAL (`Reportar-resultado-HU`) — nunca
  reemplazar/reordenar lo que ya funciona. Build 584 revisión 21→22
  (8 steps finales: Gana + 6 existentes + Reportar, dentro de 3 phases
  nuevas: `Evaluar ventana`/`Ventana de agrupacion`/`Agent job 1`
  mutado). Release 366 revisión 5→6 (`Reportar-resultado-HU` agregado
  como ÚLTIMO `workflowTask` de `deployPhases[0]` en LOS 3 environments
  incluida Producción, `enableAccessToken=true` en los 3 — confirmado con
  diff campo a campo que Producción solo ganó ese task group: mismos 4
  workflowTasks previos intactos byte-a-byte, mismo `variableGroups=[391]`,
  mismas `conditions`; las únicas diferencias fueron ids de aprobación/
  `deployStep`/sufijo de `badgeUrl` que Azure DevOps siempre reasigna
  solo, no algo que yo haya tocado).
- **Anomalía real detectada (no bloqueante, reportada tal cual)**: entre
  mi update anterior (Build 584 revisión 20) y este (revisión 21 al
  hacer el GET fresco), alguien EXTERNO a este flujo quitó los 5 steps
  deshabilitados legacy que existían antes (`Task group: Build`
  duplicado deshabilitado, `Bash Script`, `Delete files`, 2 `File
  Creator` viejos) — Build 584 pasó de 12 a 6 steps sin que yo hiciera
  ese cambio. Se adaptó al estado REAL confirmado por el GET fresco (tal
  como exige el flujo — nunca asumir un estado de memoria), y se avisó
  como anomalía real en vez de act como si nada. Contraste útil: en la
  MISMA sesión, ninguna de las 3 aplicaciones de `update-release-definition`
  tuvo un cambio externo inesperado — solo el Build.

- **4to y último seguimiento — approver real del stage Producción.**
  El usuario vio en la UI "Pre-deployment approvals: Enabled" sin
  approver (`"Enter at least one approver"`). La premisa dada
  ("`approvals[0]` ya existe vacío, solo falta completar `approver`")
  **no coincidía con el GET fresco**: `isAutomated` era `true` (deploy
  automático, sin gate en absoluto), no `false`-sin-approver como se
  esperaba — anomalía real, reportada, no ignorada. Para que el approver
  funcionara de verdad como gate manual (igual que la referencia real
  `Deploy-...-Administracion-Proyectos-Web` 383, `isAutomated:false` +
  grupo `[Shared-Service-GM]\Release Executers` id
  `397ddbfe-1d60-4533-a4c9-b099f80ac154`), se cambió `isAutomated` a
  `false` EN EL MISMO PUT que se agregó el `approver` — mismo patrón ya
  documentado para creación (`400 VS402896` si se separan). `approvalOptions`
  no se tocó (quedó en su valor previo, no fue parte del pedido).
  Release 366 revisión 6→7. Diff campo a campo confirmó que Producción
  no cambió NADA más (mismos 5 workflowTasks con sus inputs intactos,
  `variableGroups=[391]`, `postDeployApprovals` sin cambios reales una
  vez normalizados los ids que ADO siempre reasigna). Desarrollo/UAT
  intactos (siguen `isAutomated=true`, sin approver).
  **Bug propio real encontrado y corregido en el camino**: al copiar el
  objeto `approver` de la referencia, removí por error su propiedad
  `id` (confundiéndola con el `id` de servidor de `approvals[0]`, que sí
  hay que quitar) — pero `approver.id` es el GUID REAL de la identidad
  (`397ddbfe-...`), had que conservarlo intacto. Son 2 campos `id`
  distintos en 2 niveles distintos del mismo objeto — no confundirlos en
  el futuro.

**Gateway (Desarrollo/UAT + fixes de Producción sobre el pipeline
existente) queda cerrado end-to-end con esta tarea.**

**CONFIRMADO POR EL USUARIO 2026-08-26 (fuera de esta sesión del agente,
el usuario encoló el Build real él mismo): compiló y el Release desplegó
correctamente en el cluster.** Toda la convención Dev/UAT de Gateway (las
5 rondas de este caso) queda probada de punta a punta, no solo aplicada —
es la plantilla validada para repetir con los 12 microservicios Buklo que
faltan.

## Por qué este caso NO encajaba en el flujo estándar de
`New-AdoClassicAksPlan.ps1`

No se creó ningún Build/Release nuevo — solo 2 VG + 2 PUT sobre recursos
YA EXISTENTES. Cada `approvedOperations` solo admite 1 operación por tipo
por plan (`Test-AdoClassicPlan.ps1` lo rechaza si hay 2 `create-*` del
mismo tipo), así que fueron **4 archivos de plan separados**, cada uno
con su propia aprobación/tarjeta nativa al aplicar — mismo patrón que la
reconstrucción de administracion-proyectos-web (ver
`ado-classic-aks-plan-multi-env-generator-gaps`).

`New-AdoClassicAksPlan.ps1` sigue siendo el generador correcto incluso
para un plan que solo va a crear una VG o actualizar un Build/Release —
da la base con `dependencies`/`release`/`repo` resueltos contra
inventario, aunque esos campos no se consuman por el operationType real
de ESE plan puntual. Usar `-DisableMergeBatching` cuando el Build/Release
real NO usa la convención de agrupación de merges (confirmarlo siempre
con GET, nunca asumir que todo pipeline AKS nuevo la tiene — Build
584/Release 366 no la usan).

## 3 bugs reales de herramienta encontrados y corregidos por el
coordinador (yo los diagnostiqué, el coordinador aplicó el fix — un Edit
mío sobre estos scripts compartidos fue bloqueado por el clasificador de
modo automático las 2 primeras veces que lo intenté)

1. **Repo cross-project bloqueaba un plan que no crea Build.**
   `Test-AdoClassicPlan.ps1` exigía sin condición que `plan.repo.name`
   existiera en el inventario del proyecto DE PIPELINES (`DevOps`) — pero
   el repo real de la app (`buklo-backend`) vive en el proyecto `Buklo`,
   nunca visible en un inventario `-Project DevOps`. Fix: nuevo flag
   `$planDeclaresNoNewBuild` (activo solo cuando `approvedOperations` ya
   está poblado Y ninguna entrada es `create-build-definition`) degrada
   el chequeo a advertencia. Un plan vacío (todavía sin aprobar) sigue
   exigiendo el repo real, sin cambios.
2. **Duplicado de nombre "todo o nada".** El punto 9 (`$isUpdateOnlyPlan`)
   se apaga apenas el plan trae CUALQUIER `create-*` — mi plan de "solo
   crear la VG" (`create-variable-group`) activaba entonces el chequeo de
   duplicado también para Build/Release, que este plan nunca iba a
   crear. Fix: 3 flags granulares por tipo de recurso
   (`$planCreatesBuild`/`$planCreatesRelease`/`$planCreatesVariableGroup`),
   mismo criterio conservador (`approvedOperations` vacío = exigir los 3
   como antes).
3. **Bug de encoding en `Invoke-AdoRest.ps1`** (ver detalle completo en
   `debugging.md` y en la memoria de sesión
   `ado-invoke-adorest-utf8-encoding-bug`) — `Invoke-WebRequest` enviaba
   el body con el codepage por defecto del sistema (Windows-1252) en vez
   de UTF-8, corrompiendo cualquier tilde/guion-em-dash del body. Este es
   el más importante de los 3: afecta a CUALQUIER escritura futura con
   texto no-ASCII, no solo a este caso.

## Revisión independiente sin tool de Agent/Task disponible

En esta sesión no tuve un tool para invocar `ado-pipeline-reviewer`
directamente (solo `Read`/`Grep`/`Glob`/`Bash`/`Write`/`Edit`) — el
coordinador lo invocó él mismo y me pasó los 3 hallazgos de vuelta
(reconciliar `reportarResultadoHU`/`artifactFilterBranch`, y exigir
sustancia real en el "Plan D" antes de poblar `approvedOperations` con
ids todavía inexistentes). Documentar esto explícitamente si vuelve a
pasar — no asumir que el tool de delegación está siempre disponible.

## Patrón: "Plan D" con body que depende de un id que no existe todavía

Cuando un `update-release-definition` necesita referenciar un recurso que
otro plan de la MISMA operación atómica todavía no creó (la VG nueva),
el orden correcto es: aplicar primero los planes `create-*` de los que
depende, y recién con los ids reales armar el body del `update-*`
(nunca inventar/placeholder-ear un id). Mientras tanto, el plan
`update-*` puede — y el reviewer pidió explícitamente esto — documentarse
con un archivo `design-notes-<app>.md` hermano (mismo patrón que
`design-notes-administracion-proyectos-web.md`) que explicite: id del
recurso destino, mapeo EXACTO campo por campo de qué cambia y a qué,
confirmación explícita de qué NO cambia, y el criterio de field-stripping
aplicable — para que el plan sea revisable en su forma "vacía" (sin
`approvedOperations` todavía) sin tener que adivinar qué se va a hacer.
