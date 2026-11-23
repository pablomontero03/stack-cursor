---
name: ado-buklo-uat-dbname-batch-2026-09-02
description: Batch update of the UAT DB name (Secret.data key) across all 20 classic Builds under \buklo — 10 matched, 9 out of scope, 1 declined queue item; real mojibake-retyping bug found and fixed mid-task
metadata:
  type: project
---

## Qué se pidió

Cambiar únicamente el valor del nombre de base de datos (dentro del bloque
`Secret.data`/`ConfigMap.data`/`Secret.stringData` del YAML generado por el
step "File Creator" `./deployment-uat.yml`) a `buklo_lab_v2`, en TODOS los
Builds clásicos bajo `\buklo` que tuvieran esa clave — sin tocar ningún
otro byte del YAML. Preparación pura (sin Apply, sin aprobación, sin
readback) — el coordinador entrega el manifiesto final a la sesión
principal.

## Resultado — 10 de 20 Builds con la clave, 10 sin ella

Confirmado con GET fresco de los 20 (`Get-AdoClassicDefinitionTemplate.ps1`)
antes de asumir cualquier nombre/id de la lista que trajo el coordinador —
2 correcciones reales encontradas así (ver abajo).

**CON clave de nombre de BD (`Secret.data`, base64 `YnVrbG9fbGFi` =
`buklo_lab` → `YnVrbG9fbGFiX3Yy` = `buklo_lab_v2`):**

| id | Build | clave |
|----|-------|-------|
| 585 | Auth | `DATABASE_NAME` |
| 586 | Engine | `DATABASE_NAME` |
| 587 | Notifications | `DATABASE_NAME` |
| 589 | AI | `DB_NAME` |
| 590 | Billing | `DATABASE_NAME` |
| 591 | EMR | `DATABASE_NAME` |
| 592 | Hacienda | `DB_DATABASE` |
| 595 | **Surveys** (no "Ticketing" — ver corrección abajo) | `DB_NAME` |
| 596 | **Ticketing** (microservicio, no el "-web") | `DB_NAME` |
| 621 | Buklo-Server | `DB_NAME` |

Los 3 nombres de clave distintos (`DATABASE_NAME`/`DB_NAME`/`DB_DATABASE`)
confirman que no se puede asumir un nombre único al escanear este tipo de
cambio org-wide — hay que revisar cada `filecontent` real.

**SIN la clave (revisados, no tocados):** 579 shell-web, 580 hr-web, 581
ontology-web, 582 ticketing-web (los 4 "-web" son frontends Angular sin
sección de BD), 583 Rag-Knowledge-Base (ver anomalía abajo), 584 gateway
(solo `REDIS_DB: "0"` — índice numérico de Redis, NO es nombre de BD, no
se toca), 588 Storage (confirma memoria previa "sin DB/Redis"), 593
Realtime (solo Redis, sin índice ni nombre), 594 Subscriptions, 599
Patient-Mobile (sin ningún step "File Creator" — es un build de app móvil
Expo/Android/iOS, no genera manifiestos K8s).

## 2 correcciones reales sobre la lista que trajo el coordinador

1. **id 595/596 intercambiados**: el coordinador etiquetó 595 como
   "Microservice-Ticketing" (con nota "revisar" en 596). El GET real
   confirma: 595 = `Build-Buklo-Microservice-Surveys`, 596 =
   `Build-Buklo-Microservice-Ticketing`. Nunca asumir el nombre de la lista
   de un coordinador sin GET fresco, ni siquiera cuando parece completa.
2. **Build 584 (Gateway) trae `REDIS_DB: "0"` en su ConfigMap** — esto
   coincide con un patrón de búsqueda ingenuo de "DB" pero es el índice
   lógico de Redis (0–15), no un nombre de base de datos. Confirmado
   leyendo el valor real antes de excluirlo. Ver también 590 (Billing),
   que tiene AMBOS: `DATABASE_NAME` (Secret, sí aplica) y `REDIS_DB: "0"`
   (ConfigMap, no aplica) — un mismo Build puede tener los dos patrones a
   la vez, hay que distinguirlos por ubicación/semántica, no solo por la
   letra "DB".

## Anomalía encontrada, NO corregida (fuera de alcance de esta tarea)

Build 583 (`Build-Buklo-Rag-Knowledge-Base`) tiene su File Creator
`deployment-uat.yml` con el contenido de OTRO servicio (`web-hr`, un
frontend Angular con Secret/ConfigMap `NG_APP_*`, nada relacionado con
Rag-Knowledge-Base). Mismo patrón de bug de contenido cruzado ya
documentado para Engine/Gateway en
[[ado-buklo-microservice-engine-2026-08-27]]. Reportado al usuario, no
tocado — la tarea era estrictamente "solo el nombre de BD", y este Build
no tiene esa clave de todos modos.

## Bug real encontrado armando esto: retipear texto ya mojibake corrompe un nivel más

Al escribir a mano (vía `Write`) el YAML completo de Build 592 (Hacienda)
para el `fileContent` del splice, copié visualmente el texto ya
mojibake-corrompido preexistente en el dato real (`ProducciÃ³n`,
`â€”` — UTF-8 mal reinterpretado como Latin-1, ya presente en Azure DevOps,
no introducido por mí) desde la salida de `Read`. El archivo resultante
quedó con un NIVEL ADICIONAL de mojibake (`ProducciÃƒÂ³n`, `Ã¢â‚¬â€`,
`aÃºn` en vez de `aún`) — confirmado comparando contra el GET fresco
re-leído. La causa exacta (dónde se reencodeó) no se aisló, pero el
patrón es claro: cualquier secuencia de bytes ya "rara" (multi-byte
mojibake) retipeada a mano por el LLM en un parámetro de tool grande
corre riesgo real de una re-codificación adicional silenciosa — a
diferencia de un único carácter UTF-8 bien formado (ej. "—" propio, que
si sobrevivió intacto en 585/586/587).

**Solución aplicada y ahora preferida para este tipo de tarea**: nunca
retipear/copiar a mano contenido largo con caracteres no-ASCII (mojibake
o no) desde la salida de `Read` hacia un nuevo archivo. En su lugar,
extraer el valor JSON-string EXACTO (bytes intactos, con su escaping JSON
ya existente) directamente del archivo crudo descargado, vía `sed`/`grep`
(Bash — no PowerShell, no reimplementar el parseo JSON a mano), y aplicar
la única sustitución real (el token base64, puro ASCII) con un `sed`
adicional anclado al nombre de la clave (`CLAVE: valorViejo` →
`CLAVE: valorNuevo`) — nunca anclado a un `\n` literal de 2 caracteres
sin escapar el backslash correctamente en el patrón sed (primer intento
fallido: 0 coincidencias). Verificado con un diff "reversa la sustitución
y compara contra el original" para las 10 builds — bytes idénticos salvo
el cambio buscado. Aplicado retroactivamente también a 585/586/587 (que
habían pasado la verificación puntual de la clave, pero no una
verificación de fidelidad byte a byte del resto del archivo) por
consistencia y para no dejar ese riesgo sin cubrir en ningún build de este
lote, aunque no mostraban mojibake visible.

**Regla derivada para el futuro**: para cualquier edición de
`fileContent`/YAML grande de un File Creator existente, preferir SIEMPRE
extracción `sed`/`grep` desde el GET crudo + sustitución quirúrgica del
token exacto, en vez de reproducir el contenido completo a mano en un
`Write`/`Edit`, incluso si ya se verificó visualmente que "se ve bien" —
la verificación visual no detecta un nivel extra de mojibake en texto que
ya era mojibake de origen.

## Gap real de `Test-AdoClassicPlan.ps1` con el que no contaba

Un plan `standalone-build` puramente `update-build-definition` (sin
ningún `create-*`) SIGUE exigiendo `-InventoryPath` con un inventario
completo y fresco para validar sin bloqueantes — el bloqueante "NOT_
VERIFIED: Variable Group/Build/Release destino no duplicado" se dispara
de forma incondicional cuando no hay inventario, ANTES de que el código
llegue a la rama `isUpdateOnlyPlan` que omitiría ese chequeo (esa rama
solo aplica dentro del bloque `if ($inventory)`). Mi lectura inicial del
código asumió que un update-only sin create-* podía validar sin
inventario — incorrecto. Siempre pasar `-InventoryPath` (fresco,
`Export-AdoClassicInventory.ps1 -Project DevOps`) incluso para un plan
que sabés que es update-only.

## Bug real #2, más grave, encontrado por el coordinador en el primer Apply real: `bodyHash` no coincidía con el body

El primer `Apply-AdoClassicPlan.ps1` real (Build 585) fue rechazado por
`Invoke-AdoRest.ps1` con "el bodyHash aprobado no coincide con el body
solicitado" — rechazo pre-flight, seguro, cero escritura. Causa raíz
confirmada empíricamente (no por lectura de código sola): en
`Invoke-AdoClassicUpdatePlanGeneration`
(`New-AdoClassicUpdatePayload.ps1`), el `bodyHash` de `approvedOperations`
se calculaba con `Get-AdoBodyCanonicalHash` sobre `$currentTarget` (el
objeto en memoria, resultado de GET→`ConvertTo-AdoUpdateBuildBody`→
splice, NUNCA releído de disco), mientras que `Apply-AdoClassicPlan.ps1`
(vía `Invoke-AdoApplyPhases`) reconstruye el body para la escritura real
con `Get-Content -LiteralPath $UpdateBuildBodyPath -Raw | ConvertFrom-Json`
— es decir, RELEYENDO EL ARCHIVO YA ESCRITO EN DISCO. Un primer intento de
fix (reparsear el mismo string en memoria sin tocar disco) dio el MISMO
hash que antes — descartado, no reproducía la diferencia real. El fix que
sí reprodujo EXACTO el hash independiente que había calculado el
coordinador fue: escribir a disco primero, y depués **releer ese mismo
archivo desde disco** (mismo `Get-Content` sin `-Encoding`, mismo método
que usa Apply-time) para calcular `approvedOperations`. Confirmado
carácter por carácter contra el cálculo manual del coordinador.

**No se identificó el mecanismo exacto** (no es truncamiento por `-Depth`
— la profundidad real del objeto es ~8-9, muy por debajo del límite de
20; tampoco es corrupción de encoding — el em-dash sobrevivió byte a byte
en ambos casos, confirmado con `xxd`). Sea cual sea el mecanismo interno
preciso de por qué `ConvertTo-Json`/`ConvertFrom-Json` no es perfectamente
idempotente para este grafo de objeto en PowerShell 5.1, la solución
estructural (hashear siempre el resultado de la MISMA lectura de disco
que hará Apply-time, nunca el objeto en memoria previo a escribir) elimina
la clase entera de riesgo sin necesitar entender el mecanismo exacto.

**Corregido en el archivo fuente compartido**
(`New-AdoClassicUpdatePayload.ps1`, función
`Invoke-AdoClassicUpdatePlanGeneration`) — protege TODO uso futuro de
`New-AdoClassicUpdatePlan.ps1`, tanto `-Kind Build` como `-Kind Release`
(misma función, mismo patrón, un solo fix cubre ambos). Ver
[[patterns]] y [[debugging]] para el detalle técnico completo del fix.

**Alcance más amplio, reportado aparte al coordinador**: este mecanismo
vulnerable (escribir body completo a un JSON, hashear el objeto en
memoria ANTES de esa escritura, y que Apply-time relea ese archivo desde
cero) es el que usaron los 7 microservicios Buklo previos
(Gateway/Auth/Engine/Notifications/Storage/AI/Billing) cada vez que
aplicaron un `update-build-definition`/`update-release-definition` real
desde que ese mecanismo se agregó (2026-08-25/27) — en teoría, cualquiera
de esos Apply reales podría haber tenido el mismo riesgo latente. En la
práctica, todos esos Apply SÍ tuvieron éxito (memoria los marca "DONE"/
"verificado end-to-end"), así que el problema no se manifestó ahí — pero,
importante como tranquilidad: aun si se hubiera manifestado, el diseño
de `Invoke-AdoRest.ps1` (rechazo pre-flight por `bodyHash` no coincidente)
NUNCA permite que un body incorrecto se escriba silenciosamente — el peor
caso posible de este bug de clase es un falso rechazo (bloquea un update
válido), nunca una corrupción real aplicada. La familia `create-*` (Build/
Release nuevos, `New-AdoBuildDefinitionPayload` con
`-DeploymentDevYamlPath`/etc.) usa un patrón ESTRUCTURALMENTE DISTINTO —
tanto la generación del plan como `Apply-AdoClassicPlan.ps1` reconstruyen
el payload FRESCO desde los mismos archivos YAML de texto cada vez, sin
un paso intermedio de "serializar body completo → releer ese mismo
archivo" — así que no comparte este mecanismo vulnerable específico (no
confirmado con el mismo nivel de prueba empírica que el flujo update-*,
pero la asimetría que causa el bug simplemente no existe ahí).

## Bug real #3: TF20507, caracteres de control C1 inválidos enviados a Azure DevOps — mismo patrón, otra lectura sin `-Encoding`

Con el bodyHash ya corregido (bug #2), el primer Apply real (Build 585)
avanzó hasta el servidor y fue rechazado por Azure DevOps mismo (HTTP 400,
`TF20507: The string argument contains a character that is not valid:
'u0090' ... filecontent`) — sin escritura, error del propio API, no del
pre-flight local. El coordinador localizó el caracter en un comentario
banner (`# ═══...`, box-drawing) de OTRO step del mismo Build (`File
Creator dockerfile`, nunca tocado por el splice de este batch) y confirmó
que NO existía en el GET crudo original.

**Causa**: la MISMA clase de bug que #2, en una lectura DISTINTA —
`Get-Content -LiteralPath $UpdateBuildBodyPath -Raw | ConvertFrom-Json`
dentro de `Invoke-AdoApplyPhases` (`New-AdoClassicPayloads.ps1`, la
lectura REAL que usa `Apply-AdoClassicPlan.ps1` para construir el PUT que
se envía), sin `-Encoding UTF8`. El archivo en disco (`body-585.json`)
estaba bien — confirmado con inspección de bytes crudos (`xxd`): la
secuencia UTF-8 real `e2 95 90` (═, U+2550) estaba intacta en el archivo,
tanto antes como después de este fix. La corrupción ocurre AL LEER, no al
escribir — Windows PowerShell 5.1 sin `-Encoding` explícito usa el
codepage ANSI del sistema; los bytes 0x90/0x9D (parte de secuencias UTF-8
multibyte válidas, ej. continuation bytes de ═ o del em-dash) no tienen
mapeo en cp1252 y se reinterpretan directo como los caracteres de control
C1 U+0090/U+009D — inválidos para el API de Azure DevOps.

Corregido: se agregó `-Encoding UTF8` a **todos** los `Get-Content
-LiteralPath` de ambos archivos fuente (`New-AdoClassicPayloads.ps1` y
`New-AdoClassicUpdatePayload.ps1`) que antes no lo tenían — 9 puntos en
total, incluyendo los 2 críticos de apply-time
(`$UpdateBuildBodyPath`/`$UpdateReleaseBodyPath`), mi propia
lectura-de-verificación del bug #2 (`$OutBodyPath`), la lectura del
splice-spec (`$SpliceSpecPath`), `-FileContentPath`, `-ExistingPlanPath`,
el journal, y los 3 manifiestos YAML de la familia `create-*`
(`$DeploymentDevYamlPath`/`UatYamlPath`/`ProdYamlPath`) y
`$ReleaseEnvironmentsPath` — cubiertos por prevención aunque no se probó
que ya hubieran fallado.

**Verificación en 3 capas para los 10** (585/586/587/589/590/591/592/595/
596/621), todas en verde:
a. Escaneo del `body-<id>.json` completo por rango Unicode U+0080-U+009F
   (`grep -aP '[\x{0080}-\x{009F}]'`) — 0 coincidencias en los 10; además
   validación independiente de UTF-8 bien formado con `iconv -f UTF-8 -t
   UTF-8` — los 10 "VALID UTF-8".
b. Regeneración independiente (2da corrida, rutas separadas) + diff de
   `bodyHash` — idéntico en los 10 (valores DISTINTOS de la corrida
   anterior al fix, como se esperaba: antes se hasheaba contenido
   corrupto, ahora contenido correcto).
c. Diff "revertir el cambio de BD y comparar contra el GET crudo
   original" del `fileContent` completo del step UAT — IDENTICAL en los
   10.

**Patrón para recordar**: cualquier `Get-Content -Raw` sobre un archivo
UTF-8 sin BOM en Windows PowerShell 5.1, sin `-Encoding UTF8` explícito,
es una fuente real y repetible de corrupción silenciosa — no un caso
aislado. Ya van 3 bugs reales de esta MISMA familia en este dominio
(`Invoke-AdoRest.ps1` request body 2026-08-26; este mismo día, primero el
bodyHash y después esto). Cualquier script nuevo o modificado en esta
skill que lea un archivo de texto/JSON con contenido potencialmente no-
ASCII DEBE llevar `-Encoding UTF8` explícito en el `Get-Content` — nunca
confiar en el default.

## Enlaces

- [[patterns]]
- [[debugging]]
