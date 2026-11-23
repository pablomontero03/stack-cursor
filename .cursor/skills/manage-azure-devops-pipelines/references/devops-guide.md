# Buklo Backend — Guía DevOps (K8s + Azure DevOps clásico)

Documentación del análisis realizado sobre manifests K8s, pipelines clásicos, releases y Variable Groups del proyecto **DevOps** (`Shared-Service-GM`).

> **Playbook genérico** (cualquier repo / con o sin File Creator de Dockerfile):  
> [`ado-classic-playbook-any-project.md`](./ado-classic-playbook-any-project.md)  
> **Alta desde cero** (sin clonar pipelines; qué lleva Library / Build / Release / Task groups):  
> [`ado-classic-from-scratch.md`](./ado-classic-from-scratch.md)  
> Incluye **pipelines de base de datos** (Build 488, Release 298, Library `Bases Datos SQL`).

> Alcance actual: **Producción** (cluster `gmon-prod-aks-eastus2-0004`, namespace `application-services`) — **estable, no se toca (salvo excepciones puntuales acordadas, ver abajo)** al configurar Dev/UAT.  
> Dev/UAT: convención definida 2026-08-26 (ver §9). **Gateway (piloto) verificado end-to-end**: Build 584 rev 24 (Dev/UAT File Creators + mecanismo de agrupación de merges + `Reportar-resultado-HU`, con `dependencies` de phase corregido — ver §9.4 paso 8), Release 366 rev 7 (Desarrollo/UAT relinkeados a Library 418/419, artifact trigger por rama `development`/`uat`, `Reportar-resultado-HU` en los 3 stages incluida Producción, y approval gate real de Producción con approver `[Shared-Service-GM]\Release Executers` — las 2 únicas excepciones puntuales acordadas a "no tocar Producción" en toda esta convención, cada una acotada exactamente a lo pedido, nada más de esa config). **Confirmado por el usuario 2026-08-26: un Build real compiló y el Release desplegó correctamente en el cluster** — la convención completa (§9) queda probada de punta a punta, no solo configurada. **Avance 2026-08-27: Auth (585/367), Engine (586/368), Notifications (587/369), Storage (588/370), AI (589/371) y Billing (590/372) configurados con la misma convención** (7 de 13 microservicios Buklo listos). Quedan **6 microservicios Buklo** por configurar (tabla §4.1), siguiendo el checklist completo de §9.4. **Nuevo 2026-08-27:** `scripts/New-AdoClassicUpdatePayload.ps1` reemplaza los scripts scratch ad hoc usados hasta EMR para armar el body PUT de `update-build-definition`/`update-release-definition` (field-stripping + splices composables) — ver comentario de cabecera del propio script para el detalle de las 3 ambigüedades reales que resolvió (preservar `properties`, quitar siempre `currentRelease`, preservar `approver` de un gate manual existente).

---

## 1. Visión general

```text
Repo buklo-backend
  └── k8s/deployments/deployment-<servicio>-prod.yml   (fuente / referencia)
        │
        ▼
Azure DevOps Build (clásico)
  · File Creator Dockerfile.service (#{SERVICE_NAME}#)
  · Replace tokens
  · File Creator deployment-prod.yml
  · Task group Build → imagen ACR
        │
        ▼
Azure DevOps Release (clásico)
  · Stage Produccion + Variable Group Produccion-Buklo-Microservice-<Servicio>
  · Task group Deployment-Azur-Aks-v3
        │
        ▼
AKS application-services
  · Deployment / Service / ConfigMap / Secret / SA / HPA
  · Ingress solo en gateway
```

---

## 2. Manifests K8s en el repo

| Archivo | Servicio | Ingress |
|---------|----------|---------|
| [`k8s/deployments/deployment-gateway-prod.yml`](../deployments/deployment-gateway-prod.yml) | gateway | Sí (`internal-ingress`) |
| [`k8s/deployments/deployment-auth-prod.yml`](../deployments/deployment-auth-prod.yml) | auth | No |
| [`k8s/deployments/deployment-engine-prod.yml`](../deployments/deployment-engine-prod.yml) | engine | No |
| [`k8s/deployments/deployment-notifications-prod.yml`](../deployments/deployment-notifications-prod.yml) | notifications | No |
| [`k8s/deployments/deployment-storage-prod.yml`](../deployments/deployment-storage-prod.yml) | storage | No |
| [`k8s/deployments/deployment-ai-prod.yml`](../deployments/deployment-ai-prod.yml) | ai | No |
| [`k8s/deployments/deployment-billing-prod.yml`](../deployments/deployment-billing-prod.yml) | billing | No |
| [`k8s/deployments/deployment-emr-prod.yml`](../deployments/deployment-emr-prod.yml) | emr | No |
| [`k8s/deployments/deployment-hacienda-prod.yml`](../deployments/deployment-hacienda-prod.yml) | hacienda | No |
| [`k8s/deployments/deployment-realtime-prod.yml`](../deployments/deployment-realtime-prod.yml) | realtime | No |
| [`k8s/deployments/deployment-subscriptions-prod.yml`](../deployments/deployment-subscriptions-prod.yml) | subscriptions | No |
| [`k8s/deployments/deployment-surveys-prod.yml`](../deployments/deployment-surveys-prod.yml) | surveys | No |
| [`k8s/deployments/deployment-ticketing-prod.yml`](../deployments/deployment-ticketing-prod.yml) | ticketing | No |
| [`k8s/deployments/deployment-buklo-server-prod.yml`](../deployments/deployment-buklo-server-prod.yml) | buklo-server | Sí (`internal-ingress`) |

También existen (referencia / no usados por el flujo clásico con tokens):

- `k8s/base/configmap.yaml`
- `k8s/base/secret-provider.yaml` (Key Vault CSI)
- `k8s/services/gateway.yaml`

### 2.1 Recursos por servicio (Prod)

| Recurso | Gateway | Auth | Engine |
|---------|---------|------|--------|
| Secret | Sí | Sí | Sí |
| ConfigMap | Sí | Sí | Sí |
| ServiceAccount + Role + RoleBinding | Sí | Sí | Sí |
| Deployment | Sí | Sí | Sí |
| Service ClusterIP | Sí (80→3000) | Sí (3002 + 4002) | Sí (3001 + 4001) |
| HPA | Sí (1–1) | Sí (1–1) | Sí (1–1) |
| Ingress | Sí | No | No |

#### HPA (réplicas fijas en Prod)

Para no consumir recursos de más, el HPA queda **sin scale-out**:

```yaml
minReplicas: 1
maxReplicas: 1
```

Misma convención para gateway, auth, engine, notifications y servicios nuevos. Subir `maxReplicas` solo si hay necesidad explícita de autoscaling.

### 2.2 Puertos y health

| Servicio | TCP (negocio) | HTTP (probes) | Health path |
|----------|---------------|---------------|-------------|
| gateway | — (HTTP público) | 3000 | `/api/v1/health` |
| auth | 3002 | 4002 | `/health` |
| engine | 3001 | 4001 | `/api/v1/health` |
| notifications | 3004 | 4003 | `/api/v1/health` |
| storage | 3005 | 4005 | `/api/v1/health` |
| ai | 3006 | — (solo TCP) | `tcpSocket :3006` |
| billing | 3003 | 4004 | `/api/v1/health/liveness` |
| emr | 3010 | 4010 | `tcpSocket :3010` |
| hacienda | — | 3012 | `/hacienda/health` |
| realtime | — | 3011 (HTTP+WS) | `tcpSocket :3011` |
| buklo-server | — | 3010 | `/health` |

El **gateway** (y auth) descubren servicios por FQDN en el mismo namespace `application-services`:

- `HOST_AUTH` → `microservice-auth-api-service.application-services.svc.cluster.local` · `PORT_AUTH=3002`
- `HOST_ENGINE` → `microservice-engine-api-service.application-services.svc.cluster.local` · `PORT_ENGINE=3001`
- `HOST_NOTIFICATION` (gateway) / `HOST_NOTIFICATIONS` (auth) → `microservice-notifications-api-service.application-services.svc.cluster.local` · puerto `3004`
- `HOST_STORAGE` (gateway/engine) / `STORAGE_TCP_HOST` (notifications) → `microservice-storage-api-service.application-services.svc.cluster.local` · puerto `3005`
- `HOST_AI_CORE` (gateway) → `microservice-ai-api-service.application-services.svc.cluster.local` · `PORT_AI_CORE=3006`
- `HOST_PAYMENT` (gateway) / `HOST_BILLING` (engine) → `microservice-billing-api-service.application-services.svc.cluster.local` · puerto TCP `3003` (HTTP probes `4004`)
- `HOST_EMR` (gateway) → `microservice-emr-api-service.application-services.svc.cluster.local` · `PORT_EMR=3010`
- `HOST_HACIENDA` (gateway) → `microservice-hacienda-api-service.application-services.svc.cluster.local` · `PORT_HACIENDA=3012`
- `HOST_REALTIME` (gateway) → `microservice-realtime-api-service.application-services.svc.cluster.local` · `PORT_REALTIME=3011`

**buklo-server** no pasa por Gateway: Ingress `internal-ingress` → `microservice-buklo-server-api.grupomontecristo.com` · ClusterIP `80→3010`. HPA fijo 1–1 por los crons de sync/enrichment.

Convención del Service: `microservice-<servicio>-api-service` (no `-core-service`, no singular `notification`).

### 2.3 Tokens `#{...}#` en los YAML Prod

Comunes:

| Token | Origen típico | Uso |
|-------|----------------|-----|
| `#{servicesname}#` | Variable Group | Nombres de recursos K8s (`Deployment`, `Service`, `ConfigMap`, `Secret`, SA, HPA) |
| `#{image}#` | Build + Variable Group | **Nombre de la imagen en ACR** (Task group Build y campo `image:` del Deployment) |
| `#{namespace}#` | Variable Group | Namespace AKS |
| `#{containerregistries}#` | Variable Group | Host del ACR |
| `#{ambiente}#` | Variable Group (`prod`) | Sufijo ambiente en el tag de imagen |
| `#{tag}#` | `$(Build.BuildId)` | Tag / build id |
| `#{reqcpu}#` / `#{reqmem}#` / `#{limcpu}#` / `#{limmem}#` | Variable Group | Resources |

#### Imagen del contenedor (importante)

Usar **`#{image}#`**, no `#{servicesname}#`:

```text
image: "#{containerregistries}#/#{image}##{ambiente}#:#{tag}#"
# ej: gmonhubacreastus20001.azurecr.io/microservice-auth-apiprod:20163
```

| Token | Para qué |
|-------|----------|
| `#{servicesname}#` | Recursos K8s (`microservice-auth-api`, `…-service`, `…-config`, …) |
| `#{image}#` | Nombre de imagen Docker/ACR (lo que publica el Task group Build) |

En la práctica hoy suelen tener el **mismo valor** (`microservice-<servicio>-api`), pero se mantienen **separados** para poder divergir (p. ej. renombrar recurso K8s sin cambiar la imagen, o al revés).

> **Convención actualizada:** en File Creator `deployment-prod.yml` y en los YAML del repo, el campo `image:` del Deployment debe usar `#{image}#`. Los manifests nuevos deben nacer así.

**Nota `image_pull_secret`:** se usa en manifests de **Dev/UAT**. En Prod la Library no lo define; el pull suele funcionar con la identidad del nodo/ACR. Si el token queda sin reemplazar, en cluster puede verse `imagePullSecrets` vacío/`null`.

`#{node_selector_value}#` → en Prod suele resolverse a `userpool01` (o quedar fijo según el YAML aplicado).

---

## 3. Dockerfile monorepo

- Archivo en **raíz**: `Dockerfile.service` (contexto = repo root; requerido por el Task group que usa la carpeta del Dockerfile como context).
- Build arg / token: `SERVICE_NAME` = nombre de carpeta bajo `services/` (`gateway` | `auth` | `engine`).
- En el Build clásico:
  1. File Creator escribe `Dockerfile.service` con `#{SERVICE_NAME}#`
  2. Replace tokens (`tokenPattern` default `#{...}#`)
  3. Task group Build

Variable de pipeline: `SERVICE_NAME=gateway|auth|engine`.

---

## 4. Azure DevOps — patrón Build + Release + Library

### 4.1 Inventario analizado

| Servicio | Build Id | Release Id | Variable Group Prod |
|----------|----------|------------|---------------------|
| Gateway | **584** | **366** | **391** `Produccion-Buklo-Microservice-Gateway` |
| Auth | **585** | **367** | **392** `Produccion-Buklo-Microservice-Auth` |
| Engine | **586** | **368** | **393** `Produccion-Buklo-Microservice-Engine` |
| Notifications | **587** | **369** | **394** `Produccion-Buklo-Microservice-Notifications` |
| Storage | **588** | **370** | **395** `Produccion-Buklo-Microservice-Storage` |
| AI | **589** | **371** | **396** `Produccion-Buklo-Microservice-AI` |
| Billing | **590** | **372** | **397** `Produccion-Buklo-Microservice-Billing` |
| EMR | **591** | **373** | **398** `Produccion-Buklo-Microservice-EMR` |
| Hacienda | **592** | **374** | **399** `Produccion-Buklo-Microservice-Hacienda` |
| Realtime | **593** | **375** | **400** `Produccion-Buklo-Microservice-Realtime` |
| Subscriptions | **594** | **376** | **401** `Produccion-Buklo-Microservice-Subscriptions` |
| Surveys | **595** | **377** | **402** `Produccion-Buklo-Microservice-Surveys` |
| Ticketing | **596** | **378** | **403** `Produccion-Buklo-Microservice-Ticketing` |
| Buklo-Server | **621** | **380** | **408** `Produccion-Buklo-Microservice-Buklo-Server` |

Proyecto: [DevOps](https://dev.azure.com/Shared-Service-GM/DevOps)  
Org: `Shared-Service-GM`

### 4.2 Convención de nombres

```text
Build-Buklo-Microservice-<Servicio>
Deploy-Desarrollo-UAT-Produccion-Buklo-Microservice-<Servicio>
Produccion-Buklo-Microservice-<Servicio>

servicesname = microservice-<servicio>-api   # recursos K8s
image        = microservice-<servicio>-api   # nombre imagen ACR (Deployment image: …/#{image}#…)
SERVICE_NAME = <servicio>                    # carpeta monorepo: auth | engine | gateway | notifications
appname      = microservice-<servicio>-api
```

Ejemplos:

- Auth → `servicesname`/`image` = `microservice-auth-api`, `SERVICE_NAME=auth`
- Engine → `microservice-engine-api`, `SERVICE_NAME=engine`
- Notifications → `microservice-notifications-api`, `SERVICE_NAME=notifications`

**Deployment `image:`** siempre:

```yaml
image: "#{containerregistries}#/#{image}##{ambiente}#:#{tag}#"
```

### 4.3 Tres capas de variables

#### A) Variables del **Build** (tab Variables — no Library)

**Mismas keys en cada pipeline**; cambian los valores. Modelo: [Build 584](https://dev.azure.com/Shared-Service-GM/DevOps/_apps/hub/ms.vss-ciworkflow.build-ci-hub?_a=edit-build-definition&id=584&view=Tab_Variables).

| Variable | Ejemplo 584 Gateway | ¿Cambia por servicio? | Rol |
|----------|---------------------|------------------------|-----|
| `appname` | `microservice-gateway-api` | **Sí** | Nombre lógico |
| `image` | `microservice-gateway-api` | **Sí** | Imagen ACR (TG Build) |
| `rutadockerfile` | `./Dockerfile.service` | A veces | Path Dockerfile |
| `conexcontainerregistries` | `ACR Hub-2` | No | Service connection ACR |
| `tag` | `$(Build.BuildId)` | No | Tag de imagen |
| `SERVICE_NAME` | `gateway` | **Sí** | Carpeta `services/` + token Dockerfile |
| `system.debug` | `false` | No | Diagnóstico (queue time) |

No crear `system.collectionId` / `system.definitionId` / `system.teamProject`. El Build **no** linkea Variable Groups.

#### B) Variable Group **Produccion-*** (deploy / token replace del YAML)

| Variable | Ejemplo | ¿Cambia por servicio? | Rol |
|----------|---------|------------------------|-----|
| `servicesname` | `microservice-auth-api` | **Sí** | Nombres K8s (`#{servicesname}#`) |
| `image` | `microservice-auth-api` | **Sí** (suele = `servicesname`) | Imagen ACR + `#{image}#` |
| `pipeline` | `Build-Buklo-Microservice-Auth` | **Sí** | Nombre del Build |
| `rutadockerfile` | `./Dockerfile.service` | A veces | Path Dockerfile |
| `ambiente` | `prod` | No (mismo env) | Sufijo tag |
| `containerregistries` | `gmonhubacreastus20001.azurecr.io` | No | Registry |
| `conexcontainerregistries` | `ACR Hub-2` | No | Connection ACR |
| `conexkubernetes` | `AKS-PROD-SVC` | No | Connection K8s |
| `namespace` | `application-services` | No | Namespace AKS |
| `aksClusterName` | `gmon-prod-aks-eastus2-0004` | No | Cluster |
| `aksResourceGroup` | `gmon_prod_rg_eastus2_0001` | No | RG |
| `tag` | `$(Build.BuildId)` | No | Tag imagen |
| `reqcpu` / `reqmem` | `75` / `128` | Raro | Requests |
| `limcpu` / `limmem` | `300` / `300` | Raro | Limits |

**Mismas keys en todas las Library Prod Buklo.** Copiar valores de ambiente; cambiar `servicesname` / `image` / `pipeline`. Plantilla: [`ado-classic-from-scratch.md`](./ado-classic-from-scratch.md) §2.1.

**No** incluye (a propósito en Prod): `image_pull_secret` (solo Dev/UAT).

#### C) Variables de stage Release

- `containerRegistryUsername` / `containerRegistryPassword` — viven como
  variables de AMBIENTE (`environments[N].variables`), no como task
  input directo. El task input del Task Group de deploy referencia cada
  una por macro nativa de ADO: `$(containerRegistryUsername)` /
  `$(containerRegistryPassword)` — **nunca** un literal ni el placeholder
  `${ADO_SECRET_*}` de este repo (ese placeholder solo va del lado de
  `environments[N].variables.containerRegistryPassword.value`, resuelto
  recién al aplicar). Ver `container-registry-secret-source.md` y la
  memoria de proyecto `ado-release-containerregistry-macro-bug` (bug real
  2026-09-08 al confundir ambos).
- `namespace=$(namespace)` pasado al Task group de deploy

### 4.4 Flujo del Build (clásico)

Orden observado (Auth 585 / Engine 586) — **correcto**:

1. **File Creator** → `Dockerfile.service`
2. **Replace tokens** → root `./`, file `Dockerfile.service`, pattern `#{...}#`
3. **File Creator** → `deployment-dev.yml` / `deployment-uat.yml` / `deployment-prod.yml`
4. **Task group: Build** → `$(image)`, `$(rutadockerfile)`, `$(ambiente)`, `$(tag)`, `$(conexcontainerregistries)`

> Dev/UAT File Creators: en los pipelines aún no configurados, suelen traer contenido
> residual de un clon viejo (nombres `-core-`, `#{servicesname}#` en la imagen en vez de
> `#{image}#`, puerto de métricas extra, bloque `env:` redundante) — **no asumir que están
> vacíos**; hay que vaciarlos y reescribirlos según §9 antes de dar el servicio por
> configurado en Dev/UAT.

### 4.5 Flujo del Release (clásico)

Stages típicos:

| Stage | Variable Group | Task group deploy | Estado |
|-------|----------------|-------------------|--------|
| Desarrollo | Library propia `Desarrollo-Buklo-Microservice-<Servicio>` (ver §9) — **antes de configurar**, suele venir linkeada a una Library prestada de otra app (ej. `Desarrollo-Buklo-ontology-web`, era id 383 en Gateway/366 antes de configurarlo) | Deployment-MultiStage-Cluster-Desarrollo | **Gateway: hecho (Library id 418)**. Resto de servicios: configurar (§9) |
| UAT | Library propia `UAT-Buklo-Microservice-<Servicio>` (ver §9) — mismo caso, ej. `UAT-Buklo-ontology-web` era id 384 en Gateway/366 antes de configurarlo | Deployment-MultiStage-Cluster-Desarrollo | **Gateway: hecho (Library id 419)**. Resto de servicios: configurar (§9) |
| **Produccion** | **392 Auth / 393 Engine / 394 Notifications / 391 Gateway / …** | **Deployment-Azur-Aks-v3** | **Activo — no tocar** |

Artefacto primario = Build correspondiente (`Latest`), p. ej. `_Build-Buklo-Microservice-Notifications`.

#### Continuous deployment trigger (obligatorio)

Tras clonar el Release, el **Continuous deployment trigger** del artefacto suele quedar **Disabled**. Hay que **activarlo**:

1. En el editor del Release → clic en el ícono de rayo del artefacto (Build).
2. Panel **Continuous deployment trigger** → poner en **Enabled**.
3. Guardar el Release.

Así, cada Build exitoso crea un Release automáticamente. El **Pull request trigger** puede quedar Disabled.

> Si el CD trigger queda apagado, el pipeline no despliega solo aunque el Build termine bien; hay que crear el Release a mano.

#### Artifact filter en stage Produccion (obligatorio — rama `release`)

Además del CD del artefacto, el stage **Produccion** debe filtrar por rama para no desplegar builds de otras branches (p. ej. `main`/`development`) que pueden traer YAML o tags incorrectos → `ImagePullBackOff`, `acr-pull-secret`, etc.

1. En el editor del Release → clic en el **rayo / persona** del stage **Produccion** (triggers / pre-deployment conditions del stage).
2. **Triggers** → **Artifact filters** → **Enabled**.
3. Artifact source = el Build de ese servicio (ej. `_Build-Buklo-Microservice-Auth`).
4. Type = **Include**.
5. **Build branch** = `release` (sin `refs/heads/`; solo el nombre corto).
6. Build tags = vacío (salvo que usen tags a propósito).
7. Guardar el Release.

Equivalente en API (condition del environment Produccion):

```json
{
  "conditionType": "artifact",
  "name": "_Build-Buklo-Microservice-<Servicio>",
  "value": "{\"sourceBranch\":\"release\",\"tags\":[],\"useBuildDefinitionBranch\":false,\"createReleaseOnBuildTagging\":false}"
}
```

> Tras clonar un Release, este filtro **no** se hereda bien a veces: hay que verificarlo. En `\Buklo` ya quedó aplicado a webs + microservicios (Prod = `release`).

### 4.6 `imagePullSecrets` e Ingress

| Archivo | `imagePullSecrets` | Ingress `ingressClassName` |
|---------|---------------------|----------------------------|
| `./deployment-dev.yml` / `./deployment-uat.yml` | `acr-pull-secret` | `nginx` |
| `./deployment-prod.yml` | **No** (tal cual Prod; pull por identidad nodo–ACR) | **Tal cual Prod** (gateway: `internal-ingress`) |

Anotaciones nginx: iguales en Dev y UAT. Prod no se reescribe para forzar `nginx`. Guía: [`ado-classic-from-scratch.md`](./ado-classic-from-scratch.md) §3.4 Paso 3.

---

## 5. Secretos y ConfigMap por servicio (Prod)

### 5.1 Gateway

**Secret:** `CRYPTOP_*`, `AES_IV`, `REDIS_PASSWORD`, `ELASTICSEARCH_PASSWORD`, `JIRA_WEBHOOK_SECRET`  
**ConfigMap:** discovery `HOST_*`/`PORT_*` de microservicios, Redis, Elastic, rate limit, etc.  
**Sin DB** (gateway no usa `DATABASE_*`).

### 5.2 Auth

**Secret (Joi required):** `DATABASE_USER`, `DATABASE_PASS`, `DATABASE_NAME`, `CRYPTO_SECRET_KEY`, `CRYPTO_IV_ENCRYPT`, `RABBITMQ_URL`  
**ConfigMap:** `DATABASE_SERVER`, puertos DB, `RABBITMQ_QUEUE`, `HOST_ENGINE`/`HOST_NOTIFICATIONS`, OAuth/JWT flags, etc.

DB apuntada (análisis):

- Server: `gmon-prod-sqlmi-eastus2-0001.15c9ad07b4c3.database.windows.net`
- Name: `buklo_lab_JALFARO_20260611`
- User: `usr_app_engine`

### 5.3 Engine

**Secret (Joi required):** `DATABASE_*` (user/pass/name), `CRYPTOP_*`, `REDIS_PASSWORD`  
**ConfigMap:** flags DB, `REDIS_HOST`, `PROVIDER_SALESFORCE`, `MICROSERVICE_PORT=3001`, `HTTP_PORT=4001`, `PREFIX=api`, `VERSION=v1`, discovery storage/billing, Azure endpoints,  
`QDRANT_URL=http://qdrant-service.data-services.svc.cluster.local:6333`

Pendiente típico: valor real de `PROVIDER_SALESFORCE` (no dejar `CHANGE_ME_*`).

### 5.4 Notifications

**Secret (Joi required):** `DATABASE_USER`, `DATABASE_PASS`, `DATABASE_NAME`  
**ConfigMap:** puertos `NOTIFICATIONS_TCP_PORT=3004` / `NOTIFICATIONS_HTTP_PORT=4003`, DB server, `STORAGE_TCP_HOST` → `microservice-storage-api-service…:3005`

### 5.5 Storage

**Secret (Joi required):** `AZURE_BLOB_STORAGE` (connection string; cuenta legacy `montecristobucket`)  
**ConfigMap:** `STORAGE_TCP_PORT=3005`, `STORAGE_HTTP_PORT=4005`, `BODY_PARSER_LIMIT=100mb`, `STORAGE_WRITE_URL_*`  
**Sin DB.** Health verifica listado de containers en Blob.

### 5.6 AI

**Solo TCP** (`NestFactory.createMicroservice`) — sin servidor HTTP ni path `/health`.  
**Probes:** `tcpSocket` puerto `3006`.  
**Secret:** `AZURE_OPENAI_API_KEY`, `REDIS_PASSWORD`, `ELASTICSEARCH_PASSWORD`, `DB_USER` / `DB_PASSWORD` / `DB_NAME`  
**ConfigMap:** `HOST_AI_CORE`/`PORT_AI_CORE=3006`, Azure OpenAI endpoint/deployment, Redis, `DB_HOST`, `HOST_ENGINE`/`PORT_ENGINE`, `QDRANT_URL`, Elastic URL, `LLM_PROVIDER_PRIORITY=azure`, `AI_CORE_AUTH_ENABLED=false` (hasta alinear secret con gateway).

> Nota: el código usa `DB_*` (no `DATABASE_*`).

### 5.7 Billing (payment)

**HTTP + TCP** (Nest HTTP app + microservice TCP).  
**Puertos:** TCP `PORT_PAYMENT=3003`, HTTP `PORT=4004` (no compartir el mismo puerto).  
**Probes:** `/api/v1/health/liveness` (evitar `/health` con check de heap 150MB en pods chicos).  
**Secret:** `DATABASE_*`, `REDIS_PASSWORD`, `ELASTICSEARCH_PASSWORD`, `POWERTRANZ_BAC_MERCH_ID` / `PWD`  
**ConfigMap:** Redis, Elastic, Powertranz URLs, rate limit/queue.  
**Discovery:** gateway `HOST_PAYMENT` / engine `HOST_BILLING` → `microservice-billing-api-service:3003` (antes `payment-api` / puerto 3004 en conflicto con notifications).

### 5.8 EMR

**HTTP + TCP** (`EMR_TCP_PORT=3010`, `EMR_HTTP_PORT=4010`).  
**Probes:** `tcpSocket :3010` — el `AppModule` actual solo carga `ConfigModule` (controllers appointment/pharmacy aún no cableados; no hay `/health` HTTP).  
**Secret:** `APPOINTMENT_INTERNAL_TOKEN`, `DATABASE_*` (preparado).  
**Discovery gateway:** ya apunta a `microservice-emr-api-service:3010`.

### 5.9 Hacienda

**Solo HTTP** (`PORT=3012`). `main.ts` lee `process.env.PORT` (antes hardcode 3001).  
**Health:** `GET /hacienda/health` (puede devolver `degraded` si Rabbit/signer no están listos; sigue HTTP 200).  
**Secret:** `DB_*`, `REDIS_PASSWORD`, `RABBITMQ_URL`, `HACIENDA_*`, `CERT_PASSWORD` (placeholders CHANGE_ME a completar).  
**ConfigMap:** URLs Hacienda CR, Redis, `SIGNER_URL` (sidecar C#).  
**Sin TCP Nest** por ahora.

### 5.10 Realtime

**HTTP + WebSocket** (`REALTIME_PORT=3011`, Socket.IO `/chat`).  
**Probes:** `tcpSocket :3011`.  
**Secret:** `REDIS_PASSWORD`, `CRYPTOP_*`.  
**ConfigMap:** Redis, CORS WS, discovery `HOST_AUTH`/`HOST_ENGINE`/`HOST_AI_CORE`.  
**Discovery gateway:** ya apunta a `microservice-realtime-api-service:3011`.

> Autónomo: SharedModule slim (crypto + TCP + cache) vive dentro de `services/realtime` (sin depender del gateway).

### 5.11 Subscriptions

**HTTP + TCP** (`SUBSCRIPTIONS_TCP_PORT=3009`, `SUBSCRIPTIONS_HTTP_PORT=4009`).  
**Probes:** `tcpSocket :3009` — Phase 1 usa `SubscriptionUseCase` stub; sin `/health` HTTP.  
**Secret:** `SUBSCRIPTION_INTERNAL_TOKEN`, `SF_CARD_AES_KEY` (placeholders CHANGE_ME).  
**ConfigMap:** bind puertos, resilience/idempotency, `HOST_ENGINE`/`PORT_ENGINE`.  
**Discovery gateway:** ya apunta a `microservice-subscriptions-api-service:3009` (`HOST_SUBSCRIPTIONS` / `PORT_SUBSCRIPTIONS`).

> **Nota funcional:** controllers TCP cableados; ejecución real sigue en Engine Core hasta Phase 2 (reemplazar stub).

### 5.12 Surveys

**HTTP + TCP** (`SURVEYS_TCP_PORT=3008`, `SURVEYS_HTTP_PORT=4008`).  
**Probes:** `tcpSocket :3008`.  
**Secret:** `DB_USER` / `DB_PASSWORD` / `DB_NAME`, `ELASTICSEARCH_PASSWORD`.  
**ConfigMap:** `DB_HOST`/`DB_PORT`, Elastic URL/user, bind puertos.  
**Código:** `SurveyRepository` usa `DB_*`; analytics usa Elastic (sin URL → ceros, no crash).  
**Discovery gateway:** ya apunta a `microservice-surveys-api-service:3008`.

### 5.13 Ticketing

**HTTP + TCP** (`TICKETING_TCP_PORT=3007`, `TICKETING_HTTP_PORT=4007`).  
**Probes:** `tcpSocket :3007`.  
**Secret:** `DB_*`, `AZURE_OPENAI_API_KEY`, `JIRA_API_TOKEN` (**CHANGE_ME** — completar), `JIRA_WEBHOOK_SECRET` (mismo valor que gateway).  
**ConfigMap:** SQL, `QDRANT_URL`, Azure OpenAI endpoint/deployments, umbrales AI, `JIRA_BASE_URL` / `JIRA_EMAIL` / `JIRA_PROJECT_KEY=PFS`.  
**Código:** `database.config` (`DB_*`), Qdrant (degradedMode), Jira sync (falla en sync si falta token), AI factory.  
**Discovery gateway:** ya apunta a `microservice-ticketing-api-service:3007`.

---

## 6. Verificación en cluster (Prod)

Context: `gmon-prod-aks-eastus2-0004`  
Namespace: `application-services`

Hallazgos al revisar:

| API | Estado | Service | Ingress | Health |
|-----|--------|---------|---------|--------|
| `microservice-gateway-api` | Running | 80→3000 | Sí | `/api/v1/health` OK |
| `microservice-auth-api` | Running | 3002+4002 | No | `/health:4002` OK |
| `microservice-engine-api` | Running | 3001+4001 | No | `/api/v1/health:4001` OK |

Cada uno con ConfigMap + Secret + SA + Deployment + Service + HPA alineados al YAML Prod.

Observaciones:

- `imagePullSecrets` vacío en los tres (token no mapeado en Prod).
- HPA Prod: `minReplicas: 1` / `maxReplicas: 1` (sin scale-out).
- CI path filters en algunos Builds aún apuntan a `services/gateway/**` (ajustar a `services/<servicio>/**`).

---

## 7. Checklist para clonar un nuevo microservicio

1. Crear `k8s/deployments/deployment-<servicio>-prod.yml` (puertos/health/secretos del código).
2. En el Deployment, `image:` debe ser `#{containerregistries}#/#{image}##{ambiente}#:#{tag}#` (**no** `#{servicesname}#`).
3. HPA: `minReplicas: 1` / `maxReplicas: 1`.
4. Clonar Build clásico → renombrar `Build-Buklo-Microservice-<Servicio>`.
5. Ajustar variables Build: `SERVICE_NAME`, `image`, `appname`, `rutadockerfile`.
6. File Creator prod = YAML del servicio; Ignore/posponer Dev/UAT.
7. Trigger path: `+services/<servicio>/**`.
8. Clonar/crear Variable Group `Produccion-Buklo-Microservice-<Servicio>` con el set de keys de la sección 4.3.B (`servicesname` + `image`).
9. Clonar Release → stage Produccion linkea esa Library + `Deployment-Azur-Aks-v3`.
10. Activar **Continuous deployment trigger** del artefacto Build (rayo → Enabled). Pull request trigger puede quedar Disabled.
11. En stage **Produccion** → Triggers → **Artifact filters** Enabled, **Build branch = `release`** (Include). Ver §4.5.
12. Verificar en AKS: deploy, svc ports, probes, envFrom, health, imagen resuelta con `#{image}#`, HPA 1–1.

---

## 8.1 Carpetas reales de `services/` en el repo (confirmado en vivo 2026-08-27)

Listado real de `buklo-backend` (`Buklo` project, MCP `repo_file`, branch
`development`) — usar esto para validar/corregir el `pathFilters` del CI
trigger de cada Build (§9.4 paso 1b), no asumir el nombre por el nombre
del servicio:

```
services/ai  services/auth  services/bdip  services/billing
services/buklo-server  services/emr  services/engine  services/gateway
services/hacienda  services/notifications  services/realtime
services/storage  services/subscriptions  services/surveys
services/ticketing  services/trackflow
```

**`bdip` y `trackflow` no están en la tabla de §4.1** — son 2 carpetas de
servicio que existen en el repo pero no tienen Build/Release/Library
documentados todavía en esta guía. Antes de asumir que son parte de los
"13 microservicios Buklo" pendientes, confirmar con el usuario si tienen
pipeline propio ya creado (buscar en el inventario por nombre) o si
todavía no se armó ninguno para ellos.

## 8. Referencias rápidas

| Recurso | URL / ruta |
|---------|------------|
| Proyecto ADO | https://dev.azure.com/Shared-Service-GM/DevOps |
| Build Gateway 584 | `_build?definitionId=584` (rev 22 — Dev/UAT + agrupación de merges + Reportar-resultado-HU, 2026-08-26) |
| Release Gateway 366 | `_release?definitionId=366` (rev 7 — Dev/UAT relinkeado + artifact trigger + Reportar-resultado-HU en los 3 stages + approval gate Producción, 2026-08-26) |
| VG Gateway Prod 391 | Variable Group `Produccion-Buklo-Microservice-Gateway` |
| VG Gateway Desarrollo 418 | Variable Group `Desarrollo-Buklo-Microservice-Gateway` |
| VG Gateway UAT 419 | Variable Group `UAT-Buklo-Microservice-Gateway` |
| Build Auth 585 | `_build?definitionId=585` |
| Release Auth 367 | `_release?definitionId=367` |
| VG Auth 392 | Variable Group `Produccion-Buklo-Microservice-Auth` |
| Build Engine 586 | `_build?definitionId=586` |
| Release Engine 368 | `_release?definitionId=368` |
| VG Engine 393 | Variable Group `Produccion-Buklo-Microservice-Engine` |
| Build Notifications 587 | `_build?definitionId=587` |
| Release Notifications 369 | `_release?definitionId=369` |
| VG Notifications 394 | Variable Group `Produccion-Buklo-Microservice-Notifications` |
| Build Storage 588 | `_build?definitionId=588` |
| Release Storage 370 | `_release?definitionId=370` |
| VG Storage 395 | Variable Group `Produccion-Buklo-Microservice-Storage` |
| Build AI 589 | `_build?definitionId=589` |
| Release AI 371 | `_release?definitionId=371` |
| VG AI 396 | Variable Group `Produccion-Buklo-Microservice-AI` |
| Build Billing 590 | `_build?definitionId=590` |
| Release Billing 372 | `_release?definitionId=372` |
| VG Billing 397 | Variable Group `Produccion-Buklo-Microservice-Billing` |
| Build EMR 591 | `_build?definitionId=591` |
| Release EMR 373 | `_release?definitionId=373` |
| VG EMR 398 | Variable Group `Produccion-Buklo-Microservice-EMR` |
| Build Hacienda 592 | `_build?definitionId=592` |
| Release Hacienda 374 | `_release?definitionId=374` |
| VG Hacienda 399 | Variable Group `Produccion-Buklo-Microservice-Hacienda` |
| Build Realtime 593 | `_build?definitionId=593` |
| Release Realtime 375 | `_release?definitionId=375` |
| VG Realtime 400 | Variable Group `Produccion-Buklo-Microservice-Realtime` |
| Build Subscriptions 594 | `_build?definitionId=594` |
| Release Subscriptions 376 | `_release?definitionId=376` |
| VG Subscriptions 401 | Variable Group `Produccion-Buklo-Microservice-Subscriptions` |
| Build Surveys 595 | `_build?definitionId=595` |
| Release Surveys 377 | `_release?definitionId=377` |
| VG Surveys 402 | Variable Group `Produccion-Buklo-Microservice-Surveys` |
| Build Ticketing 596 | `_build?definitionId=596` |
| Release Ticketing 378 | `_release?definitionId=378` |
| VG Ticketing 403 | Variable Group `Produccion-Buklo-Microservice-Ticketing` |
| Dockerfile | `/Dockerfile.service` (raíz del repo) |
| Token automatización (local) | `C:\mantenimientos\azure devops\token.txt` |

---

## 9. Convención Dev/UAT (definida 2026-08-26, empezando por Gateway)

Producción queda **siempre** intacta al aplicar esta convención: no se toca
`deployment-prod.yml`, el stage Produccion, su Library `Produccion-Buklo-Microservice-<Servicio>`
ni el task group `Deployment-Azur-Aks-v3`.

### 9.1 Punto de partida: copiar el `deployment-prod.yml` vigente

`deployment-dev.yml`/`deployment-uat.yml` se arman copiando el contenido
**actual** de `deployment-prod.yml` de ESE Build (no una plantilla genérica)
y aplicando solo los cambios de la tabla de abajo. Antes de escribir nada,
vaciar el File Creator dev/uat existente — casi todos traen contenido
residual de un clon viejo (ver nota en §4.4), no asumir que están vacíos.

| Campo | Producción | Desarrollo | UAT |
|-------|-----------|------------|-----|
| Namespace K8s (token `#{namespace}#`, valor viene de la Library) | `application-services` | `desarrollo` | `uat` |
| FQDN de discovery (`HOST_*`, `ENDPOINT_*`) | `<servicio>.application-services.svc.cluster.local` | `<servicio>.desarrollo.svc.cluster.local` | `<servicio>.uat.svc.cluster.local` |
| `REDIS_HOST` | `10.4.0.101` | `172.16.2.243` | `172.16.2.243` (mismo valor que Dev) |
| `imagePullSecrets` | (ninguno) | `- name: acr-pull-secret` **fijo, sin token** | `- name: acr-pull-secret` **fijo, sin token** |
| `nodeSelector` | fijo por servicio (ej. Gateway: `userpool03`) | sin nodeSelector | sin nodeSelector |
| Ingress (solo servicios con Ingress — ver §2.1: Gateway y Buklo-Server) | host `microservice-<servicio>-api.grupomontecristo.com`, `ingressClassName` tal cual Prod (Gateway: `internal-ingress`) | host `microservice-<servicio>-api-dev.gmontecristo.com`, `ingressClassName: nginx`, `secretName: gmontecristo-secret` | host `microservice-<servicio>-api-uat.gmontecristo.com`, `ingressClassName: nginx`, `secretName: gmontecristo-secret` |
| `spec.replicas` del Deployment | fijo por servicio (ej. Gateway: `2`) | **`1`** (decisión explícita, menor carga que Prod — confirmado con el usuario en Gateway) | **`1`** (mismo criterio que Dev) |
| Todo lo demás (ES URL, rate limits, secretos, probes, HPA, RBAC, tokens `#{servicesname}#`/`#{image}#`/etc.) | — | **idéntico a Prod** | **idéntico a Prod** |

Los secretos (`data:` del `kind: Secret`) se copian con el **mismo valor
base64** que ya usa Prod para esa misma key — así es como ya estaba en los
residuales vistos en Gateway (mismo Redis/crypto/ES password en Prod y en
el dev viejo). Si una key del Secret viejo no existe en el Secret actual de
Prod (ej. `RSA_PASSPHRASE` en el Gateway viejo), se deja afuera al copiar
— confirmar con el equipo de la app si hace falta antes de dar por
cerrado ese servicio.

### 9.2 Libraries nuevas por servicio

Se crean 2 Libraries por servicio, **`Desarrollo-Buklo-Microservice-<Servicio>`**
y **`UAT-Buklo-Microservice-<Servicio>`**, con el mismo set de keys y
mismos valores que la Library de Producción de §4.3.B, salvo:

| Variable | Cambia a |
|----------|----------|
| `ambiente` | `dev` / `uat` |
| `namespace` | `desarrollo` / `uat` |
| `conexkubernetes` | `AKS-DEV-SVC` (mismo service connection para Dev y UAT — comparten cluster) |
| `aksClusterName` / `aksResourceGroup` | no se incluyen (solo existen en la Library de Prod) |

`reqcpu`/`reqmem`/`limcpu`/`limmem` y el resto quedan **iguales a Prod**
(no se reduce a propósito, salvo pedido explícito). No se agrega
`image_pull_secret` como key de Library — el `acr-pull-secret` va fijo en
el YAML (ver 9.1), no templado.

Antes de configurar, el stage Desarrollo/UAT de un Release suele estar
linkeado a una Library **prestada de otra app** (residual del clon —
confirmado en Gateway/366: Desarrollo→id 383 `Desarrollo-Buklo-ontology-web`,
UAT→id 384 `UAT-Buklo-ontology-web`). Verificar el id real de la Library
linkeada en cada Release antes de asumir cuál reemplazar — no asumir que
coincide con el id de otro servicio.

### 9.3 Task groups de los stages (no cambian)

Desarrollo y UAT ya usan `Deployment-MultiStage-Cluster-Desarrollo` (el
mismo, para ambos stages) — comparten el cluster `AKS-DEV-SVC`. Producción
sigue con `Deployment-Azur-Aks-v3`. Esta convención **no** modifica ningún
task group, solo qué Library linkea cada stage y el contenido del File
Creator del Build.

### 9.4 Orden de aplicación por servicio

1. Confirmar en vivo Build/Release/Library ids reales del servicio (no
   asumir contra la tabla de §8 — verificar, ids pueden estar desactualizados).
1b. Confirmar que el CI trigger del Build tiene el `pathFilters` correcto
   (`+services/<servicio>/**`, comparar contra la lista real de §8.1) —
   **hallazgo real, Engine/Build 586, 2026-08-27**: tenía
   `+services/gateway/**` copiado del clon, corregido manualmente por el
   usuario en la UI. No es parte del alcance de esta convención tocarlo
   como escritura automática (es del Build, no del Dev/UAT), pero
   confirmarlo y avisar si está mal — no asumir que ya está bien.
2. Leer el `deployment-prod.yml` vigente de ESE Build (GET, no la copia de
   otro servicio).
3. Armar `deployment-dev.yml`/`deployment-uat.yml` según §9.1.
4. Crear las 2 Libraries según §9.2.
5. Relinkear los stages Desarrollo/UAT del Release a las Libraries nuevas.
6. Aplicar vía `Apply-AdoClassicPlan.ps1` (aprobación explícita del
   usuario — ver `authorization.md`).
7. Confirmar Continuous deployment trigger y Artifact filter del stage
   Desarrollo/UAT si corresponde (mismo criterio que Producción, §4.5) —
   el artifact filter usa el branch real de CI de ESE Build (confirmar
   `triggers[].branchFilters` con GET, no asumir `development`/`uat` a
   ciegas — en Gateway coincidió, pero verificar).
8. Agregar el mecanismo de agrupación de merges (`Evaluar-ventana-agrupacion`
   → delay `Ventana de agrupacion` → `Gana-el-mas-nuevo`) + `Reportar-resultado-HU`
   al Build, calcado de `Build-administracion-proyectos-web` (id 624, GET
   fresco — reusar `New-AdoMergeBatchingPhases`/`New-AdoGanaElMasNuevoStep`/
   `New-AdoReportarResultadoHuBuildStep` de `New-AdoClassicPayloads.ps1`
   solo para generar los fragmentos, **nunca** `New-AdoBuildDefinitionPayload`
   completo — ese reconstruye TODO el Build desde un `Plan` y perdería los
   steps propios de la app que no siguen la plantilla estándar, ej.
   `File Creator dockerfile`/`Replace tokens`). Es un **splice quirúrgico
   manual sobre el GET fresco**: nuevo step al principio
   (`Gana-el-mas-nuevo`), TODOS los steps existentes intactos en el mismo
   orden relativo, nuevo step al final (`Reportar-resultado-HU`) — nunca
   reemplazar/reordenar lo que ya funciona. Agregar `Task group: Reportar-resultado-HU`
   a los 3 stages del Release (Desarrollo/UAT/**Producción incluida** —
   únicamente ese task group, nada más de su config — confirmar con diff
   campo a campo que nada más cambió).

   **Trampa real, silenciosa, confirmada en un Build real (Build 21316,
   Build 584, 2026-08-26)**: además de agregar el step `Task group:
   Gana-el-mas-nuevo`/`Reportar-resultado-HU`, cada uno de los 3 phases
   (`Batch_Gate`/`Batch_Window`/`Job_1` o el phase que compile) necesita
   su propio campo `dependencies` apuntando al phase anterior — sin esto,
   Azure DevOps nunca puebla `dependencies.Batch_Window` en el contexto de
   evaluación de la `condition` del phase siguiente (llega `Null`), y ese
   phase se **salta por completo en silencio**: el Build termina en VERDE
   sin haber compilado nada. **Esto nunca da error de validación ni de la
   API al aplicar el plan** — solo se manifiesta al correr un Build real,
   por eso puede pasar desapercibido mucho tiempo (pasó en Build 624
   también, nunca detectado porque ese pipeline no había corrido un Build
   real todavía). Shape exacto (confirmado contra `Buklo-frontend-portal-Build`,
   552, real, en producción, GET fresco):
   ```json
   "dependencies": [ { "scope": "Batch_Gate", "event": null } ]
   ```
   **Es un ARRAY de 1 objeto, no un objeto simple** — enviar un objeto
   simple (`{"scope":...}` sin corchetes) hace que Azure DevOps ignore el
   campo en silencio, sin rechazar el PUT ni avisar de ninguna forma (así
   fue como se coló este bug la primera vez). `Batch_Window.dependencies`
   apunta a `{scope:"Batch_Gate"}`; el phase que compila (`Job_1` o el que
   corresponda) apunta a `{scope:"Batch_Window"}`; `Batch_Gate` (el
   primero) no lleva `dependencies` en absoluto. Ya corregido en
   `New-AdoMergeBatchingPhases`/`New-AdoBuildDefinitionPayload`
   (`New-AdoClassicPayloads.ps1`) — cualquier Build creado/actualizado
   DESPUES de 2026-08-26 con estas funciones ya lleva el shape correcto;
   verificar igual con un diff contra Build 552 después de aplicar,
   nunca asumir que el generador ya está bien solo porque no dio error.
9. Confirmar si el stage Producción tiene `preDeployApprovals` real
   configurado (approver asignado, `isAutomated:false`) — algunos
   pipelines clonados quedan con `isAutomated:true` (sin gate) o con el
   approval activado en la UI pero sin ningún approver (rechaza guardar
   hasta completarlo). Si falta, agregar el mismo approver que usa
   `Deploy-Desarrollo-UAT-Produccion-Administracion-Proyectos-Web`
   (`[Shared-Service-GM]\Release Executers`, id `397ddbfe-1d60-4533-a4c9-b099f80ac154`
   — confirmar con GET fresco contra esa referencia, no hardcodear el id
   de memoria) para mantener la convención, salvo que el usuario pida
   otro approver. `isAutomated` y `approver` van SIEMPRE en el mismo PUT
   (Azure DevOps rechaza uno sin el otro). Esta es la 2ª y última
   excepción puntual a "no tocar Producción" de esta convención — solo
   ese campo, verificar con diff que nada más de Producción cambió.
   **Ojo con el field-stripping acá**: `preDeployApprovals.approvals[0]`
   tiene su propio `id` de servidor (ese sí hay que quitarlo antes del
   PUT), pero `approvals[0].approver.id` es el GUID real de la identidad
   del approver (ese NUNCA se quita) — son 2 campos `id` en 2 niveles
   distintos del mismo objeto, fácil de confundir.
10. **`environments[].currentRelease` y `environments[].properties` —
    tratamiento DISTINTO para cada uno** (hallazgo real, Gateway + Auth,
    2026-08-27, confirmado con GET fresco antes/después en los 2
    servicios y con un intento explícito de restaurar ambos campos):

    - **`properties`** (integración con Azure Boards —
      `BoardsEnvironmentType`/`LinkBoardsWorkItems`) **SÍ hay que
      preservarlo**: si el environment ya tenía datos reales ahí
      (`{"BoardsEnvironmentType":{"$type":"System.String","$value":"unmapped"},"LinkBoardsWorkItems":{"$type":"System.String","$value":"False"}}`
      es el valor típico visto en ambos servicios), **no** incluir
      `properties` en la lista de campos a quitar del field-stripping —
      copiarlo tal cual vino del GET al body del PUT. Confirmado
      escribible: un PUT que lo incluye explícito SÍ lo persiste (se
      verificó con GET inmediato después, en los 2 servicios).
    - **`currentRelease`** (puntero a la última instancia de Release
      real desplegada a ese environment, ej. `{"id":6926,"url":".../releases/6926",...}`)
      **es de solo lectura / calculado por el servidor** — un PUT que lo
      incluye explícito con un id real es aceptado (200) pero **el
      servidor lo ignora en silencio y lo devuelve en `0`** igual que
      si nunca se hubiera enviado (confirmado con un intento explícito
      de restauración en Release 367/Auth: el PUT "funcionó" para
      `properties` en el mismo body, pero no para `currentRelease`). **No
      intentar prevenir ni restaurar este campo desde este flujo** — no
      tiene efecto, es trabajo sin resultado. Se resetea a `0` en
      CUALQUIER `update-release-definition` sobre un environment que
      tenga (o haya tenido) un release real, sin importar qué otra parte
      del body se esté cambiando — es un efecto colateral inevitable del
      endpoint de definición, no algo específico de este mecanismo de
      field-stripping. Probablemente se recalcula solo la próxima vez que
      haya un despliegue real a ese environment (no verificado, fuera de
      alcance de este flujo forzarlo). El release real en sí (sus logs,
      artifacts, `deploySteps`, historial) **no se pierde** — sigue
      existiendo intacto como recurso independiente, consultable por su
      propio id vía `GET .../release/releases/{id}`; lo único que se
      pierde es el puntero de conveniencia a nivel de la definición (que
      alimenta, entre otras cosas, algún widget de la UI de "qué está
      desplegado ahora").
    - **Antes de aplicar cualquier `update-release-definition`**, revisar
      con GET fresco si `environments[].currentRelease.id` de Producción
      (y de Desarrollo/UAT) es distinto de `0` — si lo es, avisar de que
      se va a perder ese puntero (sin poder evitarlo) antes de aplicar,
      no después. La mayoría de los 10 microservicios Buklo que faltan
      van a tener despliegues reales en Producción (a diferencia de
      Gateway, que era nuevo) — esto va a repetirse seguido.

**No asumir que el estado de un recurso en vivo es el mismo que la última
vez que se tocó** (hallazgo real, Gateway, 2026-08-26): entre dos pasos de
este mismo trabajo, alguien fuera de este flujo (probablemente el usuario
limpiando manualmente desde la UI) quitó los steps deshabilitados legado
de Build 584 sin avisar — el Build pasó de 12 a 6 steps entre un GET y el
siguiente. Siempre releer el recurso con un GET fresco antes de construir
un body de actualización, nunca reusar un conteo/estructura de un paso
anterior de la misma sesión.

**No reusar el JSON de plan generado para un servicio como plantilla de
otro** (hallazgo de revisión, Gateway, 2026-08-26): `New-AdoClassicAksPlan.ps1`
llena `repo.pathFilter`, `dockerfile.isMonorepo`, `dependencies.buildTaskGroup`
y `mergeBatching` con datos de **intake**, no verificados contra el Build
real — en Gateway/584 esos campos NO reflejan lo que el Build realmente
tiene (path filter monorepo real `+services/gateway/**`, task group legado
`Build` en vez de `Build-MultiStage`, sin batching). No afecta ningún
`update-*` (esos campos no se consumen para actualizar), pero si se copia
el plan de un servicio como base para el siguiente hay que volver a pasar
por el paso 1 de esta lista, no asumir que esa metadata ya es correcta.

---

*Documento generado a partir del análisis en repo + cluster + definiciones ADO (solo lectura). Actualizar cuando se configuren Dev/UAT o se agreguen más microservicios.*
