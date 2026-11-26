
## validationHash mismatch: Test hashea en memoria, Apply relee de disco (2026-09-16)

**Síntoma**: `Test-AdoPermissionsPlan.ps1` reporta "Plan VALIDO" y escribe
un `validationHash`, pero `Apply-AdoPermissionsPlan.ps1` lo rechaza con
"el plan cambio despues de validarse (validationHash no coincide)", aunque
NADIE tocó el archivo entre Test y Apply.

**Causa raíz confirmada**: Test calculaba `validationHash` sobre el objeto
`$plan` EN MEMORIA y luego lo escribía con `ConvertTo-Json | Set-Content`.
`ConvertTo-Json`/`ConvertFrom-Json` coercionan tipos, así que el objeto
re-parseado desde disco (lo que Apply hashea) difiere del objeto en
memoria. El campo culpable fue `validationEvidence.validatedAtUtc`: se
generaba como string ISO-8601 `'o'` (`2026-09-16T23:41:44.479599Z`) y se
hasheaba así en memoria, pero al serializar, PowerShell lo reinterpreta
como `[DateTime]` y lo re-emite en formato corto de cultura
(`09/16/2026 23:41:44`), perdiendo sub-segundos. `Get-AdoPermissionsPlanCanonicalHash`
solo ordena las claves de NIVEL SUPERIOR; no protege contra la coerción de
tipos anidados. NO era truncamiento por `-Depth 20` (verificado: depth 20
== depth 50) ni orden no-determinista de claves (el hash de disco es
estable entre lecturas). Mismo dominio de bug que el de timestamps en
`Test/Apply-AdoClassicPlan` de Pipelines.

**Solución aplicada**: en `Test-AdoPermissionsPlan.ps1`, calcular el
`validationHash` sobre el plan ya SERIALIZADO Y RE-PARSEADO (escribir a
disco primero sin hash, releer, hashear el objeto reparseado, recién ahí
persistir el hash). Garantiza que Test y Apply hasheen exactamente los
mismos bytes. La suite `run-script-tests.ps1` no regresionó (test 12 de
detección de manipulación sigue verde; los 4 FAIL son pre-existentes:
tests 8/9 con fixtures de matriz vieja pre-229ce0c, y 16/22 ambientales).
CORE-PLT se aplicó luego 46/46, readback 0 divergentes.

**NOT**: no diagnosticar el mismatch como plan corrupto ni como archivo
modificado; no parchear el JSON a mano recalculando el hash externamente
(Apply usa su propio canonical hash). El fix es hashear lo que quedará en
disco, no el objeto en memoria.# Diagnóstico — ado-permissions-builder

## Incidente de red real durante pruebas (2026-08-26)

**Síntoma**: al invocar `Apply-AdoPermissionsPlan.ps1` con un plan de
prueba (proyecto/repo/grupo ficticios) sin anular explícitamente
`$env:AZURE_DEVOPS_PAT`, el script hizo llamadas GET reales contra
`vssps.dev.azure.com/Shared-Service-GM` y `dev.azure.com/Shared-Service-GM`
(respuestas reales de error 400/404 porque los GUIDs no existen), y un
intento de POST real contra `_apis/accesscontrollists` (falló 500
"Could not find dataspace" — no llegó a persistir nada, pero SÍ fue una
escritura real intentada).

**Causa raíz confirmada**: `$env:AZURE_DEVOPS_PAT` está configurada de
forma persistente a nivel de usuario de Windows en este entorno,
compartida con el dominio Pipelines. Cualquier invocación de un script
que llame a `Invoke-AdoPermissionsRest` la usa automáticamente, sin
importar si los datos de prueba son ficticios.

**Solución validada**: nunca invocar `Apply-AdoPermissionsPlan.ps1` ni
`Apply-AdoPermissionsDeletePlan.ps1` de punta a punta para pruebas. Sus
fases (`Invoke-AdoPermissionsApplyPhases`,
`Invoke-AdoPermissionsDeleteApplyPhase`, ambas en
`Invoke-AdoPermissionsRest.ps1`) se prueban dot-sourceando el foundation y
reemplazando la función `Invoke-AdoPermissionsRest` por una versión
mockeada ANTES de llamarlas. Ver
`scripts/tests/run-script-tests.ps1` casos 19-20 para el patrón exacto.

**Comprobación segura**: `scripts/tests/run-script-tests.ps1` completo en
verde (36/36 casos, incluidos los mockeados) sin ninguna llamada de red
real — confirmado revisando que ningún caso invoque `Apply-*.ps1` como
proceso hijo.

## Bug real: self-poisoning de `validationBlockers` (2026-08-26)

**Síntoma**: `Test-AdoPermissionsPlan.ps1` seguía reportando los mismos
bloqueantes después de corregir la causa real y volver a correr la
validación sobre el MISMO archivo de plan (sin regenerarlo).

**Causa raíz confirmada**: el script arrastraba `plan.validationBlockers`
tal cual venía del archivo al inicio de cada corrida — pero como el
propio script reescribe ese campo en cada corrida (incluso al fallar),
una corrida fallida quedaba fallando para siempre.

**Solución validada**: nunca arrastrar `plan.validationBlockers` del
archivo. Las 2 categorías que `New-AdoPermissionsPlan.ps1` puede escribir
ahí (ambigüedad de grupo, lockout) se RE-DERIVAN de forma independiente
contra el inventario en cada corrida de `Test-AdoPermissionsPlan.ps1`.

**Comprobación segura**: regenerar el plan fresco y volver a validar
sobre el archivo YA marcado inválido de una corrida anterior — ambos
casos deben dar el mismo resultado correcto.

## Gotcha de codificación: `.ps1` con texto en español sin BOM (2026-08-26)

**Síntoma**: las 2 descripciones estándar (con tildes/ñ) aparecían con
mojibake tipo "LÃ­deres" en vez de "Líderes" en el plan JSON generado.

**Causa raíz confirmada**: Windows PowerShell 5.1 lee un `.ps1` guardado
como UTF-8 SIN BOM usando la codepage ANSI del sistema por defecto —
corrompe cualquier literal con caracteres no-ASCII.

**Solución validada**: `New-AdoPermissionsPlan.ps1` (y cualquier `.ps1`
nuevo de este dominio con texto no-ASCII literal) se guarda con BOM UTF-8
explícito (`[System.Text.UTF8Encoding]::new($true)`).

**Comprobación segura**: `Select-String -Path <plan.json> -Pattern
"Líderes"` debe encontrar el texto correcto, no una variante con
caracteres extraños.

## Regresión del BOM al hacer un bulk-edit de varios .ps1 (2026-09-02)

**Síntoma**: al agregar `-Encoding UTF8` a todas las llamadas
`Get-Content -Raw` del dominio de una sola pasada (regex + `WriteAllText`
sobre cada archivo), `run-script-tests.ps1` caso 5 empezó a fallar con la
descripción de Code-Reviewers en mojibake ("LÃ­deres...") — el mismo
síntoma que el gotcha de arriba, pero como REGRESIÓN nueva, no como bug
original.

**Causa raíz confirmada**: `New-AdoPermissionsPlan.ps1` es el único .ps1
de este dominio que YA tenía BOM UTF-8 (por el gotcha de arriba). El
bulk-edit reescribió el archivo con
`[System.Text.UTF8Encoding]::new($false)` (sin BOM) para TODOS los
archivos tocados, sin verificar si cada uno ya tenía BOM — le quitó el BOM
al único que lo necesitaba, mientras que en los otros 7 archivos (que
nunca tuvieron BOM) el mismo patrón no rompió nada.

**Solución validada**: antes de reescribir un `.ps1` en bulk, comprobar el
BOM original de CADA archivo (`[System.IO.File]::ReadAllBytes($f)[0..2]`
== `239,187,191`) y preservarlo por archivo — nunca asumir que todos los
archivos de un lote comparten el mismo encoding de origen. Corregido
restaurando el BOM solo en `New-AdoPermissionsPlan.ps1`
(`[System.Text.UTF8Encoding]::new($true)`).

**Comprobación segura**: `run-script-tests.ps1` completo en verde
(36/36), y los primeros 3 bytes del archivo son `EF BB BF`.

## GET guardado como UTF-8-sin-BOM + `Get-Content -Raw` sin `-Encoding` = mojibake compuesto (2026-09-02)

**Síntoma**: al generar un plan de `pr-policy-admin` a partir de 2
inventarios JSON exportados (`Export-AdoPolicyInventory.ps1`, escritos con
`[System.IO.File]::WriteAllText(..., UTF8Encoding($false))`, es decir SIN
BOM a propósito — es un archivo de datos, no un script), el `message` de
las policies "Required reviewers" (con tildes) salía corrompido en el
plan generado, y `Test-AdoPolicyPlan.ps1` reportaba `bodyHash no
coincide` para esas mismas operaciones.

**Causa raíz confirmada**: `New-AdoPolicyPlan.ps1` y `Test-AdoPolicyPlan.ps1`
leían esos JSON con `Get-Content -LiteralPath ... -Raw` SIN `-Encoding
UTF8`. En Windows PowerShell 5.1, un archivo UTF-8 sin BOM se lee con la
codepage ANSI del sistema por defecto — mismo mecanismo que el gotcha de
arriba, pero del lado de LECTURA de un archivo de datos (JSON), no de un
literal embebido en el propio script. Como el archivo pasaba por 2+
lecturas sin encoding en cadena (`New-` genera el plan ya corrompido una
vez, `Test-` lo vuelve a leer y lo corrompe una SEGUNDA vez), el mojibake
salía doblado (`"revisiÃƒÆ'Ã‚Â³n"` en vez de `"revisión"`).

**Solución validada**: TODO `Get-Content -Raw` de este dominio que lea un
archivo JSON/texto propio (inventario, plan, journal, miembros) debe
llevar `-Encoding UTF8` explícito — se corrigió en los 13 `.ps1` del
dominio de una sola pasada (ver el bug de BOM de arriba, que salió de esta
misma pasada). El lado de ESCRITURA (`[System.IO.File]::WriteAllText` con
`UTF8Encoding($false)`) ya estaba bien desde el principio — el bug era
exclusivamente de lectura.

**Comprobación segura**: `Select-String` sobre el JSON generado por
`Get-AdoPolicyOrderedSettings`/`New-AdoPolicyPlan.ps1` debe encontrar
"revisión"/"autorización"/"Producción" tal cual, no una variante con
`Ã`/`Æ`/`Â`.

## POST con tildes rechazado por Azure DevOps: "Unable to translate bytes [F3] ... to Unicode" (2026-09-02)

**Síntoma**: al aplicar un plan real de `pr-policy-admin` con 4 policies
"Required reviewers" cuyo `message` tenía tildes, las 4 fallaron con HTTP
400 y el cuerpo `{"Message":"Unable to translate bytes [F3] at index N
from specified code page to Unicode."}`, mientras las 17 policies sin
texto acentuado se crearon sin problema.

**Causa raíz confirmada**: `Invoke-AdoPermissionsRest` armaba el body con
`($Body | ConvertTo-Json -Depth 20)` y lo pasaba a `Invoke-WebRequest`
como `[string]`. En Windows PowerShell 5.1, un `-Body` de tipo `string` se
codifica con la codepage POR DEFECTO DEL SISTEMA (Windows-1252 acá) al
armar la solicitud HTTP cuando el `Content-Type` se fija vía `-Headers` en
vez del parámetro dedicado `-ContentType` — nunca UTF-8 por sí solo. `ó`
(UTF-8: `C3 B3`) salía como el byte único `F3` (Windows-1252), que Azure
DevOps no pudo decodificar como UTF-8 válido. Mismo bug, mismo mecanismo y
misma corrección que ya existía en `Invoke-AdoRest.ps1` del dominio de
Pipelines — nunca se había portado acá porque ningún body de
grupos/permisos había tenido antes texto no-ASCII real.

**Solución validada**: convertir el JSON del body a `byte[]` UTF-8
explícito ANTES de asignarlo a `Invoke-WebRequest`:
`[System.Text.Encoding]::UTF8.GetBytes($jsonBodyToSend)`, nunca pasar el
`[string]` directo. Corregido en `Invoke-AdoPermissionsRest.ps1`.

**Comprobación segura**: reintentar las 4 operaciones que habían fallado
(plan de seguimiento nuevo, ya que el journal las había marcado
`ambiguous`) — las 4 se crearon a la primera, y una relectura de solo
lectura confirmó el `message` textual correcto en el servidor real
(`revisión técnica...`, `autorización de la Junta de Control de
Cambios...`).

## INCIDENTE MAYOR 2: "Set ACL" reemplaza TODO el acesDictionary del token, no lo combina (2026-09-02, mismo día que el incidente del descriptor SID)

**Síntoma**: al escribir una ACE real para 6 identidades nuevas
("default groups": Project Administrators, Build Administrators,
Contributors, Readers + 2 Build Service identities) en `All Repositories`
de Buklo, la escritura reportó éxito (HTTP 204) — pero una relectura cruda
inmediata mostró que **`Development Team` y `Code-Reviewers` (que ya
tenían ACE real, recién restaurada minutos antes en el mismo incidente
del descriptor SID) habían desaparecido del `acesDictionary`**.

**Causa raíz confirmada**: la documentación oficial de Microsoft para
`POST .../accesscontrollists/{namespaceId}` dice literalmente "All data
that currently exists for the ACLs supplied will be overwritten" — esto
es **literal y total**: el `acesDictionary` que se envía REEMPLAZA
completo el del token, no se combina por-descriptor con lo que ya había.
Cualquier identidad que ya tuviera una ACE real en ese token, pero que NO
se incluya en el `acesDictionary` de la nueva escritura, se BORRA.

**Por qué no se detectó en el incidente del descriptor SID (arriba)**:
en ese momento, TODAS las escrituras anteriores habían fallado
silenciosamente (por el bug del descriptor) — nunca hubo un ACE real
persistido, así que nunca hubo nada que una escritura posterior pudiera
borrar. La primera escritura que funcionó de verdad fue la del canario +
lote de 29 operaciones de rama (cada token de rama se escribió UNA sola
vez, nunca dos), y recién la escritura de "All Repositories" para los 6
grupos default fue la SEGUNDA escritura real al MISMO token
(`repoV2/{projectId}`) — ahí se manifestó el problema.

**Solución validada** (arquitectural, aplica a TODO el dominio, no solo
a este incidente puntual):
1. `Get-AdoPermissionsFullAcesDictionary` (nueva función en
   `Invoke-AdoPermissionsRest.ps1`): GET crudo de un token SIN el filtro
   `&descriptors=`, trae el `acesDictionary` COMPLETO real tal cual está
   guardado (todas las identidades, no solo las 2 que administra este
   dominio).
2. `Export-AdoPermissionsSecurityInventory.ps1` ahora llama a esta
   función para CADA token que exporta (`All Repositories` y cada rama) y
   guarda el resultado como `fullAcesDictionary` en el inventario.
3. `New-AdoPermissionsPlan.ps1` (`Get-AdoPermissionsAceOperationForToken`)
   ahora arma el `acesDictionary` de cada escritura en 2 pasos: primero
   copia TAL CUAL cada entrada de `AclSnapshot.fullAcesDictionary` que
   NO sea una de las 2 que administra (Development Team/Code-Reviewers),
   preservando su allow/deny exacto; despues agrega/sobrescribe SOLO las
   entradas de los roles administrados con los bits recalculados. Nunca
   más se construye un `acesDictionary` que sea un subconjunto de lo que
   ya existe.
4. El `precondition.descriptors` de la operación también incluye estas
   entradas preservadas (con su allow/deny actual como valor esperado),
   así el drift-check existente las cubre automáticamente: si algo
   externo cambia una de esas identidades entre la exportación y el
   apply, la operación se omite (nunca sobrescribe con una copia vieja).
5. `ConvertTo-AdoPermissionsSecurityAceDescriptor` se extendió para
   dejar pasar sin modificar un descriptor `Microsoft.TeamFoundation.
   ServiceIdentity;...` (identidades de servicio, ej. Build de un
   proyecto/organización) además del ya soportado `Microsoft.
   TeamFoundation.Identity;...` — hacían falta para las 2 identidades de
   Build Service de este mismo incidente.

**Corrección inmediata aplicada**: se re-escribió `All Repositories` con
las 8 identidades juntas (las 2 que se habían borrado + las 6 nuevas),
usando sus valores reales exactos (confirmados por lectura previa) —
verificado con una relectura cruda final, las 8 quedaron correctas.

**Comprobación segura**: test 10c en `run-script-tests.ps1` (fixture con
una identidad "ajena" en `fullAcesDictionary`, confirma que sobrevive en
el body de una escritura nueva) — regresión permanente para este bug. En
producción: una exportación fresca de Buklo después del fix confirmó
`fullAcesDictionary` con las 8 identidades esperadas (más una novena,
`Business Team IA` con `Read=Allow`, que apareció por una acción manual
del usuario en el portal durante esta misma sesión — no tocada, quedará
preservada automáticamente en cualquier escritura futura gracias a este
fix).

**Lección de método**: cualquier API de "Set" que documente "reemplaza
todos los datos existentes" hay que tomarla LITERAL, no asumir que es
"reemplaza solo lo que menciono" salvo que la evidencia lo confirme
explícitamente contra un caso donde YA había algo real que preservar —
la evidencia que parecía confirmar la merge-por-descriptor (nadie más se
vio afectado en el incidente anterior) era en realidad una consecuencia
de que nada se había escrito todavía, no de que la API combine.

**Refuerzo agregado a pedido explícito del usuario (mismo día)**: además
del fix de construcción (arriba, en `New-AdoPermissionsPlan.ps1`), se
agregó una GUARDIA DURA dentro de `Invoke-AdoPermissionsRest` (la función
real de escritura, el único punto por el que pasa cualquier operación
`set-git-permissions-ace` sin importar qué script la generó): antes de
mandar el POST, vuelve a consultar en vivo el `acesDictionary` real del
token (`Get-AdoPermissionsFullAcesDictionary`) y lanza excepción --
rechazando la escritura por completo, sin llegar a la red -- si el body
dejaría fuera a alguna identidad que hoy tiene ACE real ahí. Esto protege
incluso un plan armado a mano (como los 2 planes ad-hoc de este mismo
incidente) o por un script futuro que no use `New-AdoPermissionsPlan.ps1`.
Sin flag para desactivarla -- ver `.cursor/rules/azure-devops.mdc` (sección de seguridad)
§ "Guardia dura...". Verificada con un test que llama a la función REAL
(mockeando solo la consulta en vivo) y confirma que rechaza antes de
intentar la red: caso 10d de `run-script-tests.ps1` (10c prueba que la
construcción del plan ya lo hace bien; 10d prueba que, aun si algo lo
hiciera mal, la escritura se frena igual).

## Token de rama con codificación equivocada: UTF-8 de 1 byte en vez de UTF-16LE (2026-09-02)

**Síntoma**: al construir el token de seguridad de una rama (ej.
`refs/heads/development`), el resultado no coincidía con ningún token
real ya existente en la organización para esa misma rama — se descubrió
comparando contra un listado completo del namespace de seguridad (`GET
.../accesscontrollists/{namespaceId}?api-version=7.1` sin `token=`, trae
TODOS los ACL del namespace) y buscando manualmente tokens reales que
contuvieran el nombre de un repo conocido.

**Causa raíz confirmada**: `ConvertTo-AdoPermissionsHexUtf8` (nombre
original de la función, antes de este fix) codificaba cada carácter del
segmento de la rama como UTF-8 de 1 byte (`[Text.Encoding]::UTF8`). Azure
DevOps en realidad codifica cada carácter como **UTF-16LE (2 bytes,
little-endian)** — confirmado con evidencia doble: (1) tokens reales ya
existentes en la organización para `development`/`feature`/`uat`/etc.
(creados antes por el portal) tienen la forma
`...refs/heads/64006500760065006c006f0070006d0065006e007400` (cada
carácter seguido de un byte `00`), y (2) la documentación oficial
(`https://devblogs.microsoft.com/devops/git-repo-tokens-for-the-security-service/`):
"Input characters are C# strings, which means they are UTF-16
little-endian." Ejemplo del propio artículo: "master" → hex
`6d0061007300740065007200`.

**Por qué no se detectó antes**: el test 11 original ("Token de
refs/heads/feature se construye correctamente") afirmaba validar esto,
pero su valor esperado (`66656174757265`, UTF-8 de 1 byte) codificaba la
MISMA suposición incorrecta que el código — un test que solo confirma su
propio bug, nunca lo expone. Esto NUNCA se había ejercitado contra la
API real hasta el incidente de más abajo (2026-09-02, primera corrida
real de este dominio).

**Solución validada**: la función se renombró a
`ConvertTo-AdoPermissionsHexUtf16` y usa
`[Text.Encoding]::Unicode.GetBytes($Segment)` (en .NET/PowerShell,
`[Text.Encoding]::Unicode` es UTF-16LE). El test 11 se corrigió con el
valor esperado real (`6600650061007400750072006500` para "feature").

**Comprobación segura**: comparar el token construido contra un token
real ya existente en la organización para la MISMA rama (si existe uno,
p.ej. `feature` suele tener un shell auto-creado por el portal) — deben
coincidir carácter por carácter, no solo "parecer" hex válido.

**Relación con el incidente de abajo**: este bug y el de la clave del
`acesDictionary` (SID vs Graph) son **independientes** — cualquiera de
los dos por sí solo ya haría que una escritura de ACE a nivel de rama no
tome efecto real. Los dos estaban presentes a la vez durante las
primeras corridas reales, lo que complicó separar sus síntomas.

## INCIDENTE MAYOR: `set-git-permissions-ace` reportaba "applied HTTP 204" sin escribir NADA real (2026-09-02)

**Síntoma**: al aplicar por primera vez un plan real de grupos/permisos
(30 operaciones: 1 `All Repositories` + 29 por rama en 7 repos), TODAS
reportaron `[applied] ... HTTP 204/200`. Una relectura posterior (tanto
vía script como abriendo el portal real en el navegador) no mostraba
`Development Team` ni `Code-Reviewers` en la lista de grupos con permisos
en NINGÚN nodo — ni siquiera aparecían en la lista de identidades. El
usuario, viendo el portal vacío/distinto a lo esperado, entendió
inicialmente que se habían **eliminado** otros grupos preexistentes
(`Contributors`, `Readers`, `Project Administrators`, `Business Team IA`,
`Team-Proyects`, `Build Administrators`, `Buklo Build Service`) — alarma
que resultó infundada (ver más abajo), pero que costó una investigación
larga para descartar con certeza.

**Herramienta decisiva para diagnosticar esto**: el **Audit Log** de la
organización (`GET https://auditservice.dev.azure.com/{org}/_apis/audit/auditlog`,
mismo PAT, host nuevo no cubierto por el allowlist de
`Invoke-AdoPermissionsRest.ps1` — se consultó con una llamada aparte,
autenticada igual, sin modificar el allowlist de escritura del dominio).
Registra CADA permiso modificado, con actor, mecanismo de autenticación
(`PAT_Unscoped` vs `AAD`+user-agent de navegador) y valor exacto. Esto
demostró de forma concluyente:
1. Ningún otro grupo (`Contributors`, `Readers`, etc.) tenía ni un solo
   evento en todo el día — nunca se tocaron, la alarma inicial era
   infundada.
2. Los 30 "applied HTTP 204" del script **no generaron NINGÚN evento de
   auditoría** — prueba definitiva de que la escritura nunca tomó efecto
   real, pese al código de estado exitoso.
3. Los únicos cambios reales a `Development Team` fueron hechos por el
   USUARIO manualmente vía navegador (auth `AAD` + user-agent Chrome) al
   notar el problema — no por el script.

**Causa raíz real confirmada** (tras 2 intentos fallidos, ver abajo): el
`acesDictionary` de la API de Security (`accesscontrollists`) NO usa el
descriptor de Graph (`vssgp.BASE64...`) como clave, ni ningún prefijo
sobre él — usa el descriptor LEGADO basado en SID:
`Microsoft.TeamFoundation.Identity;S-1-9-...`. El dato notable: el
payload Base64 de un descriptor `vssgp.XXXX` **es, literal y
directamente, el SID en texto plano** (`vssgp.` + Base64 de
`S-1-9-...`) — no hace falta ninguna llamada adicional a la API para
resolverlo, solo decodificar Base64. Confirmado decodificando el
descriptor real de Development Team y comparando el SID resultante
contra un GET crudo (sin `&descriptors=`) del ACL real de `All
Repositories`, que mostraba `S-1-9-1551374245-2697738344-693361735-
2808067267-2127622907-1-58883461-1312947276-2826811426-972539471` con
bits reales no-cero.

**2 intentos fallidos antes de encontrar esto** (documentar el camino,
no solo el destino — el segundo intento parecía confirmado y no lo
estaba):
1. Descriptor de Graph desnudo tal cual — el bug original. Se creyó
   descartado al ver que el Audit Log no mostraba nada, pero al principio
   no se sabía la causa.
2. Prefijo `Microsoft.IdentityModel.Claims.ClaimsIdentity;` + el
   descriptor de Graph tal cual — **PARECÍA confirmado** porque un GET
   con `&descriptors=<esa forma>` devolvía una entrada con `allow=0,
   deny=0` en el `acesDictionary`, que se interpretó erróneamente como
   "la entrada existe, pero vacía". **Trampa real**: la API de Security
   devuelve un "eco" con `allow=0/deny=0` para CUALQUIER descriptor
   pedido vía `&descriptors=` que no tiene ACE real — no es evidencia de
   que la entrada exista. La única forma confiable de confirmar una
   entrada real es un GET SIN el filtro `&descriptors=` (trae el
   `acesDictionary` completo tal cual está guardado) y buscar la clave
   ahí a mano.

**Lección de método, no solo el bug puntual**: cuando una escritura repetida
"funciona" (200/204) pero el efecto no aparece, el GET de verificación
DEBE hacerse sin filtros de conveniencia (`&descriptors=`, `&token=`
parcial, etc.) — un filtro puede devolver una respuesta con forma válida
que no prueba nada. El Audit Log de la organización es la fuente de
verdad definitiva cuando hay duda sobre si una escritura tomó efecto
real — se consulta antes de seguir iterando a ciegas sobre hipótesis de
formato.

**Solución validada**: `ConvertTo-AdoPermissionsSecurityAceDescriptor`
(nueva función en `Invoke-AdoPermissionsRest.ps1`) hace
`[Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($payload))`
sobre lo que sigue a `vssgp.`, valida que el resultado tenga forma
`S-1-9-[0-9-]+`, y antepone `Microsoft.TeamFoundation.Identity;`. Se usa
tanto al escribir (`New-AdoPermissionsPlan.ps1`, como clave del
`acesDictionary` Y como valor de su campo `descriptor`) como al leer
(`Export-AdoPermissionsSecurityInventory.ps1`, y el drift-check /
readback dentro de `Invoke-AdoPermissionsRest.ps1`). Verificado con una
escritura canario de 1 sola operación (`All Repositories`), confirmada
con un GET crudo posterior: `Development Team` quedó con exactamente los
bits de la matriz, y el bit ajeno que el usuario había puesto a mano
(`Enterprise Live Migration`) se preservó sin tocar — la fórmula `(current
AND NOT managedMask) OR desired` funcionó exactamente como se diseñó.

**Bug adicional encontrado durante el mismo incidente** (StrictMode +
colapso de colección de 1 elemento, mismo patrón familiar que el bug de
`ConvertTo-Json` de más arriba pero del lado de LECTURA): un `ace` real
encontrado por primera vez (antes SIEMPRE era `$null` por el bug de
arriba, así que esto nunca se ejecutaba) puede traer `extendedInfo` como
objeto VACÍO `{}` sin `inheritedAllow`/`effectiveAllow`/etc. — acceder a
esas sub-propiedades directo revienta bajo `Set-StrictMode -Version
Latest`. Se agregó `Get-AdoPermissionsIntPropertyOrDefault` (chequea
cada sub-propiedad por separado con `.PSObject.Properties[...]`, nunca
solo la existencia del objeto contenedor). Y por separado,
`Test-AdoPermissionsJournalOperationsRawHasDuplicateKeys` crasheaba con
"No se encuentra la propiedad 'Count'" en un plan de UNA sola operación
(`$seenKeys | Select-Object -Unique` con 1 solo resultado se desenrolla a
escalar) — corregido envolviendo con `@(...)`. Este último crasheó
DESPUÉS de que la escritura real ya se había confirmado en Azure DevOps
(mensaje "fue CONFIRMADA... pero no se pudo actualizar el journal") — la
escritura en sí no se pierde, solo el registro local queda en estado
incierto hasta corregir esto.

**Comprobación segura**: plan canario de 1 operación (`All Repositories`)
aplicado y verificado con GET crudo antes de aplicar el resto — luego las
28 operaciones de rama restantes, mismo patrón, 29/29 aplicadas y
verificadas con una relectura completa que decodifica los bits reales
(no solo confía en "applied").

## 2026-09-16 — Apply DB-Admin: 3 bugs reales de migración Windows→WSL en Invoke-AdoPermissionsRest.ps1

Al correr el ciclo completo New→Test→Apply→Readback para Database-Administration-and-Monitoring (264 ACE, matriz corregida a Code-Reviewers=82038), el primer Apply reportó exit 0 pero NO aplicó nada (ningún journal escrito). Tres bugs latentes, todos de código migrado de Windows, no de datos:

1. **`Cannot find drive '$env'`** — `$script:AdoPermissionsProductionExecutionsDir` estaba en comillas SIMPLES con separadores Windows: `'$env:REPO_ROOT\.local\...\executions'`. `$env:REPO_ROOT` no se expande en comillas simples y `$env:` con `\` se interpreta como drive PowerShell inexistente. Fix: resolver `REPO_ROOT` (env var si existe, si no `Resolve-Path (Join-Path $PSScriptRoot '..' '..' '..' '..')`) y armar la ruta con `Join-Path` cross-platform. Sin este fix, cada operación falla al registrar en el journal y NADA llega a ADO.

2. **`ConvertTo-AdoPermissionsSecurityAceDescriptor` rechaza `ClaimsIdentity`** — la re-verificación de precondición itera TODOS los descriptores del acesDictionary, incluidas identidades AAD de usuario individual en forma `Microsoft.IdentityModel.Claims.ClaimsIdentity;<tenantId>\<upn>` (ej pmontero@, mdailey@) que el plan captura para PRESERVARLAS. Esa forma YA es clave final del acesDictionary de la API Security, pero el conversor solo aceptaba `Microsoft.TeamFoundation.Identity;` y `ServiceIdentity;`. Faltaba `ClaimsIdentity;` en la lista de formas finales → lanzaba → toda la op quedaba `[skipped]`. Fix: agregar `ClaimsIdentity;` como tercera forma final que se devuelve tal cual.

3. **Readback `The property 'effectiveDeny' cannot be found`** — en `Get-AdoPermissionsReadbackResults`, bajo StrictMode, `$extendedInfo.effectiveDeny`/`effectiveAllow` por acceso directo lanza PropertyNotFoundStrict cuando el ACE trae `extendedInfo` pero SIN esos campos (Azure DevOps los omite si no hay permiso efectivo heredado). Confirmado: 211 de 264 ACE de DB-Admin no traen effectiveDeny. El código ya usaba `.PSObject.Properties['extendedInfo']` defensivo pero NO para los dos campos internos. Fix: acceso defensivo por `PSObject.Properties['effectiveAllow'/'effectiveDeny']`.

Tras los 3 fixes: Apply = 264 applied / 0 skipped / 0 failed (HTTP 204); Readback = 264 applied / 0 divergent. All Repos DB-Admin quedó Development teams allow=16438 deny=507848, Code-Reviewers allow=82038 deny=0. Suite de tests: 42/44 (los 2 FAIL son ambientales: hook/settings.json fuera del repo real). Test 8 (matriz All Repos) se actualizó porque el fixture aún esperaba el Code-Reviewers viejo (16406, sin CreateTag/ManageNote/ViewSecAlerts).

