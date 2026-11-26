# Hallazgo: buklo_lab dejó de compilar después del Schema Sync

Fecha de la revisión: 2026-09-29  
Repositorio: `project_sqldb_buklo_lab` (Azure DevOps, proyecto Database-Administration-and-Monitoring)  
Base: `buklo_lab` en `gmon-prod-sqlmi-eastus2-0001`  
Flujo: Schema Sync Multi-BD (orquestador), `ScHmSyNcOrCh0001`  
URL: http://172.16.2.60:5678/workflow/ScHmSyNcOrCh0001

Las horas de este documento están en Costa Rica (UTC-6), salvo donde se indique UTC.

## Conclusión

`d2b24da6` compiló y se publicó porque `pace.fn_facility_occupancy_stats` y `pace.cat_pace_forecast` no estaban en el `<Build Include>` del `.sqlproj`. Esos objetos ya existían en la base y los `.sql` ya estaban en el repo.

El orquestador no los escribió en la base. En `32b461ad` solo volvió a engancharlos al proyecto. A partir de ese commit SSDT sí los compila, y la función falla con `SQL71501` porque su cuerpo sigue usando columnas que la base ya no tiene.

El segundo commit del sync, `941fc98a`, no provocó ese error. Solo reformateó las tablas de lista de precios.

## Qué hace el sync con la base

El schema-sync corre en modo solo lectura:

- `ApplicationIntent=ReadOnly`
- SqlPackage solo con `/Action:Extract`

No publica ni altera objetos en `buklo_lab`. Compara el extract de la instancia contra el proyecto SSDT, actualiza scripts en el repo y hace commit a `main` si hay diferencia.

Por eso “aplicado” aquí significa “incluido otra vez en el build del repo”, no “desplegado a la base por el sync”.

## Por qué no entraban al build

En un proyecto SSDT el build y el publish toman únicamente lo que está en `sqldb_buklo_lab.sqlproj` como `<Build Include>`. Un `.sql` puede estar en la carpeta del repo y quedar fuera de la compilación si esa línea no existe.

Eso pasaba en `d2b24da6` con estos dos archivos:

- `pace/Functions/fn_facility_occupancy_stats.sql`
- `pace/Tables/cat_pace_forecast.sql`

El contenido de ambos archivos es idéntico antes y después del sync. El commit del bot no les cambió ni un byte. Solo agregó las dos líneas de `Include`.

## Cuándo se les quitó el Include

| Commit | Momento | Include de los dos archivos |
|---|---|---|
| `dc899e2f` | 28 sep, padre de la limpieza | Sí estaban |
| `3a608ba4` | 28 sep 16:17. `fix(TKS-39832): limpieza del esquema pace en release previo a reestructuracion` | Se quitaron |
| `bf8af4f4` | Merge del PR 13925 (TKS-39832) | Siguen fuera |
| `311ac2dd` | 28 sep 18:13. Reestructuración TKS-39918 | Siguen fuera |
| `d2b24da6` | 29 sep 11:56. Merge PR 13944, BUG-19474 | Siguen fuera |
| `32b461ad` | 29 sep 16:42. schema-sync-bot | Se volvieron a agregar |

La limpieza del 28 de septiembre sacó los objetos del proyecto y dejó los archivos en disco. Los commits posteriores, incluido el que compiló bien, heredaron el `.sqlproj` sin esas dos líneas.

Última vez que cambió el contenido de cada archivo (no el Include):

- `fn_facility_occupancy_stats.sql`: `b376ef52`, 14 jul 2026, BUG-21214
- `cat_pace_forecast.sql`: `23af73b1`, 24 jun 2026, version producción

Esos objetos se publicaron cuando todavía formaban parte del proyecto. `d2b24da6` no los creó ni los borró: publicó un proyecto que ya no los incluía, y en la instancia siguieron existiendo.

## Por qué siguieron en la base si el repo es la fuente

Quitar el `<Build Include>` saca el objeto del dacpac. El publish de `d2b24da6` comparó ese dacpac contra `buklo_lab` y aplicó lo que el proyecto sí trae (en ese commit, el cambio de `pa_con_tra_profile`). Sobre la función y `cat_pace_forecast` el dacpac no dice nada: ni `CREATE`, ni `ALTER`, ni `DROP`.

El build que compiló `d2b24da6` es el 647, `Build_Base_Datos_sqldb_buklo_lab`, en el proyecto DevOps. La corrida `20260929.2` (build 23510) salió bien el 29 sep a las 12:01, rama `release`, commit `d2b24da6`. Ese pipeline solo compila el `.sqlproj` con MSBuild (`/p:BlockOnPossibleDataLoss=false`) y copia el `.dacpac` a `\\172.16.2.127\Publicados\...`. No ejecuta SqlPackage contra la base.

El despliegue a la instancia lo hace el release `Deploy-Desarrollo-UAT-Produccion-Base_Datos_sqldb_buklo_lab` (definición 403). El Release-23 (id 7684) tomó ese artefacto `20260929.2` y la etapa Producción terminó en éxito. Desarrollo de ese release no está habilitado y UAT no corrió.

La etapa usa el grupo de tareas `Deployment-DataBases`. El paso “Deploy using : dacpac” publica con estos argumentos:

```text
/p:DropObjectsNotInSource=False
/p:BlockOnPossibleDataLoss=False
/p:ExcludeObjectTypes=Users;RoleMembership;Permissions
/p:IgnorePermissions=True
/p:IgnoreRoleMembership=True
```

`DropObjectsNotInSource=False` está escrito en el release, no es solo el defecto de la herramienta. Por eso el publish de `d2b24da6` creó y modificó lo que venía en el dacpac, y dejó en `buklo_lab` la función y `cat_pace_forecast`, que ya no estaban en el proyecto.

## Los tres commits del 29 de septiembre

### 1. `d2b24da6` — 11:56 — Jose Alberto Guevara Morales

SHA: `d2b24da66603e30f037d37e64fc92fe39bc4ef84`  
Mensaje: Merged PR 13944: BUG-19474: corregir buscador general de perfiles medicos (query dinamico)

Un solo archivo de código:

- `directory/Stored Procedures/pa_con_tra_profile.sql`

No tocó `pace` ni el `.sqlproj`. El proyecto compiló y se publicó. SSDT no validó la función de ocupación porque no estaba en el `Include`.

### 2. `32b461ad` — 16:42 — schema-sync-bot

SHA: `32b461ad58c2859d5f332114e40bbef69381620e`  
Mensaje: `chore(schema): sync buklo_lab from SQL MI [2026-09-29 22:42:33 UTC]`

Este es el commit que rompe la compilación.

Cambio que afecta al build, en `sqldb_buklo_lab.sqlproj`:

```xml
<Build Include="pace\Functions\fn_facility_occupancy_stats.sql" />
<Build Include="pace\Tables\cat_pace_forecast.sql" />
```

También quitó cuatro líneas en blanco del `.sqlproj`, entre los scripts de `inventory` y `navigate_ui`. Eso no cambia el conjunto de objetos compilados.

El resto de ediciones de procedimientos, comparado ignorando fines de línea, es cosmético: se quitó el BOM `UTF-8`, se quitó la línea en blanco que había antes del `CREATE`, y en `pa_con_cat_filters.sql` cambió la indentación de un `CREATE TABLE #table_valid_facilities_by_filter`. La lógica de esos procedimientos no cambió.

`directory/Stored Procedures/pa_con_tra_profile.sql` (el arreglo de las 11:56) solo perdió esa línea en blanco. El cambio del BUG-19474 sigue en el archivo. Además el sync normalizó el archivo a CRLF.

Excepción de esquema en este commit: `pace/Tables/tra_price_list.sql` y `pace/Tables/tra_price_list_hst.sql`. El script ya tenía un `DEFAULT` en la columna `active` y el sync le antepuso el constraint que venía del extract. Quedó duplicado, por ejemplo:

```sql
[active] SMALLINT CONSTRAINT [DF_tra_price_list_active] DEFAULT ((1)) NOT NULL
         CONSTRAINT DF_tra_price_list_active DEFAULT (1),
```

Ese defecto lo corrige el commit siguiente. No es el `SQL71501` de la función.

Archivos borrados en este commit. No estaban en el `<Build Include>`, así que no formaban parte del build que compiló a las 11:56. Eran scripts huérfanos en la carpeta, varios con el sufijo `jalfaro_eliminar_20260519`:

- `pace/Stored Procedures/usp_build_elasticsearch_payload_jalfaro_eliminar_20260519.sql`
- `pace/Stored Procedures/usp_capacity_upsert_jalfaro_eliminar_20260519.sql`
- `pace/Stored Procedures/usp_occupancy_snapshot_refresh_jalfaro_eliminar_20260519.sql`
- `pace/Stored Procedures/usp_occupancy_snapshot_refresh_usage_jalfaro_eliminar_20260519.sql`
- `pace/Tables/blue_facility_mapping_jalfaro_eliminar_20260519.sql`
- `pace/Tables/capacity_category_jalfaro_eliminar_20260519.sql`
- `pace/Tables/capacity_jalfaro_eliminar_20260519.sql`
- `pace/Tables/capacity_type_jalfaro_eliminar_20260519.sql`
- `pace/Tables/cat_capacity_category.sql`
- `pace/Tables/cat_capacity_type.sql`
- `pace/Tables/facility_group_jalfaro_eliminar_20260519.sql`
- `pace/Tables/facility_group_member_jalfaro_eliminar_20260519.sql`
- `pace/Tables/occupancy_snapshot_jalfaro_eliminar_20260519.sql`
- `pace/Tables/pace_forecast_jalfaro_eliminar_20260519.sql`
- `pace/Tables/tra_blue_facility_mapping.sql`
- `pace/Tables/tra_occupancy_snapshot.sql`
- `pace/Tables/tra_user_facility_scope.sql`
- `pace/Tables/user_facility_scope_jalfaro_eliminar_20260519.sql`
- `pace/Tables/user_group_scope_jalfaro_eliminar_20260519.sql`
- `pace/Tables/visit_category_jalfaro_eliminar_20260519.sql`

### 3. `941fc98a` — 16:48 — schema-sync-bot

SHA: `941fc98a5509284a98a4a8a3353860be11de8d23`  
Mensaje: `chore(schema): sync sqldb_buklo_lab from SQL MI (repo_sync read-only) [2026-09-29 16:48 -06 / 2026-09-29 22:48:33 UTC]`  
PR abierto por el bot: [13973](https://dev.azure.com/Shared-Service-GM/Database-Administration-and-Monitoring/_git/project_sqldb_buklo_lab/pullrequest/13973)

El `.sqlproj` de este commit es idéntico al de `32b461ad` (mismo hash). La función sigue incluida.

Solo cambian dos archivos, sin cambio de columnas:

- `pace/Tables/tra_price_list.sql`
- `pace/Tables/tra_price_list_hst.sql`

El sync reescribió el `CREATE TABLE` con el formato de SSDT y separó el `DEFAULT` y la llave primaria en `ALTER TABLE`. Con eso desaparece el `DEFAULT` duplicado del commit anterior. El trigger que ya estaba al final de `tra_price_list.sql` se conservó.

La validación DacFx de esta corrida falló igual, porque el proyecto ya incluía la función desde `32b461ad`.

## Error de compilación

`SQL71501` sobre `[pace].[fn_facility_occupancy_stats]`.

La función no está ligada al esquema (`schema bound`). SQL Server la deja creada aunque el cuerpo ya no coincida con las tablas, y falla cuando se ejecuta. SSDT arma el modelo completo y rechaza la referencia.

El cuerpo pide nombres viejos. Las tablas, en el repo y en la base, tienen los nombres nuevos del cambio TKS-21827 (28 jul 2026):

| La función usa | La tabla tiene |
|---|---|
| `pace.cat_provider.blue_id` | `id_blue` |
| `pace.cat_provider.cat_provider_id` | `id` |
| `pace.cat_provider.cat_company_id` | `id_cat_company` |
| `pace.cat_scope_by_capacity_type.cat_facility_id` | `id_cat_facility` |
| `pace.cat_scope_by_capacity_type.cat_provider_id` | `id_cat_provider` |

Ese desfase ya estaba en el archivo de la función desde antes del 29 de septiembre. No lo introdujo el diff de procedimientos del sync. Aparece ahora porque el `Include` hace que el build lo valide.

`cat_pace_forecast` también volvió al proyecto. El error reportado por el sync no fue esa tabla; fue la función.

## Confirmación en la base, solo lectura

Se usó el dacpac del extract de SqlPackage guardado en el host del schema-sync:

`/home/soporte/schema-sync/work/project_sqldb_buklo_lab/out/sqldb_buklo_lab/db.dacpac`  
Fecha del extract: 29 sep 2026, 19:01 hora de Costa Rica (30 sep 01:01 UTC).  
Tamaño: 4 465 134 bytes.

Ese extract es el mismo modo del sync: lectura, sin publish. En `model.xml` la instancia tiene:

| Objeto | Tipo en el modelo |
|---|---|
| `[pace].[fn_facility_occupancy_stats]` | `SqlMultiStatementTableValuedFunction` |
| `[pace].[cat_pace_forecast]` | `SqlTable` |
| `[pace].[cat_provider]` | `SqlTable` |
| `[pace].[cat_scope_by_capacity_type]` | `SqlTable` |

Columnas presentes como `SqlSimpleColumn`:

- `[pace].[cat_provider].[id]`
- `[pace].[cat_provider].[id_blue]`
- `[pace].[cat_provider].[id_cat_company]`
- `[pace].[cat_scope_by_capacity_type].[id_cat_facility]`
- `[pace].[cat_scope_by_capacity_type].[id_cat_provider]`

No existen como columna:

- `[pace].[cat_provider].[blue_id]`
- `[pace].[cat_provider].[cat_provider_id]`
- `[pace].[cat_provider].[cat_company_id]`
- `[pace].[cat_scope_by_capacity_type].[cat_facility_id]`
- `[pace].[cat_scope_by_capacity_type].[cat_provider_id]`

El sync debía volver a ponerlos en el `Include`: los dos objetos están en `buklo_lab` y los scripts ya estaban en el repo. Dejarlos fuera hacía que `d2b24da6` compilara, y a la vez el proyecto no reflejaba la instancia.

## Corrida del orquestador que dejó estos commits

Ejecución n8n `2526010`, manual, 29 sep 16:43 a 17:08. n8n la marca en éxito porque el flujo termina y notifica. El resultado de `buklo_lab` dentro de esa corrida fue error de validación SSDT, con drift ya commiteado en `main` (`941fc98`) y PR 13973.

En el log de esa corrida el extract de `buklo_lab` conectó en solo lectura, detectó drift, actualizó scripts y empujó `main`. Después DacFx validó el proyecto y falló en la función.

## Qué no explica el fallo

- El BUG-19474 de las 11:56 no tocó `pace`.
- Los procedimientos de `pace` no fueron reescritos con otra lógica. El cambio real de esos archivos es formato.
- Los 20 scripts borrados no estaban en el build.
- `941fc98a` no movió el `.sqlproj`.

## Estado al cerrar esta nota

`main` incluye la función y `cat_pace_forecast`. El proyecto no compila mientras `fn_facility_occupancy_stats` siga referenciando las columnas viejas. La base sigue teniendo la función y la tabla. El sync, en la próxima corrida, va a seguir viéndolos en la instancia.
