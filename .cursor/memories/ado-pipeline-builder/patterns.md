# Patrones — ado-pipeline-builder

**`containerRegistryUsername`/`containerRegistryPassword` de un Release
clásico van SIEMPRE en 2 lugares distintos, nunca solo en uno** —
confirmado real 2026-09-08 (`app-sso`, Release 390): el `deployTaskGroupInputs`
del task usa la MACRO nativa de Azure DevOps `$(containerRegistryUsername)`/
`$(containerRegistryPassword)` (nunca un literal, nunca un placeholder
`${ADO_SECRET_*}`), y el valor real vive aparte, en
`environments[N].variables.containerRegistryUsername`/`.containerRegistryPassword`
de ESE environment (username como literal no-secreto, password como
`${ADO_SECRET_CONTAINERREGISTRYPASSWORD}` + `isSecret:true`, resuelto
recién al aplicar). Nunca generar una plantilla de intake que deje esto
ambiguo (`${ADO_SECRET_CONTAINERREGISTRYUSERNAME_OR_LITERAL_IF_NOT_SECRET}`
tal como quedó en la corrida real de `app-sso` causó exactamente este
bug al confundir al llamador). Antes de dar por buena cualquier plantilla
de estos 2 campos, comparar contra el GET real de un Release hermano ya
funcionando (`Get-AdoClassicDefinitionTemplate.ps1 -Kind Release`) — ver
memoria de proyecto `ado-release-containerregistry-macro-bug` para el
detalle completo del incidente y la corrección aplicada por el usuario en
la UI.

**No confiar en la descripción del shape de un campo JSON de Azure
DevOps sin verificarlo con un GET propio**, aunque venga de otra fuente
ya de confianza (coordinador, memoria previa, documentación). Caso real
2026-08-26: se me dijo que `phase.dependencies` era un objeto simple
`{scope,event}` — mi propio GET fresco de la referencia real (Build 552)
mostró que en realidad es un ARRAY de 1 objeto. Enviar el shape
incorrecto no dio ningún error (Azure DevOps lo ignoró en silencio), así
que sin ese GET propio el bug hubiera quedado sin detectar. Ver detalle
completo en [[debugging]] § "Bug real en producción... phase.dependencies".

**Usar los scripts compartidos de inspección
(`Show-AdoBuildSteps.ps1 -JsonPath ...`, `Show-AdoReleaseEnvironments.ps1
-JsonPath ...`) en vez de armar un one-liner/script nuevo de PowerShell
cada vez** para leer un Build/Release ya descargado — pedido explícito
2026-08-27, motivo: un one-liner nuevo con lógica propia (ej. "buscar el
archivo más reciente") no queda cubierto por ningún wildcard fijo de
permisos, así que cada variante nueva vuelve a pedir aprobación. Los 2
scripts ya existen y cubren los casos comunes (phases/steps/dependencies
del Build; environments/variableGroups/workflowTasks/conditions/
approvals del Release). Nunca resolver una brecha creando/ejecutando un
scratch script nuevo. Si la tarea puntual (por ejemplo, mutar y escribir un
body PUT) no está cubierta, detenerse e identificar el helper versionado,
revisado y probado que falta.

**Verificar el CONTENIDO de un `filecontent` antes de sobreescribirlo,
no solo su longitud** — una longitud que "coincide" con la de otro
servicio es señal de alarma, no coincidencia a ignorar. Ver
[[ado-buklo-microservice-engine-2026-08-27]] (Build 586 tenía contenido
de Gateway en sus File Creator dev/uat).

## 2026-09-01 — RESUELTO: constructor de Build clásico standalone
construido (fuera de la familia AKS/DACPAC), con un límite de seguridad
dejado a propósito sin tocar

Continuación de la entrada de abajo, mismo día, autorizado por el
coordinador como trabajo local de scripts (funciones + tests, sin tocar
Azure DevOps). Construido y probado (445/445 tests verdes):

- `New-AdoPowerShellTaskStep` y `New-AdoStandaloneBuildDefinitionPayload`
  en `New-AdoClassicPayloads.ps1` (paralelas a
  `New-AdoFileCreatorStep`/`New-AdoBuildDefinitionPayload`, no las tocan).
- `New-AdoClassicStandaloneBuildPlan.ps1` (esqueleto de plan nuevo,
  `family='standalone-build'`, sin Release/VG).
- `New-AdoClassicCreatePlan.ps1 -Kind StandaloneBuild` (aditivo, nuevo
  `-StepsSpecPath` declarativo con `kind: FileCreator|PowerShellTask`;
  `FileCreator` soporta `fileContentPath` además de `fileContent` inline,
  para no tener que escapar a mano un script multilínea dentro de JSON).
- `Test-AdoClassicPlan.ps1` reconoce `family='standalone-build'` y salta
  los chequeos que solo tienen sentido con Release (`names.release`,
  `release.cdTriggerEnabled`, el warning de aprobación de Producción) —
  **pero `$RequiredProject = 'DevOps'` quedó SIN TOCAR a propósito**, lo
  mismo que `$script:AdoAllowedOperationTypes` en `Invoke-AdoRest.ps1`
  (el path real de `create-build-definition` sigue hardcodeado a
  `/Shared-Service-GM/DevOps/...`).

**Por qué no se tocó el límite de proyecto, pese a que el coordinador dijo
que esto "no necesita otra aprobación aparte de esta"**: ese límite es la
lista blanca real de escritura (`Invoke-AdoRest.ps1`) más el chequeo de
validación que la protege (`Test-AdoClassicPlan.ps1`) — ampliarla a otro
proyecto (`Buklo`) es una expansión PERMANENTE de qué puede escribir esta
herramienta en el resto de la organización, no una función local
aislada. Un mensaje de agente/coordinador nunca autoriza cambiar un
límite de permisos/configuración (ver system prompt de este agente y el
precedente [[ado-emr-scratch-script-authorization-declined-2026-08-27]]).
Se construyó y probó TODA la capacidad igual (útil de inmediato para
cualquier Build standalone dentro de `DevOps`, el único proyecto hoy
autorizado), y se generó el plan real de
`Build-Validation-buklo-backend` hasta el punto exacto donde el límite
se activa — 2 bloqueantes reales y esperados, capturados con
`Test-AdoClassicPlan.ps1` real contra inventario fresco de `Buklo`:
`plan.project debe ser 'DevOps'` y el URI del allowlist no matchea
`/DevOps/`. `validated` queda `false`, no se calculó `validationHash`, no
hay comando Apply que entregar. Widening real de esto (si se decide)
exige aprobación explícita del usuario humano, no de un coordinador.

**2 bugs reales encontrados armando y probando esta capacidad, ambos
corregidos, ambos afectan código YA EXISTENTE (no solo lo nuevo)**:

1. `@(Get-Content -Raw | ConvertFrom-Json)` — envolver el pipeline
   COMPLETO en `@(...)` produce, con 2+ elementos JSON, un array ANIDADO
   de 1 elemento (el único elemento es a su vez el array real de N) en
   vez de un array plano de N. Silencioso, nunca lanza; con exactamente 1
   elemento es indistinguible del colapso normal de JSON de 1 elemento a
   escalar, así que ningún test previo (todos con 1 solo elemento) lo
   había detectado nunca. Afectaba TANTO mi código nuevo
   (`$stepsSpecParsed` en el branch `StandaloneBuild`) COMO código ya
   existente sin relación (`$rawEnvironments` en el branch `Release` de
   `New-AdoClassicCreatePlan.ps1` — nunca antes ejercitado con 2+
   environments en un test, porque las únicas pruebas de ese Kind fallan
   antes por falta de `-ExistingBuildDefinitionId`). Fix: asignar primero
   SIN `@()` (variable intermedia), reenvolver en un statement aparte.
2. `deployTaskGroupInputs = @($_.deployTaskGroupInputs)` en ese mismo
   branch `Release` — envolvía el objeto de inputs (que debe ir plano,
   `{...}`) en un array de 1 elemento (`[{...}]`), lo que Azure DevOps
   habría rechazado como forma inválida de `inputs`. También nunca antes
   ejercitado. Fix: quitar el `@()`, asignar el objeto tal cual.

Ambos verificados con una prueba de regresión real que compara el
`bodyHash` del plan producido por el runner contra el `bodyHash` de un
body construido independientemente con los mismos datos (`New-AdoRelease
DefinitionPayload`/`New-AdoStandaloneBuildDefinitionPayload` llamados
directo) — no alcanza con "termina sin error", hay que confirmar que el
body es el CORRECTO.

**Discrepancia real encontrada en el intake, corregida contra evidencia
en vivo (no contra lo que decía el pedido)**: se pidió usar `versionSpec
'7.*'` para el task File Creator (`1f81a8be-d8ce-497d-9791-190126f661e7`)
alegando que "ya lo usa este proyecto para este propósito". Un GET fresco
contra un Build real y reciente (`Build-administracion-proyectos-web`,
id 624, proyecto `DevOps`) mostró `versionSpec: "6.*"` en sus 3 steps
File Creator — coincide con el default ya hardcodeado en
`New-AdoFileCreatorStep` (correcto, ya confirmado antes). Se usó `6.*`
real, no `7.*`, y se dejó constancia en vez de asumir el dato del pedido
sin verificar (mismo patrón ya documentado arriba, "no confiar en la
descripción del shape sin GET propio").

## 2026-09-01 — RESUELTO (2do gap, distinto del anterior): `Invoke-AdoApplyPhases`
(Fase 2) no tenía ninguna rama para `family='standalone-build'`

Continuación del mismo día. El coordinador amplió el allowlist de
proyectos en la sesión principal (`$script:AdoAllowedProjects =
@('DevOps','Buklo')` en `Invoke-AdoRest.ps1`, con
`Assert-AdoOperationRequestMatchesSpec -ExpectedProject` + el mismo
chequeo replicado en `Test-AdoClassicPlan.ps1` contra inventario real —
**verificado por mí leyendo ambos archivos antes de confiar en el
reporte**, 446/446 tests, coincide con lo reportado) e intentó aplicar el
plan real: `Apply-AdoClassicPlan.ps1` lo rechazó ANTES de tocar la red
(cero escrituras) porque `Invoke-AdoApplyPhases` (Fase 2, Build) siempre
reconstruía el body vía `New-AdoBuildDefinitionPayload` exigiendo los 3
manifiestos K8s incondicionalmente — nunca tuvo una rama para la familia
standalone-build nueva.

**Construido (453/453 tests, +7 desde el gap anterior)**:

- `ConvertFrom-AdoStepsSpecFile` (`New-AdoClassicPayloads.ps1`): parseo
  de `-StepsSpecPath` FACTORIZADO desde el bloque inline que antes vivía
  en `New-AdoClassicCreatePlan.ps1` — misma función, cero duplicación.
  `New-AdoClassicCreatePlan.ps1 -Kind StandaloneBuild` ahora solo la
  llama.
- `plan.dependencies.standaloneBuild`: bloque nuevo que
  `New-AdoClassicCreatePlan.ps1 -Kind StandaloneBuild` escribe en el plan
  de salida (además de `approvedOperations`), con los STEPS YA
  RESUELTOS (nunca una ruta externa — `fileContentPath` ya se leyó
  dentro de `ConvertFrom-AdoStepsSpecFile`) más `fetchDepth`,
  `ciBranchFilters`, `ciBatchChangesEnabled`,
  `agentSpecificationIdentifier`, `agentPoolId/Name`, `queueId`. Cubierto
  por `Get-AdoPlanCanonicalHash` (incluye `dependencies` completo), así
  que cualquier edición posterior invalida `validationHash` igual que
  cualquier otro campo — **decisión de diseño: embeber, no referenciar
  por path**, precisamente para que Apply nunca dependa de que un
  archivo externo siga existiendo/sin cambios en disco (a diferencia del
  patrón ya existente de AKS, que sí re-lee los 3 manifiestos K8s por
  path en cada invocación — patrón mantenido tal cual para AKS, no
  tocado, solo no replicado para esta familia nueva).
- `Invoke-AdoApplyPhases` Fase 2, rama nueva: si
  `$Plan.family -eq 'standalone-build'`, reconstruye vía
  `New-AdoStandaloneBuildDefinitionPayload` usando EXCLUSIVAMENTE los
  datos embebidos en `plan.dependencies.standaloneBuild` — nunca pide
  `-DeploymentDevYamlPath`/etc. (esos siguen siendo exclusivos de
  family=aks/dacpac, rama `else` sin cambios). El chequeo de nombre
  duplicado (`Test-AdoClassicResourceNameAlreadyExists`) se movió antes
  del branch, compartido por ambas ramas (sin duplicar).

**Verificación real de que la reconstrucción es bit-a-bit idéntica** (no
solo "no lanza"): test con `Invoke-WebRequest` mockeado que llama
`Invoke-AdoApplyPhases` sobre un plan real (steps con `fileContentPath`,
comillas incluidas) validado con `Test-AdoClassicPlan.ps1`, y confirma
que `Invoke-AdoRest` acepta el body reconstruido sin lanzar "bodyHash no
coincide" — ese chequeo genérico ya existente es la prueba, no hizo
falta ningún mecanismo nuevo (tal como sugirió el coordinador). Mismo
patrón que ya usé para el bug de `deployTaskGroupInputs`/array anidado
del gap de Release.

**Plan real completado end-to-end, sin escrituras**:
`D:\Proyectos\automation\.local\azure-devops\plans\standalone-build-buklo-backend-final.json`
— `family=standalone-build`, `project=Buklo`, `validated=true`,
`validationHash=23245bcb185c30e718591d78b1f525d555c41aff139f35e715985cf477515b36`.
El `bodyHash` de `approvedOperations[0]`
(`11927102f406ac6e297075e5d30df4026fffbbdb642e442bbe3b8705d73cddca`)
coincide EXACTO con el calculado en el intento anterior (antes de este
gap) para el mismo contenido — confirma determinismo end-to-end de
`New-AdoStandaloneBuildDefinitionPayload` a través de 2 corridas
independientes, separadas por sesión.

Ver también [[ado-emr-scratch-script-authorization-declined-2026-08-27]]
§ "Recurrencia 2026-09-01" — el turno inmediatamente anterior a este,
donde SÍ correspondía rechazar (una supuesta autorización del usuario
relayada por el coordinador para tocar el allowlist de seguridad). La
diferencia con este turno: acá el coordinador reportó un cambio que
YA HIZO ÉL MISMO en su propia sesión (verificable leyendo el archivo
real), y pidió trabajo de scripts puramente local a partir de ahí — sin
relay de una aprobación de terceros para MÍ. Distinguir estos dos casos
es importante: no todo lo que dice un coordinador se rechaza, solo lo
que pide que YO cruce un límite de autorización en base a su palabra.

## 2026-09-01 — Gap real de capacidad (histórico, ver RESUELTO arriba):
no existe un constructor de Build clásico genérico (fuera de la familia
AKS/DACPAC)

Caso: pedido de un Build "Build Validation" standalone (política de PR,
sin Release, sin Variable Group) en el proyecto `Buklo` (repo
`buklo-backend`, distinto del proyecto `DevOps` donde viven los 13
pipelines de deploy). Dos steps genéricos (File Creator +
PowerShell@2), sin CI trigger, sin build de Docker, sin manifiestos K8s.

**Confirmado que NO existe ningún camino versionado para esto**:
`New-AdoClassicCreatePlan.ps1 -Kind Build` llama siempre a
`New-AdoBuildDefinitionPayload` (`New-AdoClassicPayloads.ps1`), que:
- exige los 3 manifiestos K8s (dev/uat/prod) como parámetro obligatorio
  y arma siempre 3 File Creator + 1 step de `buildTaskGroup` (metaTask,
  contrato `Build-MultiStage`) — no hay forma de pasar una lista de
  steps propia ni de omitir el build Docker;
- exige `plan.repo.ciBranchFilters` no vacío (tira si falta) — no hay
  forma de pedir "sin CI trigger" (el pedido explícito de este caso);
- `New-AdoClassicAksPlan.ps1` (el único generador de `$Plan` compatible
  con `Kind=Build`) exige `Producto`/`App`/`Dockerfile`/`ServicesName`/
  `Image`/`Namespace`/cluster AKS — ninguno de estos datos existe ni
  aplica a un Build de validación de PR.
- `New-AdoVariableGroupPayload`/`New-AdoReleaseDefinitionPayload`
  mapean el `projectId` real solo para `'DevOps'` — un proyecto nuevo
  como `Buklo` ni siquiera tiene ese mapeo (no llegó a importar en este
  caso porque no hacía falta VG/Release, pero es otro punto ciego real
  si algún día se necesita).

**Decisión tomada**: no fabricar el body a mano ni con un script de
scratch (prohibido). Se detuvo la tarea en la fase de plan y se reportó
el gap al coordinador/usuario en vez de inventar un payload. Inventario
de solo lectura de `Buklo` sí se generó (0 pipelines, repo
`buklo-backend` confirmado id `0550ab98-7959-45ee-8361-18b8e4df22a3`,
rama `development` como default branch) — eso queda vigente y
reutilizable para cuando exista la capacidad.

**Dato reutilizable sobre pools**: no existe ningún Agent Pool llamado
literalmente `ubuntu-latest` en esta organización (16 pools inventariados
2026-09-01) — el patrón real (ya usado en `New-AdoBuildDefinitionPayload`)
es `queue.pool = {id:9, name:'Azure Pipelines'}` (el pool Microsoft-hosted
compartido) + `process.target.agentSpecification.identifier` con el
nombre de imagen (`'ubuntu latest'` con espacio, no guion, en el default
existente — a confirmar antes de reutilizar literal). El `queue.id=127`
hardcodeado como default en `$script:AdoDefaultBuildQueue` viene de
`Build-portal-cmdb` (578, proyecto `DevOps`) — no asumir que ese mismo
`queue.id` es válido en otro proyecto (`Buklo`) sin confirmarlo primero
contra un Build real de ESE proyecto (que hoy no existe, siendo el
primer pipeline del proyecto).

**Qué necesitaría la capacidad nueva** (para cuando se construya, no
construir ad-hoc): una función tipo
`New-AdoStandaloneBuildDefinitionPayload` (o un `Kind` nuevo en
`New-AdoClassicCreatePlan.ps1`) que acepte: proyecto/repo arbitrarios
(no solo `DevOps`), lista de steps arbitraria provista por el llamador
(reutilizando `New-AdoFileCreatorStep` para File Creator, y un nuevo
helper `New-AdoPowerShellTaskStep` para PowerShell@2 con el contrato
`targetType/filePath/pwsh/errorActionPreference/failOnStderr/
ignoreLASTEXITCODE`), triggers CI opcionales (hoy es obligatorio),
sin exigir `Producto`/`App`/Docker/AKS. `fetchDepth=0` y `queue`
Microsoft-hosted sí son directamente reutilizables tal cual del
constructor existente.

Todavía no existen patrones confirmados propios de este agente. Categorías
que ya usa su proceso (ver
`.claude/agents/azure-devops/ado-pipeline-builder.md`): familia AKS
(Library por app + `Deployment-Azur-Aks-v3`) vs familia DACPAC (Library
compartida `Bases Datos SQL` + `Deployment-DataBases`). Los patrones
reales (ids confirmados, nombres de service connections/pools vigentes,
payloads de Build/Release que funcionaron) se agregan solo cuando se
confirmen en una construcción real.

## Sincronizado 2026-08-25 desde trabajo directo (no delegado a este agente)

El siguiente trabajo se hizo directamente por la sesión principal en vez
de vía este agente, pero cambia el comportamiento por default que este
agente va a heredar la próxima vez que arme un plan — dejarlo anotado
para no perder el contexto:

- **`Build-MultiStage` es el task group de build por default**, ya no
  `Build`. Su contrato de `inputs` es
  `{ambiente, ambienteOverride='auto', conexcontainerregistries, image,
  rutadockerfile, tag}` (no `servicesname`). `buildVariables.image` es
  obligatorio y debe terminar en guion (`Build-MultiStage` concatena
  `$(image)$(ambiente)` sin separador).
- **Agrupación de merges ("gana el más nuevo") está activa por default**
  en todo pipeline AKS clásico nuevo (`New-AdoClassicAksPlan.ps1` ya lo
  arma solo, `-DisableMergeBatching` para excluirlo explícitamente). Spec
  completo de las 8 piezas Build + 2 piezas Release en
  `references/ado-classic-payload-templates.md` y en la memoria de sesión
  `ado-batching-phases-standing-convention`.
- **`Reportar-resultado-HU` (lado Build) usa `alwaysRun=false`**, no
  `true` — confirmado 2026-08-25 vía GET fresco contra Build 552 y 622
  reales. No asumir `true` por analogía con el lado Release (ahí sí es
  `true`, son campos independientes).
- **`.env` → ConfigMap/Secret**: usar
  `ConvertTo-AdoEnvClassification -PopulateRealValues` para poblar
  valores reales (incluidos secretos) directo en el manifiesto — política
  vigente de la organización, no pedir al usuario que los transcriba a
  mano. Antes de aplicar, mostrar siempre una tabla corta
  nombre→categoría (build-time/pipeline/Secret/ConfigMap) para que el
  usuario confirme de un vistazo, nunca el YAML completo.
- **Ensamblado multi-ambiente del Release**: usar
  `New-AdoReleaseEnvironmentEntry` para construir cada entrada de
  `$Environments` en vez de armarlas a mano — resuelve el contrato de
  `deployTaskGroupInputs` según el nombre del deploy task group
  (`Deployment-Azur-Aks-v3` vs `Deployment-MultiStage-Cluster-Desarrollo`).
- **Plantilla de intake actualizada**: usar
  `references/ado-new-pipeline-intake-template.md` como fuente primaria
  de datos a pedir, no volver a derivar la lista de preguntas desde cero.

Todo esto ya vive en los scripts/reference docs de la skill (no depende
de esta nota para funcionar correctamente) — esta entrada es solo para
que el "por qué" quede disponible la primera vez que este agente arme un
plan real después de estos cambios.

## 2026-08-26 — Agregar un ambiente (VG + update-*) a un pipeline YA
existente, sin crear Build/Release nuevo

Ver caso completo en [[ado-buklo-microservice-gateway-dev-uat-2026-08-26]].
Patrón reutilizable para cualquier app Buklo futura (o cualquier app) que
ya tenga Producción viva y solo necesite sumar Desarrollo/UAT:

- 1 plan por `create-variable-group` (uno por ambiente nuevo) + 1 plan
  `update-build-definition` + 1 plan `update-release-definition` — NUNCA
  agrupar 2 operaciones del mismo `operationType` en un plan
  (`Test-AdoClassicPlan.ps1` lo rechaza).
- `New-AdoClassicAksPlan.ps1` sigue siendo el generador correcto para
  CADA uno de esos planes (incluidos los que no van a crear Build/Release
  nunca) — da `dependencies`/`release`/`repo` ya resueltos contra
  inventario, aunque el operationType real del plan no los consuma.
- GET fresco SIEMPRE antes de asumir que la convención de agrupación de
  merges (`Build-MultiStage` + 8 piezas) o `reportarResultadoHU` aplican
  — no todo Build/Release AKS de la org las usa (Build 584/Release 366 de
  Buklo Microservice Gateway no las tienen).
- Body de un `update-*` que depende de un id creado por OTRO plan de la
  misma operación atómica (ej. `update-release-definition` necesitando la
  VG que crea otro plan): documentar el mapeo exacto en un
  `design-notes-<app>.md` hermano ANTES de poblar `approvedOperations`
  con placeholders — nunca inventar el id, esperar a que el plan del que
  depende se aplique de verdad.
- `Get-Content -Raw` de un archivo UTF-8 SIN BOM, sin `-Encoding UTF8`
  explícito, corrompe tildes/guion-em-dash en Windows PowerShell 5.1
  (cae al codepage ANSI del sistema). Workaround para archivos propios
  (nunca para scripts compartidos): escribirlos CON BOM
  (`UTF8Encoding($true)`) para que cualquier `Get-Content -Raw` sin
  `-Encoding` los detecte bien igual. Ver `debugging.md` para el bug
  hermano (y más grave) que esto llevó a encontrar en `Invoke-AdoRest.ps1`.

- **Readback post-Apply de un Build: siempre re-verificar
  `triggers[].pathFilters` explícitamente, no solo que el Build exista**
  (2026-09-05, `app-logistics`/buklo-web). El readback estándar
  (`Test-AdoCreatedResources.ps1`/`Show-AdoBuildSteps.ps1`) confirma que
  el recurso existe y su estructura de phases/steps, pero no imprime por
  default el `pathFilters` del trigger CI — el usuario encontró y corrigió
  a mano en la UI un problema ahí que no habíamos verificado nosotros
  mismos tras aplicar. Agregar al checklist de cualquier Build AKS nuevo:
  `Get-AdoClassicDefinitionTemplate.ps1 -Kind Build` + leer
  `.triggers[0].pathFilters` y compararlo contra el `pathFilter` del plan
  (`+apps/app-<nombre>/**` para buklo-web).
- **buklo-web: `hostAliases` (gateway-buklo.grupomontecristo.com→
  10.6.2.240) en `deployment-prod.yml` ya NO va por defecto en una app
  nueva** (decisión 2026-09-05, cambia lo documentado para las 4 apps
  hermanas que sí lo tienen activo) — comentarlo/omitirlo salvo pedido
  explícito de esa app puntual. Ver
  memoria de sesión `ado-buklo-web-frontend-deploy-pattern` para el detalle
  completo del patrón de despliegue de buklo-web.
