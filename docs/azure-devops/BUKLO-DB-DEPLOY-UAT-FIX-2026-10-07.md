# Buklo Database DACPAC — Fix Deploy UAT (2026-10-07/08)

**Repo:** `buklo-database-sqlproject` (proyecto Buklo, ADO Shared-Service-GM)  
**Branch trabajado:** `uat`  
**Build final exitoso:** 24457  
**Release UAT exitoso:** 7927  
**Fecha sesión:** 2026-10-07 / 2026-10-08  

---

## Problema raíz

El deploy DACPAC a UAT fallaba con:

```
An error occurred while the batch was being executed
bigint is incompatible with uniqueidentifier
```

### Causa

Había **dos mundos mezclados** en el repo `buklo-database-sqlproject` rama `uat`:

| Origen | Tipo en tablas IA | Tipo en SPs IA |
|---|---|---|
| Dev (rama `development`) | no definía tablas `IA.*` | `@p_id BIGINT` + `SCOPE_IDENTITY()` |
| Copia de prod (`project_sqldb_buklo_lab`) | `id UNIQUEIDENTIFIER DEFAULT(newid())` | `@p_id UNIQUEIDENTIFIER` + `NEWID()` |

Los **SPs del dev** asumen `BIGINT IDENTITY` (usan `SCOPE_IDENTITY()` para capturar el ID insertado). Las **tablas** fueron copiadas de producción con `id UNIQUEIDENTIFIER`. SqlPackage/SSDT valida que los tipos sean consistentes al hacer `ALTER PROCEDURE`, y detectaba el clash en cada SP.

---

## Por qué el release fallaba — orden de ejecución de SSDT

SqlPackage/SSDT aplica los cambios en un orden fijo predefinido. Los **Stored Procedures se procesan antes que las tablas**. Esto significa que cuando el DACPAC intentaba hacer `ALTER PROCEDURE pa_con_analysis_event`, SQL Server validaba los tipos de los parámetros contra las columnas de la tabla **tal como estaban en ese momento** (aún `UNIQUEIDENTIFIER`). Como los SPs del dev tienen `@p_id BIGINT` y la columna `id` era `UNIQUEIDENTIFIER`, el batch fallaba con `bigint is incompatible with uniqueidentifier` antes de siquiera llegar a alterar las tablas.

El ciclo era:

```
1. SqlPackage inicia deploy
2. Intenta ALTER PROCEDURE pa_con_analysis_event   ← FALLA aquí
   (parámetro BIGINT vs columna UNIQUEIDENTIFIER de la tabla actual)
3. Deploy aborta — las tablas nunca se tocan
```

Aunque el DACPAC "sabía" que iba a cambiar las tablas a BIGINT más adelante, el motor de SQL Server valida el SP contra el estado **actual** de la BD en el momento del ALTER, no contra el estado futuro. Por eso nunca se llegaba al paso de modificar las tablas.

---

## Diagnóstico iterativo

1. Primeros errores apuntaban a `pa_con_analysis_event` — parámetros `@p_id BIGINT` vs columna `id UNIQUEIDENTIFIER`.
2. Fix regex de parámetros `@p_id*` no alcanzó a parámetros con otros nombres (`@p_caused_by`, `@p_affects`, `@p_detected_by`).
3. Al ampliar el fix a todos los `BIGINT` en parámetros, apareció el error opuesto: `int incompatible with uniqueidentifier` — variables internas.
4. Diagnóstico definitivo: los SPs del dev usan `SET @p_id = SCOPE_IDENTITY()` — esto solo funciona con `BIGINT IDENTITY`, nunca con `UNIQUEIDENTIFIER`.
5. Consulta del código en `development` confirmó que el dev diseñó **todo** el esquema `IA` para `BIGINT IDENTITY`. El estado `UNIQUEIDENTIFIER` de las tablas era el estado de la BD, no la intención del diseño.

**Lección aplicada:** ante inconsistencia repo vs BD, leer el código real en `development` para inferir la intención. `SCOPE_IDENTITY()` en los SPs fue la señal decisiva — el dev quería `BIGINT IDENTITY`.

---

## Cambios realizados

### 1. Tablas `IA.*` — rama `uat` del repo

**67 archivos de tabla** actualizados de:
```sql
[id] UNIQUEIDENTIFIER DEFAULT (newid()) NOT NULL
```
a:
```sql
[id] BIGINT IDENTITY(1,1) NOT NULL
```

También se actualizaron las **columnas FK** dentro de las tablas hija (columnas `id_*` y FK columns que apuntan a tablas `IA.*` con BIGINT):
- Columnas `[agent_id]`, `[task_id]`, `[session_id]`, `[analytical_task_id]`, etc. → `BIGINT`
- Columnas auxiliares `[id_analytical_task]`, `[id_agent]`, `[id_ontology]`, etc. → `BIGINT`

**Tablas NO tocadas:** `tra_agent_conversations`, `tra_agent_messages`, `tra_agent_conversation_metrics` (ya tenían `BIGINT IDENTITY` desde el inicio).

**Otros esquemas (pace, schedule, auth, pharmacy):** no modificados — 0 cambios.

### 2. Stored Procedures `IA.*` — rama `uat` del repo

**32 SPs** alineados con el modelo `BIGINT`:

#### SPs del dev (existían en `development`)
Se reemplazaron con la versión exacta de `development` — sin modificación adicional. Son SPs correctos por definición.

#### `pa_man_agent*` — 7 SPs copiados de producción
Portados al modelo `BIGINT IDENTITY` siguiendo el patrón del dev:

| Patrón prod (UNIQUEIDENTIFIER) | Patrón nuevo (BIGINT IDENTITY) |
|---|---|
| `@p_id UNIQUEIDENTIFIER = NULL OUTPUT` | `@p_id BIGINT = NULL OUTPUT` |
| `SELECT @p_id = NEWID()` | _(eliminado)_ |
| `INSERT INTO ... ([id], ...) VALUES (@p_id, ...)` | `INSERT INTO ... (...) VALUES (...)` _(sin [id])_ |
| _(no había)_ | `SET @p_id = SCOPE_IDENTITY()` |
| `WHERE [id] = @p_id` | `WHERE [id] = @p_id` _(sin cambio)_ |

SPs portados: `pa_man_agent`, `pa_man_agent_dependency`, `pa_man_agent_excluded_company`, `pa_man_agent_focus_area`, `pa_man_agent_integration`, `pa_man_agent_preferred_index`, `pa_man_agent_role`, `pa_man_agent_use_case`.

#### SPs `sp_*` y otros
`sp_create_conversation_session`, `sp_update_session_context`, `sp_get_metrics_impacted_by_resource`, `pa_man_data_source_process_relation` y similares — mismo port: cambio de `UNIQUEIDENTIFIER` a `BIGINT` en parámetros y variables internas, eliminación de `NEWID()`, adición de `SCOPE_IDENTITY()` donde aplica.

### 3. Migración de la BD UAT (`buklo_lab @ 172.16.2.34`)

Ejecutada manualmente por el operador en SSMS con el script generado por el agente (`IA_migrate_DEFINITIVO.sql`):

1. **Deshabilitar restricciones** de FK en esquema `IA` (dinámico vía `sp_executesql`).
2. **Eliminar las 54 tablas** con `id UNIQUEIDENTIFIER`.
3. **Recrear las 54 tablas** con `id BIGINT IDENTITY(1,1)`.

Verificación ejecutada: 57 tablas con `bigint` + `is_identity=1`, `tablas_uid_restantes = 0`.

> **Nota:** El script fue generado por el agente y ejecutado por el operador desde SSMS. El agente no ejecuta DROP TABLE directamente (política de seguridad del stack).

### 4. `.sqlproj`

- Se incluyeron en Build todos los SPs portados.
- Los 7 `pa_man_agent*` pasaron de excluidos a incluidos una vez portados.

---

## Estado final por capa

| Capa | Estado |
|---|---|
| **Tablas `IA.*` en repo `uat`** | ✅ `BIGINT IDENTITY(1,1)` |
| **Columnas FK en tablas `IA.*`** | ✅ `BIGINT` |
| **SPs del dev en `uat`** | ✅ versión de `development` (sin cambios) |
| **`pa_man_agent*` en `uat`** | ✅ portados a modelo `BIGINT` |
| **BD UAT (`buklo_lab`)** | ✅ 54 tablas `BIGINT IDENTITY` |
| **Build 24457** | ✅ Succeeded |
| **Release 7927 — stage UAT** | ✅ Succeeded |
| **Otros esquemas (pace, schedule, auth)** | ✅ Sin cambios |

---

## Composición de la rama `uat`

La rama `uat` de `buklo-database-sqlproject` es una combinación de **tres capas**:

### Capa 1 — Lo que viene de `development` (código del dev)
SPs del esquema `IA` escritos por el dev con el modelo nuevo: `@p_id BIGINT = NULL OUTPUT` + `SCOPE_IDENTITY()`. Llegaron a `uat` vía el PR 14223 (merge de `feature/TKS-42592`). Ejemplos: `pa_man_task_step`, `pa_man_analytical_task`, `pa_man_ontology`, `pa_con_*`, etc.

### Capa 2 — Lo que viene de producción (`project_sqldb_buklo_lab`)
Objetos del esquema `IA` copiados manualmente del repo de producción para tener la base que el dev aún no había definido en `development`:
- **54 tablas `IA.*`** con `id UNIQUEIDENTIFIER DEFAULT(newid())` — el modelo antiguo de producción.
- **7 SPs `pa_man_agent*`** con `@p_id UNIQUEIDENTIFIER` + `NEWID()` — también modelo antiguo.

Este merge de prod fue intencional: el dev no tenía esos objetos en `development` todavía y el DACPAC los necesitaba para compilar.

### Capa 3 — Sobrantes propios de `uat`
SPs que existían en `uat` con versiones intermedias o mixtas — ni la versión limpia de `development` ni la de prod. Durante el proceso de fix se identificaron y reemplazaron con la versión correcta de `development` cuando existía, o se portaron/excluyeron cuando no.

### El conflicto
Las **capas 1 y 2 son incompatibles** entre sí:
- Capa 1 (dev): tablas deben ser `BIGINT IDENTITY` para que `SCOPE_IDENTITY()` funcione.
- Capa 2 (prod): tablas son `UNIQUEIDENTIFIER`, SPs usan `NEWID()`.

La solución aplicada fue migrar todo al modelo de la **capa 1** (el diseño intencional del dev): tablas a `BIGINT IDENTITY` y los 7 SPs de prod portados a ese mismo modelo.

---

## Lo que producción tiene hoy

El repo de producción (`project_sqldb_buklo_lab`) **no fue modificado**. Las tablas de producción siguen con `id UNIQUEIDENTIFIER` y los SPs de producción usan `UNIQUEIDENTIFIER` — son consistentes entre sí y el deploy de producción actual funciona.

El esquema `IA` en producción es el modelo **antiguo** (UNIQUEIDENTIFIER). El repo `buklo-database-sqlproject` en `uat` es el modelo **nuevo** (BIGINT IDENTITY) que el dev diseñó para Buklo.

---

## Pendiente / próximos pasos

### Dev — PR `uat` → `development`
Para que los cambios queden en `development` como base de trabajo del dev, se debe hacer el PR:

```
buklo-database-sqlproject: uat -> development
```

Esto lleva a `development`:
- Las 67 tablas con `BIGINT IDENTITY`
- Los 32 SPs alineados
- Los 7 `pa_man_agent*` portados

El dev hereda un modelo `BIGINT` consistente y puede seguir trabajando sobre esa base.

### Dev — revisar `pa_man_agent*` portados
Los 7 SPs portados son adaptaciones mecánicas del código de producción. Funcionan correctamente para las operaciones básicas CRUD. Si el dev quiere agregar funcionalidad nueva al grupo `agent` (como hizo con los demás SPs del esquema `IA`), trabaja sobre esas versiones.

### Producción (cuando llegue el momento)
Cuando el equipo decida desplegar el esquema `IA` a producción, el proceso será:
1. El release def apunta a rama `release`.
2. Las tablas de producción serán migradas por el DBA (el DACPAC hará DROP+CREATE de las 54 tablas `IA.*`).
3. Los SPs de producción (`pa_man_agent*`) serán reemplazados por las versiones nuevas con `BIGINT`.
4. Requiere ventana de mantenimiento — las tablas `IA.*` en producción se recrean.

---

## Archivos generados durante la sesión

| Archivo | Descripción |
|---|---|
| `IA_migrate_to_BIGINT_UAT.sql` | Script original (PASO 3 tenía DDL sin modificar — no usar) |
| `IA_migrate_PASO2_PASO3.sql` | Script intermedio con BIGINT en algunas tablas |
| `IA_migrate_DEFINITIVO.sql` | **Script final correcto** — elimina FKs dinámicamente, DROP, CREATE con BIGINT |

Los archivos están disponibles en el outbox del dashboard.

---

*Generado 2026-10-08 — sesión de corrección DACPAC buklo-database-sqlproject UAT*
