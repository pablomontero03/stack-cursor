# Plantillas reales de payload — Variable Group / Build / Release clásicos

Generado 2026-08-24 como parte de la tarea "completar Apply-AdoClassicPlan.ps1".
Fuente: **lectura de solo lectura (GET)**, vía `Get-AdoClassicDefinitionTemplate.ps1`
(nuevo script de esta skill, dot-sourcea `Invoke-AdoRest.ps1`, nunca invocado
desde Bash), de definiciones REALES ya montadas y confirmadas compatibles
con el patrón AKS clásico de esta org.

**Definiciones usadas como plantilla:**

| Pieza | Definición real | Id | Por qué es compatible |
|---|---|---|---|
| Build | `Build-portal-cmdb` | 578 | SPA/frontend servida por contenedor propio en AKS, mismo patrón File Creator ×3 (dev/uat/prod) + Task group Build, mismas 3 ramas de CI (development/uat/release) que ya usa `Administracion-de-proyectos` |
| Release | `Deploy-Desarrollo-UAT-Produccion-portal-cmdb` | 360 | Mismo Build como único artefacto, 3 stages Desarrollo/UAT/Producción con artifact filter por rama, mismo patrón de Variable Groups confirmado en `ado-classic-aks-variablegroup-template.md` (memoria) |
| Task group Build | `Build` | `06f86588-69b1-4ff4-80fc-acc811efffdc` rev 13 | Es el que YA resuelve por nombre el inventario en vivo — el id embebido en el step de la definición 578 (`f214b26f-...`) está **obsoleto** (ver hallazgo abajo) |
| Task group Deploy | `Deployment-Azur-Aks-v3` | `1fdf52f7-9160-4049-bb78-c7bffadf022d` rev 2 | Igual en ambos — coincide con el id resuelto por nombre |

**⚠️ Hallazgo de seguridad (no relacionado con esta tarea, reportado al
usuario en el momento):** el GET de la definición de Release 360 devolvió
`containerRegistryPassword` en texto plano como variable de **stage**
(sin `isSecret`), repetida en los 3 stages. El archivo crudo con ese valor
se leyó solo en memoria de este proceso y se borró inmediatamente
(`Remove-Item` sobre el directorio scratch) — nunca se copió a
`.local/azure-devops/`, nunca se commiteó, nunca se repite acá. Esto
**no** se usa como fuente de ningún campo de las plantillas de abajo.

## Hallazgo clave: el step "Task group: Build" de la definición 578 usa un id OBSOLETO

El step real de 578 referencia `task.id = f214b26f-73a6-4765-838b-197a336cfcd9`
(hoy, en el inventario en vivo, ese id pertenece a un task group **distinto**
llamado `Build-MultiStage`, rev 9). El task group que hoy se llama **`Build`**
tiene id `06f86588-...` rev 13, **version.major=1** (confirmado via GET a
`/_apis/distributedtask/taskgroups/06f86588-...`).

Sus inputs actuales (confirmados por GET, no adivinados) son **distintos**
a los que usa el step obsoleto de 578:

| Input | Step obsoleto (578, `f214b26f`) | Task group `Build` VIGENTE (`06f86588` rev13) |
|---|---|---|
| `ambiente` | sí | sí |
| `conexcontainerregistries` | sí | sí |
| `rutadockerfile` | sí | sí |
| `image` | **sí** | **no existe** |
| `servicesname` | no | **sí** (reemplaza a `image`) |
| `ambienteOverride` | sí (vacío) | no existe |
| `tag` | sí | sí |

**Decisión:** el generador de payload de Build usa el contrato VIGENTE
(`servicesname`, no `image`) para el step "Task group: Build" y para las
variables de pipeline del Build. Esto es un cambio respecto al diseño
previo de `New-AdoClassicAksPlan.ps1` (que todavía usa `image` como
variable de Build) — ver nota de seguimiento al final de este documento.

El task group `Deployment-Azur-Aks-v3` (`1fdf52f7-...` rev2, version.major=1)
sí coincide exactamente con lo documentado: inputs `aksClusterName`,
`aksResourceGroup`, `ambiente`, `namespace`, `pipeline` — **no** tiene un
input de service connection propio (`conexkubernetes` no es un input del
task group). Esto es coherente con lo observado en los Variable Groups
reales (memoria `ado-classic-aks-variablegroup-template.md`): Dev/UAT no
necesitan `aksClusterName`/`aksResourceGroup` en su Library porque —según
el Release 360 real— esos dos valores se resuelven por Variable Group
distinto por ambiente iiiigual, mientras que en Dev/UAT el task group que
corre es en realidad **`Deployment-MultiStage-Cluster-Desarrollo`**
(`fc4043e2-...`), NO `Deployment-Azur-Aks-v3` — ver hallazgo siguiente.

## Hallazgo clave: Dev/UAT y Producción usan DOS task groups de deploy distintos

En el Release 360 real:

- Stage **Desarrollo** (id 432) y **UAT** (id 433): step
  `Task group: Deployment-MultiStage-Cluster-Desarrollo`
  (`fc4043e2-e239-4710-9d5a-2a92055ff1ea`, version 1.*), inputs:
  `ambiente`, `containerregistries`, `containerRegistryPassword`,
  `containerRegistryUsername`, `image`, `namespace`, `pipeline`,
  `servicesname`, `tag` — **9 inputs**, sin `aksClusterName`/
  `aksResourceGroup` (coincide exacto con las 14 keys de sus Variable
  Groups reales, que tampoco los tienen).
- Stage **Producción** (id 434): step `Task group: Deployment-Azur-Aks-v3`
  (`1fdf52f7-...`), inputs `aksClusterName`, `aksResourceGroup`,
  `ambiente`, `namespace`, `pipeline` — **5 inputs** (coincide con las 16
  keys de su Variable Group real, que sí los tiene).

Esto **resuelve** la duda pendiente que quedó abierta en la conversación
sobre `Administracion-de-proyectos`: Dev/UAT no omiten
`aksClusterName`/`aksResourceGroup` por casualidad — usan un task group de
deploy **distinto**, pensado para un cluster fijo compartido
("Desarrollo"), mientras que Producción usa el genérico que sí recibe
cluster/RG explícitos. Cada ambiente probablemente apunta a un cluster
distinto de forma implícita según qué task group corre.

**Decisión para el generador de payload:** el plan (`plan.dependencies`)
debe poder declarar un `deployTaskGroup` **por stage**, no uno solo fijo
para los 3. `New-AdoClassicAksPlan.ps1` y los planes ya generados de
`Administracion-de-proyectos` asumían `Deployment-Azur-Aks-v3` para los 3
— es una simplificación que hay que corregir en un seguimiento posterior
(no forma parte de esta tarea, que es sobre la herramienta, no sobre ese
plan puntual). El generador de payload de esta tarea soporta ambos task
groups (uno por stage, configurable), documentado con datos ficticios en
las pruebas.

## Plantilla sanitizada — POST Variable Group

**Corrección 2026-08-25:** la afirmación original de esta sección ("no hay
una definición real de VG para copiar por GET directo") era incorrecta —
`GET .../distributedtask/variablegroups/{id}` sí devuelve el body
completo. Un primer intento real de `POST` sin `variableGroupProjectReferences`
falló con `500` contra la organización real; se confirmó la causa
leyendo `VariableGroup 370` (`Desarrollo-portal-cmdb`) por GET, y se
corrigió `New-AdoVariableGroupPayload` para incluir ese campo, que esta
organización/versión de API exige para crear.

Basada en la definición real 370, con:

```jsonc
{
  "name": "<Ambiente>-<servicesname>",           // ej. Desarrollo-portal-cmdb
  "type": "Vsts",
  "variables": {
    "ambiente": { "value": "<dev|uat|prod>" },
    "conexcontainerregistries": { "value": "<nombre service connection ACR>" },
    "containerregistries": { "value": "<host ACR>" },
    "conexkubernetes": { "value": "<nombre service connection AKS>" },   // solo si el stage la usa
    "namespace": { "value": "<namespace>" },
    "aksClusterName": { "value": "<cluster>" },      // solo Produccion (o el stage que use Deployment-Azur-Aks-v3)
    "aksResourceGroup": { "value": "<resource group>" }, // idem
    "tag": { "value": "$(Build.BuildId)" },
    "reqcpu": { "value": "<n>" }, "reqmem": { "value": "<n>" },
    "limcpu": { "value": "<n>" }, "limmem": { "value": "<n>" },
    "servicesname": { "value": "<servicesname>" },
    "image": { "value": "<image>" },
    "pipeline": { "value": "Build-<servicesname>" },
    "rutadockerfile": { "value": "<ruta>" }
  },
  "variableGroupProjectReferences": [
    {
      "projectReference": { "id": "<GUID real del proyecto>", "name": "<Proyecto>" },
      "name": "<Ambiente>-<servicesname>",
      "description": ""
    }
  ]
}
```

**Conservado**: forma de `variables` (cada key → `{ value }`), `type:
"Vsts"`, `variableGroupProjectReferences[0].name` = mismo nombre que el
VG raíz (patrón real observado).

**Sustituido**: `variableGroupProjectReferences[0].projectReference.id`
→ el GUID real del proyecto (`DevOps` = `7f632f4b-b3cb-4530-a5ff-ee9f809ab478`,
confirmado via MCP `core_list_projects`; único proyecto soportado hoy —
`New-AdoVariableGroupPayload` lanza si el plan usa otro proyecto sin un
mapeo explícito, nunca inventa un id).

Campos **eliminados** respecto a lo que devolvería un GET de un VG real:
`id`, `isShared`, `createdBy`/`modifiedBy`/`createdOn`/`modifiedOn`
(identidad/timestamps — server-side), `description` a nivel raíz (vacía,
no aplica a creación), y — regla de oro de este dominio — **cualquier**
`value` real preexistente de otro VG (nunca se copian valores de otra
app, solo la FORMA de las keys).

## Plantilla sanitizada — POST Build definition

Basada en la definición real 578, con:

**Conservado** (estructura y valores no específicos de portal-cmdb):
`options` (2 entradas: CI habilitado con `branchFilters:["+refs/heads/*"]`
a nivel de opción — distinto del trigger real, ver abajo —, y creación de
work item en fallo deshabilitada), `buildNumberFormat`,
`jobAuthorizationScope`, `jobTimeoutInMinutes`, `jobCancelTimeoutInMinutes`,
forma de `process.phases[0].target` (`agentSpecification.identifier:
"ubuntu latest"`), `process.type: 1`, forma de
`repository.properties` (fetchDepth, cleanOptions, etc.), `quality:
"definition"`.

**Sustituido** (valor específico de la app, tomado del plan):
`triggers[0].branchFilters` → las 3 ramas reales del plan
(`+refs/heads/<dev>`, `+refs/heads/<uat>`, `+refs/heads/<prod>`, tal cual
`repo.ciBranchFilters`), `variables` → `ambiente`/`conexcontainerregistries`/
`rutadockerfile`/`servicesname`/`tag`/`system.debug` con los valores del
plan (usando el contrato VIGENTE del task group `Build`, no `image`),
`process.phases[0].steps` → los 3 File Creator (`deployment-dev.yml` /
`-uat.yml` / `-prod.yml`, el de prod `enabled:false` hasta activarse) con
el `filecontent` real del manifiesto de ESTA app (nunca el de
portal-cmdb), el step "Task group: Build" con `task.id` = el id VIGENTE
resuelto por nombre (nunca `f214b26f`) y `inputs` con el contrato nuevo
(`servicesname`, no `image`), `repository` → repo/branch default/id de
ESTA app, `path`/`name` → los del plan, `queue` → **por defecto** se
conserva literal `{id:127, pool:{id:9, name:"Azure Pipelines"}}` (mismo
valor real y funcional que usa 578; el plan puede sobreescribirlo via
`dependencies.agentPool` si la app necesita otro pool — no se resuelve
dinámicamente en esta primera implementación, ver nota de alcance).

**Eliminado** (nunca se envían en un POST de creación, son campos de
respuesta / identidad / temporales): `id`, `uri`, `url`, `_links`,
`revision`, `createdDate`, `authoredBy` (identidad del creador —
`pmontero@grupomontecristo.com` en el original), `drafts`, `project`
completo (el POST va a `/{project}/_apis/build/definitions`, el proyecto
va en la URL, no en el body), `queue._links`. También se elimina el step
"Delete files from src/environments" (limpieza específica de un proyecto
Angular, no aplica a esta app) y el step Bash "setea variable ambiente"
(estaba `enabled:false` en el original y su lógica de branch→ambiente no
aporta nada si el Build no usa `$(ambiente)` para nada relevante al
publicar — el ambiente real de cada deploy lo define la Variable Group de
cada STAGE del Release, no el Build).

## Plantilla sanitizada — POST Release definition

Basada en la definición real 360, con:

**Conservado**: forma general de `environments[]` (uno por stage, con
`preDeployApprovals`/`postDeployApprovals`/`deployPhases`/`conditions`/
`environmentOptions`/`retentionPolicy`/`executionPolicy`), forma de
`artifacts[0]` (`type:"Build"`, `defaultVersionType:{id:"latestType",
name:"Latest"}`), forma de `triggers[0]`
(`triggerType:"artifactSource"`, `triggerConditions: []` — CD siempre
habilitado), `releaseNameFormat: "Release-$(rev:r)"`,
`deployPhases[0].deploymentInput.queueId` → **por defecto** se conserva
literal `308` (mismo valor real y funcional; sobreescribible vía plan, no
resuelto dinámicamente en esta primera implementación).

**Sustituido**: `environments[].name`/`rank` → Desarrollo(1)/UAT(2)/
Producción(3), `environments[].variableGroups` → el id del VG de CADA
ambiente (resuelto en vivo, nunca inventado), `environments[].conditions[1].value.sourceBranch`
→ la rama real de cada ambiente del plan, `environments[].deployPhases[0].workflowTasks[0]`
→ el task group de deploy que corresponda por stage (Desarrollo/UAT:
`Deployment-MultiStage-Cluster-Desarrollo`; Producción:
`Deployment-Azur-Aks-v3`, ver hallazgo arriba) con sus inputs reales,
`environments[].preDeployApprovals`/`postDeployApprovals` → `isAutomated:
true` (sin gate humano) por defecto, EXCEPTO si el plan declara
`release.preDeploymentApprovalRequired=true` con
`preDeploymentApprovalGroup`, en cuyo caso queda `isAutomated: false` con
un `approver` cuyo id debe resolverse por separado (identidad del grupo,
fuera de alcance de esta tarea — el plan lo deja marcado
`approverIdResolved:false` hasta que se resuelva contra el API de
identidades), `artifacts[0].alias`/`definition` → el Build de este plan.

**Eliminado**: `id`, `url`, `_links`, `revision`, `createdBy`/`modifiedBy`
(identidad), `createdOn`/`modifiedOn`, `isDeleted`/`isDisabled` (server-side),
`lastRelease`/`currentRelease` (no existen todavía), `source`
(`userInterface` — no aplica a creación por API), `environments[].owner`
(identidad), `environments[].variables.containerRegistryPassword/
containerRegistryUsername` (⚠ el hallazgo de seguridad de arriba — nunca
se copian, y de todos modos no son necesarios: `conexcontainerregistries`
ya resuelve el pull de imagen por service connection, no por user/pass
sueltos), `environments[].deployStep` (asignado por el servidor),
`environments[].badgeUrl`, `properties.DefinitionCreationSource` (decía
`"ReleaseClone"` — no aplica, esta definición se crea desde cero).

## Campos a quitar de un GET antes de usarlo como body de un PUT (update-*)

Confirmado 2026-08-25 aplicando la primera actualización real
(Build 622 / Release 381, Administracion-de-proyectos): a diferencia de
crear (POST, body armado desde cero), actualizar (PUT) parte de un GET
real y solo muta lo necesario — pero el GET trae campos de solo
lectura/identidad que la API SÍ rechaza con `400` si van en el body del
PUT (confirmado por ensayo estructurado: cada quitado se probó contra la
organización real, nunca a ciegas, comparando siempre contra el body de
creación que ya había funcionado).

**Build definition** — quitar del nivel raíz: `_links`, `authoredBy`,
`createdDate`, `drafts`, `uri`, `url`, `project`. Mantener `id` y
`revision` (requeridos para el PUT). También quitar `queue._links`
(anidado).

**Release definition** — quitar del nivel raíz: `_links`, `createdBy`,
`createdOn`, `modifiedBy`, `modifiedOn`, `url`, `projectReference`,
`source`, `description`, `isDeleted`, `isDisabled`. Mantener `id` y
`revision`. Por cada `environments[]`: quitar `owner`, `deployStep`,
`badgeUrl`, `currentRelease`, `properties`, **y el propio `id` del
environment** (a diferencia de la definición raíz, aquí el `id` SÍ
rompe el PUT). Por cada entrada de `preDeployApprovals.approvals[]` /
`postDeployApprovals.approvals[]`: quitar `id` (el approval real
asignado por el servidor) — mantener solo `rank`/`isAutomated`/
`isNotificationOn`, igual que en el body de creación.

**Regla general para cualquier update-* futuro**: el body aprobado (y
por lo tanto el `bodyHash`) debe ser el GET real MENOS exactamente los
campos de arriba — nunca reconstruir desde cero (eso ya es lo que hace
`create-*`), y nunca asumir que el servidor tolera los campos de
identidad/solo-lectura del GET con silencio — probarlo.

## Convención org-wide: fases de agrupación de merges ("gana el más nuevo")

Agregado 2026-08-25, a pedido explícito del usuario: **de ahora en
adelante, todo Build clásico AKS nuevo que se cree en este dominio debe
incluir estas 3 fases**, no solo Administracion-de-proyectos — es una
convención real ya usada por `Buklo-frontend-portal-Build` (552) y
aplicada por primera vez fuera de Buklo en `Build-administracion-proyectos-web`
(622, revisión 3, luego corregida hasta revisión 8). El objetivo: si
varias Historias de Usuario mergean casi al mismo tiempo, agrupa esos
builds en uno solo en vez de encolar uno por cada push.

**AUTOMATIZADO 2026-08-25.** `New-AdoBuildDefinitionPayload` (en
`New-AdoClassicPayloads.ps1`) genera las 8 piezas del lado Build por
defecto — ya no hace falta replicar a mano. Se activa cuando
`$Plan.mergeBatching.enabled -eq $true` (campo que `New-AdoClassicAksPlan.ps1`
escribe con default `$true`, o sea que un plan nuevo lo trae activo salvo
que se pase `-DisableMergeBatching` explícito). Requiere que
`$Plan.dependencies.evaluarVentanaTaskGroup.id`,
`.ganaElMasNuevoTaskGroup.id` y `.reportarResultadoTaskGroup.id` estén
resueltos (`Test-AdoClassicPlan.ps1` los resuelve contra inventario en
vivo, mismo patrón que `buildTaskGroup`/`deployTaskGroup` — solo cuando
`mergeBatching.enabled=true`, un plan viejo sin ese campo no exige nada
nuevo). Funciones nuevas en `New-AdoClassicPayloads.ps1`:
`New-AdoMergeBatchingPhases` (arma las 2 fases previas),
`New-AdoGanaElMasNuevoStep`, `New-AdoReportarResultadoHuBuildStep`. Los
datos exactos de abajo (ids, script puente, conditions) son ahora la
documentación de REFERENCIA de lo que esas funciones generan — ya no
hace falta copiarlos a mano, pero siguen siendo la fuente de verdad si
hay que auditar o depurar el generador. Cubierto por 12 tests nuevos en
`scripts/tests/run-script-tests.ps1` (grupo "S-batch"), 243/243 verdes.

**Orden de fases**: `Evaluar ventana` → `Ventana de agrupacion` →
`Agent job 1` (la fase de build real, ya documentada arriba — sin
cambios en sus propios steps).

**Fase 1 — `Evaluar ventana`** (agente, `target.type=1`,
`allowScriptsAuthAccessOption=true`, `refName="Batch_Gate"`,
`condition="and(succeeded(), not(canceled()))"`,
`jobAuthorizationScope="projectCollection"`, `jobTimeoutInMinutes=10`,
`jobCancelTimeoutInMinutes=1`):
1. `Task group: Evaluar-ventana-agrupacion` (metaTask, id
   `8c699091-35a9-475b-af9c-2d3386d6118c`, versionSpec `1.*`, **0 inputs
   propios** — confirmado contra la definición real del task group,
   `inputs=[]`), `timeoutInMinutes=5`, `continueOnError=true`,
   `alwaysRun=false`, `condition="succeeded()"`.
2. `Publicar shouldWait al job siguiente` (task PowerShell nativo, id
   `e213ff0f-5d5c-4791-802d-52ea3e7be1f1`, versionSpec `2.*`,
   **`refName="gate"` es obligatorio** — la fase siguiente lo referencia
   como `dependencies.Batch_Gate.outputs['gate.shouldWait']`),
   `timeoutInMinutes=5`, `continueOnError=true`, `alwaysRun=false`,
   `condition="succeeded()"`. Script (puente entre la variable de salida
   del task group y la siguiente fase — texto exacto, sin modificar):
   ```powershell
   $ErrorActionPreference = 'Continue'
   $v = $env:SHOULDWAIT
   if ([string]::IsNullOrWhiteSpace($v)) { $v = $env:shouldWait }
   if ([string]::IsNullOrWhiteSpace($v)) {
     $v = 'true'
     Write-Host '##vso[task.logissue type=warning]shouldWait no llego del task group; se espera por precaucion.'
   }
   Write-Host "Puente: shouldWait=$v"
   Write-Host "##vso[task.setvariable variable=shouldWait;isOutput=true]$v"
   exit 0
   ```
   Otros inputs: `targetType='inline'`, `filePath=''`, `arguments=''`,
   `errorActionPreference='continue'`, `failOnStderr='false'`,
   `showWarnings='false'`, `ignoreLASTEXITCODE='true'`, `pwsh='false'`,
   `workingDirectory=''`, `runScriptInSeparateScope='false'`.

**Fase 2 — `Ventana de agrupacion`** (servidor, SIN agente —
`target={"executionOptions":{"type":0},"type":2}`, sin
`allowScriptsAuthAccessOption`, `refName="Batch_Window"`,
`dependencies={"scope":"Batch_Gate","event":null}`,
`condition="and(and(succeeded(), ne(variables['BATCH_WINDOW_MINUTES'], '0'), eq(dependencies.Batch_Gate.outputs['gate.shouldWait'], 'true')), not(canceled()))"`,
`jobAuthorizationScope="projectCollection"`, `jobTimeoutInMinutes=120`,
`jobCancelTimeoutInMinutes=1`):
1. `Esperar ventana para agrupar merges de varias HU` (task Delay, id
   `28782b92-5e8e-4458-9751-a71cd1492bae`, versionSpec `1.*`,
   `timeoutInMinutes=0`, `continueOnError=false`, `alwaysRun=false`,
   `condition="succeeded()"`, input único: `delayForMinutes='$(BATCH_WINDOW_MINUTES)'`).

**Fase 3 — `Agent job 1`** (la fase de build ya existente): agregar
`dependencies={"scope":"Batch_Window","event":null}` y cambiar
`condition` a
`"and(in(dependencies.Batch_Window.result, 'Succeeded', 'SucceededWithIssues', 'Skipped'), not(canceled()))"`.
`refName` se mantiene `"Job_1"` (default ya existente). **`target.allowScriptsAuthAccessOption` debe ser `true`** en esta fase también (no solo en la fase 1) —
`Gana-el-mas-nuevo` y `Reportar-resultado-HU` usan `SYSTEM_ACCESSTOKEN`
(OAuth) para hablar con la API de Azure DevOps (cancelar builds
superados / comentar en la HU); sin esto esas llamadas fallan en
silencio o quedan sin permiso. **Además** — y esto SÍ es parte del
mecanismo de agrupación, no de los 5 pasos opcionales de la lista de
abajo — hay que agregar como **PRIMER step** de esta fase (antes de
cualquier File Creator/build):
- `Task group: Gana-el-mas-nuevo` (metaTask, id
  `69c14633-6cac-4096-b70f-95736fdaae95`, versionSpec `1.*`, **0 inputs
  propios**), `enabled=true`, `continueOnError=false`, `alwaysRun=false`,
  `timeoutInMinutes=5`, `condition="succeeded()"`.

**Corrección 2026-08-25:** este step se omitió por error la primera vez
que se replicaron las 3 fases en Administracion-de-proyectos (Build 622
revisión 3) — se documentaron y copiaron bien los task groups de las
fases 1 y 2, pero no este de la fase 3, a pesar de que `Gana-el-mas-nuevo`
es literalmente el mecanismo que le da nombre a toda esta convención
("gana el más nuevo"). El usuario lo notó comparando visualmente contra
el Build 552 real y se agregó en la revisión 7. Al replicar esta
convención en un pipeline nuevo, verificar los 3 pasos de la fase 1, el 1
paso de la fase 2, Y este primer paso de la fase 3 — los 5 juntos son el
mecanismo completo.

**El step `Task group: Reportar-resultado-HU` (al final de `Agent job 1`,
después del build real) necesita su propio `condition` distinto del
default.** No usar `succeededOrFailed()` — dejar
`condition="and(always(), not(canceled()))"`. Motivo: un build que fue
SUPERADO por uno más nuevo (la fase 2 lo deja `Skipped`/cancelado por el
mecanismo de agrupación, no por un error real) no debe comentar un
resultado de ERROR en la Historia de Usuario; `and(always(),
not(canceled()))` corre siempre salvo que el job en sí haya sido
cancelado, que es justo la señal correcta para distinguir "build
superado, no reportar" de "build corrió y falló de verdad, sí reportar".

**El trigger de CI (`triggers[0]`) necesita `maxConcurrentBuildsPerBranch=5`,
no el default `1`.** Con `1`, un build nuevo que llega mientras otro ya
está corriendo/esperando en la ventana de agrupación queda en estado
`notStarted` y nunca llega a entrar a la fase `Ventana de agrupacion` —
rompe el mecanismo completo de agrupación silenciosamente (el build ni
siquiera arranca la fase 1). `batchChanges` sigue en `false` (eso es un
concepto distinto, batching nativo de ADO, no relacionado con este
mecanismo custom).

**Corrección 2026-08-25 (revisión 8):** estos 3 puntos (OAuth en Job_1,
condition de Reportar-resultado-HU, maxConcurrentBuildsPerBranch) también
se omitieron en la primera replicación y se detectaron por el usuario
comparando explícitamente contra el Build 552 real, campo por campo. Con
esto, la convención completa de agrupación son 8 piezas: 3 pasos de fase
1 + 1 paso de fase 2 + 1 paso de fase 3 (Gana-el-mas-nuevo) + OAuth en
fase 1 Y fase 3 + condition especial de Reportar-resultado-HU +
`maxConcurrentBuildsPerBranch=5` en el trigger. Verificar los 8 al
replicar en un pipeline nuevo.

**Corrección 2026-08-25 (dry-run de comparación contra Build 552/622
reales):** el step `Task group: Reportar-resultado-HU` tiene además su
propio `alwaysRun=false` — confirmado vía GET fresco en AMBOS Build 552 y
Build 622 reales. El generador original asumía `alwaysRun=true` (copiado
por error del lado Release, donde ese campo sí es `true` — ver más
abajo), sin confirmarlo por separado del lado Build. La `condition`
propia (`and(always(), not(canceled()))`) ya cubre "correr aunque el step
anterior haya fallado"; `alwaysRun=true` sería redundante y no es lo que
la organización usa de verdad. Corregido en `New-AdoClassicPayloads.ps1`
(`New-AdoReportarResultadoHuBuildStep`), test-locked, 270/270.

### Piezas equivalentes del lado Release (OAuth + condition por ambiente)

El mismo motivo de fondo (`Reportar-resultado-HU` necesita
`SYSTEM_ACCESSTOKEN` para comentar en la HU) aplica también dentro del
**Release**, no solo del Build — son dos superficies distintas con el
mismo requisito, hay que revisar ambas. Confirmado 2026-08-25 comparando
`Deploy-Desarrollo-UAT-Produccion-portal-cmdb` (348, real) contra
`Deploy-Desarrollo-UAT-Produccion-Administracion-Proyectos-Web` (381) en
sus 3 ambientes (Desarrollo/UAT/Producción):

1. **`environments[].deployPhases[0].deploymentInput.enableAccessToken`**
   debe ser `true` en los 3 ambientes ("Agent job → Allow scripts to
   access the OAuth token" en la UI). Sin esto, `Reportar-resultado-HU`
   no tiene `SYSTEM_ACCESSTOKEN` y no puede comentar en la HU ni moverla
   a "Applied in production" — falla en silencio, no tira un error
   visible.
2. **`condition` del step `Reportar-resultado-HU`** dentro de cada
   ambiente: usar `always()` (no `succeededOrFailed()`), igual que en
   348. Con el punto 1 ya resuelto el flujo funciona igual; esto es
   alineación de consistencia con la referencia real, no un blocker
   funcional por sí solo — aun así se aplica siempre que se replique esta
   convención, para no dejar una divergencia sin motivo.

Corregido en Release 381 revisión 3 (los 3 ambientes a la vez, mismo
`update-release-definition` PUT). Al crear o revisar un Release nuevo que
siga este patrón (artifact de un Build con `Reportar-resultado-HU`),
verificar estos 2 puntos en cada ambiente antes de darlo por completo —
son la contraparte, del lado Release, de la pieza "OAuth en fase 1 y fase
3" y "condition especial" ya documentadas arriba para el Build.

**AUTOMATIZADO 2026-08-25.** `New-AdoReleaseDefinitionPayload` genera
ambas piezas por ambiente cuando ese elemento del array `$Environments`
trae la clave `reportarResultadoTaskGroupId` (el id, ya resuelto, del
mismo task group `Reportar-resultado-HU` que usa el lado Build —
`$Plan.dependencies.reportarResultadoTaskGroup.id`). Cuando esa clave
está presente en un ambiente: agrega el 2do `workflowTask` (Reportar-
resultado-HU, `condition="always()"`) y fuerza
`deploymentInput.enableAccessToken=true` SOLO para ese ambiente — un
ambiente que no traiga la clave sigue con el comportamiento viejo
(1 solo workflowTask, `enableAccessToken=false`), sin cambios. Como
`New-AdoClassicAksPlan.ps1` arma un plan por stage (no el array
`$Environments` completo), quien ensambla ese array a mano para llamar
`New-AdoReleaseDefinitionPayload` debe agregar
`reportarResultadoTaskGroupId` en cada stage cuyo plan tenga
`release.reportarResultadoHU=true` (marcador que el plan ya trae). Cubierto
por 3 tests en el grupo "S-batch" de `run-script-tests.ps1`.

**Variables de Build nuevas requeridas** (valores reales de 552, ajustar
`BATCH_WINDOW_MINUTES` si se quiere otra ventana de tiempo, el resto es
config fija del mecanismo): `BATCH_WINDOW_MINUTES='5'`,
`SUPERSEDE_REASONS='IndividualCI,BatchedCI'`,
`BATCH_WAIT_REASONS='IndividualCI,BatchedCI'`,
`BATCH_PR_TITLE_MARKER='[AUTO]'`. **NO agregar `major`/`minor`** — esas
son del esquema de versionado de 552 (`buildNumberFormat=$(major).$(minor).$(Rev:r)`),
un tema aparte no relacionado con la agrupación; se agregaron por error
la primera vez en Administracion-de-proyectos y se sacaron después.

**Limitación conocida, sin resolver:** al aplicar esto vía PUT
(actualización), el campo `dependencies` de fase no persiste en el GET
de vuelta — solo persisten las `condition` (que sí referencian
`dependencies.Batch_Gate...`/`dependencies.Batch_Window...` y ADO
probablemente reconstruye el grafo de dependencias a partir de esas
condiciones). Confirmado visualmente en la UI que las 3 fases quedan
bien ordenadas (screenshot del usuario, 2026-08-25). Nunca verificado
con un Build real corriendo (fuera de alcance mientras no se apruebe
encolar un Build) — si se llegara a encolar uno como prueba, confirmar
que efectivamente espera la ventana antes de arrancar `Agent job 1`.

**Cuándo NO copiar además los otros 5 pasos de 552** (`File Creator
.npmrc`, `File Creator generate-version-json.ps1` + su copia
deshabilitada, `Bash Script setea variable ambiente` standalone, `npm
Authenticate .npmrc`): son independientes de la agrupación de merges —
sirven para apps que necesitan paquetes npm privados y versionado de
`generate-version-json.ps1`. Administracion-de-proyectos los descartó
explícitamente (SPA sin dependencias privadas); evaluar caso por caso en
la próxima app, no copiarlos por default junto con las fases de
agrupación.

## Alcance de esta primera implementación (documentado, no oculto)

- `queue`/`queueId` de Build y Release quedan con el valor real observado
  como default fijo, no resueltos dinámicamente contra un pool/queue
  distinto — cualquier app que necesite otro agent pool debe pasar
  `dependencies.agentPool` explícito (el generador lo usa si está
  presente; si no, usa el default documentado arriba).
- La resolución de identidad de un grupo de aprobadores (ej.
  `[Shared-Service-GM]\Release Executers`) no se implementa en esta
  tarea — el payload de Release admite `preDeploymentApprovalRequired`
  pero no completa `approvers[].approver.id` todavía; aplicar un plan que
  lo requiera de verdad exige ese paso adicional primero.
- **RESUELTO 2026-08-25.** Este punto decía que los planes ya generados
  para `Administracion-de-proyectos` seguían el diseño anterior y que
  corregir el generador quedaba pendiente — ya se corrigió: ver
  "Task group de build: `Build-MultiStage` es el estándar, no `Build`"
  más abajo. Los archivos `aks-administracion-proyectos-web-*.json`
  puntuales de esa app siguen con su contenido histórico (no se
  regeneran retroactivamente), pero el GENERADOR (`New-AdoClassicAksPlan.ps1`
  / `New-AdoBuildDefinitionPayload`) ya usa el contrato correcto por
  defecto para cualquier plan nuevo.

## Task group de build: `Build-MultiStage` es el estándar, no `Build`

**Corregido 2026-08-25.** El generador (`New-AdoClassicAksPlan.ps1` /
`New-AdoBuildDefinitionPayload`) usaba por defecto el task group `Build`
(contrato: `ambiente`/`conexcontainerregistries`/`rutadockerfile`/
`servicesname`/`tag`) — pero el pipeline real que sirvió de base para
toda esta documentación (`Build-administracion-proyectos-web`, 622) usa
`Build-MultiStage` (contrato distinto: `ambiente`/`ambienteOverride`
(fijo `'auto'`)/`conexcontainerregistries`/`image`/`rutadockerfile`/`tag`
— sin `servicesname`). El usuario confirmó explícitamente que
`Build-MultiStage` es el que se va a usar en los pipelines de acá en
adelante.

Cambios aplicados:

- `New-AdoClassicAksPlan.ps1`: `-BuildTaskGroupName` default cambió de
  `'Build'` a `'Build-MultiStage'`.
- `New-AdoBuildDefinitionPayload`: el `displayName` del step del task
  group de build ahora es dinámico (`"Task group: $($Plan.dependencies.buildTaskGroup.name)"`,
  nunca hardcodeado); sus `inputs` default son el contrato de
  `Build-MultiStage`. Un nuevo parámetro opcional `-BuildTaskGroupInputs`
  (hashtable) permite pasar otro contrato explícito si algún pipeline
  puntual todavía necesitara `Build` — la función nunca adivina el
  contrato por el nombre del task group, siempre hay un default
  documentado, sobreescribible.
- `buildVariables.servicesname` se quitó del payload del Build (no lo
  consume `Build-MultiStage`); se agregó `buildVariables.image`
  (obligatorio — la función lanza si falta). **`image` debe venir con el
  guion final incluido** (ej. `"mi-app-web-"`): `Build-MultiStage` arma
  el nombre del repositorio Docker concatenando `$(image)$(ambiente)`
  **sin separador**. Esta convención del guion final ya existía para el
  token `#{image}#` de los manifiestos K8s (mismo patrón de
  concatenación, ver sección de abajo) — no es una exigencia nueva, solo
  ahora también aplica al Build.

Cubierto por tests nuevos en el grupo `S` de `run-script-tests.ps1`
(displayName dinámico, contrato default, rechazo sin `image`, override
vía `-BuildTaskGroupInputs`) y por la regeneración del fixture de
`Test-AdoClassicPlan.ps1` para incluir `Build-MultiStage` en el
inventario base de pruebas — 247/247 tests verdes.

## Ensamblado del Release de varios ambientes: `New-AdoReleaseEnvironmentEntry`

**Agregado 2026-08-25.** `New-AdoClassicAksPlan.ps1` sigue armando **un
plan por ambiente** (no cambia). Su `release.stage` ya NO queda
hardcodeado a `'Produccion'` desde el 2026-08-26 — ahora lo decide el
parámetro `-Stage` (`Desarrollo`/`UAT`/`Produccion`, default `Produccion`
para no romper invocaciones existentes) — ver § "3 gaps reales del
generador corregidos" más abajo para el detalle completo. Juntar los 3 ambientes
(Desarrollo/UAT/Producción) en el array `$Environments` que pide
`New-AdoReleaseDefinitionPayload` se venía haciendo a mano cada vez,
recordando de memoria el contrato exacto de `deployTaskGroupInputs` de
cada task group de deploy — la parte más propensa a error de todo el
ensamblado.

`New-AdoReleaseEnvironmentEntry` (en `New-AdoClassicPayloads.ps1`) arma
**una** entrada de ese array, resolviendo el contrato correcto según
`-DeployTaskGroupName`:

- `Deployment-Azur-Aks-v3` → `{ aksClusterName, aksResourceGroup,
  ambiente, namespace, pipeline }` (confirmado contra Release 381/360
  reales, stage Producción).
- `Deployment-MultiStage-Cluster-Desarrollo` → `{ ambiente,
  containerregistries, containerRegistryUsername: '',
  containerRegistryPassword: '', image, namespace, pipeline,
  servicesname, tag }` (confirmado contra Release 381/360 reales, stages
  Desarrollo/UAT).
- Cualquier otro nombre de task group de deploy → **rechaza**, nunca
  adivina el contrato; el llamador pasa `-DeployTaskGroupInputsOverride`
  (hashtable) explícito para un contrato nuevo no contemplado todavía.

Sigue exigiendo que `-VariableGroupId` (id real de una VG YA CREADA) y
`-DeployTaskGroupId` (resuelto por `Test-AdoClassicPlan.ps1` contra
inventario en vivo) vengan ya resueltos — esta función no crea nada ni
resuelve ids, solo da forma al hashtable de la entrada. Ensamblar el
Release completo queda en:

```powershell
$environments = @(
    (New-AdoReleaseEnvironmentEntry -Stage 'Desarrollo' -VariableGroupId 409 -ArtifactFilterBranch 'development' `
        -DeployTaskGroupName 'Deployment-MultiStage-Cluster-Desarrollo' -DeployTaskGroupId $idDeployDev `
        -Ambiente '$(ambiente)' -ContainerRegistries '$(containerregistries)' -Image '$(image)' `
        -Namespace '$(namespace)' -Pipeline '$(pipeline)' -ServicesName '$(servicesname)' `
        -ReportarResultadoTaskGroupId $idReportar),
    # ...UAT igual con VariableGroupId 410...
    (New-AdoReleaseEnvironmentEntry -Stage 'Produccion' -VariableGroupId 411 -ArtifactFilterBranch 'release' `
        -DeployTaskGroupName 'Deployment-Azur-Aks-v3' -DeployTaskGroupId $idDeployProd `
        -AksClusterName '$(aksClusterName)' -AksResourceGroup '$(aksResourceGroup)' -Ambiente '$(ambiente)' `
        -Namespace '$(namespace)' -Pipeline '$(pipeline)' -ApprovalRequired $true -ReportarResultadoTaskGroupId $idReportar)
)
$releaseBody = New-AdoReleaseDefinitionPayload -Plan $plan -Environments $environments -BuildDefinitionId $buildId -BuildDefinitionName $buildName
```

**Nota de diseño:** devuelve un `Hashtable` plano (`@{...}`, no
`[ordered]@{...}`) a propósito — `New-AdoReleaseDefinitionPayload` valida
cada environment con `.ContainsKey()`, método que `[OrderedDictionary]`
no implementa (solo `.Contains()`). Bug real encontrado al integrar
ambas funciones por primera vez 2026-08-25, antes de que llegara a
usarse contra datos reales — corregido antes de aplicar nada.

Validado reconstruyendo los 2 ambientes reales de Administracion-de-proyectos
(Desarrollo + Producción) con esta función y confirmando que el payload
resultante de `New-AdoReleaseDefinitionPayload` reproduce exactamente el
Release 381 real (Reportar-resultado-HU + `enableAccessToken=true` en
Desarrollo, `isAutomated=false` en Producción). 6 tests nuevos en el
grupo "W" de `run-script-tests.ps1` — 269/269 en el total de la suite.
No reemplaza ni modifica `New-AdoClassicAksPlan.ps1` ni
`New-AdoReleaseDefinitionPayload` — se agrega al lado, ambas funciones
existentes siguen exactamente igual.

**Dry-run 2026-08-25, más tarde el mismo día:** además de esta validación
del lado Release, se corrió una comparación equivalente del lado Build
(`New-AdoBuildDefinitionPayload` vs GET fresco del Build 622 real, mismos
ids/valores). Único bug real encontrado: `alwaysRun` del step
Reportar-resultado-HU (ver corrección arriba, sección de agrupación de
merges). El resto de diffs fueron falsos positivos (orden de claves JSON
en `variables`/`process.phases`; campos `queue.name`/`queue.pool.isHosted`
que Azure DevOps solo agrega como enriquecimiento en el GET). Con esto,
tanto el generador de Build como el de Release quedaron validados
campo-por-campo contra datos reales — 270/270 tests.

## Convención org-wide: plantilla de manifiestos K8s para File Creator (dev/uat/prod)

Instrucción del usuario, 2026-08-25: los 3 archivos que deja el usuario en
`references/deployment-dev.yml`, `references/deployment-uat.yml`,
`references/deployment-prod.yml` son la **plantilla para todos los
pipelines que se creen de aquí en adelante**, no solo para
Administracion-de-proyectos. **Estos 3 archivos nunca se editan** — son
la base fija; lo que varía se resuelve al generar el `filecontent` real de
cada step "File Creator deployment-{env}.yml" de un Build concreto.

### Qué varía por aplicativo (evaluar siempre, nunca asumir)

1. **Secret + ConfigMap** — nombre y claves de datos según lo que la app
   realmente necesite (nunca dejar `xxx: xxxx` / `xxxx` literal del
   template). **Automatizado 2026-08-25** mediante la biblioteca
   `ConvertTo-AdoEnvClassification.ps1`, invocada exclusivamente por el
   entrypoint versionado `Convert-AdoEnvFileClassification.ps1` (sin red):
   dado el contenido de un `.env`/`.env.example` real del
   repo (leído vía `mcp__azure-devops__repo_file`), clasifica cada
   variable en 5 categorías —
   - `buildTimeVars` (prefijos conocidos `VITE_`/`REACT_APP_`/
     `NEXT_PUBLIC_`/`VUE_APP_`/`NG_APP_`/`GATSBY_`/`NUXT_PUBLIC_`/
     `PUBLIC_`, o dentro de una sección marcada "build-time"/"tiempo de
     build" por comentario) → van a `buildVariables.dockerBuildArgs` del
     plan, NUNCA a ConfigMap/Secret.
   - `pipelineVars` (prefijo `DOCKER_`) → config del propio pipeline CI
     (registry/tag), se excluyen de ConfigMap/Secret por completo.
   - `secretVars` (nombre matchea patrón sensible — password/secret/
     token/credential/connectionstring/apikey/`*_PAT`/`*_PASS`/
     certificate/etc., O el valor tiene forma de token real aunque el
     nombre no lo sugiera) → van al Secret del manifiesto.
   - `configMapVars` (el resto) → van al ConfigMap.
   - `ambiguousVars` — casos que la función no resuelve sola (valor
     sospechoso con nombre no-secreto) y que hay que confirmar antes de
     dar el manifiesto por completo.

   **Valores reales — `-PopulateRealValues` (autorizado 2026-08-25).**
   Por defecto (sin este switch) la función es cautelosa: `secretVars`
   nunca trae `value`, y `configMapVars` solo trae el `value` real si la
   fuente es un `.env.example`/`.sample`/`.template` confirmado
   (`-IsExampleFile $true`); con un `.env` REAL sin variante `.example`,
   todo queda `value=""` y se marca en `ambiguousVars`. **El usuario
   confirmó explícitamente que este proyecto ya usa valores reales de
   `.env` en TODOS sus pipelines clásicos existentes** (mismo criterio
   que un pipeline YAML con el manifiesto en el repo — el valor real vive
   igual en el File Creator del Build), con el proyecto `DevOps` de
   Azure DevOps restringido a ~3 personas de jefatura — no es una
   práctica nueva que este skill esté introduciendo. Con
   `-PopulateRealValues`: `configMapVars` **y** `secretVars` llevan el
   `value` real del `.env` que se les pasó, sin importar `-IsExampleFile`.
   Es un switch explícito, nunca un default silencioso — hay que pedirlo
   a propósito para cada `.env` que se procese así.

   **Higiene al reportar, aunque los valores SÍ se escriban en el
   manifiesto:** el manifiesto YAML final lleva los valores reales tal
   cual se pidió, pero al resumir en el chat lo que se hizo, no repetir
   los valores de `secretVars` en texto — referirlos por nombre de
   variable ("se completaron N secretos: DB_PASS, PASSWORD_BLUE"), no
   por su contenido. Esto es higiene de la conversación, no una
   restricción del manifiesto en sí.

   Validado reproduciendo exactamente la clasificación manual ya hecha
   para Administracion-de-proyectos (mismo `.env.example`, mismo
   resultado: 5 `VITE_*` build-time, `ADO_PAT` secret, `ENVIRONMENT`/
   `LOG_LEVEL` configMap, `DOCKER_REGISTRY`/`DOCKER_TAG` pipeline, cero
   ambiguos). 16 tests en el grupo "V" de `run-script-tests.ps1`
   (263/263 en el total de la suite).

   **Gap real encontrado y corregido 2026-08-25** probando la función
   contra la estructura de claves de un `.env` real de otro repo
   (`survey-metropolitano`, con valores ficticios en la prueba, nunca los
   reales): `DB_PASS` **no** quedaba clasificada como secreto —
   `AdoEnvSecretNamePattern` cubría `password`/`passwd`/`pwd` completos
   pero no la abreviatura suelta `PASS`. Corregido agregando
   `(^|_)pass($|_)` (con límite de palabra, para no disparar con
   `COMPASS_DIRECTION` o similares). Ojo con esto al confiar en la
   clasificación: la heurística de nombre nunca es 100% exhaustiva —
   revisar igual `ambiguousVars` y, ante la duda, tratar una variable
   como secreta aunque el nombre no matchee ningún patrón conocido.

   **Práctica estándar acordada 2026-08-25:** con `-PopulateRealValues`
   ambos objetos (Secret y ConfigMap) terminan con el valor real puesto
   igual — el riesgo real no es que un valor se pierda, es que una
   variable sensible quede en el objeto de Kubernetes equivocado
   (ConfigMap en vez de Secret suele tener control de acceso más laxo en
   el cluster). Como ninguna heurística de nombre puede ser 100%
   exhaustiva, antes de aplicar el manifiesto siempre se muestra al
   usuario una **tabla resumen corta** (nombre de variable → categoría
   asignada: build-time/pipeline/Secret/ConfigMap), nunca el YAML
   completo a leer — un vistazo de 10 segundos, no una auditoría. Si algo
   se ve mal clasificado, el usuario lo señala ahí antes de aplicar.
2. **Puerto** — `containerPort`, `Service.targetPort`, y el puerto que use
   el `EXPOSE`/`nginx.conf`/`listen` real de la app. Confirmarlo leyendo
   el `Dockerfile` (y `nginx.conf` si aplica) del repo real vía
   `mcp__azure-devops__repo_file`, nunca asumir el `3000` del template.
3. **Sondas** (`startupProbe`/`readinessProbe`/`livenessProbe`) — el
   `path` depende de si la app expone un endpoint de salud real (ej.
   `/api/v1/health`, como asume el template) o no. Una SPA servida por
   nginx sin backend propio normalmente NO tiene ese endpoint — usar
   `path: /` en ese caso (confirmado con `nginx.conf` real: sin location
   `/health`, con `try_files ... /index.html`).
4. **Ingress** — host (`tls.hosts`/`rules.host`) y `tls.secretName`,
   ambos por ambiente. Si el usuario no da el `secretName` explícito,
   **preguntar** (no asumir `gmontecristo-secret` solo porque es el más
   común) — confirmado con el usuario: "casi siempre se usan esos pero
   mejor me preguntas".
5. **Volúmenes** (`volumeMounts`/`volumes` para `logs`/`tmp`) — validar si
   la app realmente escribe a esas rutas (ej. logs a archivo). Una app que
   loguea a stdout/stderr (confirmado sin directivas de log a archivo en
   su `nginx.conf`/código) no los necesita — quitar el bloque completo
   (`volumeMounts` del container y `volumes` del pod) en vez de dejarlo
   sin uso.
6. **`ServiceAccount`/`Role`/`RoleBinding`** — validar si la app necesita
   permisos de K8s API en tiempo de ejecución (ej. leer `ConfigMaps`/
   `Secrets`/`Ingresses` desde dentro del pod). Una SPA estática servida
   por nginx no los necesita — quitar los 3 `kind:` completos y
   `serviceAccountName:` del pod spec.

### Qué se mantiene fijo salvo indicación explícita

Todo lo demás del template: estructura general de 6-7 documentos YAML
(Secret → ConfigMap → [ServiceAccount/Role/RoleBinding si aplica] →
Deployment → Service → HorizontalPodAutoscaler → Ingress), `replicas: 1`,
`revisionHistoryLimit: 3`, estrategia `RollingUpdate` (`maxUnavailable: 0`
/ `maxSurge: 1`), `podAntiAffinity` preferido por hostname,
`terminationGracePeriodSeconds: 60`, `lifecycle.preStop` con `sleep 20`,
todas las anotaciones `nginx.ingress.kubernetes.io/*` del Ingress, HPA
`minReplicas: 1`/`maxReplicas: 1` con targets CPU 70%/mem 75% y su bloque
`behavior` completo de scaleUp/scaleDown.

### Diferencias fijas entre dev/uat y prod (ya presentes en los 3 archivos, no inventadas)

| | dev/uat | prod |
|---|---|---|
| `imagePullSecrets` | `- name: acr-pull-secret` | ausente |
| `ingressClassName` | `nginx` | `internal-ingress` |
| `nodeSelector` | ausente | `agentpool: userpool03` |

### Los tokens `#{...}#` NUNCA se resuelven — quedan literales

**Corregido 2026-08-25 (revisión 6 de Build 622).** Los archivos de
`references/` usan notación `#{token}#` (estilo "Replace Tokens" de Azure
DevOps) para `#{servicesname}#`, `#{namespace}#`, `#{containerregistries}#`,
`#{image}#`, `#{ambiente}#`, `#{tag}#`, `#{reqcpu}#`, `#{reqmem}#`,
`#{limcpu}#`, `#{limmem}#`. **Estos tokens deben quedar EXACTAMENTE como
están en el template, sin resolver, en el `filecontent` real que se sube
al step "File Creator deployment-{env}.yml"** — confirmado explícitamente
por el usuario: "las variables como estas #{servicesname}# y las demas,
no hay q reemplazarlas".

Un intento anterior (revisión 5) los había resuelto a valores literales
razonando que `Build-MultiStage` no tiene ningún step de reemplazo de
tokens visible en su lista de tareas — esa inferencia fue **incorrecta**
como guía de qué hacer: sea cual sea el mecanismo real que los resuelve
(otro momento del pipeline, un proceso externo, o simplemente una
convención de la org para dejarlos como referencia), el paso de este
skill NO es responsable de resolverlos y no debe tocarlos. Verificar con
un grep de `#{` sobre el contenido generado — **debe dar el mismo conteo
que el archivo de referencia original** (32 en los 3 archivos de
Administracion-de-proyectos), no 0.

**Qué SÍ se reemplaza por un valor literal real** (no son tokens `#{}#`,
son valores de ejemplo hardcodeados en el template que si deben
sustituirse): el puerto (`3000`), el `path` de las 3 sondas
(`/api/v1/health`), el host de Ingress (`gateway-buklo-dev.gmontecristo.com`,
2 apariciones: `tls.hosts` y `rules.host`) y el `tls.secretName`
(`gmontecristo-secret`) — ver los puntos 2/3/4 de la lista de arriba. La
línea que separa "token a preservar" de "placeholder a resolver" es
exactamente la sintaxis `#{...}#` vs. un valor de ejemplo suelto.

### Caso resuelto — Administracion-de-proyectos-web (Build 622, revisión 6)

Confirmado leyendo archivos reales del repo (`Administracion-de-proyectos`,
rama `master`, vía `mcp__azure-devops__repo_file`): `Dockerfile`/`nginx.conf`
→ SPA servida por nginx, `EXPOSE 80`, healthcheck contra `/` (sin endpoint
de salud propio); `.env.example` → confirma las claves reales runtime
`ADO_PAT` (Secret, sensible, "no implementada aún en el código" pero es el
contrato documentado), `ENVIRONMENT`/`LOG_LEVEL` (ConfigMap, con enum
`production|staging|development` y `error|warn|info|debug`);
`deploy-k8s.ps1`/`k8s-manifest.yml`/`docker-compose.k8s.yml` → sin
`ServiceAccount`/RBAC, sin volúmenes persistentes de logs (corrobora los
puntos 5/6).

Decisiones aplicadas (las 6 variables de la lista de arriba):

1. Secret/ConfigMap: `ADO_PAT` (Secret, valor vacío — nunca un secreto
   real), `ENVIRONMENT`/`LOG_LEVEL` (ConfigMap) — claves reales
   confirmadas en `/.env.example`, no inventadas. Valores por ambiente:
   dev=`development`/`debug`, uat=`staging`/`info`, prod=`production`/`info`
   (siguiendo el enum documentado en el mismo `.env.example`).
2. Puerto: `80` (no `3000` del template) en `containerPort`,
   `Service.targetPort` y las 3 sondas (`port: http` sigue apuntando al
   `name: http` del container port).
3. Sondas: `path: /` en las 3 (no `/api/v1/health`).
4. Ingress: `administracion-proyectos-dev.gmontecristo.com` (dev),
   `administracion-proyectos-uat.gmontecristo.com` (uat),
   `administracion-proyectos-grupomontecristo.com` (prod — dominio propio,
   no subdominio de `gmontecristo.com`, tomado literal según lo dado por
   el usuario). `secretName`: `gmontecristo-secret` (dev/uat, confirmado
   por el usuario), `grupomontecristo-cert-secret` (prod, confirmado por
   el usuario).
5. Volúmenes: quitados por completo (`volumeMounts`/`volumes` de
   `logs`/`tmp`) — la app no escribe logs a archivo.
6. RBAC: quitados por completo (`ServiceAccount`/`Role`/`RoleBinding` +
   `serviceAccountName:` del pod spec) — SPA estática, sin necesidad de
   leer la API de K8s en runtime.

Todos los `#{token}#` genéricos (`servicesname`/`namespace`/
`containerregistries`/`image`/`ambiente`/`tag`/`reqcpu`/`reqmem`/
`limcpu`/`limmem`) quedaron literales, sin resolver — 32 ocurrencias en
cada uno de los 3 archivos, igual que en el template original.

Generador usado (script de scratch, no versionado):
`Generate-Fixed-Manifests.ps1` — parte del texto EXACTO de cada archivo
de `references/deployment-{dev,uat,prod}.yml` (normalizando CRLF→LF antes
de comparar, porque un `.Replace()` literal falla en silencio si los
finales de línea no coinciden byte a byte) y aplica únicamente
reemplazos quirúrgicos de texto: quitar los 3 bloques `kind:`
ServiceAccount/Role/RoleBinding + la línea `serviceAccountName:`, quitar
`volumeMounts`/`volumes` de logs/tmp, `containerPort`/`targetPort`
3000→80, `path: /api/v1/health`→`path: /`, host+`secretName` del Ingress,
y las claves de `data:` del Secret/ConfigMap — nunca toca ningún
`#{token}#`. Verificado post-generación: el conteo de `#{` se mantiene en
32 (no 0) en los 3 archivos antes de aplicar el PUT.

**Este mismo procedimiento (leer Dockerfile/.env.example/nginx.conf reales
→ decidir las 6 variables → editar quirúrgicamente el template
preservando TODOS los `#{token}#` → verificar que el conteo de `#{` no
cambió → PUT) se repite para cada pipeline nuevo que se cree de aquí en
adelante, independientemente de la app.**

## Dos bugs reales corregidos en `Test-AdoClassicPlan.ps1` (2026-08-25)

Encontrados validando el plan de corrección de la revisión 6 de arriba —
ambos afectan a CUALQUIER plan `update-*` futuro de este dominio, no solo
a este caso puntual.

1. **Los chequeos de "posible duplicado" de nombre no distinguían
   `update-*` de `create-*`.** Un plan que solo trae operaciones
   `update-build-definition`/`update-release-definition` (sin ningún
   `create-*`) por definición apunta a un recurso que YA EXISTE con ese
   nombre exacto — es el recurso que se está actualizando. El validador
   los trataba igual que un plan de creación y los bloqueaba como
   "posible duplicado". Corregido: se agregó `$isUpdateOnlyPlan`
   (`approvedOperations.Count -gt 0` y ninguna entrada con
   `operationType -like 'create-*'`) que, cuando es `$true`, cambia los 3
   bloqueantes de nombre-duplicado (Build/Release/Variable Group) por una
   sola advertencia informativa. El chequeo de existencia de la Library
   compartida (DACPAC) sigue corriendo igual, independiente de este flag
   — sigue siendo válido confirmar que existe.
2. **El escaneo de "placeholders sin resolver" podía autoenvenenarse.**
   El patrón `(?i)(change_me|\bxxx+\b|\btbd\b|\btodo\b|<[a-z_]+>)` se
   corría sobre el JSON crudo COMPLETO del plan, incluyendo
   `validationBlockers`/`validationWarnings` — campos que el propio
   script escribe al final de cada corrida. Si una corrida anterior
   disparó ESTE MISMO bloqueante, su mensaje (que contiene literalmente
   "CHANGE_ME/xxx/TBD/TODO/<...>") quedaba grabado en el plan y volvía a
   disparar el mismo bloqueante en cada corrida siguiente, para siempre,
   sin relación con el contenido real del plan. Corregido: el escaneo de
   placeholders ahora usa una copia del plan sin esos dos campos
   (`validationBlockers`/`validationWarnings` removidos antes de
   serializar y escanear). `notes` SÍ sigue escaneado — una nota de
   negocio real puede legítimamente decir "todo" en español y disparar
   `\btodo\b`; si eso pasa, hay que reformular la nota (ej. "el resto de"
   en vez de "todo lo demás"), no ampliar la exclusión a `notes`.

Ambos fixes están cubiertos por la suite existente
(`scripts/tests/run-script-tests.ps1`, 221/221 verde después del cambio)
y no alteran el comportamiento para planes `create-*` puros.

## 3 gaps reales del generador corregidos (2026-08-26)

Reconstruir `administracion-proyectos-web` con los subagentes expuso 3
gaps reales en `New-AdoClassicAksPlan.ps1` que obligaban a parchear el
JSON a mano después de generar, cada vez (detalle histórico completo en
la memoria del agente
`ado-classic-aks-plan-multi-env-generator-gaps.md`). Corregidos
directamente en el generador, todos como parámetros opcionales
**aditivos** — ninguna invocación existente que no pase los parámetros
nuevos cambia de resultado (325/325 tests verdes, 15 nuevos en el grupo
`C2`):

- **`-Stage`** (`Desarrollo`/`UAT`/`Produccion`, default `Produccion`)
  reemplaza el hardcode de "Produccion" — decide `variableGroup.name`,
  `keys.ambiente`, `release.stage`, y el default real de
  `release.stageAutoDeploy` (Desarrollo=`true`, UAT/Produccion=`false`).
- **`-CiBranchFilters`** (default `development,uat,release`) y
  **`-DisableCi`** (switch invertido, mismo motivo que
  `-DisableMergeBatching`) pueblan `repo.ciEnabled`/
  `ciBatchChangesEnabled`/`ciBranchFilters` desde el principio —
  `New-AdoBuildDefinitionPayload` los exige siempre, así que antes de
  esto SIEMPRE hacía falta agregarlos a mano.
- **`AksClusterName`/`AksResourceGroup`/`ConexKubernetes`** dejaron de
  ser `Mandatory`: los primeros 2 solo se exigen y solo aparecen en
  `variableGroup.keys` cuando `-DeployTaskGroupName` es
  `'Deployment-Azur-Aks-v3'` (el default); pasarlos con otro deploy task
  group ahora tira un error explícito en vez de dejar una clave que
  después había que borrar a mano.
- **`-PreDeploymentApprovalRequired`/`-PreDeploymentApprovalGroup`**:
  `release.preDeploymentApprovalRequired`/`Group` ahora siempre existen
  (antes exigían `Add-Member -Force`), pero nunca se asumen `true` solo
  por `-Stage Produccion` — la gobernanza de aprobación sigue exigiendo
  confirmación explícita del usuario cada vez (ver `authorization.md`).
- **`-ExtraVariableGroupKeys`** (formato `'clave=valor;clave=valor'`,
  ej. `'loglevel=info'`) agrega claves no estándar sin `Add-Member`.
- **`-BuildName`/`-ReleaseName`** son ahora la única fuente de
  `names.build`/`names.release` y arrastran automáticamente
  `variableGroup.keys.pipeline`/`release.artifactAlias` — sobreescribir
  el nombre del Build ya no puede desincronizar esos 2 campos (el bug de
  casing original).

**2 trampas reales de PowerShell encontradas escribiendo las pruebas de
este fix** (generales, no específicas de este script — aplican a
cualquier parámetro futuro de un script pensado para invocarse vía
`powershell -File`):

1. Pasar un **string vacío explícito** (`-Param ''`) a través de `&
   powershell -File` se pierde en el armado de la línea de comandos del
   proceso hijo — todos los parámetros siguientes se corren un lugar y el
   error resultante señala un parámetro que en realidad sí se pasó, no el
   que faltó. Para un default vacío, **omitir el parámetro**, nunca
   pasarle `''` explícito entre procesos.
2. Un string con **comillas dobles incrustadas** (ej. un blob JSON
   `'{"clave":"valor"}'`) puede perder esas comillas en el mismo cruce de
   proceso, corrompiendo el payload en silencio. Por eso
   `-ExtraVariableGroupKeys` usa un formato plano sin comillas
   (`clave=valor;clave=valor`) en vez de JSON o un literal de hashtable
   de PowerShell (que tampoco sobrevive el cruce de proceso).
