# Azure DevOps clásico — alta desde cero (sin clonar pipelines)

> **Nota 2026-08-26:** este doc queda como referencia del flujo manual
> anterior y de errores frecuentes (ver `SKILL.md` § enrutamiento). Para
> un pipeline AKS nuevo, la fuente primaria de datos/pasos es
> `ado-new-pipeline-intake-template.md` + `ado-classic-payload-templates.md`,
> no este archivo. En particular, las menciones de **`Task group: Build`**
> más abajo (§ tabla de familias, §4 "siempre") describen el estándar
> **viejo** — desde 2026-08-25 el default es **`Build-MultiStage`** (con
> agrupación de merges activa por default). No usar `Build` para un
> pipeline nuevo salvo que se pida explícitamente.

Cómo montar **Library + Build + Release** empezando en blanco, con lo que ya se sabe que debe llevar cada pieza.

Hay **dos familias** (no mezclar task groups ni variables):

| Familia | Referencia | Qué publica |
|---------|------------|-------------|
| **App → AKS** (Docker) | Build [584](https://dev.azure.com/Shared-Service-GM/DevOps/_apps/hub/ms.vss-ciworkflow.build-ci-hub?_a=edit-build-definition&id=584) | Imagen ACR + YAML K8s |
| **Base de datos** (DACPAC / SSDT) | Build [488](https://dev.azure.com/Shared-Service-GM/DevOps/_apps/hub/ms.vss-ciworkflow.build-ci-hub?_a=edit-build-definition&id=488&view=Tab_Variables) · Release [298](https://dev.azure.com/Shared-Service-GM/DevOps/_releaseDefinition?definitionId=298&_a=definition-pipeline) | DACPAC → apply SQL |

> No clona un pipeline existente.  
> Los **Task groups** de la org **sí se reutilizan**: se **añaden como un paso**, no se reescriben por dentro.

Complementos:

| Documento | Cuándo |
|-----------|--------|
| [ado-classic-playbook-any-project.md](./ado-classic-playbook-any-project.md) | Decisiones (Dockerfile en repo vs File Creator), checklist mixto, errores |
| [devops-guide.md](./devops-guide.md) | Caso Buklo (ids, puertos, YAML por servicio) |

Org de referencia: `Shared-Service-GM` · Proyecto pipelines: **DevOps**.

---

## 0. Qué se crea nuevo vs qué se reutiliza

| Pieza | ¿Desde cero? | Notas |
|-------|----------------|-------|
| Manifiesto K8s (`deployment-prod.yml`) | **Sí** | Tokens `#{…}#`, probes reales del código |
| Variable Group (Library) | **Sí** | Crear grupo vacío y cargar keys |
| Build clásico | **Sí** | New pipeline → Empty job; armar steps a mano |
| Release clásico | **Sí** | New release pipeline; artefacto + stages + tasks |
| Task group **Build** | **No** | Marketplace interno / org: añadir *Task group: Build* |
| Task group **Deployment-Azur-Aks-v3** | **No** | Añadir en stage Produccion |
| Service connections ACR / AKS | **No** (si ya existen) | `ACR Hub-2`, `AKS-PROD-SVC` |
| Task **File Creator** / **Replace tokens** | Marketplace | Extensiones ya instaladas en DevOps |

Si en otro proyecto **no** existen esos task groups, no inventes uno distinto: pide a DevOps de la org que los publique, o documenta el gap. Esta guía asume que ya están.

---

## 1. Antes de tocar Azure DevOps

Anota esto (sin valores “de otro servicio” copiados a ciegas):

```text
Producto / App:
Repo Git (ADO) + branch de Prod:          (Buklo: release)
Carpeta de código / path filter:
Dockerfile (ruta real):                   (ej. ./Dockerfile  o  ./Dockerfile.service)
Nombre recurso K8s (servicesname):
Nombre imagen ACR (image):                (puede = servicesname)
Namespace AKS:
Cluster / RG:
Service connection ACR / AKS:
Puerto(s) y probe (HTTP path o tcpSocket):
¿Ingress? ¿DB / Redis / HOST_*?
```

**Imagen en el YAML** (obligatorio):

```yaml
image: "#{containerregistries}#/#{image}##{ambiente}#:#{tag}#"
```

**No** uses `#{servicesname}#` en `image:`.

UTF-8 **sin BOM** en el YAML (BOM → error `uFEFF` al guardar File Creator por API/UI).

---

## 2. Library (Variable Group) — crear vacío

**Pipelines → Library → + Variable group**

Nombre:

```text
Produccion-<Producto>-<App>
```

Ejemplo: `Produccion-Buklo-Microservice-Auth`

Scope: proyecto **DevOps**. No hace falta “link secrets from Azure Key Vault” si los secretos van en el YAML `Secret` (base64).

### 2.1 Plantilla fija: mismas keys, cambian los valores

El set de variables es **siempre el mismo**. No inventes keys nuevas por app.  
Crea el grupo vacío y carga **estas 17 names**. Solo rellenas **Value**.

Dos capas de valores:

| Tipo | Keys | Qué pasa entre apps del mismo cluster/env |
|------|------|-------------------------------------------|
| **Fijas de ambiente** | ACR, AKS, namespace, `ambiente`, `tag` | Casi siempre **idénticas** (copiar de otra Library Prod del mismo cluster) |
| **Por app** | `servicesname`, `image`, `pipeline`, a veces `rutadockerfile` y resources | **Solo estas cambian** |

#### Keys de ambiente (copiar tal cual en Prod Buklo / AKS 0004)

| Key | Valor típico Prod (no cambia por microservicio) |
|-----|--------------------------------------------------|
| `ambiente` | `prod` |
| `containerregistries` | `gmonhubacreastus20001.azurecr.io` |
| `conexcontainerregistries` | `ACR Hub-2` |
| `conexkubernetes` | `AKS-PROD-SVC` |
| `namespace` | `application-services` |
| `aksClusterName` | `gmon-prod-aks-eastus2-0004` |
| `aksResourceGroup` | `gmon_prod_rg_eastus2_0001` |
| `tag` | `$(Build.BuildId)` |
| `reqcpu` | `75` |
| `reqmem` | `128` |
| `limcpu` | `300` |
| `limmem` | `300` |

Resources (`req*` / `lim*`) son el default. Súbelos **solo** si esa app lo necesita; no crees keys distintas.

Otro cluster / otro namespace (Dev, UAT, otro producto) → **mismas keys**, otros valores de ambiente.

#### Keys por app (únicas que sí cambian siempre)

| Key | Cómo se arma | Ejemplo Auth |
|-----|----------------|--------------|
| `servicesname` | Nombre K8s | `microservice-auth-api` |
| `image` | Nombre imagen ACR (sin registry/tag). Suele **=** `servicesname` | `microservice-auth-api` |
| `pipeline` | Nombre **exacto** del Build | `Build-Buklo-Microservice-Auth` |
| `rutadockerfile` | Ruta que usa el Task group Build | `./Dockerfile.service` (monorepo) o `./Dockerfile` (repo dedicado) |

`servicesname` e `image` se mantienen como **dos keys** aunque el valor coincida (por si un día divergen).

#### Cómo crear la siguiente Library (30 segundos)

1. New Variable group → nombre `Produccion-<Producto>-<App>`.
2. Pegar las **17 keys** de arriba.
3. Copiar de otra Library Prod del **mismo cluster** todos los valores de ambiente.
4. Cambiar solo `servicesname`, `image`, `pipeline` (y `rutadockerfile` si el Dockerfile no es el mismo).
5. Guardar. Linkear **solo** en el stage Produccion del Release (el Build no usa esta Library).

**No pongas en Prod:** `image_pull_secret` (salvo que el cluster lo exija **y** el secret exista). Un valor inventado (`acr-pull-secret`) provoca `FailedToRetrieveImagePullSecret`. No agregues keys de negocio (`DATABASE_*`, `HOST_*`): eso va en el YAML ConfigMap/Secret.

**Permissions:** Pipeline permissions → Allow a los Builds/Releases que la usen (o “open access” según política).

Guarda el grupo. El Build **no** lo linkea; el **Release stage Produccion** sí.

---

## 3. Build clásico — pipeline vacío

**Pipelines → New pipeline → Use the classic editor**  
(no YAML). **Empty job**.

### 3.1 Identidad

| Campo | Valor |
|-------|--------|
| Name | `Build-<Producto>-<App>` |
| Folder | p. ej. `\Buklo` |
| Agent pool | el de la org (p. ej. Azure Pipelines / pool con Docker) |
| Get sources | Azure Repos Git → **repo correcto** |
| Default branch | rama de Prod (`release`) |

### 3.2 Variables del **pipeline** (tab Variables — no Library)

Referencia real: [Build 584 Variables](https://dev.azure.com/Shared-Service-GM/DevOps/_apps/hub/ms.vss-ciworkflow.build-ci-hub?_a=edit-build-definition&id=584&view=Tab_Variables) (`Build-buklo-microservice-gateway`).

**Mismas keys en cada Build.** No linkees la Library de Produccion aquí.  
`system.collectionId`, `system.definitionId`, `system.teamProject` las pone ADO: **no las crees**.

#### Keys que tú agregas (plantilla)

| Key | ¿Cambia por app? | Valor típico | Ejemplo 584 Gateway |
|-----|------------------|--------------|---------------------|
| `appname` | **Sí** | = `servicesname` / `image` | `microservice-gateway-api` |
| `image` | **Sí** | Nombre imagen ACR (sin registry/tag) | `microservice-gateway-api` |
| `rutadockerfile` | A veces | Path Dockerfile en el workspace | `./Dockerfile.service` |
| `conexcontainerregistries` | No (mismo ACR) | Nombre service connection ACR | `ACR Hub-2` |
| `tag` | No | Siempre `$(Build.BuildId)` | `$(Build.BuildId)` |
| `SERVICE_NAME` | **Sí** | Carpeta monorepo (`services/<esto>/`). **Omite** si el Dockerfile no usa `#{SERVICE_NAME}#` | `gateway` |
| `system.debug` | No | `false` (Settable at queue time = on) | `false` |

Cómo armar el siguiente Build:

1. Variables → Pipeline variables → las keys de la tabla (no las `system.*` automáticas).
2. Copiar `conexcontainerregistries`, `tag`, `rutadockerfile`, `system.debug` de otro Build del mismo producto.
3. Cambiar `appname`, `image` y `SERVICE_NAME` (si aplica).

`appname` e `image` suelen ser el mismo string. `SERVICE_NAME` es corto (`gateway`, `auth`, `engine`…), no el FQDN K8s.

#### `ambiente` en el Build

El Task group Build recibe `ambiente: $(ambiente)` y concatena `{image}{ambiente}` → `microservice-gateway-apiprod`.  
Si al correr el Build la imagen queda **sin** sufijo `prod`, añade también `ambiente` = `prod` en estas variables (mismo valor que la Library). Si el TG ya trae default, 584 puede no mostrar la key y igual publicar `…apiprod`.

No pongas aquí `servicesname`, `namespace`, `aksClusterName`: eso es Library + Release.

### 3.3 Triggers CI

- Enable continuous integration.
- Branch filters: `release` (y las que el equipo use para build; **Prod no desplegará** otras si el Release filtra bien).
- Path filters: solo el código de **esta** app (`+services/<app>/**` en monorepo; `+/**` en repo dedicado).

### 3.4 Job: pasos en este orden

Un job. Añade tasks **en este orden**. Marketplace:

| # | Task (buscar) | Display name | ¿Siempre? |
|---|----------------|--------------|-----------|
| 1 | **File Creator** | File Creator dockerfile | Solo si el Dockerfile **no** está en el repo (caso monorepo plantilla) |
| 2 | **Replace Tokens** | Replace tokens | Solo si el Dockerfile tiene `#{…}#` |
| 3 | **File Creator** | File Creator deployment.yml produccion | **Siempre** (clon YAML) |
| 4 | **File Creator** | File Creator deployment.yml dev / uat | **Mismo YAML**; solo CM/Secret/DNS |
| 5 | **Task group: Build** | Task group: Build | **Siempre** (imagen ACR) |

#### Paso 1 — File Creator Dockerfile (solo si aplica)

- Task: File Creator (`1f81a8be-d8ce-497d-9791-190126f661e7`, 7.\*)
- `filepath`: `Dockerfile.service` (raíz del workspace)
- `filecontent`: Dockerfile con tokens `#{SERVICE_NAME}#` si monorepo
- `fileoverwrite`: true
- UTF-8 sin BOM

**Si el Dockerfile ya vive en el repo:** no añadas este paso. `rutadockerfile` apunta al archivo versionado.

#### Paso 2 — Replace tokens (solo si el Dockerfile tiene `#{…}#`)

- Task: Replace Tokens (`a8515ec8-7254-4ffd-912c-86772e2b5962`, 7.\*)
- `rootDirectory`: `./`
- `targetFiles`: `Dockerfile.service` (el mismo filepath)
- `tokenPattern`: **default** → `#{…}#`
- `writeBOM`: false
- `actionOnMissing`: warn

**Orden:** File Creator **antes** de Replace. Al revés, el archivo nace con tokens sin resolver y Docker falla.

#### Paso 3 — File Creator: tres YAML (clon del mismo `deployment.yml`)

Modelo: Build **584** — File Creator `deployment.yml produccion` / `dev` / `uat`.

Hay **tres** File Creator (misma task, distinto `filepath` + `filecontent`):

| Display name | `filepath` | Cuándo se aplica |
|--------------|------------|------------------|
| File Creator deployment.yml dev | `./deployment-dev.yml` | Stage Desarrollo |
| File Creator deployment.yml uat | `./deployment-uat.yml` | Stage UAT |
| File Creator deployment.yml produccion | `./deployment-prod.yml` | Stage Produccion |

**Es el mismo manifiesto clonado tres veces** (kinds, probes, `image:`, anotaciones Ingress).  
Copia Prod → Dev → UAT y ajusta valores + **solo en Dev/UAT** los dos extras de abajo.

Estructura idéntica (kinds y nombres):

```text
Secret → ConfigMap → ServiceAccount → Role → RoleBinding
→ Deployment → Service → HPA → Ingress (solo si hay tráfico público)
```

`fileoverwrite: true`. UTF-8 **sin BOM**. Tokens `#{servicesname}#`, `#{image}#`, `#{namespace}#`, `#{containerregistries}#`, `#{ambiente}#`, `#{tag}#`, `#{reqcpu}#`… iguales en los tres (el Replace los resuelve en el **Release** de ese ambiente).

##### Solo Dev y UAT (`./deployment-dev.yml`, `./deployment-uat.yml`)

En el **pod**:

```yaml
      imagePullSecrets:
        - name: acr-pull-secret
```

En el **Ingress** (si existe):

```yaml
spec:
  ingressClassName: nginx
```

El secret `acr-pull-secret` debe existir en el namespace Dev/UAT. Si no está → `FailedToRetrieveImagePullSecret`.

**Prod (`./deployment-prod.yml`) no lleva eso.** Se deja **tal cual** el manifiesto Prod (Build 584 / YAML del repo):

- **Sin** `imagePullSecrets` / `acr-pull-secret` (pull por identidad nodo–ACR).
- Ingress: **no** forzar `nginx`. En gateway Prod queda `ingressClassName: internal-ingress` (y hosts/TLS de Prod).

##### Qué **sí** cambia entre los tres clones (valores)

| Bloque | Qué editar | Ejemplos |
|--------|------------|----------|
| **Secret** `data:` | Credenciales de ese ambiente (base64) | DB, Redis, crypto, API keys |
| **ConfigMap** `data:` | Hosts, URLs, `NODE_ENV` / `MODE`, Elastic, CORS, `HOST_*` | Dev: `*.desarrollo.svc…` · UAT: `*.uat.svc…` · Prod: `*.application-services.svc…` |
| **Ingress DNS** | `spec.tls[].hosts`, `spec.rules[].host`, `secretName` TLS | Dev/UAT `…-dev` / `…-uat` · Prod host real |
| **nodeSelector** (si aplica) | Pool de ese cluster | Prod Buklo: `userpool03` |
| **imagePullSecrets** | **Solo Dev/UAT** | `acr-pull-secret` |
| **ingressClassName** | **Solo Dev/UAT** → `nginx`. Prod: el valor que ya tenga el YAML Prod | |

Mismas **keys** de ConfigMap; otros **values**. Anotaciones nginx del Ingress: **iguales** en Dev y UAT (y en Prod se conservan las del YAML Prod, no se pisan con `nginx` si Prod usa otra class).

##### Ingress Dev / UAT — class `nginx` + anotaciones fijas

Usar en **`deployment-dev.yml` y `deployment-uat.yml`**. Solo cambiar hosts / `secretName` TLS.

```yaml
apiVersion: networking.k8s.io/v1
kind: Ingress
metadata:
  name: #{servicesname}#-ingress
  namespace: #{namespace}#
  labels:
    app: #{servicesname}#
  annotations:
    nginx.ingress.kubernetes.io/backend-protocol: "HTTP"
    nginx.ingress.kubernetes.io/ssl-redirect: "true"
    nginx.ingress.kubernetes.io/force-ssl-redirect: "true"
    nginx.ingress.kubernetes.io/proxy-body-size: "300m"
    nginx.ingress.kubernetes.io/proxy-buffering: "on"
    nginx.ingress.kubernetes.io/proxy-connect-timeout: "30"
    nginx.ingress.kubernetes.io/proxy-send-timeout: "240"
    nginx.ingress.kubernetes.io/proxy-read-timeout: "240"
    nginx.ingress.kubernetes.io/affinity: "cookie"
    nginx.ingress.kubernetes.io/affinity-mode: "persistent"
    nginx.ingress.kubernetes.io/session-cookie-name: "route"
    nginx.ingress.kubernetes.io/session-cookie-path: "/"
    nginx.ingress.kubernetes.io/session-cookie-max-age: "86400"
    nginx.ingress.kubernetes.io/proxy-next-upstream: "error timeout http_502 http_503 http_504"
    nginx.ingress.kubernetes.io/proxy-next-upstream-tries: "3"
    nginx.ingress.kubernetes.io/rate-limit: "1000"
    nginx.ingress.kubernetes.io/rate-limit-window: "1m"
    nginx.ingress.kubernetes.io/rate-limit-connection: "20"
    nginx.ingress.kubernetes.io/enable-compression: "true"
    nginx.ingress.kubernetes.io/compression-level: "6"
    nginx.ingress.kubernetes.io/compression-types: "text/plain,text/css,application/json,application/javascript,text/xml,application/xml,application/xml+rss,text/javascript,application/atom+xml"
    nginx.ingress.kubernetes.io/upstream-keepalive-connections: "32"
    nginx.ingress.kubernetes.io/upstream-keepalive-timeout: "60s"
    nginx.ingress.kubernetes.io/upstream-keepalive-requests: "100"
    nginx.ingress.kubernetes.io/proxy-buffer-size: "16k"
    nginx.ingress.kubernetes.io/proxy-buffers-number: "8"
    nginx.ingress.kubernetes.io/proxy-busy-buffers-size: "64k"
spec:
  ingressClassName: nginx
  tls:
    - hosts:
        - <dns-dev-o-uat>
      secretName: <tls-secret-dev-o-uat>
  rules:
    - host: <dns-dev-o-uat>
      http:
        paths:
          - path: /
            pathType: Prefix
            backend:
              service:
                name: #{servicesname}#-service
                port:
                  number: 80
```

| Ambiente | Host típico (ejemplo gateway 584) | `imagePullSecrets` | `ingressClassName` |
|----------|-----------------------------------|--------------------|--------------------|
| Dev | `gateway-buklo-dev.gmontecristo.com` | `acr-pull-secret` | `nginx` |
| UAT | `gateway-buklo-uat.gmontecristo.com` | `acr-pull-secret` | `nginx` |
| Prod | el del YAML Prod (p. ej. `microservice-gateway-api.buklo.dev`) | **no** (tal cual Prod) | **tal cual Prod** (p. ej. `internal-ingress`) |

Apps **sin** Ingress: clona Secret/CM/Deployment/Service/HPA; **no** copies Ingress. En Dev/UAT igual agrega `imagePullSecrets`.

##### Receta al crear un servicio nuevo

1. Armar **Prod** (`deployment-prod.yml`) y dejarlo **tal cual** (sin `acr-pull-secret`, Ingress de Prod sin forzar `nginx`).
2. Clonar ese YAML a Dev y UAT.
3. En Dev/UAT: Secret, ConfigMap, DNS Ingress + **añadir** `imagePullSecrets: acr-pull-secret` y, si hay Ingress, `ingressClassName: nginx` (anotaciones del bloque de arriba).

El **Replace de `#{…}#` lo hace el Release** (Library del stage), no el Build.

#### Paso 4 — Task group: Build (**siempre**)

Añadir **Task group** (no una task suelta de Docker).

Nombre en org: **Build** (id metaTask típico `f214b26f-73a6-4765-838b-197a336cfcd9`).

Inputs (todos con `$(…)` del pipeline):

| Input del TG | Valor |
|--------------|--------|
| `image` | `$(image)` |
| `rutadockerfile` | `$(rutadockerfile)` |
| `ambiente` | `$(ambiente)` |
| `tag` | `$(tag)` |
| `conexcontainerregistries` | `$(conexcontainerregistries)` |

Eso publica:

```text
$(containerregistries)/$(image)$(ambiente):$(tag)
# gmonhubacreastus20001.azurecr.io/microservice-auth-apiprod:20274
```

(`containerregistries` suele resolverlo el propio TG / connection ACR.)

**Contexto Docker** = carpeta del Dockerfile. Si `rutadockerfile` = `./Dockerfile.service` en la raíz, el contexto es el **repo root** (necesario para monorepo `packages/` + `services/`).

### 3.5 Artifact del Build

El YAML `deployment-prod.yml` debe quedar en el **drop** que consume el Release. El Task group Build de esta org ya publica imagen + artefactos típicos; si el primer Release no ve `deployment-prod.yml`, añade **Publish Pipeline Artifact** (o Copy files + Publish) del archivo creado por File Creator.

Guarda el Build. Anota el **definition id** y el nombre exacto (`pipeline` en la Library).

---

## 4. Release clásico — pipeline vacío

**Releases → New pipeline → Empty job** (no “start with a template” de Azure web app).

Nombre:

```text
Deploy-Desarrollo-UAT-Produccion-<Producto>-<App>
```

Folder: mismo que el Build (`\Buklo`).

### 4.1 Artefacto

- Add artifact → **Build**
- Source: el Build del §3
- Default version: **Latest**
- Alias: `_Build-<Producto>-<App>` (ADO suele prefijar `_`)

**Continuous deployment trigger** (rayo del artefacto):

1. Enabled  
2. Pull request trigger: Disabled  

Sin esto el Build OK **no** crea Release.

### 4.2 Stages

Puedes crear solo **Produccion** al inicio. Si quieres paridad visual con Buklo: Desarrollo + UAT + Produccion, y **no** actives Dev/UAT hasta tener VG + YAML de ese ambiente.

Cada stage: 1 job, agent job.

### 4.3 Stage **Produccion** — variables

- Link **Variable group**: `Produccion-<Producto>-<App>` (§2)
- Variables de stage (si el TG/deploy las pide; secretos):
  - `containerRegistryUsername` / `containerRegistryPassword` (si aplica)
  - `namespace` = `$(namespace)` si hay que reexponer al TG

### 4.4 Stage **Produccion** — tasks

Orden típico observado (ajusta si el TG ya incluye wait):

| # | Task | Enabled | Inputs |
|---|------|---------|--------|
| 1 | PowerShell (opcional) | a criterio | p. ej. `Start-Sleep -Seconds 60` si hay race ACR |
| 2 | **Task group: Deployment-Azur-Aks-v3** | **Sí** | ver tabla |
| 3 | NSG / scripts extra | **No** salvo que el producto lo pida | — |

Inputs del TG **Deployment-Azur-Aks-v3** (`1fdf52f7-9160-4049-bb78-c7bffadf022d`):

| Input | Valor |
|-------|--------|
| `aksClusterName` | `$(aksClusterName)` |
| `aksResourceGroup` | `$(aksResourceGroup)` |
| `ambiente` | `$(ambiente)` |
| `namespace` | `$(namespace)` |
| `pipeline` | `$(pipeline)` |

Ese TG: Replace tokens del YAML del artefacto + apply en AKS (connection K8s / Azure).

Condition del job: `succeededOrFailed()` en el TG suele estar así en Prod Buklo; no lo copies si no entiendes el efecto (puede desplegar tras un paso anterior fallido). Preferible: `succeeded()` salvo estándar de la org.

### 4.5 Pre-deployment del stage Produccion

- Approvals: **Disabled** (o según gobernanza)
- Gates: Disabled
- **Artifact filters: Enabled**
  - Type: **Include**
  - Artifact: el alias del §4.1
  - **Build branch:** `release` (nombre corto, no `refs/heads/release`)
  - Build tags: vacío

Condition equivalente:

```json
{
  "conditionType": "event",
  "name": "ReleaseStarted",
  "value": ""
}
```

```json
{
  "conditionType": "artifact",
  "name": "_Build-<Producto>-<App>",
  "value": "{\"sourceBranch\":\"release\",\"tags\":[],\"useBuildDefinitionBranch\":false,\"createReleaseOnBuildTagging\":false}"
}
```

Sin el filtro de rama, un build de `main`/`development` puede aplicar YAML/tags que no existen en ACR.

Guarda el Release.

---

## 5. Primera corrida (validar)

1. Queue el **Build** en `release`.
2. Log File Creator: YAML escrito; log TG Build: push ACR `…/{image}{ambiente}:{BuildId}`.
3. Debe crearse un **Release** solo; stage Produccion debe **correr** (branch filter).
4. AKS: `kubectl get deploy,po -n <namespace> -l app=<servicesname>`
5. Imagen del pod = tag del Build; Ready; probes OK; logs sin CrashLoop.
6. Si ImagePullBackOff: tag existe en ACR; no hay `imagePullSecrets` fantasma; `image:` usó `#{image}#`.

---

## 6. Lista de “qué tiene que ir” (resumen)

### Manifiesto (tres clones)

Un YAML × Dev / UAT / Prod (kinds iguales). **Solo Dev/UAT:** `imagePullSecrets: acr-pull-secret` e Ingress `ingressClassName: nginx`. **Prod:** tal cual (`deployment-prod.yml` sin esos extras). Cambia en todos: Secret, ConfigMap, DNS. Ver §3.4 Paso 3.

### Library Prod

**Mismas 17 keys siempre.** Copiar valores de ambiente; cambiar solo `servicesname`, `image`, `pipeline` (y a veces `rutadockerfile` / resources). Ver §2.1.

### Build

Repo + branch + path filter · **Pipeline variables** (mismas keys que [584](https://dev.azure.com/Shared-Service-GM/DevOps/_apps/hub/ms.vss-ciworkflow.build-ci-hub?_a=edit-build-definition&id=584&view=Tab_Variables): `appname`, `image`, `rutadockerfile`, `conexcontainerregistries`, `tag`, `SERVICE_NAME` si monorepo, `system.debug`) · File Creator Prod · (Dockerfile File Creator + Replace solo si aplica) · Task group Build. Ver §3.2.

### Release

Artefacto Build + CD Enabled · VG linkeada en Produccion · TG Deployment-Azur-Aks-v3 · Artifact filter branch `release`

---

## 7. Dev / UAT más adelante (también desde cero)

No reutilices la Library de Prod. El YAML **sí** se reutiliza: clon Dev/UAT del File Creator Prod (§3.4 Paso 3).

1. Variable Groups `Desarrollo-…` / `UAT-…` (mismas keys, valores de ese cluster).
2. File Creator `deployment-dev.yml` / `deployment-uat.yml` = clon de Prod + `acr-pull-secret` + Ingress `nginx`; Secret/CM/DNS de ese ambiente.
3. Stage del Release: link esa VG + connection AKS de ese cluster.
4. Artifact filter del stage: branch `development` / `uat`.

---

## 8. Pipelines de base de datos (DACPAC) — desde cero

Otra familia: **no** usa File Creator ni Task group `Build` / `Deployment-Azur-Aks-v3`.  
Compila un proyecto SSDT (`*.sqlproj`) y el Release aplica el DACPAC contra SQL MI / SQL Server.

Referencias reales:

| Pieza | Id | Nombre | Path |
|-------|-----|--------|------|
| Build | [488](https://dev.azure.com/Shared-Service-GM/DevOps/_apps/hub/ms.vss-ciworkflow.build-ci-hub?_a=edit-build-definition&id=488&view=Tab_Variables) | `Base_Datos_Build_sqldb_buklo_lab_Produccion` | `\BaseDatos\sqldb_buklo_lab` |
| Release | [298](https://dev.azure.com/Shared-Service-GM/DevOps/_releaseDefinition?definitionId=298&_a=definition-pipeline) | `Base_Datos_sqldb_buklo_lab_PRODUCCION` | `\BaseDatos\sqldb_buklo_lab` |
| Library | **181** | `Bases Datos SQL` | (compartida: **un solo grupo** para todos los pipelines de BD) |
| Repo | — | `project_sqldb_buklo_lab` | Default branch `release` |
| Agent Build | — | `172.16.2.127-prtg` (self-hosted; MSBuild/SSDT) | |

### 8.1 Convención de nombres

```text
Build:    Base_Datos_Build_<databaseProjectName>_Produccion
Release:  Base_Datos_<databaseProjectName>_PRODUCCION
Folder:   \BaseDatos\<databaseProjectName>
Repo:     project_<databaseProjectName>     (o el repo SSDT de esa DB)
```

Ejemplo 488/298: `databaseProjectName` = `sqldb_buklo_lab` · DB lógica `database` = `buklo_lab`.

### 8.2 Library `Bases Datos SQL` (id 181) — **no** se duplica por app

A diferencia de AKS (una Library **por** microservicio), aquí **se linkea el mismo grupo**.  
Keys fijas; no crees otro VG por cada `sqldb_*` salvo que DevOps lo pida.

| Key | ¿Cambia por pipeline? | Rol | Valor de referencia (181) |
|-----|------------------------|-----|---------------------------|
| `usuario_db` | No | Login SQL del apply | `usr_application_db` |
| `pass_db` | No | Password SQL | en Library; **marcar candado (secret)** |
| `instanciadb_dev` | No | Host SQL Dev | `172.16.2.30` |
| `instanciadb_uat` | No | Host SQL UAT | `172.16.2.34` |
| `instanciadb_prod` | No | Host SQL Prod | `gmon-prod-sqlmi-eastus2-0001.15c9ad07b4c3.database.windows.net` |
| `requerimientoPrefijo` | No | Prefijo HU / work item (TG reportes) | `TKS` |
| `adoPrProject` | No | Proyecto ADO de PRs/HU | `Database-Administration-and-Monitoring` |
| `failOnSqlErrorText` | No | Fallar si el log SQL trae error | `true` |
| `failReleaseOnError` | No | Fallar el Release si el apply falla | `true` |

El **Build 488 y el Release 298 linkean este grupo** (el Build de AKS 584 **no** linkea Library).

En el Release Prod el TG deploy usa `instanciadb: $(instanciadb_prod)`. Un stage Dev/UAT usaría `$(instanciadb_dev)` / `$(instanciadb_uat)` — **mismas keys**, otro input.

### 8.3 Variables del Build (tab Pipeline variables)

Modelo: [488 → Variables](https://dev.azure.com/Shared-Service-GM/DevOps/_apps/hub/ms.vss-ciworkflow.build-ci-hub?_a=edit-build-definition&id=488&view=Tab_Variables).

**Mismas keys en cada Build de BD.** No copies las de 584 (`image`, `SERVICE_NAME`, …).

| Key | ¿Cambia por DB? | Valor 488 | Settable at queue |
|-----|-----------------|-----------|-------------------|
| `databaseProjectName` | **Sí** | `sqldb_buklo_lab` | no |
| `BuildConfiguration` | No | `Debug` | sí |
| `BuildPlatform` | No | `any cpu` | sí |
| `BATCH_PR_TITLE_MARKER` | No | `[AUTO]` | sí |
| `BATCH_WAIT_REASONS` | No | `IndividualCI,BatchedCI` | sí |
| `BATCH_WINDOW_MINUTES` | No | `3` | sí |
| `SUPERSEDE_REASONS` | No | `IndividualCI,BatchedCI` | sí |
| `system.debug` | No | `false` | sí |

`system.collectionId` / `definitionId` / `teamProject`: automáticas, no crearlas.

`databaseProjectName` debe coincidir con el `.sqlproj` / carpeta del DACPAC (input del TG **Build-DataBases**).

Luego: Variables → **Variable groups** → **Link** → `Bases Datos SQL`.

### 8.4 Build — jobs y task groups (orden 488)

Agent pool: self-hosted con Visual Studio / MSBuild para SSDT (`172.16.2.127-prtg` en el ejemplo).  
CI: branch `release` (488 no usa path filters).  
`buildNumberFormat`: `$(date:yyyyMMdd)$(rev:.r)`.

Tres jobs **encadenados** (no un solo Empty job como AKS):

```text
Batch_Gate  (Evaluar ventana)
    → Batch_Window  (Delay)     [solo si shouldWait=true y BATCH_WINDOW_MINUTES ≠ 0]
        → Job_1  (build DACPAC + reportar HU)
```

| Job | RefName | Condition (resumen) | Steps |
|-----|---------|---------------------|-------|
| Evaluar ventana | `Batch_Gate` | succeeded, not canceled | TG **Evaluar-ventana-agrupacion** → PowerShell “Publicar shouldWait” (`refName: gate`, output `shouldWait`) |
| Ventana de agrupacion | `Batch_Window` | `shouldWait==true` y `BATCH_WINDOW_MINUTES != 0` | Delay `$(BATCH_WINDOW_MINUTES)` minutos (agrupa varios CI/merges) |
| Agent job 1 | `Job_1` | ventana Succeeded / Skipped | TG **Gana-el-mas-nuevo** → TG **Build-DataBases** → TG **Reportar-resultado-HU** |

Task groups (referenciar, no recrear):

| Task group | Id metaTask | Inputs que debes mapear |
|------------|-------------|-------------------------|
| Evaluar-ventana-agrupacion | `8c699091-…` | (vacío; lee `BATCH_*` / `SUPERSEDE_*`) |
| Gana-el-mas-nuevo | `69c14633-…` | (vacío) |
| Build-DataBases | `e483b285-…` | `databaseProjectName=$(databaseProjectName)` · `BuildConfiguration=$(BuildConfiguration)` · `BuildPlatform=$(BuildPlatform)` · `requerimientoPrefijo=$(requerimientoPrefijo)` |
| Reportar-resultado-HU | `cefd6b95-…` | (vacío; usa Library `adoPrProject` / prefijo) |

Job `Job_1` condition observada:

```text
and(in(dependencies.Batch_Window.result, 'Succeeded', 'SucceededWithIssues', 'Skipped'), not(canceled()))
```

Ventana:

```text
and(succeeded(), ne(variables['BATCH_WINDOW_MINUTES'], '0'), eq(dependencies.Batch_Gate.outputs['gate.shouldWait'], 'true'), not(canceled()))
```

Si `BATCH_WINDOW_MINUTES=0`, el delay se salta y el build DACPAC corre igual.

### 8.5 Release — desde cero (modelo 298)

1. New release pipeline (Empty) → nombre `Base_Datos_<databaseProjectName>_PRODUCCION` → folder `\BaseDatos\<databaseProjectName>`.
2. Artefacto: Build 488 (o el Build nuevo) · alias `_Base_Datos_Build_<…>_Produccion` · CD trigger **Enabled** (`artifactSource`).
3. **Variable groups** del Release (nivel definición, no solo stage): link **`Bases Datos SQL`**.
4. Variables **del Release** (mismas keys; cambian valores por DB):

| Key | 298 | ¿Cambia? | Rol |
|-----|-----|----------|-----|
| `databaseProjectName` | `sqldb_buklo_lab` | **Sí** | Proyecto SSDT (igual que el Build) |
| `database` | `buklo_lab` | **Sí** | Nombre de la base en el servidor |
| `build` | `Base_Datos_Build_sqldb_buklo_lab_Produccion` | **Sí** | Nombre exacto del Build (artefacto) |
| `mode` | `Apply` (queue override on) | No (salvo DryRun si el TG lo soporta) | Modo del TG deploy |

5. Un stage **Produccion** (298 no trae Dev/UAT).
   - Pre-deployment approvals: en 298 **no** están automatizados (alguien aprueba Prod).
   - Agent: pool de BD (queue id 393 en 298).
6. Tasks del job:

| # | Task group | Inputs |
|---|------------|--------|
| 1 | **Deployment-DataBases** (`4634d6ff-…`) | `databaseProjectName=$(databaseProjectName)` · `database=$(database)` · `build=$(build)` · `mode=$(mode)` · `instanciadb=$(instanciadb_prod)` · `usuario_db=$(usuario_db)` · `pass_db=$(pass_db)` · `requerimientoPrefijo=$(requerimientoPrefijo)` |
| 2 | **Reportar-resultado-HU** | (vacío) |

`sqldb_core_global_db_reference` en 298 está en `xxx` (placeholder del TG; no inventes otro valor si el estándar es ese).

7. Artifact filter de rama: 298 dispara por CD del Build (el Build ya está filtrado a `release`). Si añades Dev/UAT, filtra branch por stage como en AKS.

### 8.6 Checklist nueva base

1. [ ] Repo SSDT + branch `release`.
2. [ ] Folder `\BaseDatos\<databaseProjectName>`.
3. [ ] Build Empty + 3 jobs / TGs de §8.4 + pool con MSBuild.
4. [ ] Pipeline variables de §8.3 (`databaseProjectName` el de esta DB).
5. [ ] Link Library **`Bases Datos SQL`** (no crear VG nueva).
6. [ ] CI branch `release`.
7. [ ] Release + variables `database` / `databaseProjectName` / `build` / `mode=Apply`.
8. [ ] Link la misma Library; TG **Deployment-DataBases** con `instanciadb_prod`.
9. [ ] CD trigger on; aprobación Prod según gobernanza.
10. [ ] Primer run: DACPAC publicado + apply en `instanciadb_prod` / `$(database)`.

### 8.7 AKS vs BD (no cruzar)

| | App AKS (584) | Base de datos (488 / 298) |
|--|---------------|---------------------------|
| Library | Una **por** app `Produccion-<Producto>-<App>` | **Una** compartida `Bases Datos SQL` |
| Variables pipeline | `appname`, `image`, `SERVICE_NAME`, `rutadockerfile`… | `databaseProjectName`, `BATCH_*`, `BuildConfiguration`… |
| Task groups Build | File Creator + **Build** (Docker) | **Build-DataBases** + ventana/HU |
| Task groups Release | **Deployment-Azur-Aks-v3** | **Deployment-DataBases** |
| Artefacto | Imagen + YAML | DACPAC |
| `instanciadb_*` | No | Sí (host SQL por ambiente) |

---

## 9. Errores si se arma mal desde cero


| Error | Causa | Corrección |
|-------|--------|------------|
| Tokens `#{SERVICE_NAME}#` en Docker | Replace después del File Creator, o ausente | Orden File Creator → Replace → TG Build |
| Contexto Docker incompleto | Dockerfile en subcarpeta y COPY espera la raíz | Dockerfile en raíz o COPY/rutas acordes |
| `ImagePullBackOff` tag inexistente | Build de otra branch / filtro Prod ausente | Artifact filter `release` |
| Warning `acr-pull-secret` en **Prod** | YAML Prod copió el bloque de Dev/UAT | Quitar `imagePullSecrets` de `deployment-prod.yml` |
| Warning `acr-pull-secret` en Dev/UAT | Secret ausente en ese namespace | Crear `acr-pull-secret` en el NS Dev/UAT |
| Release no se crea | CD trigger off | Rayo del artefacto → Enabled |
| Release se crea pero Prod no corre | Falta filtro o branch distinta | Include + `release` |
| File Creator API `uFEFF` | BOM UTF-8 | Guardar sin BOM |
| DACPAC no aplica / login fail | Library 181 no linkeada o `instanciadb_prod` mal en el TG | Link `Bases Datos SQL`; `instanciadb=$(instanciadb_prod)` |
| Build BD sin DACPAC | `databaseProjectName` ≠ nombre del `.sqlproj` | Igualar key al proyecto SSDT |
| Jobs BD en orden incorrecto | Un solo job tipo AKS | Tres jobs Batch_Gate → Batch_Window → Job_1 |

---

## 10. Relación con las otras guías

| Quieres… | Documento |
|----------|-----------|
| Armar **todo nuevo** click a click (AKS **y** DACPAC) | **Este archivo** (§1–7 AKS, §8 BD) |
| Decidir Dockerfile / monorepo / checklist corto | [ado-classic-playbook-any-project.md](./ado-classic-playbook-any-project.md) |
| Buklo concreto (ids, env, DB app) | [devops-guide.md](./devops-guide.md) |

*Alta desde cero: AKS (TG Build + Deployment-Azur-Aks-v3) y BD (TG Build-DataBases + Deployment-DataBases). Los task groups se referencian, no se reimplementan.*
