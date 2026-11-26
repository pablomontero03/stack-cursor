# Hallazgo: sqldb_core_global y sqldb_core_workflow dejaron de compilar después del Schema Sync

Fecha de la revisión: 2026-09-30  
Repositorio: `project-qldb_core_workflow-sqldb_core_global` (Azure DevOps, proyecto Database-Administration-and-Monitoring)  
URL: https://dev.azure.com/Shared-Service-GM/Database-Administration-and-Monitoring/_git/project-qldb_core_workflow-sqldb_core_global  
Copia local: `C:\code\BaseDatos\project-qldb_core_workflow-sqldb_core_global\databases`  
Flujo: Schema Sync Multi-BD (orquestador), `ScHmSyNcOrCh0001`  
URL del flujo: http://172.16.2.60:5678/workflow/ScHmSyNcOrCh0001

Las horas de este documento están en Costa Rica (UTC-6), salvo donde se indique UTC.

Se revisó `origin/main` en `753d007`. La compilación fue MSBuild de los dos `.sqlproj` (`sqldb_core_global` y `sqldb_core_workflow`), con salida limitada a errores. El checkout de trabajo no se modificó.

Actualización del mismo día: los fixes se aplicaron en la herramienta de schema-sync, no editando `main` a mano. El sync volvió a correr solo con estas dos bases y sanó el árbol. La corrida de cierre, `2537744` (14:23–14:25), compiló bien y no tuvo drift. `main` quedó en `070ec23`. El detalle está en [Correcciones aplicadas](#correcciones-aplicadas).

## Conclusión

`release` compila. `main` no, por dos commits de `schema-sync-bot` del 30 de septiembre. Esos commits no están en `release`.

El mensaje de ambos dice `sync OpsObservability from SQL MI`. Los archivos que cambiaron son de este repositorio, no de OpsObservability.

| Commit | Momento | Base que tocó |
|---|---|---|
| `370143fc4d5e9bbbccd34aad0c3bfb6592701e9e` | 30 sep 10:58 (16:58 UTC) | `sqldb_core_global` |
| `753d0076716fe717dfe1e9117273f992c8e29f97` | 30 sep 11:50 (17:50 UTC) | `sqldb_core_workflow` |

El padre de `370143f` es `5fde5b0f8c5915201b849e668d4ed26224653302`, merge del PR 13981, “version produccion 28 sept 2026”, 30 sep 08:43 (14:43 UTC).

`main` no quedó igual a `release`. Además del sync, las ramas ya iban separadas:

- En `main` y no en `release`: `5fde5b0` (PR 13981) y los dos commits del bot.
- En `release` y no en `main`: `f2daa0f` y su merge `4d4c174` (PR 13979, 30 sep 09:00 / 15:00 UTC). Ese fix limita el envío automático al INS a casos desde el 30 de septiembre de 2026. La punta de `release` es `4d4c174`.

El sync no reescribió `release`. `release` sigue compilando porque no tiene `370143f` ni `753d007`.

## Qué hace el sync con la base

El schema-sync corre en modo solo lectura: `ApplicationIntent=ReadOnly` y SqlPackage solo con `/Action:Extract`. No publica a la instancia. Compara el extract contra el proyecto SSDT, actualiza scripts en el repo y hace commit a `main`.

En un proyecto SSDT el build toma únicamente lo que está como `<Build Include>`. Un script en `<None Include>` está en disco y no entra al dacpac.

## Compilación de origin/main

Al compilar `753d007` completo, `sqldb_core_global` falla y `sqldb_core_workflow` falla con los mismos errores, porque el segundo proyecto referencia al primero. El build de global reportó 3 errores:

- `SQL71508`: el modelo ya tiene un elemento con el mismo nombre `RegExValidator`. El ensamblado sale dos veces: `obj\PROY_REGEXVALIDATOR.generated.sql` (generado desde el DLL) y `Assemblies\RegExValidator.sql` (script que el sync metió al build).
- `SQL71501`: `utility.fn_validate_regex` queda con el ensamblado `RegExValidator` sin resolver.

Para ver los errores propios de workflow se volvió a compilar con el `.sqlproj` de global en el estado previo al sync (`5fde5b0`). Global salió con 0 errores. Workflow, ya con `753d007`, salió con 350 errores y 6659 advertencias:

- 4 `SQL71508`: esquemas `external` y `aseguradora` duplicados.
- 346 `SQL71561`: referencias sin resolver en `workflow.fn_get_workflow_requirement_advance` hacia `[sqldb_core_global]`.

## Commit 370143f: sqldb_core_global

48 archivos. Casi todo el volumen es refresco de scripts (saltos de línea y formato). El `.sqlproj` cambió 9 inserciones. Lo que rompe el build es estructural.

El proyecto ya referencia tres DLL, con `GenerateSqlClrDdl=False`:

| Referencia | DLL | Nombre del ensamblado |
|---|---|---|
| `Proy_RegExValidator` | `Assemblies\Proy_RegExValidator.dll` | `RegExValidator` |
| `CLRSQLRegexLibrary` | `Assemblies\CLRSQLRegexLibrary.dll` | `CLRSQLRegexLibrary` |
| `sql.common` | `Assemblies\sql.common.dll` | `sql.common` |

Con `GenerateSqlClrDdl=False` el build emite el `CREATE ASSEMBLY` a partir del DLL (`obj\PROY_REGEXVALIDATOR.generated.sql`). No hace falta un script `.sql` de ensamblado en el `<Build Include>`.

El sync agregó estos scripts nuevos y los enganchó al build:

- `Assemblies\RegExValidator.sql` (`CREATE ASSEMBLY [RegExValidator]`)
- `Assemblies\CLRSQLRegexLibrary.sql`
- `Assemblies\sql.common.sql`

`RegExValidator.sql` y el SQL generado desde `Proy_RegExValidator.dll` declaran el mismo ensamblado. SSDT responde `SQL71508`. A partir de ahí `fn_validate_regex` no puede enlazar el ensamblado (`SQL71501`).

También pasó de `<None Include>` a `<Build Include>`:

- `dbo\Functions\IsRegexMatch.sql`
- `dbo\Functions\ExtractMatch.sql`

En `5fde5b0` esas funciones no se compilaban. Si se quitan del build los tres scripts `CREATE ASSEMBLY` y se dejan las funciones en `<Build Include>`, el siguiente error es `SQL71501`: `IsRegexMatch` y `ExtractMatch` no resuelven `CLRSQLRegexLibrary`, porque la referencia del DLL no emite el `CREATE ASSEMBLY`.

El mismo commit agregó al build tres tablas de respaldo, objetos distintos de `replicator.cat_data_origin`:

- `replicator\Tables\cat_data_origin_BKP_20260623.sql`
- `replicator\Tables\cat_data_origin_BKP_20260625.sql`
- `replicator\Tables\cat_data_origin_BK_20260707.sql`

Esos tres no aparecen en los 3 errores del build de `753d007`. El fallo de global es el ensamblado duplicado.

## Commit 753d007: sqldb_core_workflow

112 archivos. El volumen grande es refresco de procedimientos y de `tra_workflow`. Lo que impide compilar son dos cambios del proyecto.

### Esquemas duplicados

`external_1.sql` y `aseguradora_1.sql` ya estaban en `<Build Include>` y crean el esquema:

```sql
CREATE SCHEMA [external]
CREATE SCHEMA [aseguradora]
```

`Security\external.sql` y `Security\aseguradora.sql` crean los mismos esquemas y estaban en `<None Include>`. El sync los pasó a `<Build Include>`. SSDT compila el esquema dos veces:

- `SQL71508` en `Security\external.sql` y `Security\external_1.sql`, nombre `external`
- `SQL71508` en `Security\aseguradora.sql` y `Security\aseguradora_1.sql`, nombre `aseguradora`

El mismo commit pasó de `None` a `Build` los scripts de usuarios (`usr_dev_*`, `usr_app_*`, `usr_data`, `usr_etl_datafwk`, `usr_prtg_alert`, `usr_prueba`) y `Security\RoleMemberships.sql`. Esos scripts no agregaron códigos de error en el build de 350 errores. Los usuarios se crean con `CREATE USER ... WITHOUT LOGIN`.

### Variable SQLCMD reemplazada por el nombre de la base

La referencia cruzada del proyecto es `[$(sqldb_core_global)]`. SSDT la resuelve con la referencia al otro `.sqlproj`. El nombre fijo `[sqldb_core_global]` no pasa por esa referencia y el build lo marca `SQL71561`.

En `workflow\Functions\fn_get_workflow_requirement_advance.sql` el sync sustituyó las 56 apariciones. Ejemplo real del diff entre `5fde5b0` y `origin/main`:

```sql
-- antes
FROM [$(sqldb_core_global)].workflow.cat_workflow_requirement_stage AS M
    INNER JOIN [$(sqldb_core_global)].workflow.cat_workflow_requirement AS D

-- después
FROM [sqldb_core_global].workflow.cat_workflow_requirement_stage AS M
    INNER JOIN [sqldb_core_global].workflow.cat_workflow_requirement AS D
```

En `origin/release` ese archivo sigue con las 56 variables. Por eso `release` no produce estos `SQL71561`.

El build aislado de workflow reportó las 346 `SQL71561` solo en esta función. Los objetos que no resuelve son, entre otros, `[sqldb_core_global].[workflow].[cat_workflow_requirement_stage]` y `[sqldb_core_global].[workflow].[cat_workflow_requirement]`.

Antes del sync (`5fde5b0` y también `origin/release`) había 10 archivos con `$(sqldb_core_global)`. En `origin/main` quedan 3:

- `utility\Stored Procedures\pa_pro_tra_invoice_header_JMH_BORRAR.sql`
- `utility\Stored Procedures\pa_pro_tra_invoice_hst_JMH_BORRAR.sql`
- `workflow\Tables\tra_workflow.sql`

Perdieron la variable:

| Archivo | Qué pasó |
|---|---|
| `workflow\Functions\fn_get_workflow_requirement_advance.sql` | 56 variables pasaron a `[sqldb_core_global]`. Es el archivo de los 346 `SQL71561`. |
| `utility\Stored Procedures\pa_pro_create_invoices_drivera.sql` | 11 variables pasaron al nombre fijo. |
| `utility\Stored Procedures\pa_pro_status_according_to_related_document.sql` | 12 variables pasaron al nombre fijo. |
| `utility\Stored Procedures\pa_pro_create_user_drivera.sql` | 3 variables pasaron al nombre fijo. |
| `utility\Functions\fn_returns_parameters_final.sql` | 1 variable pasó a `sqldb_core_global` sin corchetes. |
| `utility\Stored Procedures\pa_pro_manual_partial_case.sql` | 5 variables pasaron a `sqldb_core_global` sin corchetes. |
| `external\Stored Procedures\pa_man_tra_invoice_header_jalfaro.sql` | El archivo se borró en este commit. |

### Objetos que el sync sacó del proyecto

El commit borró el `<Build Include>` y el archivo de las tablas y procedimientos `external` de facturas, y de `workflow\Tables\cat_catalog_homologation.sql`:

- `external\Tables\tra_invoice.sql`
- `external\Tables\tra_invoice_header.sql`
- `external\Tables\tra_invoice_detail.sql`
- `external\Tables\tra_invoice_document.sql`
- `external\Tables\tra_invoice_mirror.sql`
- `external\Tables\tra_invoice_header_mirror.sql`
- `external\Tables\tra_invoice_detail_mirror.sql`
- `external\Tables\cfg_hana_invoice_table.sql`
- `external\Stored Procedures\pa_con_tra_invoice_header.sql`
- `external\Stored Procedures\pa_man_tra_invoice_header.sql`
- `external\Stored Procedures\pa_man_tra_invoice_detail.sql`
- `external\Stored Procedures\pa_man_tra_invoice_header_jalfaro.sql`
- `workflow\Tables\cat_catalog_homologation.sql`

Esas bajas no sumaron errores en el build de 350. El fallo de workflow es el esquema duplicado y la variable SQLCMD.

Sacar un objeto del `.sqlproj` lo saca del dacpac. Un publish con `DropObjectsNotInSource=False` no lo borra de la instancia. Este documento no revisó el pipeline de despliegue de estas dos bases.

## Qué no explica el fallo

- `release` no contiene `370143f` ni `753d007`.
- El PR 13979 (envío al INS) está solo en `release` y no es la causa de que `main` no compile.
- El volumen de líneas de los dos commits es en su mayoría refresco de scripts. El build se cae por los `<Build Include>` nuevos de ensamblados y esquemas, y por sustituir `$(sqldb_core_global)`.
- El mensaje `OpsObservability` no corresponde a los archivos de estos dos commits.

## Estado al cerrar el diagnóstico

En este punto `origin/main` (`753d007`) no compilaba las dos bases. `origin/release` (`4d4c174`) no tenía esos commits del bot y conservaba `[$(sqldb_core_global)]` en `fn_get_workflow_requirement_advance`.

El plan, antes de tocar la herramienta, era:

- En `sqldb_core_global`: sacar del `<Build Include>` los tres `CREATE ASSEMBLY` y devolver `IsRegexMatch` y `ExtractMatch` a `<None Include>`, que es como estaban en `5fde5b0`.
- En `sqldb_core_workflow`: devolver `Security\external.sql` y `Security\aseguradora.sql` a `<None Include>`, y restaurar `[$(sqldb_core_global)]` en los scripts donde el sync lo reemplazó.

No se forzó `main` de vuelta a `release`. Ese force habría botado el PR 13981 (`5fde5b0`). Se dejó `main` como estaba para que el siguiente sync demostrara que puede sanar el árbol.

## Por qué el sync hizo dos commits

La publicación a prod del workflow (Release-5, id 7716) salió de `release` `4d4c174`, antes del sync. Global no tuvo release nuevo de prod esa mañana. El cuerpo del procedimiento INS quedó en `753d007` porque el sync lo leyó de la base ya publicada, con una línea en blanco de diferencia respecto a `release`, no porque se mergeara `4d4c174`.

El orquestador no dejó un solo commit porque fueron dos ejecuciones:

- La primera abortó después de global (`SYNC_EXIT=1`) y el wrapper igual commiteó `370143f`.
- La segunda hizo workflow y commiteó `753d007`.

El título decía `OpsObservability` porque, si `DATABASE` no viene seteada, `run-sync.sh` usa ese nombre por defecto. En modo bundle el nombre real es el del bundle. El wrapper de error commiteaba con ese default.

## Correcciones aplicadas

Código de la herramienta: `C:\code\BaseDatos\automation\schema-sync\SchemaSyncTool`. El binario que corre el flujo está en el host del sync, `publish/SchemaSyncTool.dll`. Cada cambio de CLR, de `None` y de variable SQLCMD se publicó solo para este bundle (`core-workflow-global`), con listas explícitas en el JSON del bundle. Una lista vacía deja a las demás bases sin esas reescrituras. Hay tres comportamientos de la herramienta que sí corren en todas las bases; están en [Comportamiento común a las demás bases](#comportamiento-común-a-las-demás-bases).

Durante las pruebas el orquestador quedó con un solo bundle activo, en este orden: `sqldb_core_global`, luego `sqldb_core_workflow`. El catálogo completo no se restauró.

### Ensamblados CLR, solo en sqldb_core_global

`skipClrAssemblies`: `RegExValidator`, `CLRSQLRegexLibrary`, `sql.common`.

El nombre entra en la regla solo si además el `.sqlproj` tiene un `<Reference>` con ese `SqlAssemblyName` y `GenerateSqlClrDdl=False`. La herramienta borra el script `CREATE ASSEMBLY` (no el DLL) y saca del compare las diferencias de ensamblado. Las rutinas CLR que apuntan a ese ensamblado (`fn_validate_regex`, y las funciones `IsRegexMatch` / `ExtractMatch`) se quedan en el proyecto y no vuelven a salir como cambio de compare. `IsRegexMatch` y `ExtractMatch` siguen en `<None Include>` por `keepAsNone`. `fn_validate_regex` sigue en `<Build Include>`. Su cuerpo es `EXTERNAL NAME [RegExValidator].[RegExValidator].[ValidateRegex]`; `sys.sql_modules.definition` es NULL en CLR, así que el refresco de módulo no lo reescribe.

`sqldb_database_maintenance` tiene localmente la misma referencia a `RegExValidator` y no está en el catálogo del orquestador. La regla no se hizo global.

### Esquemas external y aseguradora, solo en sqldb_core_workflow

`keepAsNone`: `Security\external.sql`, `Security\aseguradora.sql`.

Esos dos quedan en `<None Include>` y fuera del compare. `Security\external_1.sql` y `Security\aseguradora_1.sql` siguen siendo el único `CREATE SCHEMA` de cada nombre dentro del build. `external_1.sql` autoriza a `[dbo]`.

### Variable SQLCMD, solo en sqldb_core_workflow

`preserveSqlCmdRefs`: `["sqldb_core_global"]`.

`SqlCmdPreserve` devuelve tanto `[sqldb_core_global]` como `sqldb_core_global.` a `[$(sqldb_core_global)]`, y no toca literales dentro de strings ni comentarios. Comparar después de restaurar la variable hacía que DacFx reportara cambios falsos. El orden que quedó es: refresco de módulos y borrado de huérfanos con el nombre literal, expandir `[$(db)]` a `[db]` justo antes de la comparación final, y restaurar la variable al terminar, en éxito y en fallo. En las demás bases la lista va vacía y preservar o expandir no hace nada.

### No borrar un script solo porque el compare dice Delete

Un `Delete` del compare significa que el proyecto tiene el objeto y el compare no lo vio en el extract. No alcanza para borrar el archivo. El script se borra solo si `schema.name` no está en los nombres de dos partes del `model.xml` del dacpac. Si el extract no se puede leer, no se borra nada. Si el objeto sí está en el extract y hay varios scripts que lo definen, se borra el suelto que no está en el `.sqlproj` y se conserva el que el proyecto ya incluye.

Las tablas y procedimientos `external` de facturas sí están en el dacpac y tenían que volver. `workflow.cat_catalog_homologation` del proyecto workflow no está en el dacpac, y sacarlo del proyecto sigue siendo correcto. Global tiene su propia `workflow\Tables\cat_catalog_homologation.sql`, que se quedó.

### La tabla tra_workflow y sus triggers

`workflow.tr_ai_tra_workflow` y `workflow.tr_au_tra_workflow` viven dentro de `workflow\Tables\tra_workflow.sql`, después de un `GO`. Ese archivo está en el `.sqlproj`. Los `workflow\Triggers\tr_*.sql` sueltos no estaban en git. El refresco de módulo escribía el trigger suelto y, como el regex también ve `CREATE TRIGGER` dentro de la tabla, borraba `tra_workflow.sql`.

La regla que quedó: si otro archivo hace `CREATE TABLE` y además define el mismo trigger, se borra el trigger suelto y se conserva el script de la tabla. Un borrado de trigger no puede borrar un script cuyo `CREATE TABLE` es de otra tabla. Confirmado en lectura contra la instancia: los dos triggers y `external.pa_con_tra_invoice_header` existen. Los triggers tienen fecha de modificación 2026-02-19.

### El wrapper que marcaba éxito y commiteaba como OpsObservability

`accept-dacfx-incongruence.py` aceptaba cualquier mensaje que contuviera “incongruencia” y el commit salía con el database por defecto, `OpsObservability`. Ahora solo acepta cuando todos los esquemas citados en el mensaje son `pace` (el caso conocido de FK circular de DacFx). El título del commit usa el database del resultado. En un bundle, si `DATABASE` no venía seteada, el script del servidor usa el nombre del repo. El `run-sync.sh` del servidor es más largo que la copia local; no se reemplazó el del servidor con la copia corta.

### Validación en Linux, alineada con SSDT

En el host no hay build de Windows. La validación arma un modelo DacFx. Dos ajustes hicieron que ese modelo coincida con lo que SSDT compila:

- Solo entran los `.sql` de `<Build Include>`. Un `<None Include>` queda en disco y fuera del modelo. Cargar `Security\external.sql` junto con `external_1.sql` duplicaba `CREATE SCHEMA [external]` y las tablas de factura quedaban con `SQL71501` de esquema no resuelto, aunque el `.sqlproj` ya estaba bien.
- Un aviso no tumba la corrida. `cat_catalog_homologation.sql` de global produce `SQL70588`: la opción `WITH CHECK` se ignora. SSDT lo deja pasar (`TreatWarningsAsErrors=false`).
- Si el `.sqlproj` tiene un `<Reference>` con `GenerateSqlClrDdl=False`, un `SQL71501` de ensamblado no resuelto para ese `SqlAssemblyName` no cuenta. Es el caso de `utility.fn_validate_regex` y `RegExValidator`: el ensamblado entra por el DLL, no por un script.
- Si un `<ProjectReference>` tiene `SuppressMissingDependenciesErrors=True`, un `SQL71501` o `SQL71561` que cite la variable `$(DatabaseSqlCmdVariable)` no cuenta. En workflow esa variable es `sqldb_core_global`. Un objeto que falte en la misma base sigue siendo error.

## Corridas de prueba

Todas con el catálogo reducido a este bundle.

| Ejecución | Hora | Resultado |
|---|---|---|
| `2536884` | ~40 s | Paró en `Change ScalarFunction [utility].[fn_validate_regex]`. El archivo no había cambiado. Se excluyó del compare la rutina CLR del ensamblado omitido. |
| `2537054` | | Global cerró. Workflow falló la comparación final: se restauraba la variable SQLCMD antes de comparar. |
| `2537217` | | Los procedimientos de factura ya no salían como cambio. Seguían `Change` de `tra_workflow` y `Delete` de los dos triggers. |
| `2537319` | | Mal resultado. El refresco borró `workflow\Tables\tra_workflow.sql` porque también contiene `CREATE TRIGGER`. |
| `2537421` | 13:55–13:57 | La tabla se conservó, se restauró la variable en 57 archivos y se commiteó `22a7603`. PR 13986. La validación falló `SQL71501` de esquema `external` porque todavía cargaba los scripts `None`. |
| `2537584` | 14:09–14:12 | El esquema `external` ya no falló. Commiteó `070ec23` y la validación aún marcó el aviso de `WITH CHECK`, el ensamblado `RegExValidator` y las referencias `$(sqldb_core_global)`. |
| `2537744` | 14:23–14:25 | Éxito. `buildOk=true`, mensaje “Compiló correctamente”. Sin drift. No hubo commit nuevo. Aviso por el canal de éxito. `main` sigue en `070ec23`. |

Commits del sync después del diagnóstico:

| Commit | Momento | Qué dejó |
|---|---|---|
| `22a7603a34683483bc53544e4c5229c1930d299a` | 30 sep 13:56 (19:56 UTC) | Bundle con el nombre real de las dos bases. Volvieron los objetos de factura. `tra_workflow.sql` está en el commit. `external.sql` y `aseguradora.sql` en `None`. PR 13986. |
| `070ec23bc8f99e3c092e02c59881b0be95fd3448` | 30 sep 14:12 (20:12 UTC) | Siguiente sync del mismo bundle, sobre `22a7603`. Es la punta de `main` al cerrar. |

## Comportamiento común a las demás bases

CLR, los scripts `None` de `external` y `aseguradora`, y la variable `$(sqldb_core_global)` no se aplican a otra base. Esas listas van vacías fuera de este bundle, así que el sync no les quita ensamblados, no les baja scripts a `None` y no les toca referencias SQLCMD.

Tres correcciones de la herramienta sí las usan todas las bases. Quedan bien así.

### Borrado de scripts

Un `Delete` del compare ya no borra el archivo por sí solo. El script se borra solo si el objeto no está en el extract. Si el objeto salió de la base y no está en el extract, se elimina igual que antes. Si el compare pide borrarlo pero el extract todavía lo tiene, el script se queda. Si el extract no se puede leer, no se borra nada.

El caso del trigger solo cambia cuando el `CREATE TRIGGER` ya va dentro del script de la tabla: se conserva esa tabla y se quita el archivo suelto. Una base cuyos triggers viven solo en su propio archivo sigue igual.

### Validación en Linux

Compila únicamente los `<Build Include>` y un aviso no detiene el sync. El ensamblado o el `$(variable)` se ignoran solo si el `.sqlproj` de esa base ya lo declara (`GenerateSqlClrDdl=False` o `SuppressMissingDependenciesErrors=True`). Si no lo declara, el error sigue frenando la corrida.

### Incongruencia de esquema

Antes cualquier mensaje con “incongruencia” se daba por bueno y hacía commit, a menudo con el título `OpsObservability`. Ahora eso solo pasa si todos los objetos que quedaron son del esquema `pace`. En cualquier otra base el sync se detiene y no hace commit.

Al volver a activar las demás bases en el orquestador, les aplica esto. Hoy el catálogo sigue reducido a `sqldb_core_global` y `sqldb_core_workflow`.

## Qué se dejó como está

- Las tres tablas de respaldo de global siguen en el build. Son tablas distintas de `replicator.cat_data_origin`, no fueron la causa del fallo: `cat_data_origin_BKP_20260623`, `cat_data_origin_BKP_20260625`, `cat_data_origin_BK_20260707`.
- Los usuarios y `RoleMemberships` que pasaron de `None` a `Build` no produjeron código de error. No se revirtieron.
- El camino que acepta incongruencia solo de esquemas `pace` sigue activo para ese caso conocido.
- El orquestador sigue con solo `sqldb_core_global` y `sqldb_core_workflow` activas.

## Estado al cerrar las correcciones

`main` (`070ec23`) coincide con las dos bases. La validación del flujo, con las mismas reglas que SSDT usa para estos proyectos, compiló bien en la ejecución `2537744`. El checkout local de trabajo no se modificó y el repositorio de la herramienta no se commiteó.
