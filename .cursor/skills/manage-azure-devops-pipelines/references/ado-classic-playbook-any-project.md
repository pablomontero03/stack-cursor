# Playbook Azure DevOps clásico → AKS (cualquier proyecto)

Guía **genérica** para montar Build + Release + Variable Group (Library) + deploy a AKS con el patrón clásico de `Shared-Service-GM` / proyecto **DevOps**.

> Complementa la guía específica de Buklo monorepo: [`devops-guide.md`](./devops-guide.md).  
> **Alta desde cero** (no clonar definiciones; campos y steps a crear): [`ado-classic-from-scratch.md`](./ado-classic-from-scratch.md).  
> Esta playbook **no asume** monorepo, Nest, ni un Dockerfile generado por pipeline.

---

## 1. Qué construyes (siempre es lo mismo)

```text
Repo del proyecto (cualquier estructura)
        │
        ▼
Azure DevOps Build (clásico)
  · (opcional) File Creator Dockerfile
  · (opcional) Replace tokens
  · File Creator deployment-<env>.yml   ← manifiestos K8s con tokens #{...}#
  · Task group Build → push imagen a ACR
        │
        ▼
Azure DevOps Release (clásico)
  · Stage Produccion + Variable Group Produccion-…
  · Task group Deployment-Azur-Aks-v3 (u otro de deploy AKS)
  · Replace tokens del YAML + kubectl apply
        │
        ▼
AKS (namespace del proyecto)
  · Deployment / Service / ConfigMap / Secret / HPA / (Ingress si aplica)
```

Las tres piezas ADO son independientes del lenguaje del repo:

| Pieza | Qué hace |
|-------|----------|
| **Build** | Compila/empaqueta imagen Docker y deja artefactos de YAML |
| **Variable Group (Library)** | Valores de **deploy** (`servicesname`, `image`, cluster, resources, …) |
| **Release** | Toma la imagen + YAML, reemplaza tokens y aplica en AKS |

---

## 2. Árbol de decisión (elige el caso **antes** de armar el Build)

### 2.1 ¿Dónde vive el Dockerfile?

| Caso | Cuándo | File Creator Dockerfile | `rutadockerfile` | Replace tokens Dockerfile |
|------|--------|-------------------------|------------------|---------------------------|
| **A — Dockerfile en el repo** | App single-repo, frontend, API con `Dockerfile` / `docker/Dockerfile` versionado | **No** hace falta (deshabilitar o no crear el step) | Ruta real en el repo, p. ej. `./Dockerfile` o `./docker/Dockerfile` | Solo si el Dockerfile usa `#{...}#` |
| **B — Dockerfile generado en el Build** | Monorepo / plantilla compartida / un mismo Dockerfile parametrizado por servicio | **Sí** (File Creator escribe el archivo en el workspace del agente) | Ruta donde File Creator escribe, p. ej. `./Dockerfile.service` | **Sí**, **después** del File Creator |
| **C — Imagen ya publicada** | Solo redeploy / imagen externa | No | N/A (puede no usar Task group Build de imagen) | N/A |

**Regla de oro:** el Task group Build usa la **carpeta del Dockerfile** como contexto Docker.  
Si el Dockerfile está en `./Dockerfile`, el contexto es la **raíz del repo**.  
Si está en `./apps/web/Dockerfile`, el contexto suele ser `./apps/web` (según cómo esté armado el task group). Valida siempre con un build de prueba.

### 2.2 ¿Monorepo o repo dedicado?

| Tipo | Qué cambia |
|------|------------|
| **Repo dedicado** (1 app = 1 repo) | CI path filter = `/**` o carpetas de esa app. Sin `SERVICE_NAME` salvo que el Dockerfile lo pida. |
| **Monorepo** (varias apps en un repo) | Un Build por app. Path filter = `+apps/<app>/**` o `+services/<app>/**`. Variable `SERVICE_NAME` / carpeta solo si el Dockerfile o scripts lo necesitan. |
| **Multi-proyecto ADO** | El patrón es el mismo; cambia org/proyecto, service connections y Variable Groups. |

### 2.3 ¿Hace falta Replace tokens en el Build?

| Archivo | ¿Replace en Build? |
|---------|-------------------|
| Dockerfile con `#{SERVICE_NAME}#` u otros tokens | **Sí** (después de File Creator si aplica) |
| Dockerfile sin tokens (solo `COPY .` / ARG fijos) | **No** |
| `deployment-prod.yml` con `#{servicesname}#`, `#{image}#`, … | Suele reemplazarse en el **Release** (Variable Group del stage). El File Creator del Build solo **inyecta** el YAML; no hace falta que el Build resuelva todos los tokens K8s. |

---

## 3. Convención de nombres (plantilla)

Sustituye `<Producto>`, `<App>`, `<env>`:

```text
Build-<Producto>-<App>
Deploy-Desarrollo-UAT-Produccion-<Producto>-<App>
Produccion-<Producto>-<App>          # Variable Group / Library

servicesname = <nombre-recurso-k8s>  # Deployment, Service, ConfigMap, Secret…
image        = <nombre-imagen-acr>   # lo que publica el Task group Build
appname      = <nombre-lógico>       # suele = servicesname
```

Ejemplos:

```text
Build-Buklo-Microservice-Auth
Produccion-Buklo-Microservice-Auth
servicesname = microservice-auth-api
image        = microservice-auth-api

Build-HR-Web-Shell
Produccion-HR-Web-Shell
servicesname = shell-web
image        = shell-web
```

`servicesname` e `image` **pueden** ser iguales, pero mantenlos como variables **separadas** por si un día divergen.

---

## 4. Tres capas de variables (no mezclar roles)

### A) Variables del **Build** (tab Variables del pipeline)

**Mismas keys en cada Build**; solo cambian valores. No se linkea la Library aquí. Referencia: [Build 584](https://dev.azure.com/Shared-Service-GM/DevOps/_apps/hub/ms.vss-ciworkflow.build-ci-hub?_a=edit-build-definition&id=584&view=Tab_Variables). Detalle: [`ado-classic-from-scratch.md`](./ado-classic-from-scratch.md) §3.2.

| Key | ¿Cambia por app? | Ejemplo 584 Gateway |
|-----|------------------|---------------------|
| `appname` | **Sí** | `microservice-gateway-api` |
| `image` | **Sí** | `microservice-gateway-api` |
| `rutadockerfile` | A veces | `./Dockerfile.service` |
| `conexcontainerregistries` | No | `ACR Hub-2` |
| `tag` | No | `$(Build.BuildId)` |
| `SERVICE_NAME` | **Sí** (solo monorepo) | `gateway` |
| `system.debug` | No | `false` (queue time) |

Ignora `system.collectionId` / `definitionId` / `teamProject` (automáticas). No pongas `servicesname` ni cluster aquí.

### B) Variable Group **Produccion-…** (deploy / tokens del YAML)

**Las keys son fijas.** Cada app es un grupo nuevo con el **mismo set**; solo cambian valores. Plantilla completa: [`ado-classic-from-scratch.md`](./ado-classic-from-scratch.md) §2.1.

| Key | ¿Cambia por app? | Rol |
|-----|------------------|-----|
| `ambiente`, `containerregistries`, `conexcontainerregistries`, `conexkubernetes`, `namespace`, `aksClusterName`, `aksResourceGroup`, `tag` | **No** (mismo cluster/env) | ACR + AKS + tag |
| `reqcpu`, `reqmem`, `limcpu`, `limmem` | Raro (default compartido) | Resources |
| `servicesname`, `image`, `pipeline` | **Sí** | Nombre K8s, imagen ACR, Build |
| `rutadockerfile` | A veces | Ruta Dockerfile del TG Build |

**Prod Library:** no definas `image_pull_secret`. `acr-pull-secret` e `ingressClassName: nginx` van **solo** en YAML Dev/UAT. Prod se deja tal cual.

### C) Variables de **stage** del Release

Secretos de stage (registry user/pass si aplica), overrides puntuales, `namespace=$(namespace)` hacia el task group de deploy.

---

## 5. Tokens en el manifiesto K8s

Convención de imagen (Prod):

```yaml
image: "#{containerregistries}#/#{image}##{ambiente}#:#{tag}#"
# → gmonhubacreastus20001.azurecr.io/mi-appprod:20274
```

| Token | Uso |
|-------|-----|
| `#{servicesname}#` | `metadata.name`, labels, ConfigMap/Secret/SA/HPA |
| `#{image}#` | **Solo** el nombre de imagen (no el recurso K8s) |
| `#{namespace}#` | Namespace |
| `#{containerregistries}#` | Registry |
| `#{ambiente}#` | Sufijo ambiente en el tag |
| `#{tag}#` | Build id |
| `#{reqcpu}#` … `#{limmem}#` | Resources |

**Nunca** uses `#{servicesname}#` en el campo `image:` del Deployment si el Task group publica bajo `#{image}#`.

Secretos sensibles → `Secret` (`data:` base64). Config no sensible → `ConfigMap`. Ambos vía `envFrom` en el Deployment.

---

## 6. Flujo del Build (recetas)

### Receta A — Dockerfile ya en el repo (caso más común fuera de monorepo)

1. ~~File Creator Dockerfile~~ → **omitir / disabled**
2. ~~Replace tokens Dockerfile~~ → omitir (salvo tokens reales)
3. **File Creator** ×3: `deployment-dev.yml` / `deployment-uat.yml` / `deployment-prod.yml` — **clon** del mismo YAML (cambia CM/Secret/DNS). Ver [`ado-classic-from-scratch.md`](./ado-classic-from-scratch.md) §3.4 Paso 3.
4. **Task group Build** con `rutadockerfile` apuntando al Dockerfile del repo

```text
rutadockerfile = ./Dockerfile          # o ./docker/Dockerfile, etc.
```

### Receta B — Dockerfile generado (monorepo / plantilla)

1. **File Creator** → escribe `Dockerfile.service` (o el nombre que uses) con tokens `#{…}#`
2. **Replace tokens** → root `./`, archivo del Dockerfile, pattern `#{…}#`
3. **File Creator** → tres clones `deployment-*.yml` (dev / uat / prod)
4. **Task group Build**

```text
Orden correcto: File Creator Dockerfile → Replace tokens → Build
Orden incorrecto: Replace → File Creator (el archivo nace con tokens sin resolver)
```

### Receta C — Solo manifiestos / redeploy

Build mínimo o Release que consume una imagen ya existente. Menos frecuente; documenta de dónde sale el tag.

### Triggers CI

- Path filters acotados al código de **esa** app.
- Branch: la que use el equipo (`main`, `release`, `master`, …).
- Tras el primer clone, revisa que el trigger no siga apuntando a carpetas del pipeline **origen**.

---

## 7. Flujo del Release

| Stage | Variable Group | Deploy task group | Nota |
|-------|----------------|-------------------|------|
| Desarrollo | VG Dev del producto | Cluster Dev | Opcional / plantilla |
| UAT | VG UAT | Cluster UAT | Opcional / plantilla |
| **Produccion** | **`Produccion-<Producto>-<App>`** | **`Deployment-Azur-Aks-v3`** (o el vigente) | **Activo** |

Artefacto primario = Build de esa app (`Latest` o el build que dispara el CD).

### Continuous deployment trigger (obligatorio si quieres deploy automático)

Al clonar un Release, el CD trigger del artefacto suele quedar **Disabled**:

1. Editor del Release → rayo del artefacto Build  
2. **Continuous deployment trigger** → **Enabled**  
3. Guardar  

Sin eso, el Build OK **no** despliega solo.

### Artifact filter del stage Produccion (rama de deploy)

El CD crea el Release; el **filtro del stage** decide si **Produccion** corre con ese artefacto. Sin filtro, un build de otra branch puede desplegar YAML/imagen incorrectos.

1. Editor del Release → triggers del stage **Produccion** (ícono rayo/persona en el stage).  
2. **Artifact filters** → **Enabled**.  
3. Type **Include**, **Build branch** = la rama de Prod del equipo (en Buklo: `release`).  
4. Guardar.

```text
CD trigger (artefacto)     → crea el Release al terminar el Build
Artifact filter (stage)    → Produccion solo si Build branch = release
```

En condition API del environment:

```json
{
  "conditionType": "artifact",
  "name": "_Build-<Producto>-<App>",
  "value": "{\"sourceBranch\":\"release\",\"tags\":[],\"useBuildDefinitionBranch\":false,\"createReleaseOnBuildTagging\":false}"
}
```

Ajusta `sourceBranch` al flujo del producto (`release`, `main`, etc.). Dev/UAT pueden filtrar `development` / `uat` si aplica.

---

## 8. Checklist para **cualquier** proyecto nuevo

Usa esto como orden de trabajo (humano o agente).

### Preparación

1. [ ] Identificar **repo**, branch y estructura (Dockerfile path, carpeta de manifests).
2. [ ] Elegir **caso A/B/C** de Dockerfile (sección 2.1).
3. [ ] Definir nombres: Build, Release, VG, `servicesname`, `image`, `namespace`, cluster.
4. [ ] Escribir / adaptar `deployment-prod.yml` con tokens `#{…}#` y probes reales del código.
5. [ ] Confirmar service connections: ACR + AKS existen y el agente/pool las ve.

### Azure DevOps

6. [ ] Clonar Variable Group desde uno **del mismo tipo** (web vs API vs mismo stack) y renombrar keys.
7. [ ] Clonar Build → renombrar → apuntar al **repo correcto** y branch.
8. [ ] Ajustar variables Build (`image`, `rutadockerfile`, …). Quitar `SERVICE_NAME` si no aplica.
9. [ ] File Creator Prod = YAML del proyecto. Dev/UAT: placeholder OK hasta configurar.
10. [ ] Si **caso A**: deshabilitar File Creator Dockerfile + Replace de Dockerfile. Si **caso B**: mantener orden File Creator → Replace → Build.
11. [ ] Path filters / CI triggers alineados al código de la app.
12. [ ] Clonar Release → stage Produccion linkea la Library nueva + task group de deploy AKS.
13. [ ] Activar **CD trigger** del artefacto.
14. [ ] Stage **Produccion** → Artifact filters Enabled, **Build branch** = rama de Prod (Buklo: `release`).
15. [ ] Primer Build manual → revisar logs Docker (contexto, COPY paths).
16. [ ] Release Prod → verificar en AKS: pod Ready, imagen tag, envFrom, probes, Service ports.

### Post-deploy

17. [ ] Logs del pod sin CrashLoop.
18. [ ] Health/probe acorde al proceso real (HTTP path vs `tcpSocket`).
19. [ ] Discovery / URLs / DB / Redis según el producto (no copiar ciegamente env de otro sistema).

---

## 9. Errores frecuentes (aprendidos)

| Síntoma | Causa típica | Qué hacer |
|---------|--------------|-----------|
| Build Docker no encuentra `packages/` o `src/` | Contexto Docker = carpeta del Dockerfile, no la raíz que esperabas | Mover Dockerfile a la raíz **o** ajustar COPY / `rutadockerfile` |
| Imagen `services/#{SERVICE_NAME}#/...` literal | Replace **después** del File Creator, o sin Replace | Orden File Creator → Replace → Build |
| Pod `ImagePullBackOff` con nombre raro | `image:` usó `#{servicesname}#` o token sin resolver | Usar `#{image}#` + VG con `image` correcto |
| Release no sale tras Build OK | CD trigger Disabled | Activar rayo del artefacto |
| Prod despliega build de otra branch / ImagePullBackOff raro | Artifact filter del stage ausente o mal | Stage Produccion → Include + Build branch = rama de Prod |
| CrashLoop / probe fail | Health path/puerto del YAML ≠ app real | Alinear probes al código (`/health`, tcpSocket, etc.) |
| App OK en local, falla en cluster | ConfigMap/Secret con hosts legacy (`*-core-service`, puertos viejos) | Discovery FQDN actual + reinicio/rollout |
| File Creator PUT falla con `uFEFF` | BOM UTF-8 en el YAML | Guardar UTF-8 **sin BOM** |
| `pnpm`/`npm` no resuelve workspace | Repo no monorepo pero Dockerfile asume workspaces | Dockerfile y lockfile del **ese** repo |
| Clonar Build “Auth” para una web | Path filters / Dockerfile monorepo heredados | Limpiar steps y variables ajenas al tipo de app |

---

## 10. Cómo operar con la API (agente / automatización)

Patrón usado en Buklo (reutilizable):

1. **Leer** definición origen (Build / Release / VG) por id.
2. **Deep copy** → cambiar `name`, `id`/`revision` limpias, repo si aplica, variables, File Creator `filecontent`.
3. **POST** Variable Group → **POST** Build → **POST** Release linkeando el Build nuevo y la VG en stage Prod.
4. Activar CD trigger (UI o API de release definition).
5. Guardar export JSON local solo como respaldo (`_ado_review/`), no como fuente de verdad.

Datos típicos en esta org:

| Concepto | Valor de referencia (ajustar por proyecto) |
|----------|--------------------------------------------|
| Org | `https://dev.azure.com/Shared-Service-GM` |
| Release API | `https://vsrm.dev.azure.com/Shared-Service-GM` |
| Proyecto pipelines | `DevOps` |
| Token local | `C:\mantenimientos\azure devops\token.txt` |
| ACR | `gmonhubacreastus20001.azurecr.io` / connection `ACR Hub-2` |
| Cluster Prod | `gmon-prod-aks-eastus2-0001` / connection `AKS-PROD-SVC` |

**Clonar siempre desde un pipeline del mismo “tipo”:**

- API / microservicio → clonar otro microservicio  
- SPA / Angular / estático → clonar otra web  
- Job / worker → clonar un worker  

No clones un monorepo Nest para una web con Dockerfile propio sin limpiar File Creator Dockerfile.

---

## 11. Matriz rápida: ¿qué copiar del origen?

| Elemento | ¿Copiar? | Ajustar |
|----------|----------|---------|
| Task group Build | Sí (referencia) | `image`, `rutadockerfile`, registry |
| File Creator Dockerfile | Solo caso B | Contenido + tokens |
| Replace tokens Dockerfile | Solo si hay tokens | Archivo / root |
| File Creator deployment-prod / dev / uat | Sí — **mismo YAML clonado** | Solo Secret, ConfigMap, DNS Ingress |
| Path filters | No ciego | Rutas de **esta** app |
| Repo del Build | Revisar | Repo Git correcto |
| Variable Group keys | Sí como plantilla | `servicesname`, `image`, resources, namespace |
| Release stages Dev/UAT | Sí estructura | Pueden quedar inactivos |
| Stage Produccion VG | Sí | Link a VG nueva |
| CD trigger | — | **Activar** siempre |
| Artifact filter stage Prod | — | **Include** + Build branch de Prod (Buklo: `release`) |

---

## 12. Dev / UAT = clon del YAML Prod

Los File Creator `deployment-dev.yml` y `deployment-uat.yml` son el mismo diseño que Prod, con Secret/ConfigMap/DNS de ese ambiente, más **`imagePullSecrets: acr-pull-secret`** e Ingress **`ingressClassName: nginx`**. **`deployment-prod.yml` se deja tal cual** (sin esos dos). Detalle: [`ado-classic-from-scratch.md`](./ado-classic-from-scratch.md) §3.4 Paso 3.

Cada ambiente tiene **su** Variable Group (`Desarrollo-…` / `UAT-…` / `Produccion-…`). No reutilices la Library de Prod en UAT.

---

## 13. Relación con la guía Buklo

| Documento | Alcance |
|-----------|---------|
| [`devops-guide.md`](./devops-guide.md) | Buklo monorepo: servicios, puertos, DB, inventario Build/Release/VG ids |
| [`ado-classic-from-scratch.md`](./ado-classic-from-scratch.md) | Alta en blanco: **AKS** (§1–7) y **base de datos DACPAC** (§8, Build 488 / Release 298 / Library `Bases Datos SQL`) |
| **Este playbook** | Cualquier producto/repo: decisiones Dockerfile, variables, checklist, anti-patrones |

Si el proyecto es Buklo microservicio → usa playbook + guía Buklo.  
Si es otro producto y **no** hay pipeline que clonar → [`ado-classic-from-scratch.md`](./ado-classic-from-scratch.md) + YAML de ese repo.

---

*Playbook derivado de la experiencia montando pipelines clásicos Buklo (Build / Release / Library / AKS). Actualizar cuando cambien task groups o convenciones de tokens en la org.*
