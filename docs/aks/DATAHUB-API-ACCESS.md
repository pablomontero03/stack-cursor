# DataHub — Acceso a la API (GMS)

Guía de conexión a la API del **DataHub migrado al k3s del `.31`** (`prod-onprem-01`,
`srvdesarrollo03`, namespace `datahub`). Validado en vivo el **2026-09-18**.

> El DataHub sirve su metadata por el **GMS** (Generalized Metadata Service). El GMS expone
> GraphQL y OpenAPI/REST. La autenticación de la API está **activada**
> (`METADATA_SERVICE_AUTH_ENABLED=true`), así que **toda llamada exige un token**. Un `401` es el
> servidor sano pidiendo credencial, **no** un fallo.

---

## Credenciales

Viven en `env/.env` (chmod 600, **no versionado**). Los nombres (sin el secreto) están en
`env/.env.example` como plantilla.

| Variable | Valor |
|---|---|
| `DATAHUB_GMS_URL` | `https://datahub.grupomontecristo.com` |
| `DATAHUB_GMS_TOKEN` | Personal Access Token (PAT) del usuario `datahub` — **secreto, nunca imprimir** |

El PAT se genera desde la UI de DataHub (**Settings → Access Tokens**) por un usuario logueado.

---

## Endpoints

| Vía | URL |
|---|---|
| GraphQL | `$DATAHUB_GMS_URL/api/graphql` |
| OpenAPI / REST | `$DATAHUB_GMS_URL/openapi/...` |
| Interno al cluster (scripts en el `.31`) | `http://datahub-datahub-gms:8080` (svc `datahub-datahub-gms:8080`, ns `datahub`) |

Para alcanzar el GMS interno desde otro host: `kubectl port-forward -n datahub svc/datahub-datahub-gms 8080:8080`.

---

## Uso

```bash
source env/.env

curl -sk -X POST "$DATAHUB_GMS_URL/api/graphql" \
  -H "Authorization: Bearer $DATAHUB_GMS_TOKEN" \
  -H 'Content-Type: application/json' \
  --data-raw '{"query":"{ me { corpUser { username } } }"}'
```

### Helper de consulta

`docs/aks/scripts/datahub-query.sh` (versionado) envuelve el patrón anterior y trae subcomandos
comunes (`me`, `count`, `search`, `dataset`, `sources`, `gql`, `rest`). Lee `DATAHUB_GMS_URL` /
`DATAHUB_GMS_TOKEN` del `env/.env` automáticamente (sube desde el script hasta encontrar la raíz
del repo). Requiere `jq` para salida formateada (si no está, imprime JSON crudo). Ejemplos:

```bash
docs/aks/scripts/datahub-query.sh me      # usuario autenticado
./datahub-query.sh count                  # total de datasets
./datahub-query.sh search ventas 10       # busca "ventas", 10 resultados
./datahub-query.sh dataset "<urn>"        # detalle + esquema de un dataset
./datahub-query.sh sources                # ingestion sources configuradas
./datahub-query.sh gql '{ me { corpUser { username } } }'   # GraphQL arbitrario
./datahub-query.sh rest /openapi/v3/entity/dataset?count=1  # GET REST arbitrario
```

---

## Consultas GraphQL útiles

**Total de datasets:**
```graphql
{ search(input:{type:DATASET, query:"*", start:0, count:0}) { total } }
```

**Buscar datasets por texto:**
```graphql
{ search(input:{type:DATASET, query:"ventas", start:0, count:10}) {
    total
    searchResults { entity { urn ... on Dataset { name platform { name } } } }
} }
```

**Detalle + esquema de un dataset por URN:**
```graphql
{ dataset(urn:"<urn>") {
    urn name platform { name }
    schemaMetadata { fields { fieldPath type nativeDataType } }
} }
```

---

## Validación en vivo (2026-09-18)

- `me` → `{"data":{"me":{"corpUser":{"username":"datahub"}}}}`, **HTTP 200**.
- `search(type:DATASET, query:"*")` → **total = 4709 datasets** (catálogo completo sirviendo).

---

## Notas de seguridad

- El PAT vive **solo** en `env/.env` (no versionado). Nunca se imprime en logs, respuestas ni memorias.
- Si el token se rota/revoca desde la UI, actualizar `DATAHUB_GMS_TOKEN` en `env/.env`; nada más cambia.
- La API es de **lectura de metadata**; para escrituras (crear tags, editar linaje) usar el token con cuidado y bajo el modelo de aprobaciones del stack.

> Detalle completo de la migración: `.local/aks/datahub-migration/TRASPASO-MIGRACION-DATAHUB.md`.

---

## Agregar un origen de datos (ingestion source) — ejemplo Elasticsearch

Un **origen** es una conexión a un sistema real que DataHub escanea para traer su metadata
(no copia los datos, solo lee esquemas). Se puede crear por la UI (**Ingestion → + Create new
source**) o por API. Elasticsearch **no aparece como mosaico** en el asistente visual: se
configura por receta YAML/avanzada — no es que la versión sea vieja.

### Patrón de secretos (no meter contraseñas en la receta)

Igual que hicieron con SIREP/Tableau: la credencial se registra como **secreto de DataHub** y la
receta la referencia con `${NOMBRE}`. Así la contraseña nunca queda en texto plano en la receta.

```bash
source env/.env
# crear secreto (una vez por credencial)
curl -sk -X POST "$DATAHUB_GMS_URL/api/graphql" \
  -H "Authorization: Bearer $DATAHUB_GMS_TOKEN" -H 'Content-Type: application/json' \
  --data-raw "$(jq -nc --arg v "$ES_GMONTECRISTO_PASSWORD" \
    '{query:"mutation($v:String!){ createSecret(input:{name:\"ES_GMONTECRISTO_PASSWORD\", value:$v}) }", variables:{v:$v}}')"
```

### Receta Elasticsearch (la que quedó en producción)

```yaml
source:
  type: elasticsearch
  config:
    host: 'https://elastic.grupomontecristo.com:443'
    username: '${ES_GMONTECRISTO_USER}'
    password: '${ES_GMONTECRISTO_PASSWORD}'
    ingest_index_templates: false
    index_pattern:
      allow: [".*"]
      deny:
        - "^\\..*"          # índices de sistema (.kibana, .security, .monitoring…)
        - ".*_backup$"
        - ".*_respaldo$"
        - ".*_test$"
        - ".*_[0-9]{8}$"    # respaldos con fecha AAAAMMDD al final
```

> **OJO — dos trampas confirmadas:**
> 1. **NO** poner un bloque `stateful_ingestion` en la receta ES: esta versión del conector
>    revienta con `AttributeError: 'StatefulIngestionConfig' object has no attribute
>    'remove_stale_metadata'`. La primera corrida falló por esto; se quitó y corrió limpio.
> 2. El `deny` de fecha debe anclarse al **final** (`_[0-9]{8}$`). Varios índices legítimos
>    llevan un **código de empresa** numérico en medio del nombre
>    (`index_replicator_tra_766043_estados_financieros`) que NO es una fecha de respaldo —
>    un patrón `_[0-9]{6,8}` sin ancla los excluiría por error.

### Crear, ejecutar y verificar (por API)

```bash
# crear el source
createIngestionSource(input:{ name, type:"elasticsearch", schedule:{interval:"0 2 * * *", timezone:"America/Mexico_City"}, config:{recipe:"<json>", executorId:"default"} })
# correr la primera ingesta
createIngestionExecutionRequest(input:{ ingestionSourceUrn:"<urn>" })
# estado de la corrida
executionRequest(urn:"<execUrn>") { result { status durationMs } }   # SUCCESS / RUNNING / FAILURE
```

### Etiquetado por dominio en lote (clasificación por nombre, sin inventar negocio)

Los tags se derivan **solo del nombre del índice** — no se inventan dueños ni descripciones de
negocio (eso lo pone quien conoce el dato). Tags creados y aplicados:

| Tag | Regla (por nombre) |
|---|---|
| `crm` | contiene `salesforce` |
| `clinico` | `blue` / `appointment` / `encounter` |
| `financiero` | `estados_financieros` |
| `cobranza` | `cuentas_por_cobrar` |
| `ventas` | `ventas_medicas` / `ventas_no_medicas` |
| `call-center` | `neotel` |

Se aplican con `createTag` (una vez) + `addTag(input:{tagUrn, resourceUrn})` por tabla.

> **WAF:** los scripts en lote deben usar **curl** (o el helper), NO `python urllib/requests`:
> el proxy frente a DataHub bloquea el User-Agent de urllib con `HTTP 403` aunque el token sea
> válido por curl.

---

## Estado actual (2026-09-18)

- **Origen:** `Elasticsearch_GMontecristo_Datos` (schedule diario 02:00 America/Mexico_City).
- **Catalogado:** 499 datasets de negocio (de 661 índices; excluidos 152 de sistema + 6 respaldos).
- **Elasticsearch origen:** v8.15.1, `https://elastic.grupomontecristo.com`.
- **Tags de dominio aplicados** a ~291 tablas (crm 66, clinico 65, financiero 56, cobranza 52,
  ventas 43, call-center 11). ~208 tablas quedaron **sin tag a propósito** (familias
  `redshift`/`payment`/`invoice`/`sap`/otras cuyo significado no está confirmado — clasificar
  solo cuando alguien de negocio lo aclare).

### Pendiente / próximos pasos (para quien continúe)

- **Documentación y dueños:** requieren conocimiento de negocio (no se inventan). Preparar
  borradores y validar con los responsables de cada dominio.
- **Clasificar las ~208 tablas sin tag** una vez confirmado qué son.
- **Freshness / alertas:** avisar si una tabla deja de actualizarse (objetivo, no requiere
  conocimiento de negocio) — buen siguiente paso.
- **Usuario read-only dedicado** en el Elastic (hoy usa el superusuario `elastic`) y verificar
  el certificado TLS (hoy `verify_certs=False`).
