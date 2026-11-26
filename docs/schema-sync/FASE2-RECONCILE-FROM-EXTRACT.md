# Schema Sync — Fase 2: `main` = BD de prod (Extract + reconciliación)

Estado: en producción desde 2026-11-09, opt-in por base.
Host: `172.16.2.60` (`/home/soporte/schema-sync/`). Copia versionada de los scripts: `schema-sync/host60/`.

## Objetivo

`main` de cada repo SSDT debe quedar **tal cual está la BD de producción**, compile o no.
Si hay diferencias, gana la BD. Los errores nunca se esconden: se suben a `main` y se
reportan en el resultado (`status=error`) y en Teams.

Sigue siendo **solo lectura contra SQL**: la BD se lee con `SqlPackage /Action:Extract`
y `ApplicationIntent=ReadOnly`. Nada se publica ni se escribe en la base.

## Flujo por base

`run-sync.sh` (lo llaman los dos orquestadores n8n, `ScHmSyNcOrCh0001` y `F9RXPgIJQ7QzZ15q`):

1. Si la base **no** está en `reconcile-enabled.txt`: corre el sync clásico (`SchemaSyncTool`). Ver "Fase 1" abajo.
2. Si **sí** está: corre el sync clásico (su salida va a stderr) y después `reconcile-and-push.sh`, cuyo JSON es el resultado final para n8n.

`reconcile-and-push.sh`:

| Paso | Qué hace |
|---|---|
| 1 | Deja la copia de trabajo en `origin/main` limpia (descarta lo que dejó el `SchemaSyncTool` sin subir). |
| 2 | Extract de solo lectura con `/p:ExtractTarget=SchemaObjectType`: un `.sql` por objeto, generado por el motor. |
| 3 | `reconcile-from-extract.py`: agrega lo que falta, sobrescribe lo distinto, borra lo que ya no existe en prod y ajusta los `<Build Include>` del `.sqlproj`. |
| 4 | `build-check.sh`: compila el proyecto en el .60 (SDK .NET 8 en `/home/soporte/.dotnet` + `Microsoft.Build.Sql 0.1.19`). No toca la BD. |
| 5 | Commit + push fast-forward a `main` **siempre que haya cambios**. Nunca `--force`. Si no hay cambios, no hay commit. |
| 6 | Resultado: `status=success` solo si compila **y** el push salió bien. Si no compila: `status=error` con `buildErrors` (main igual queda = prod). Si el push falla: `status=error` con el error de git. |

Requisito: la identidad del PAT del sync (`pmontero`) tiene **"Bypass policies when pushing"**
en `refs/heads/main` de cada repo (aplicado a 46 repos el 2026-11-09). Sin eso ADO rechaza el
push con `TF402455`.

## Alcance de la reconciliación

Entra: tablas, vistas, procedimientos, funciones, triggers, tipos, índices y constraints
(todo lo que el Extract genera como objeto), y el `CREATE SCHEMA` de `Security/<schema>.sql`.

Queda fuera a propósito (política del sync):

- Usuarios, logins, roles, membresías y permisos (`Security/*` salvo `CREATE SCHEMA`).
  En `Security/<schema>.sql` se conservan los `GRANT` del repo.
- Carpetas `Scripts/` / `scripts/` en cualquier nivel (scripts de migración y datos del equipo).
- `Properties/`, `bin/`, `obj/`.
- Archivos `.sql` en disco que no están como `<Build Include>` en el `.sqlproj`: no se comparan ni se borran.

## Reglas de comparación y escritura (fixes del 2026-11-09)

- **Fin de línea:** se conserva el del Extract. En módulos (SP, funciones, vistas, triggers) el
  CRLF es parte del texto que guarda la BD; normalizarlo a LF hace que DacFx y el Schema
  Compare de Visual Studio marquen esos objetos como modificados. Caso real: 34 SPs de
  `buklo_lab`, corregido en `main` con el commit `c1d301b`. El Extract y el `.sqlproj` se leen
  con `newline=''` para no perder el CRLF.
- **Texto exacto:** cada archivo queda con el texto exacto del Extract; solo se quitan el BOM,
  las líneas en blanco del principio y el `GO`/líneas en blanco del final. No se tocan los
  fines de línea del medio: en la BD pueden ser mixtos (ej. un SP todo en CRLF salvo las
  últimas líneas en LF) y unificarlos también produce "Alter" en el Schema Compare
  (15 SPs `replicator.*` de `core_module`). Un archivo se reescribe solo si ese texto exacto
  cambia; la primera corrida de cada base reescribe muchos archivos por espacios y fines de
  línea, las siguientes no.
- **Nombres de archivo:** al emparejar repo y Extract se ignoran mayúsculas y espacios solo en
  las carpetas; el nombre del archivo se compara tal cual (`presup uesto.sql` ≠
  `presupuesto.sql`). Antes, un archivo con un espacio en el nombre en `int_nomedica` hizo que
  se sacara del `.sqlproj` el archivo correcto.
- **Carpetas:** se respeta el nombre de carpeta que ya usa el proyecto (`Stored Procedures`
  aunque el Extract escriba `StoredProcedures`).
- **`.sqlproj`:** se quitan `<Build Include>` duplicados (causan `SQL71508` en Visual Studio)
  y se preservan el BOM y el fin de línea del archivo.
- **Idempotencia:** una segunda corrida sin cambios en la BD da 0 cambios y no genera commit.

## Cómo verificar que `main` = prod

No alcanza con que la reconciliación diga 0 cambios. La prueba válida es la del motor:

1. Compilar el proyecto de `main` en un DACPAC (`build-check.sh`; si hay objetos que no
   compilan, sacarlos del build solo para la prueba).
2. `sqlpackage /a:DeployReport` del DACPAC del proyecto contra un DACPAC extraído de prod,
   excluyendo usuarios, roles y permisos.
3. Esperado: 0 diferencias, salvo los objetos sacados del build y sus dependientes.

Verificado así en `gm_cotizadores` (0 diferencias) y `buklo_lab` (0 tablas y 0 SPs distintos;
solo los 27 objetos que no compilan). Confirmado además por Pablo con Schema Compare de
Visual Studio contra `c1d301b`.

## Bases en fase 2 (`/home/soporte/schema-sync/reconcile-enabled.txt`)

43 bases desde el 2026-11-10 (todas las habilitadas de los dos flujos, menos las de abajo).
Primera corrida completa: flujo 1 exec `3084823` (20 bases, 43 min) y flujo 2 exec `3085297`
(23 bases, 64 min). En las 43, `origin/main` = commit del resultado y sin ramas `schema-sync/*`.

| Resultado | Bases |
|---|---|
| `success` (main = prod y compila) | 37 |
| `error` por código de la BD (main = prod) | `buklo_lab`, `core_log`, `core_trace`, `sds_blue`, `int_medica`, `stg_iolab` |

Fuera de fase 2:

| Base | Motivo |
|---|---|
| `sqldb_core_workflow` (bundle) | pendiente de revisión: usa la variable SQLCMD `$(sqldb_core_global)` (el texto no puede ser idéntico a prod) |


`sqldb_sds_salesforce` y `sqldb_database_maintenance` entraron el 2026-11-10 (45 bases) gracias
a los stubs de validación (ver "Compilación en el .60"): `sds_salesforce` queda en `error` solo
por 2 triggers con nombre de 3 partes; `database_maintenance` compila (`success`).
| `stg_hana`, `stg_hana_nomed`, `SOFTLAND` | heavy, inactivas; probar por esta vía (el Extract no usa Compare live) |

Agregar una base: probar primero en copia (Extract + reconciliación + `build-check.sh` +
DeployReport), revisar qué agrega/borra, y recién ahí sumarla al archivo (una por línea, con el
nombre real de la BD). El bundle `core_workflow_global` todavía no está soportado.

## Fase 1 (bases que no están en fase 2)

Siguen con el `SchemaSyncTool` y `accept-dacfx-incongruence.py`:

- Compara y actualiza el repo; hace push directo a `main` (gracias al bypass).
- Si no compila: igual sube a `main` y queda `status=error`.
- Si después del sync **quedan diferencias** BD vs repo: **no sube nada** y queda `status=error`.
  No se activa `--push-on-incongruence`: el `SchemaSyncTool` puede dejar archivos corruptos en
  ese caso (ej. `quotes.sql` de `gm_cotizadores` con un `ALTER TABLE` incrustado).
- Los casos `pace.*` y "Falta tabla" ya no se marcan como `success`.
- No conserva el CRLF de los módulos: en esas bases el Schema Compare puede mostrar SPs como
  modificados aunque el texto sea igual. Se resuelve pasándolas a fase 2.

## Compilación en el .60 (`build-check.sh`)

Validación solamente: nada de esto cambia el repo (`build-check-items.py` arma la lista):

- **Ensamblados CLR** (`CREATE ASSEMBLY`) y módulos que los usan (`EXTERNAL NAME`) no se validan:
  el SDK en Linux los marca como corruptos (`SQL70557`). Quedan en el repo tal cual prod.
- **Dueños de schema** (`AUTHORIZATION [usuario]`) y **credenciales** (`CREDENTIAL = [x]`) que el
  sync deja fuera: si el proyecto ya tiene el archivo que los define (aunque esté como `<None>`),
  se usa ese; si no, se genera un stub (`CREATE USER ... WITHOUT LOGIN`, credencial con identidad
  ficticia). Lo usado queda en `reconcile/build/validation.json`.
- `MBS_VERSION` (default `0.1.19-preview`) permite validar con `Microsoft.Build.Sql 2.3.0`, que
  soporta `Sql170`. Probado en 5 bases con los mismos resultados; no es el default todavía.
- Limitación conocida del DeployReport (verificación): en External Data Sources `TYPE = RDBMS`
  el SDK y `sqlpackage` 170 guardan otro valor de enum y el reporte muestra "drop + create"
  aunque el texto del repo es idéntico al de prod. No afecta al repo. Proyectos `Sql170`
  necesitan `/p:AllowIncompatiblePlatform=True` contra un DACPAC de prod `Sql160`; sin eso el
  reporte falla (el probe lo marca `REPORT_FALLO`, no 0).

El wrapper copia del `.sqlproj` original la collation (`ModelCollation`, `DefaultCollation`) y
demás propiedades de modelo. Sin `ModelCollation` el SDK valida distinguiendo mayúsculas y da
errores falsos (`SQL70590 @P_X` vs `@p_x`, `SQL71501 [dbo].[SYSNAME]`). Antes de ese fix se
reportaron como "código de la BD" errores que no lo eran (83 en `buklo_lab`; reales: 7).

## Errores de código en la BD (se reportan, no se corrigen desde el sync)

Verificados con `build-check.sh` corregido:

- `sds_blue`, `stg_iolab`, `sds_salesforce`: triggers que se nombran con 3 partes (`[base].[schema].[tabla]`).
- `int_medica`: vista `hana_med.vw_ventas_medicas` (3 partes).
- `buklo_lab`: función `pace.fn_facility_occupancy_stats` (7 errores).
- `core_log`, `core_trace`: `notification.pa_con_email_message` con referencias no resueltas.

No son código de la BD sino alcance del sync (pendiente decidir):

- `sds_salesforce`: schemas con `AUTHORIZATION` a usuarios, que el sync excluye.
- `database_maintenance`: ensamblado CLR y External Data Sources con credenciales que el Extract no trae.

## Rollback

Respaldos en `/home/soporte/schema-sync/backups/` (cada uno con `SHA256SUMS`):

| Respaldo | Contiene |
|---|---|
| `pre-push-siempre-20261109T224449Z` | estado original antes de los cambios del 2026-11-09 (scripts + binario) |
| `pre-fase2-20261109T232630Z` | `run-sync.sh` y `accept` antes de integrar la fase 2 |
| `pre-fase2-scriptsfix-20261110T010329Z` | reconcile antes de excluir `Scripts/` |
| `pre-fase2-eolfix-20261110T021130Z` | reconcile antes del fix de fin de línea |
| `pre-buildcheck-collation-20261110T025914Z` | build-check antes de copiar la collation del proyecto |
| `pre-fase2-exact-20261110T034624Z` | reconcile antes del texto exacto |
| `pre-fase2-key-20261110T040300Z` | reconcile antes del fix de nombres de archivo |

Desactivar la fase 2 para una base: quitarla de `reconcile-enabled.txt`. Para todas: vaciar el
archivo. Los permisos de bypass se revierten con los respaldos `backup-acl-*` en
`.local/schema-sync/plans/` (quitar solo el bit 128).



## Protección contra borrados (desde 2026-11-10)

El Extract a archivos puede no traer un objeto que sí existe en prod (ej. creado en prod justo
entre dos Extract). Para no borrarlo del repo por error:

1. `reconcile-and-push.sh` corre primero la reconciliación en seco (`--dry-run`).
2. Si va a borrar algo, extrae también el DACPAC de prod (solo lectura) y reconcilia con
   `--prod-dacpac`: un objeto solo se borra si **no** está en el DACPAC. Los que existen se
   conservan y quedan en `reconcile.keptUnreadableInProd` del resultado.
3. Si no hay borrados, no se extrae el DACPAC (sin costo extra).

## Bundle `core_workflow_global` (desde 2026-11-10)

Script propio: `reconcile-bundle-and-push.sh`. `run-sync.sh` lo llama cuando algún proyecto del
bundle (por `projectName`) está en `reconcile-enabled.txt`:

1. Corre el sync clásico del bundle (fase 1, sigue cubriendo los proyectos fuera de fase 2) y
   guarda su resultado en `work/<repo>/phase1-result.json`.
2. Desde `origin/main`, reconcilia **solo** los proyectos habilitados, en el orden del bundle y
   con sus reglas de `bundles/core-workflow-global.json`:
   - `keepAsNone`: se actualiza el texto pero el archivo sigue como `<None>` (funciones CLR).
   - `skipClrAssemblies`: no se agrega el `CREATE ASSEMBLY` del Extract (el proyecto usa
     `<Reference>` a un `.dll`).
3. Compila cada proyecto, un solo commit + push. El resultado trae `projects.<nombre>` con el
   detalle por proyecto y `phase1` con el resultado del sync clásico.

Hoy solo `sqldb_core_global` está habilitado (primer push: `65ed442`, 74 objetos al texto de
prod, compila). Proyectos con `preserveSqlCmdRefs` (`workflow`) se rechazan a propósito.

### Pendiente: `sqldb_core_workflow`

- **Variable SQLCMD:** el repo usa `[$(sqldb_core_global)]` en 57 archivos (más 9 con
  `[sqldb_core_global]` literal y 18 sin corchetes). Prod tiene el nombre literal. Decidir si se
  mantiene la variable (el texto difiere de prod solo en esas referencias) o se usa el literal.
- **Bug del sync clásico:** en cada corrida agrega ~1.045 copias del comentario
  `-- Author / Create date / Description` del trigger dentro de
  `workflow/Tables/tra_workflow.sql` (81.625 líneas el 04-nov, 118.193 el 10-nov; el bloque
  está 23.490 veces). Por eso el bundle commitea en cada corrida. La fase 2 lo corrige al
  reescribir el archivo con el texto de prod.
- **Validación:** `build-check.sh` acepta `REF_DACPAC`/`REF_VAR` para compilar `workflow`
  contra el DACPAC de `global`.

### Artefacto conocido de la verificación

Objetos creados sin schema en prod (ej. `CREATE PROC sp_ReportCache`): el Extract a archivos los
trae tal cual, pero el DACPAC los normaliza a `CREATE PROC [dbo].[sp_ReportCache]`, así que el
DeployReport (y probablemente el Schema Compare de VS) los marca como distintos.

## Bases validadas contra el Schema Compare de Visual Studio (2026-11-12)

Pablo comparó en Visual Studio (Schema Compare, proyecto vs BD) estas bases y el resultado
**coincide con lo que dejó el Orquestador** (`main` = prod, vía fase 2):

| Base (catálogo) | Repo / proyecto |
|---|---|
| `sqldb_core_job_schedule` | `project_sqldb_core_job_schedule` |
| `sqldb_stg_blue` | `project_sqldb_stg_blue` |
| `sqldb_core_global` | bundle `project-qldb_core_workflow-sqldb_core_global` |
| `sqldb_core_workflow` | bundle (conserva `[$(sqldb_core_global)]`, excepción documentada) |
| `sqldb_core_config` | `project_sqldb_core_config` |
| `buklo_lab` (catálogo `sqldb_buklo_lab`) | `buklo-database-sqlproject` (proyecto `Buklo`) |

**Sus pipelines (Build + Release) ya se están usando en UAT y Producción** y el contenido que
despliegan es el que mantiene el Orquestador. Para estas 6 bases el repo es fuente confiable:
`main` coincide con prod.
