# Pipelines Buklo — Promoción por Historia de Usuario + Build/Release Mobile

> Análisis en vivo 2026-09-28 (solo lectura, sin escrituras). Org `Shared-Service-GM`, proyecto ADO `DevOps`.
> Fuentes: MCP `azure-devops` (`pipelines_definition`) para builds; GET a archivo + parseo python3 para el Release clásico 379 (vsrm no lo cubre el MCP).

Cubre dos familias **independientes** pero encadenadas para Buklo Patient Mobile:

1. **`\Pipelines-Estado-HU`** — motor de promoción por Historia de Usuario (cherry-pick automático a `uat`/`release`).
2. **`\buklo` + `\Buklo`** — Build 599 (compile-only móvil) + Release 379 (distribución tester → producción).

---

## 1) Familia `\Pipelines-Estado-HU` — Promoción por Historia de Usuario

4 build definitions, **todas con el mismo motor** `promote-workitem.ps1` (embebido por File Creator en la definición, idéntico byte a byte salvo variables). VG compartido `pull-request-cherry-pick` (id 336).

| ID | Nombre | Repo destino | Proyecto Git | Reviewers (VG `adoReviewerNames`) |
|----|--------|--------------|--------------|-----------------------------------|
| 555 | `pull-request-cherry-pick-buklo-frontend-portal-HISTORIA-USUARIO` | `buklo-web` | CORE-PLT | `[CORE-PLT]\Code-Reviewers` |
| 562 | `pull-request-cherry-pick-sqldb_buklo_lab-HISTORIA-USUARIO` | `project_sqldb_buklo_lab` | Database-Administration-and-Monitoring | `[Database-Administration-and-Monitoring]\Code-Reviewers` |
| 600 | `pull-request-cherry-pick-buklo-mobile-HISTORIA-USUARIO` | `buklo-mobile` | Buklo | `[Buklo]\Code-Reviewers` |
| 558 | `promote-us-webhook-trigger` (YAML disparador `azure-pipelines-promote-us-trigger.yml`, repo `automatizaciones`) | — | — | — |

**Pool:** `sh-pool-2` (id 308, self-hosted) para 555/562/600. Timeout 60 min.

### Estructura de la definición (555/562/600)
- `File Creator promote-workitem.ps1` — escribe el `.ps1` al workspace (input `filecontent`).
- `File Creator promote-workitem.ps1 v1` — versión alterna **deshabilitada**.
- `PowerShell Script promote-workitem.ps1` — lo ejecuta. Env: `SYSTEM_ACCESSTOKEN=$(System.AccessToken)`, `targetBranch=$(targetBranch)`, `userStoryId=$(userStoryId)`.
- `Task group: Pull-Request-cherry-pick` — **deshabilitado** (legacy).

### Variables clave (VG 336 + variables de definición)
`dryRun=false`, `createDraftPr=false`, `enableAutoComplete=false`, `completePrImmediately=false`, `replaceExistingPr=true`, `prTitlePrefix=[AUTO]`, `tempBranchPrefix=temp`, `requirementCodePrefix=TKS`, `targetBranch=release` (override), `userStoryId` (override), `filterChildrenByPromoteState=true`, `includeParentCommits=true`, `commentWorkItem=true`, `commentOnFailure=true`.

**Por diseño NO autocompleta el PR** (`enableAutoComplete=false`, `completePrImmediately=false`) — respeta la regla de no completar PRs automáticamente.

### Lógica de `promote-workitem.ps1` (14 pasos)
1. **Leer HU** (`userStoryId`/`workItemId` como alias) con `$expand=relations`; resuelve `System.TeamProject` automáticamente (`boardsProject`).
2. **Tareas hijas** (`System.LinkTypes.Hierarchy-Forward`). Filtro por estado: `targetBranch=uat`→hijas `In UAT`; `release`→`Ready for Production`. Extrae commits (`ArtifactLink` → `vstfs:///Git/Commit/`).
3. **Filtrar commits** al repo configurado (`adoRepositoryName`); ignora commits de otros repos.
4. **Detalle de commits**, orden cronológico por `AuthorDate`.
   - 4.1 **Códigos de requerimiento** (`TKS-*`) del mensaje **y de las rutas de archivos**, en orden de aparición (no alfabético — el release BD lee el título del PR para decidir scripts).
   - 4.2 Pre-check informativo de solapamiento de archivos (no decide conflicto).
5. **Workspace git**: valida rama destino, limpia ramas temporales `temp/<destino>/us-<id>` previas; con `replaceExistingPr=true` abandona PRs activos previos.
   - 5.2 Detecta commits ya aplicados en destino (`merge-base --is-ancestor` / `git cherry`) para omitir.
6-7. **Cherry-pick cronológico** desde una rama temporal creada sobre destino. Casos: vacío (`--skip`), ya en destino (omite), **conflicto real** → publica la rama temporal con lo aplicado + genera artifact `manual-resolution` con instrucciones copy-paste + comenta la HU + aborta.
8-9. Valida cambios reales (evita PR vacío) y publica la rama temporal.
10. **Crea PR** `<TKS,...> [AUTO][DESTINO] US <id> - <titulo>`, vincula la HU al PR (ArtifactLink).
    - 11 reviewers, 12 auto-complete, 13 completion — gated por flags (todos off por defecto).
14. Comenta la HU con el resultado. Variables de salida `Promote_*` (PRId, PRUrl, Result=SUCCESS/NO_CHANGES/FAILED, RequirementCodes, ReplacedPrIds).
- **catch**: comenta la HU con el error (`commentOnFailure`).

---

## 2) Build 599 — `Build-Buklo-Patient-Mobile` (path `\buklo`, COMPILE ONLY)

- **Repo:** `buklo-mobile` (Expo/React Native monorepo, app `apps/app-patient`), default branch `uat`.
- **Trigger CI:** push a `uat` con pathFilters `apps/app-patient/**` + `package.json`/`package-lock.json` (excluye `*.md`, `*.test.*`).
- **Pools:** gate en `Azure Pipelines` hosted (127); compilación en `sh-pool-2` (308) y `macOS-26` (iOS).
- **VGs:** `Buklo-Patient-Mobile-EAS` (405, config: APP_DIR, APPLE_TEAM_ID, ASC issuer/key id, NODE_VERSION 20.x, PACKAGE_NAME, FIREBASE_APP_ID_ANDROID, keystore file) + `Buklo-Patient-Mobile-KeyVault` (406, Azure Key Vault: tokens EAS/Expo/Firebase, keystore base64, ASC .p8, iOS p12, `EXPO_PUBLIC_*`). Secretos se escriben a `.env` sin imprimir valores.

### Jobs (7)
1. **Evaluar ventana** (`Batch_Gate`, hosted) — task group `Evaluar-ventana-agrupacion` + puente que publica `shouldWait`.
2. **Ventana de agrupación** (`Batch_Window`, server job) — Delay `BATCH_WINDOW_MINUTES` (10) para agrupar merges de varias HU. Solo si `shouldWait=true`.
3. **Validate** — task group `Gana-el-mas-nuevo`; **bump de versión** en `uat` (`apps/app-patient/ci/bump-version.sh`, push con `[skip ci]`, sin ID de HU en mensaje, con guardia de "build más nuevo ya existe"); `npm ci`; `tsc --noEmit`; check i18n. `continueOnError` en tsc/i18n.
4. **Android local (AAB)** — Sync uat tip + prebuild + gradle → `buklo-patient.aab` (artifact `android-aab`).
5. **Android local (APK)** — build release APK Firebase (artifact `android-firebase-apk`, gate `ENABLE_FIREBASE_APK=true`).
6. **iOS local (IPA)** — macOS, prepara ASC .p8, prebuild + xcodebuild firmado → artifact `ios-ipa` (gate `ENABLE_IOS_BUILD=true`).
7. **iOS Signing Probe** (experimental, gate `ENABLE_IOS_SIGNING_PROBE=true` — al activarlo salta Android/iOS normales).
8. **Reportar resultado a HU** — task group `Reportar-resultado-HU`, siempre corre.

**COMPILE ONLY**: publica artifacts, NO distribuye. La distribución la hace el Release 379.

---

## 3) Release 379 — `Release-Buklo-Patient-Mobile` (path `\Buklo`, rev 59)

- **Artifact:** Build **599** alias `_BukloPatientMobile` (Latest, primario).
- **Trigger CD:** `artifactSource` sobre `_BukloPatientMobile` sin condiciones de tag → cada build 599 exitoso crea un Release.
- **Política ejecución** (3 stages): `concurrencyCount=1`, `queueDepthCount=1` = "Deploy latest and cancel the others".

### Stages (secuenciales por estado de ambiente)

**1. `Internal-Play-Firebase (tester)` (rank 1)** — aprobación **automática**, arranca con `ReleaseStarted`.
- Fase *Android distribute (Linux)*: task group `Buklo-Patient-Mobile-Release` (`96f3248d...`) → Play internal + Firebase App Distribution. Luego `Reportar-resultado-HU`.
- Fase *TestFlight (macOS)*: `TestFlight submit (IPA)` (Bash) sube el IPA a TestFlight. Luego `Reportar-resultado-HU`.
- Stage vars: `BUILD_PROJECT, FIREBASE_GROUPS, GIT_PROJECT, GIT_REPO, RELEASE_NOTES, WORK_ITEM_ID, WORK_ITEM_PROJECT`.

**2. `ASC What-to-Test sync` (rank 2)** — aprobación **automática**, arranca cuando stage 1 = succeeded.
- Fase *ASC delay* (server job): `Esperar procesamiento ASC antes de What-to-Test` (Delay).
- Fase *ASC What-to-Test durable sync* (agent, Bash): sincroniza el texto "What to Test" en App Store Connect.

**3. `Produccion` (rank 3)** — **aprobador humano: Pablo Montero Chávarria** (`releaseCreatorCanBeApprover=true`). Único stage con aprobación manual.
- Condiciones: stage 2 = succeeded **Y** artifact filter `sourceBranch=release` (solo builds de rama `release` habilitan producción).
- Fase *Agent job*: task group `Buklo-Patient-Mobile-Release` (mismo del stage 1, distribuye a producción) + `Reportar-resultado-HU`.

### Task groups usados
- `Buklo-Patient-Mobile-Release` = `96f3248d-1017-4be9-92c1-8a53d24e9075`
- `Reportar-resultado-HU` = `cefd6b95-eb0f-4a3f-b63e-a2d669a53e55`

---

## Ciclo completo Buklo Patient Mobile

```
HU (In UAT / Ready for Production)
  → Build 600 (promote-workitem: cherry-pick de commits de tareas hijas → rama uat/release, crea PR)
  → merge PR → push uat
  → Build 599 (compile: bump versión [skip ci], AAB + APK + IPA)
  → Release 379 (CD por artifactSource):
       1. Internal-Play-Firebase (auto)  → Play internal + Firebase + TestFlight
       2. ASC What-to-Test sync (auto)    → delay + sync texto ASC
       3. Produccion (aprueba Pablo, solo si el artifact viene de rama 'release')
```

Familia web (555 → `buklo-web`, CORE-PLT) y BD (562 → `project_sqldb_buklo_lab`) usan el mismo motor de promoción por HU hacia sus propios repos.

## IDs de referencia
- Builds: 555, 558, 562, 600 (`\Pipelines-Estado-HU`); 599 (`\buklo`).
- Release clásico: 379 (`\Buklo`, vsrm).
- VGs: 336 (pull-request-cherry-pick), 405/406 (mobile EAS/KeyVault).
- Pools: 308 (sh-pool-2 self-hosted), 127 (Azure Pipelines hosted), macOS-26.

---

## Cambios 2026-09-28 — Task group compartido + filtro de estado en commits de la HU + on/off

> Aplicados y verificados en vivo (builds 555 rev23, 562 rev18, 600 rev10). Aprobados A+B+C juntos.
> Respaldos previos en `.local/azure-devops/backups/` (build-555/562/600.json, promote-workitem.ps1.orig sha `9d31c092`, taskgroup-Promote-WorkItem-Cherry-Pick.json).

### A) Commits vinculados directamente a la HU respetan el filtro por estado
Antes, `promote-workitem.ps1` incluía los commits de la HU (`includeParentCommits=true`) **sin** aplicar el filtro por estado que sí se aplica a las tareas hijas. Ahora la HU se filtra igual que las hijas:

- HU en `In UAT` → habilita para `targetBranch=uat`.
- HU en `Ready for Production` → habilita para `targetBranch=release`.
- En cualquier otro estado, sus commits se omiten con el mensaje `[WARN] Commits de la HU omitidos: estado HU '<X>' != '<requerido>' requerido para rama '<destino>'`.

Guardia exacta en el script (envuelve el bloque de commits de la HU):
```powershell
$includeHuByState = ( -not $filterChildrenByPromoteState ) -or ( $huState -eq $requiredChildState )
if ($includeParentCommits -and -not $includeHuByState) { Write-WarnLog "Commits de la HU omitidos: ..." }
if ($includeParentCommits -and $includeHuByState) { $parentCommits = @(Get-CommitRelationsFromWorkItem -WorkItem $userStory) ... }
```
`$requiredChildState` se calcula ANTES del bloque de la HU (uat→`In UAT`, release→`Ready for Production`). Script parcheado sha `752b3678`.

> Nota operativa: si tras el filtro no queda ningún commit (ni HU ni hijas), el script termina con el error preexistente `[ERROR] No hay commits para promover` (exit 1). Eso NO es una regresión del cambio — es el comportamiento normal de "nada que promover". Verificado en build 600 #23271 (HU 21454, hoy en `In Development`): omitió correctamente la HU y las 74 hijas para `uat`.

### B) Interruptor on/off por pipeline — variable `includeParentCommits`
Variable **local por definición** (NO en el VG 336 compartido), `allowOverride=true` (*Settable at queue time*):
- `true` (default) → se leen los commits vinculados a la HU (sujetos al filtro de estado del punto A).
- `false` → se apagan por completo los commits de la HU en ese pipeline; solo cuentan las tareas hijas.

Se puede sobreescribir al encolar sin tocar código.

### C) Motor único = task group compartido `Promote-WorkItem-Cherry-Pick`
Los 3 pipelines (555/562/600) ahora ejecutan **un solo paso**: la invocación al task group `Promote-WorkItem-Cherry-Pick` (id `a0794992-6b57-43b0-bb08-6e778314311e`, `versionSpec 1.*`), en lugar de tener el motor embebido por File Creator en cada definición.

- El task group tiene 2 tasks: **File Creator** (escribe `promote-workitem.ps1`, ya con el parche A) + **PowerShell Script** (lo ejecuta).
- Parámetros del task group: `targetBranch`, `userStoryId`, `includeParentCommits`.
- Cada pipeline sigue apuntando a su propio repo (`adoRepositoryName`) y solo cherry-pickea commits de ESE repo — comportamiento correcto por diseño.
- Los recursos legacy (`File Creator ...v1`, `Task group: Pull-Request-cherry-pick`, ambos deshabilitados) quedaron fuera de los pipelines; NO se borró ningún recurso.

**Ventaja:** un solo lugar para mantener el motor. Un cambio futuro al `.ps1` se hace en el task group y aplica a los 3 pipelines a la vez.

---

## Cierre 2026-09-28 — Validación POSITIVA end-to-end + Service Hook para Bugs

> Cierra el pendiente de la corrida positiva. Verificado en vivo con el Bug **18151** (CORE-PLT, "El género de la usuaria aparece como Otro…"), commits en `buklo-mobile`.

### Service Hook nuevo para work items tipo Bug
El disparo automático (webhook `PromoteUS` → 558 → 555/562/600) usaba una única suscripción de Service Hook con filtro `workItemType = User Story`, por lo que **un Bug nunca disparaba la promoción** aunque cambiara a `In UAT`/`Ready for Production`.

- Suscripción original (intacta): `f25dba3c-ad79-4486-afaa-ba79391b4636` — `workItemType = User Story`.
- **Suscripción nueva creada:** `8c540fdd-f7d8-467f-bd87-2b12e8ddbe2a` — clon idéntico con `workItemType = Bug`, mismo `changedFields=System.State`, `projectId` CORE-PLT (`626de103…`), misma `url` de consumer (`PromoteUserStory-Webhook`).
- ADO no admite multi-valor en `workItemType`; por eso se agrega una segunda suscripción en vez de tocar la de User Story (aditivo, reversible con DELETE de `8c540fdd…`).
- Respaldo de la suscripción original: `.local/azure-devops/backups/servicehook-promoteus-userstory.json`.
- El filtro de estados vive en el YAML del 558 (`azure-pipelines-promote-us-trigger.yml`, repo `automatizaciones`, var `stateTargetMap`): `In UAT|uat`, `Ready for Production|release`.

### Prueba positiva confirmada (build 600 #23329, disparo automático)
Cambio de estado del Bug 18151 → `In UAT` disparó el hook de Bug → 558 encoló el 600 (`userStoryId=18151, targetBranch=uat`) → motor ejecutó:
- `[WARN] La Historia de Usuario tiene 2 commit(s) vinculados directamente. Se incluiran.` con `HU='In UAT'` == requerido → **commits de la HU INCLUIDOS** (Cambio A en positivo). Hijas 39924/39925 omitidas por estar `Closed`.
- Cherry-pick a `temp/uat/us-18151`: aplicó `ae7399ff`; `f9b98de8` salió vacío (ya contenido) → `--skip` (correcto).
- PR creado: **13928** (`[AUTO][UAT] US 18151 - …`), reviewer `[Buklo]\Code-Reviewers` agregado, HU vinculada, comentario en el work item, sin autocompletar.

Con esto quedan validados en vivo A (filtro estado HU, negativo con 21454 y positivo con 18151), B (variable on/off) y C (task group único), más el disparo automático para Bugs.

---

## Fix auth del task group `Promote-WorkItem-Cherry-Pick` (2026-10-15/16)

### Síntoma
Desde el 2026-10-15 **todos** los pipelines `pull-request-cherry-pick-*` (defs 549, 553, 555, 562, 563, 568, 600, 693) empezaron a fallar con:
```
git push origin --delete temp/uat/us-XXXXX
fatal: could not read Username for 'https://dev.azure.com': terminal prompts disabled
##[error]PowerShell exited with code '1'.
```
El build fallaba en el **Paso 5.1** (borrar la rama temporal remota preexistente).

### Causa raíz (NO era permiso ni cambio de código)
El task group `Promote-WorkItem-Cherry-Pick` (`a0794992-6b57-43b0-bb08-6e778314311e`, proyecto DevOps) **no cambió** (revisión 1, sin tocar desde 2026-09-28). El bug estaba **latente desde el día 1** en la función `Ensure-RemoteHasAuth`:

```powershell
# ANTES (roto):
$authRemoteUrl = $remoteUrl -replace '^https://', "https://:$token@"   # usuario VACÍO
Exec-Git -Args @('remote','set-url','origin',$authRemoteUrl)
```
El checkout de ADO instala la credencial como `git config http.https://Shared-Service-GM@dev.azure.com/.../repo.extraheader "AUTHORIZATION: bearer <token>"` — con el usuario **`Shared-Service-GM@`** en la URL. Al reescribir el remote a `https://:$token@...` (sin ese usuario), git **deja de matchear** ese `http.<url>.extraheader` → el `:$token@` embebido no autentica la **escritura** → prompt de username → muere con prompts deshabilitados. Las **lecturas** (fetch/ls-remote) seguían pasando, por eso el bug confundía.

**Por qué se disparó justo ese día:** solo entra al `push --delete` cuando hay una **rama temporal previa** que borrar. Había **75 ramas `temp/uat/*` acumuladas** sin limpiar (los PRs no se completaban → sus ramas quedaban vivas), así que casi toda re-promoción cruzaba el umbral y caía en el camino roto.

### Fix aplicado (task group rev 2 — confirmado end-to-end build 600 #25495)
Reescritura de `Ensure-RemoteHasAuth`: remote **limpio** (sin credencial embebida) + `http.extraheader` **global** con bearer, el canal oficial que ADO acepta para escritura, independiente del match de URL:
```powershell
# DESPUÉS (fix):
Exec-Git -Args @('remote','set-url','origin',$remoteUrl)                                   # remote limpio
Exec-Git -Args @('config','--global','http.extraheader',"AUTHORIZATION: bearer $token")   # auth por canal oficial
```
**Solo cambió la auth; la lógica (cherry-pick, PR, reviewers, vinculación HU) quedó intacta.** El build 25495 corrió verde: borró la rama vieja, cherry-pick, publicó rama, creó PR 14497. Backup del task group: `.local/azure-devops/taskgroup-backups/tg_promote_BACKUP_20261015T234411Z.json`.

### Permiso complementario: ForcePush del Build Service por repo
`git push --delete` exige el permiso **ForcePush** (bit 8, "Force push / delete branches") de la identidad **Project Collection Build Service (Shared-Service-GM)** (`51996d75-4b48-451e-9f65-134798c05fb9`) sobre **cada repo**. El fix de auth es global, pero ForcePush es **por repo**. Otorgado (ACE puntual, namespace Git `2e9eb7ed-3c0a-47d4-87c1-0ffdd275fd87`, `allow |= 8`, `merge=true`, backup + readback) en los 5 repos de los 8 pipelines:

| Repo | Proyecto | allow antes → después |
|---|---|---|
| buklo-mobile | Buklo (`26c82ecb…`) | 16534 → 16542 |
| buklo-web | CORE-PLT (`626de103…`) | 16404 → 16412 |
| project_sqldb_buklo_lab | Database-Admin (`a666d3bc…`) | 16404 → 16412 |
| project_sqldb_core_job_schedule | Database-Admin | 16404 → 16412 |
| project-qldb_core_workflow-sqldb_core_global | Database-Admin | 16404 → 16412 |
| buklo-database-sqlproject | Buklo | 16404 → 16412 |

Backups de los ACEs: `.local/azure-devops/taskgroup-backups/forcepush-aces/`. Rollback = re-aplicar el `allow` anterior sobre cada descriptor.

### Cómo encolar def 600 (y hermanas) por API
`userStoryId` es **variable settable at queue-time** → pasarla como `variables`, NO como `templateParameters` (eso deja la variable vacía → el script cae al fallback `workItemId` que también está vacío → aborta con `La variable requerida 'workItemId' no esta definida`). `workItemId` NO es settable; no intentar pasarla.
