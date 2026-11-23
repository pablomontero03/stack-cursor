# Diagnóstico — ado-pipeline-builder

## 2026-09-02 — `bodyHash` de update-build/update-release no coincidía con el body en el primer Apply real (Build 585)

Ver detalle completo del caso en
[[ado-buklo-uat-dbname-batch-2026-09-02]]. Resumen técnico reutilizable:

**Síntoma**: `Apply-AdoClassicPlan.ps1` rechazado por `Invoke-AdoRest.ps1`
con "el bodyHash aprobado para '<op>' no coincide con el body solicitado"
— rechazo pre-flight ANTES de cualquier red, cero escritura, cero riesgo
de corrupción real (confirmado: el diseño de este chequeo solo puede
producir falso-rechazo, nunca falso-positivo).

**Causa raíz confirmada empíricamente** (no alcanzó con leer el código —
hubo que reproducir el hash exacto con 2 variantes de fix hasta encontrar
la que coincidía carácter por carácter con el valor independiente que
había calculado el coordinador): en
`Invoke-AdoClassicUpdatePlanGeneration` (`New-AdoClassicUpdatePayload.ps1`),
`bodyHash` se calculaba con `Get-AdoBodyCanonicalHash` sobre el objeto EN
MEMORIA (`$currentTarget`, nunca releído de disco), mientras que
`Apply-AdoClassicPlan.ps1` (vía `Invoke-AdoApplyPhases`) reconstruye el
body real releyendo el archivo YA ESCRITO con
`Get-Content -LiteralPath $UpdateBuildBodyPath -Raw | ConvertFrom-Json`.
Aunque el JSON final en disco era byte-idéntico al contenido correcto
(confirmado con diff y con inspección de bytes crudos del em-dash — no es
un bug de encoding ni de truncamiento `-Depth`, la profundidad real del
objeto es ~8-9, muy por debajo del límite de 20 usado por
`Get-AdoBodyCanonicalHash`), `ConvertTo-Json`/`ConvertFrom-Json` en
Windows PowerShell 5.1 NO es perfectamente idempotente para este grafo de
objeto entre "objeto construido por GET→clon-Depth60→mutación in-place" y
"objeto reconstruido desde texto JSON ya serializado" — produce un
`ConvertTo-Json -Depth 20 -Compress` distinto pese a representar el mismo
JSON semántico. El mecanismo interno exacto no se aisló (no era necesario
para la solución).

**Evidencia usada**: 2 intentos de fix comparados contra el valor
independiente ya calculado por el coordinador (`Get-Content` manual →
`ConvertTo-Json -Depth 20 -Compress` → SHA-256) — intento 1 (reparsear el
string en memoria sin tocar disco, `$bodyJsonText | ConvertFrom-Json`) NO
cambió el hash respecto al original (mismo bug, no reproducido); intento 2
(escribir a disco, después releer ESE MISMO ARCHIVO con `Get-Content`) SÍ
coincidió exacto con el valor del coordinador — probando la causa y la
solución en el mismo paso.

**Solución validada**: en `Invoke-AdoClassicUpdatePlanGeneration`,
serializar el body UNA vez, escribirlo a `$OutBodyPath`, y releer ESE
ARCHIVO desde disco (`Get-Content -LiteralPath $OutBodyPath -Raw |
ConvertFrom-Json`, mismo método sin `-Encoding` que usa
`Invoke-AdoApplyPhases`) para construir `approvedOperations` — nunca
hashear el objeto en memoria previo a la escritura. Corregido en el
archivo fuente compartido: protege automáticamente tanto `-Kind Build`
como `-Kind Release` de `New-AdoClassicUpdatePlan.ps1` (misma función).

**Comprobación segura**: regenerar 2 veces cada plan/body (mismos
parámetros, rutas de salida distintas) y diff — body y `bodyHash`
idénticos entre las 2 corridas, para los 10 builds del batch. Esta
comprobación de determinismo con la herramienta ya autorizada (correrla
2 veces y diffear) es la alternativa legítima cuando no existe un script
versionado dedicado para "recalcular `Get-AdoBodyCanonicalHash` de un
archivo local arbitrario" — nunca crear un script scratch nuevo ni
dot-sourcear `Invoke-AdoRest.ps1` directo para ese fin puntual.

**Alcance más amplio**: este patrón vulnerable (hashear el objeto en
memoria, escribir a disco, que Apply-time relea ese archivo desde cero)
es el mismo que usaron los 7 microservicios Buklo previos cada vez que
aplicaron un `update-build-definition`/`update-release-definition` real
desde que ese mecanismo se agregó (2026-08-25/27) — todos esos Apply
tuvieron éxito en su momento (no se manifestó ahí), pero en teoría
compartían el mismo riesgo latente. La familia `create-*` (Build/Release
nuevos vía manifiestos YAML) reconstruye el payload fresco desde archivo
de texto en cada llamada (generación Y apply), sin este paso intermedio
de serializar-body-completo-y-releer — no comparte esta asimetría
específica.

## 2026-09-02 (mismo día, 2do hallazgo) — TF20507: Azure DevOps rechazó el body por caracteres de control C1 inválidos

Ver detalle completo en [[ado-buklo-uat-dbname-batch-2026-09-02]] §
"Bug real #3". Resumen: con el bug del bodyHash (arriba) ya corregido, el
primer Apply real avanzó hasta el servidor y Azure DevOps lo rechazó con
`TF20507: The string argument contains a character that is not valid:
'u0090'` sobre `definition.Steps.filecontent` — el caracter apareció en
un banner box-drawing (`═`) de OTRO step del mismo Build, no en el step
tocado por el cambio. Confirmado con `xxd` que el archivo en disco tenía
los bytes UTF-8 correctos (`e2 95 90`) — la corrupción no estaba en el
archivo, estaba en CÓMO se releía: `Get-Content -LiteralPath ... -Raw`
sin `-Encoding UTF8` en Windows PowerShell 5.1 usa el codepage ANSI del
sistema por defecto; bytes de continuación UTF-8 como 0x90/0x9D no tienen
mapeo en cp1252 y se reinterpretan como los caracteres de control C1
U+0090/U+009D directamente — inválidos para el API de Azure DevOps.

Encontrados y corregidos 9 `Get-Content -LiteralPath` sin `-Encoding
UTF8` en `New-AdoClassicPayloads.ps1`/`New-AdoClassicUpdatePayload.ps1`
(incluidos los 2 críticos de apply-time real,
`$UpdateBuildBodyPath`/`$UpdateReleaseBodyPath`). Verificado en 3 capas
para los 10 builds del batch: escaneo de rango Unicode U+0080-U+009F
(`grep -aP`) + validación `iconv -f UTF-8 -t UTF-8`, determinismo
(2da corrida independiente, mismo `bodyHash`), y diff completo contra el
GET original. Los 3 bugs reales de esta misma sesión (bodyHash
desincronizado, este, y el de retipeo manual de mojibake) comparten la
misma familia: JSON/texto no-ASCII + PowerShell 5.1 + un paso de I/O sin
encoding explícito = corrupción silenciosa. Cualquier `Get-Content -Raw`
nuevo en esta skill debe llevar `-Encoding UTF8` explícito, siempre.

## 2026-08-26 — Primer `-Apply` real de una definición de Release: 3 causas raíz

Ver detalle completo en [[ado-release-create-update-real-bugs-2026-08-26]].
Resumen para lectura rápida:

- **Bug real en `Invoke-AdoApplyPhases` (Fase 3)**: `-ReleaseEnvironmentsPath`
  perdía silenciosamente `reportarResultadoTaskGroupId`/`stageVariables` al
  reconstruir `$environments` desde el JSON — el body armado en Apply
  quedaba distinto del body ya aprobado/hasheado, y `Invoke-AdoRest`
  rechazaba por "bodyHash no coincide" (correcto, pero por una causa que no
  era "el plan fue modificado"). **Ya corregido** en
  `New-AdoClassicPayloads.ps1` + 2 tests nuevos (272/272 verde).
- **Restricción real de la API de Azure DevOps**: no se puede crear una
  definición de Release con un stage `isAutomated=false` sin `approver`
  asignado en el mismo POST (`400 VS402896`). El patrón correcto (y ahora
  confirmado obligatorio, no solo prolijo) es crear con ese stage
  automático primero, y aplicar el gate real como un
  `update-release-definition` **separado**, con su propia aprobación.
- **Journal 'ambiguous' tras un 400 real**: reconciliar borrando el
  archivo de journal COMPLETO (nunca editar una clave dentro de uno
  existente — eso dispara un bloqueo de "journal corrupto" a propósito).
  Confirmar primero con `Test-AdoCreatedResources.ps1` que nada se creó.

También se agregó una mejora de diagnóstico permanente: `Invoke-AdoRest.ps1`
ahora incluye el body de RESPUESTA real de Azure DevOps (nunca la
solicitud) en el mensaje de error de una escritura fallida — sin esto, el
`400 VS402896` de arriba habría quedado como un genérico "(400) Solicitud
incorrecta" imposible de diagnosticar sin adivinar.

## 2026-08-26 — Bug crítico de encoding: `Invoke-AdoRest.ps1` corrompía en
silencio cualquier body no-ASCII (encontrado armando Buklo Microservice
Gateway, pipeline de Producción intacto, Desarrollo/UAT)

**Síntoma**: `update-build-definition` (Build 584, agregar dev/uat
manifests con comentarios en español, guiones em-dash) fallaba con
`400 "This request expects an object in the request body, but the
supplied data could not be deserialized"` — un error de deserialización
DURA, no una validación de campo específico.

**2 causas raíz distintas, ambas reales, había que encontrar y arreglar
las 2 para que funcionara**:

1. **Mi propio bug** (scripts de sesión, no del skill): `Get-Content
   -Raw` sin `-Encoding UTF8` sobre los 2 archivos `.yml` (UTF-8 SIN BOM)
   — Windows PowerShell 5.1 cae al codepage ANSI del sistema si no hay
   BOM, partiendo cada carácter multi-byte (tildes, guion em-dash) en
   bytes sueltos mal decodificados. Confirmado con
   `[System.Text.Encoding]::Default.WebName` → `Windows-1252`. Fix:
   `-Encoding UTF8` explícito al leer.
2. **Bug real y más profundo, en el propio `Invoke-AdoRest.ps1`
   (compartido, no solo mío)**: el header `Content-Type: application/json`
   se seteaba vía `-Headers` (no vía el parámetro dedicado `-ContentType`
   de `Invoke-WebRequest`), y el body se pasaba como `[string]` crudo.
   Confirmado con un `HttpListener` LOCAL en loopback (sin tocar Azure
   DevOps ni ningún script del skill): un string en memoria con
   codepoints correctos (`á`=U+00E1, `—`=U+2014, verificados con
   `[char]0xNNNN` explícito para descartar que el propio archivo `.ps1`
   fuera el problema) llegaba al servidor como `E1-20-2D-...` en vez de
   `C3-A1-20-E2-80-94-...` — es decir, `Invoke-WebRequest` codificó el
   body con el codepage por defecto del sistema (Windows-1252), no UTF-8,
   sustituyendo además el em-dash por un guion simple ASCII (best-fit
   fallback). Un byte `0xE1` suelto es UTF-8 inválido (necesita bytes de
   continuación que nunca llegan) → el deserializador de Azure DevOps
   rechaza TODO el payload. **Corregido por el coordinador** (yo no debía
   tocar este script): `$invokeParams['Body'] =
   [System.Text.Encoding]::UTF8.GetBytes($jsonBodyToSend)` en vez de
   pasar el string crudo. 334/334 tests (3 nuevos, grupo M-UTF8).

**Por qué importaba más allá de este caso puntual**: el bug del punto 2
afecta CUALQUIER escritura (`POST`/`PUT`/`DELETE`) con un carácter
no-ASCII en el body, no solo `update-build-definition`. Y no siempre
falla fuerte — un body cuya corrupción por casualidad siga siendo UTF-8
válido se habría escrito con datos SILENCIOSAMENTE incorrectos, sin
ningún error. El 400 de este caso fue, en ese sentido, "con suerte"
ruidoso.

**Técnica de diagnóstico reutilizable**: para aislar un bug de encoding
HTTP sin arriesgar más escrituras reales contra Azure DevOps, levantar un
`System.Net.HttpListener` en `127.0.0.1` (loopback), enviar exactamente
el mismo patrón de llamada (`Invoke-WebRequest` con los mismos
`-Headers`/`-Body`) contra ese listener local, y comparar los bytes
REALMENTE recibidos (`$request.InputStream`) contra los bytes UTF-8
esperados. Cero riesgo, cero dependencia de la organización real, prueba
concluyente. Construir el string de prueba con `[char]0xNNNN` explícitos
(nunca literales en el código fuente del script de diagnóstico) para no
mezclar un segundo problema de encoding (cómo `powershell.exe -File` lee
su propio `.ps1`) con el que se está diagnosticando.

**Journal 'ambiguous' de este mismo incidente**: un `400` real (respuesta
HTTP definitiva del servidor, no una falla de red) también cae en el
mismo `catch` genérico que marca `ambiguous` en el journal — no hay
diferenciación entre "sabemos que falló" y "no sabemos qué pasó". Mismo
procedimiento de reconciliación que el caso anterior: confirmar primero
con un GET fresco que nada cambió (`revision` sin incrementar, contenido
original), y recién ahí borrar el archivo de journal COMPLETO.

Ver también [[ado-buklo-microservice-gateway-dev-uat-2026-08-26]] para el
caso completo end-to-end (incluye 2 bugs más del validador encontrados
antes de llegar a este).

## 2026-08-26 — Bug real en producción (no solo en la skill): job de
build real saltado en silencio por `phase.dependencies` ausente/mal
formado en el mecanismo de agrupación de merges

**Síntoma real**: Build 584 corrido manualmente (id 21316) terminó en
VERDE pero sin compilar nada — el phase `Job_1` (el que realmente
compila) se saltó completo. Detectado por el usuario en el log real de
Azure DevOps, no por ningún chequeo de este dominio.

**Causa raíz**: `Job_1.condition` es
`in(dependencies.Batch_Window.result, 'Succeeded', ..., 'Skipped')`, pero
sin un campo `dependencies` real en el phase que declare el LINK hacia
`Batch_Window`, Azure DevOps nunca puebla
`dependencies.Batch_Window.result` en el contexto de evaluación de esa
`condition` — llega `Null`, la condición nunca matchea ninguno de los 3
valores esperados, y el phase se salta. **Nunca da error de validación
ni de la API al aplicar el plan** — el `update-build-definition` se
aplica sin problema, el plan pasa `Test-AdoClassicPlan.ps1` limpio; el
bug es 100% silencioso hasta que corre un Build real.

**2 capas del mismo bug, encontradas en el mismo incidente**:

1. Mi splice manual sobre Build 584 (ver
   [[ado-buklo-microservice-gateway-dev-uat-2026-08-26]]) nunca agregó
   `dependencies` a los phases `Batch_Window`/`Job_1` — la función
   `New-AdoMergeBatchingPhases` genera esas 2 fases, pero el splice
   manual las usó tal cual sin fijarse que el phase PREEXISTENTE (`Job_1`)
   también necesitaba su propio `dependencies` agregado a mano (no lo
   genera ninguna función, porque en el flujo de creación normal
   `New-AdoBuildDefinitionPayload` sí se lo agrega — pero yo no usé esa
   función para Build 584, hice splice quirúrgico).
2. **Bug real en el propio `New-AdoClassicPayloads.ps1`** (no solo mío):
   tanto `New-AdoMergeBatchingPhases` (para `Batch_Window`) como
   `New-AdoBuildDefinitionPayload` (para el `mainPhase`) construían
   `dependencies` como un **objeto simple** (`[ordered]@{scope=...;event=$null}`),
   pero el shape REAL que Azure DevOps espera y devuelve (confirmado
   contra `Buklo-frontend-portal-Build`, 552, real, producción, GET
   fresco) es un **ARRAY de 1 objeto**
   (`[{"scope":"Batch_Gate","event":null}]`). Enviar el objeto simple NO
   da error — Azure DevOps simplemente IGNORA el campo en silencio (bug
   silencioso de esquema, no de negocio). Esto significa que **todo Build
   creado hasta ahora vía `create-build-definition` con merge batching
   habilitado tiene este mismo bug** (confirmado en Build 624,
   `Build-administracion-proyectos-web`, creado por POST — nunca
   detectado porque ese pipeline no había corrido un Build real
   todavía). Corregido en `New-AdoClassicPayloads.ps1` (ambos puntos,
   `@(...)` en vez de objeto simple) — 334/334 tests siguen verdes (nada
   dependía del shape incorrecto).

**Cómo se confirmó/verificó (sin poder correr un Build real)**: GET
fresco de Build 552 (real, funcional) como única fuente de verdad del
shape correcto — nunca inventarlo ni confiar en la descripción de otra
persona sin verificarlo con un GET propio (el coordinador describió el
shape como objeto simple, basado en su propia lectura; mi GET directo lo
contradijo — ver [[patterns]] "no confiar en descripciones de shape sin
verificar con GET propio"). Después de aplicar el fix con el shape
correcto (array), un GET de readback SÍ mostró `dependencies` poblado
(al contrario del primer intento con objeto simple, donde el campo
simplemente desaparecía del GET de vuelta sin ningún error). Comparación
campo a campo contra Build 552 confirmó match exacto en los 3 phases.

**Nota sobre una "limitación conocida" documentada anteriormente que
resultó ser una conclusión apurada**: `ado-classic-payload-templates.md`
tenía una nota fechada 2026-08-25 diciendo que `dependencies` "no
persiste en el GET de vuelta" tras un PUT, asumiendo que Azure DevOps
igual reconstruía el grafo desde las `condition` — nunca verificado con
un Build real corriendo. Esa conclusión era CASI correcta (el campo
efectivamente no persistía) pero por la razón equivocada (shape
incorrecto, no una limitación real de la plataforma) y con una
consecuencia funcional real que no se había anticipado (el job se salta,
no solo "se ve raro en la UI"). Actualizada la nota — ver
`references/devops-guide.md` §9.4 paso 8 para el detalle completo pensado
para los 12 microservicios Buklo que faltan.

## 2026-08-27 — Anomalía real encontrada en Auth: `environments[].currentRelease`
se resetea a `0` al hacer un `update-release-definition` PUT sobre un
environment que YA tenía un release real desplegado

**Contexto**: aplicando el mismo mecanismo de field-stripping ya usado
para Gateway (`owner`/`deployStep`/`badgeUrl`/`currentRelease`/`properties`/`id`
se quitan de cada `environments[]` antes de cualquier PUT — documentado,
usado sin problema en Gateway) al Release 367 (Buklo Microservice Auth).

**Diferencia real con Gateway, no anticipada**: en Gateway, `Producción.currentRelease.id`
ya era `0` ANTES de tocar nada (nunca se había desplegado un release real
ahí) — stripping ese campo era un no-op observable. En Auth, `Producción.currentRelease.id`
era **`6926`** (un release real, existente, desplegado antes de este
trabajo — Auth ya tiene tráfico/despliegues reales, a diferencia de
Gateway). Después del PUT (que solo agregaba `Reportar-resultado-HU` +
el approver de Producción, nada relacionado a `currentRelease`),
`currentRelease.id` quedó en `0` — confirmado con 2 GETs frescos
independientes después de aplicar (no es un cache transitorio). También
`environments[].properties` (`BoardsEnvironmentType`/`LinkBoardsWorkItems`)
se reseteó de sus valores reales a `{}`.

**No se investigó más allá de confirmar el hecho** (evitar más
escrituras/lecturas no solicitadas mientras se reporta) — no se sabe
todavía si esto es: (a) puramente cosmético/recalculable (Azure DevOps
podría repoblar `currentRelease` en el próximo deployment real, y el
release 6926 en sí — sus logs, artifacts, historial — probablemente
sigue existiendo como recurso aparte, no destruido), o (b) una pérdida
real de un puntero que algo (UI, otra automatización) consulta. Reportado
como anomalía real al coordinador/usuario en vez de asumir cualquiera de
las 2 opciones.

**Implicación para el futuro**: el field-stripping de `currentRelease`/`properties`
en `environments[]` antes de un PUT (documentado como seguro, confirmado
en Gateway) **deja de ser un no-op observable en cualquier pipeline que YA
tenga un release real desplegado** — que van a ser la mayoría de los 12
microservicios Buklo restantes, a diferencia de Gateway que era nuevo.
Antes de aplicar el mismo mecanismo a otro servicio, confirmar con GET
fresco si `environments[].currentRelease.id` es distinto de `0` en
Producción — si lo es, avisar ANTES de aplicar (no después), no asumir
que el resultado va a ser un no-op solo porque lo fue en Gateway.

**CERRADO 2026-08-27 — diagnóstico + intento de restauración + fix hacia
adelante, con resultado DISTINTO para cada campo:**

1. Confirmé que Gateway tuvo exactamente el mismo problema que Auth,
   solo que antes (revisión 3→4 de Release 366, mi primer
   `update-release-definition` de esa app) — lo reporté mal la primera
   vez ("Gateway nunca tuvo un release real ahí") porque nunca until
   entonces había revisado ese campo específico; cada diff posterior
   arrancaba ya desde `0`, ocultando la pérdida original. GET del
   release real (6925, Gateway) y 6926 (Auth) confirmó que **ambas
   ejecuciones siguen 100% intactas** como recursos independientes
   (`status=active`, `environments[].status=succeeded`, `deploySteps`
   reales con `deploymentId` real) — nada se borró a nivel de historial
   real, solo el puntero de conveniencia en la definición.
2. Intento explícito de restaurar `currentRelease={id:6926,...}` +
   `properties={Boards...}` en Auth (367), exploratorio, PUT + GET
   inmediato: **`properties` persistió, `currentRelease` NO** — volvió a
   `0` aunque el PUT devolvió 200. Confirma que `currentRelease` es
   real y genuinamente de solo lectura/calculado por el servidor en este
   endpoint (no es que el mecanismo de field-stripping lo estuviera
   descartando por error — ni enviándolo explícito se puede setear).
   Coordinador confirmó no seguir intentando esto, ni en Gateway ni en
   el mecanismo hacia adelante — sería trabajo sin efecto.
3. Aplicado el mismo restore de `properties` (solo `properties`, nunca
   `currentRelease`) a Gateway (366) — confirmado igual de exitoso por
   GET fresco + diff (nada más de Producción cambió).
4. Mecanismo hacia adelante corregido (documentado en
   `references/devops-guide.md` §9.4 punto 10, no como función
   compartida — vive en cómo armo el body de cada `update-release-definition`
   de acá en más): cuando un environment YA tiene `properties` con datos
   reales, **no** se incluye en la lista de campos a quitar — se copia
   tal cual del GET. `currentRelease` sigue en la lista de campos a
   quitar (da igual, el servidor lo descarta de cualquier forma; no hay
   beneficio en intentar preservarlo, y complicaría el código sin
   ganancia real).

**Aprendizaje reutilizable clave**: un PUT que devuelve 200 no confirma
que TODOS los campos del body se hayan aceptado — algunos son
selectivamente de solo lectura y se descartan en silencio (mismo patrón
ya visto con el shape de `dependencies`, pero ahí SÍ era corregible
enviando el shape correcto; acá NO hay ningún shape que funcione). La
única forma de saberlo es un GET fresco inmediato después, campo por
campo — nunca asumir éxito total por el código de respuesta.

## 2026-09-04 — Hallazgo del reviewer sobre `containerRegistryUsername/Password`
en `Deployment-MultiStage-Cluster-Desarrollo` era INCORRECTO; verificación
propia contra 2 GET reales lo revirtió (app-logistics, buklo-web)

**Contexto**: `ado-pipeline-reviewer` marcó como bloqueante que
`deployTaskGroupInputs.containerRegistryUsername/Password` en Desarrollo/UAT
usaran macros `$(containerRegistryUsername)`/`$(containerRegistryPassword)`
"huérfanos" (0 coincidencias en las Variable Groups ni en el Build), citando
el default del generador (`New-AdoReleaseEnvironmentEntry`, contrato
`Deployment-MultiStage-Cluster-Desarrollo`) como "el contrato real
confirmado": string vacío `''` hardcodeado.

**Verificación propia obligatoria (nunca asumir el hallazgo de otro agente
sin repetir el GET)**: `Get-AdoClassicDefinitionTemplate.ps1 -Kind Release`
contra 2 Releases reales hermanas de la MISMA app-logistics (361 = shell-web,
364 = ticketing-web, mismo monorepo buklo-web, mismo `path=\Buklo`) mostró
que las macros SÍ son correctas — el reviewer solo había buscado la
resolución en las Variable Groups y el Build, nunca en el propio Release.
Cada `environments[]` (Desarrollo/UAT/Produccion, las 3, aunque solo
Desarrollo/UAT las consuman) trae una colección `variables` PROPIA del
environment (`environments[].variables`, distinta de `variableGroups` y del
`variables` de nivel raíz del Release, que está vacío `{}`) con
`containerRegistryUsername`/`containerRegistryPassword` resueltos a valores
reales — sin flag `isSecret` en ninguno de los 2 (práctica existente de la
organización, no introducida por este cambio).

**Fix correcto aplicado** (opuesto al sugerido por el reviewer): mantener
las macros en `deployTaskGroupInputs` tal cual estaban, y agregar
`stageVariables` (parámetro YA soportado por
`New-AdoReleaseEnvironmentEntry`/`New-AdoReleaseDefinitionPayload`, mapea a
`environments[].variables` — CERO cambio de código necesario) a las entradas
Desarrollo/UAT del `-ReleaseEnvironmentsPath`: `containerRegistryUsername`
literal (`gmonhubacreastus20001`, no sensible — mismo prefijo ya visible en
`containerregistries` de la Variable Group) e `isSecret:false`;
`containerRegistryPassword` como placeholder `${ADO_SECRET_CONTAINERREGISTRYPASSWORD}`
con `isSecret:true` (nunca el valor real, aunque la organización no lo trate
como secreto en sus pipelines existentes — una definición NUEVA creada por
esta skill sigue el mecanismo `${ADO_SECRET_*}` de `security.md`, que ya
soporta paths tipo `environments[N].variables.<key>.value` vía
`-ReleaseSecretReferencesPath` de `Apply-AdoClassicPlan.ps1` — sin necesitar
ninguna extensión). Índice de `environments[N]` = orden del array de
`-ReleaseEnvironmentsPath` (Desarrollo=0, UAT=1, Produccion=2 en este caso),
nunca asumido sin confirmar el orden real del archivo.

**Aprendizaje reutilizable**: un hallazgo de `ado-pipeline-reviewer` (u otro
agente) que cite "el contrato real confirmado" a partir del código fuente
del generador, sin un GET fresco de una definición real equivalente, puede
estar describiendo el DEFAULT del generador (que puede tener un gap) en vez
del comportamiento real de la plataforma — repetir siempre la verificación
con la propia herramienta antes de aplicar una corrección de otro agente,
tal como exige el flujo de este subagente.

## 2026-09-04 — `ConvertTo-AdoUpdateReleaseBody` quitaba `environments[].id`
y `environments[].owner`, ambos campos requeridos por la API (Release 388,
app-logistics)

**Síntoma real, en vivo** (`Apply-AdoClassicPlan.ps1` con
`-UpdateReleaseBodyPath`, primer uso real de `New-AdoClassicUpdatePlan.ps1
-Kind Release` sobre un Release recién creado sin `-ExistingPlanPath`):
1er intento → 400 `"An item with the same key has already been added"`
(`System.ArgumentException`); 2do intento (ya con `id` preservado) → 400
`"VS402873: Owner of release pipeline stage 'Desarrollo' cannot be empty"`.
Cero escrituras en ambos casos — el chequeo de `bodyHash` nunca deja pasar
un mismatch, y la API rechaza el body ANTES de escribir nada.

**Causa raíz de ambos**: `ConvertTo-AdoUpdateReleaseBody`
(`New-AdoClassicUpdatePayload.ps1`) tenía `'owner'` e `'id'` en la lista de
campos a quitar SIEMPRE de cada `environments[]`, basado en una nota de
`references/ado-classic-payload-templates.md` (2026-08-25, Release 381) que
resultó mal atribuida: aquel update se armó con un script de scratch ad hoc
(esta librería compartida no existía todavía) y la regla se documentó por
analogía con el body de creación (`New-AdoReleaseDefinitionPayload`, que sí
arma los environments desde cero, sin id/owner) — nunca hubo una ablación
real que aislara esos 2 campos como causa de aquel 400 original.

- `id` ausente/0 en un `environments[]` de un `update-release-definition`
  hace que Azure DevOps lo trate como "environment NUEVO a crear", no
  "actualizar el existente" — con 3 environments simultáneos sin id, los 3
  colisionan en la estructura interna del servidor.
- `owner` es un campo REQUERIDO por la API en este endpoint (no de solo
  lectura/opcional como se asumía) — debe preservarse tal cual vino del
  GET. No es un secreto (identidad ya visible en la UI de ADO para
  cualquiera con acceso al proyecto).

**Fix aplicado en la fuente**: `ConvertTo-AdoUpdateReleaseBody` ya NO quita
`id` ni `owner` de `environments[]` — solo `deployStep`/`badgeUrl`/
`currentRelease` (este último confirmado de solo lectura real, ver
decisión 2 del header del archivo). 453/453 tests offline verdes tras el
fix (1 test viejo ajustado — afirmaba el comportamiento incorrecto).

**Aprendizaje reutilizable**: una nota de documentación heredada de un
incidente viejo resuelto con un script ad hoc, sin ablación real, puede
quedar mal atribuida a un campo que en realidad nunca fue la causa. La
PRIMERA vez que una librería compartida nueva se usa de verdad contra la
API es la validación real de esas reglas heredadas — no asumir que
"siempre se quitó este campo" sigue siendo correcto solo porque está en
una lista vieja; un 400 real con mensaje explícito (`VS402873`, o
cualquier `InvalidRequestException` con nombre de campo) es más confiable
que la memoria/documentación previa.

## 2026-09-07 — `New-AdoBuildDefinitionPayload` omitía `appname` y nunca generaba
el step "Replace tokens" para el caso `rutadockerfile=./Dockerfile`
(Dockerfile genérico ya versionado, no generado por File Creator) —
6to app buklo-web, `directory-web`

**Síntoma real**: primer Build real (`Build-Buklo-directory-web`, id 634)
falló al correr — el `./Dockerfile` genérico recibió el literal
`#{appname}#` sin resolver en `ARG APP_NAME=#{appname}#`, y la variable
`appname` ni siquiera existía en el Build. `Test-AdoClassicPlan.ps1` no
detectó nada — el plan era JSON válido y coherente, el bug solo se
manifiesta cuando el Build corre de verdad (mismo patrón que el bug de
`dependencies` como objeto simple vs array del 2026-08-26: silencioso
hasta ejecución real).

**Causa raíz** (comparando GET fresco de Build 634 roto contra Build 633
real de `logistics-web`, que sí tiene ambos): `New-AdoBuildDefinitionPayload`
(`New-AdoClassicPayloads.ps1`) arma el objeto `variables` campo por campo a
mano y nunca copiaba `$Plan.buildVariables.appname`; y no existía ninguna
función generadora del step "Replace tokens" (`a8515ec8-7254-4ffd-912c-86772e2b5962`).
Build 633 solo lo tiene porque alguien lo parcheó a mano después de crearlo,
sin llevar el fix al generador — **todas las apps `buklo-web` creadas por
este generador con `rutadockerfile=./Dockerfile` (no File-Creator-generado)
comparten este mismo bug**, algunas con parche manual ad-hoc no
documentado, otras (como esta) sin parchear todavía.

**Fix aplicado en la fuente** (`New-AdoClassicPayloads.ps1`):
- Nueva función `New-AdoReplaceTokensStep` (contrato de `inputs` confirmado
  exacto contra Build 633 real).
- `New-AdoBuildDefinitionPayload`: copia `appname` cuando el plan lo trae, y
  agrega el step "Replace tokens" (posición real confirmada: justo después
  de "Gana-el-mas-nuevo", antes de los 3 File Creator) **solo** cuando
  `plan.dockerfile.generatedByFileCreator=false` **explícito** — nunca
  cuando el campo simplemente falta, para no alterar planes/fixtures viejos
  que no lo traen.

**2do bug real, encontrado al construir el fix de UPDATE para el Build ya
existente** (`New-AdoClassicUpdatePayload.ps1`): 2 splices nuevos,
`Add-AdoBuildStepAfterDisplayName` (primitiva genérica) y
`Add-AdoBuildReplaceTokensStep` (wrapper con chequeo anti-duplicado). Al
usarlos por primera vez, `Add-AdoBuildVariables` fallaba con
`.ContainsKey('isSecret')` — método que no existe sobre un `[ordered]`
(`OrderedDictionary`, el tipo real que produce `ConvertTo-AdoHashtableDeep`
al parsear el JSON declarativo del plan) aunque sí exista sobre un
`Hashtable` normal. Nunca antes ejercitado por este camino. Corregido a
`.Contains(...)` (funciona en ambos tipos).

453/453 tests verdes tras cada cambio. El plan de actualización de Build
634 se armó desde el GET real (`ConvertTo-AdoUpdateBuildBody`, nunca
reconstruido desde cero) con solo estos 2 splices — verificado línea por
línea que el orden final de steps coincide exacto con Build 633.

**Pendiente (no bloqueante)**: agregar tests automatizados de regresión
para `New-AdoReplaceTokensStep`/los 2 splices — hoy solo verificados por
inspección manual del body real, no por `run-script-tests.ps1`.

## 2026-09-07 — `containerRegistryPassword` confirmado GENUINAMENTE
necesario (no vestigial) para Desarrollo/UAT de un frontend `buklo-web` —
causa raíz real de por qué falta rompe el despliegue

Contexto: antes de aplicar el Release de `directory-web`, se dudó si
`environments[].variables.containerRegistryPassword`/`Username` (heredado
del modelo canónico `Release-modelo.json`, API gateway) aplicaba también a
un frontend web o era vestigial. GET fresco de Release 388 real
(`logistics-web`) más el Task Group `Deployment-MultiStage-Cluster-Desarrollo`
(rev 10) lo confirmó: ambos inputs son `"required": true` y el script real
que corre por SSH en el host de despliegue hace
`docker login $(containerregistries) -u $(containerRegistryUsername)
--password-stdin` **antes** de `docker pull`/`kubectl apply` — una capa
completamente distinta y anterior al `imagePullSecret` del propio
manifiesto K8s (ese resuelve el pull DENTRO del clúster; este resuelve el
pull en el host ANTES de aplicar el YAML). El comentario real de Release
388 documenta el incidente que motivó agregarlo: *"Fix ACR: copiar
containerRegistryUsername/Password de shell-web (361). En logistics el
password estaba isSecret sin valor; docker login fallaba y el SSH apply
marcaba Failed sin logs en la UI."*

Mismo valor de credencial (usuario admin `gmonhubacreastus20001` del ACR)
compartido sin cambios entre las 3 apps hermanas comparadas — no es un
secreto nuevo por-app, es la misma credencial de siempre. Sigue en texto
plano en los Releases reales existentes (sin `isSecret=true`) — hallazgo
de seguridad ya conocido, **nunca replicarlo** en un pipeline nuevo: usar
siempre `${ADO_SECRET_CONTAINERREGISTRYPASSWORD}` + `isSecret:true` vía
`-ReleaseSecretReferencesPath`.

**Aprendizaje reutilizable**: no asumir que un campo heredado del modelo
canónico es vestigial solo porque no aparece en la Variable Group — puede
vivir en `environments[].variables` del propio Release (scope distinto) y
ser funcionalmente crítico. Confirmar siempre contra un GET real de un
hermano ya desplegado antes de quitar o vaciar un campo así.

## 2026-09-07 — Lección operativa: el handoff del comando Apply para
`-Kind Release` debe incluir TODOS los parámetros requeridos en un solo
mensaje, no incrementalmente

Al entregar el comando final de `Apply-AdoClassicPlan.ps1` para crear el
Release de `directory-web`, el primer handoff omitió
`-ReleaseEnvironmentsPath` (rechazo inmediato, cero escritura) y, corregido
eso, aún faltaba `-ExistingBuildDefinitionId`/`-BuildDefinitionName`
(otro rechazo, cero escritura) — 2 ciclos evitables de ida y vuelta con el
usuario (que ejecutaba el comando él mismo por el secreto de ACR). Ninguno
de los 2 causó una escritura parcial (el validador de
`Apply-AdoClassicPlan.ps1` rechaza antes de tocar la red), pero sí costó
tiempo real de usuario. **Regla derivada**: antes de entregar el comando
final de un Release nuevo, releer la firma completa de
`Apply-AdoClassicPlan.ps1` para ese `-Kind` y confirmar que el comando
entregado trae CADA parámetro que ese `-Kind` puede necesitar (PlanPath,
InventoryPath, ReleaseEnvironmentsPath, ExistingBuildDefinitionId,
BuildDefinitionName, ReleaseSecretReferencesPath según aplique) — no
confiar en que "ya lo mencioné antes" cubre el comando copy-pastable final.

## 2026-08-27 — Bug real de PS5.1 (`Get-Content -Raw` + `ConvertTo-Json
-Depth` alto) visto EN VIVO por primera vez en este agente, armando
Buklo Microservice Billing

Ya documentado en memoria de usuario (`ps51-getcontent-raw-convertjson-bug`)
desde otro dominio, pero nunca antes disparado en el propio trabajo de
este agente. **Síntoma**: un scratch script que lee un `.yml` nuevo con
`Get-Content -LiteralPath ... -Raw -Encoding UTF8`, lo embebe tal cual
como `filecontent` dentro del objeto grande del Build, y después llama
`ConvertTo-Json -Depth 40` sobre TODO el objeto — el proceso nunca
termina (CPU sigue subiendo sin fin, confirmado con `Get-Process` en una
sesión PowerShell separada). **Causa** (ya conocida): un string leído con
`-Raw` puede quedar en un estado interno que hace que la serialización
recursiva de `ConvertTo-Json` con profundidad alta se vuelva ~800x más
lenta/se cuelgue. **Diagnóstico seguro**: nunca asumir que "está tardando
mucho" es solo un archivo grande — abrir una sesión `PowerShell` NUEVA
(nunca reusar la que está colgada) y correr `Get-Process powershell |
Select Id,StartTime,CPU` para confirmar cuál proceso es el colgado antes
de matarlo (`Stop-Process -Id <id> -Force`). Confirmado que ningún
`Invoke-AdoRest`/escritura real había ocurrido todavía en el proceso
colgado (se traba ANTES de llegar a esa parte del script). **Fix**:
`[string]::new($s.ToCharArray())` inmediatamente después de cada
`Get-Content -Raw` cuyo resultado se vaya a embeber en un objeto que
después pasa por `ConvertTo-Json -Depth` alto. Este workaround solo debe
implementarse dentro de un helper versionado, revisado y probado; no autoriza
crear ni ejecutar scripts de scratch nuevos. Ver
[[ado-buklo-microservice-billing-2026-08-27]].
