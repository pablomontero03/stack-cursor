# Plantilla de datos — pipeline AKS clásico nuevo (Build + Release)

Actualizado 2026-08-25, alineado con las herramientas reales de este
skill (`New-AdoClassicAksPlan.ps1`, `ConvertTo-AdoEnvClassification.ps1`,
la convención de agrupación de merges y la plantilla de manifiestos K8s).
Reemplaza como fuente primaria de intake al checklist viejo de
`ado-classic-playbook-any-project.md` §8 (ese doc queda como referencia
de errores frecuentes y del flujo manual anterior, no como plantilla de
datos).

**Cómo usarla:** el usuario pega esta plantilla llenada (o solo las
partes que sabe) en el chat cuando pide crear un pipeline nuevo. Todo lo
marcado "🔍 lo reviso yo" no hace falta llenarlo — se investiga leyendo
el repo real vía `mcp__azure-devops__repo_file`; si el usuario ya lo
sabe y lo da, se usa igual sin re-preguntar.

---

## 1. Identificación del aplicativo

- **Producto** (carpeta/grupo en Azure DevOps, ej. `Administracion-Proyectos`):
- **App** (nombre visible del Build/Release, ej. `administracion-proyectos-web`):
- **Repo** (nombre exacto en Azure DevOps):
- **Proyecto ADO del repo** (solo si es distinto de `DevOps` — el repo de
  la app puede vivir en su propio proyecto, el Build/Release siempre vive
  en `DevOps`):
- **Rama de producción** (ej. `release`):
- **Ramas que disparan CI** (default: `development`, `uat`, `release`):

## 2. Docker / Build

- **Ruta del Dockerfile** (ej. `./Dockerfile`) — 🔍 lo reviso yo si no lo das.
- **Path filter del trigger CI** (default `+/**`):
- **ServicesName** (nombre del recurso K8s, ej. `mi-app-web`):
- **Image** — prefijo de imagen Docker. **Debe terminar en guion**
  (ej. `mi-app-web-`) — `Build-MultiStage` arma el repositorio
  concatenando `$(image)$(ambiente)` sin separador.
- **¿Es monorepo?** Si sí, `ServiceName` del servicio puntual:
- **Container Registry** (dominio real, ej. `gmonhubacreastus20001.azurecr.io`):
- **Service Connection ACR** (nombre exacto, ej. `ACR Hub-2`):
- **Agent pool del Build**, si NO es el default de Azure Pipelines
  (Microsoft-hosted):

## 3. Por ambiente — Desarrollo / UAT / Producción

Repetir para cada ambiente que aplique (Producción siempre; Desarrollo/UAT
si se van a activar ya):

| | Desarrollo | UAT | Producción |
|---|---|---|---|
| Namespace K8s | | | |
| reqcpu/reqmem/limcpu/limmem | *(default 50/70/100/200 si es liviana)* | | *(default 75/128/300/300)* |
| Service Connection AKS (solo si el ambiente usa `Deployment-MultiStage-Cluster-*`) | | | — |
| Cluster AKS real (Producción) | — | — | |
| Resource Group del cluster (Producción) | — | — | |
| Service Connection Kubernetes (Producción, solo si `Deployment-Azur-Aks-v3` la exige) | — | — | |
| ConexKubernetes (nombre) | | | |
| `¿aprobación humana antes de desplegar?` | no | no | *(confirmar — default no)* |

## 4. Ingress (por ambiente)

- **Host Desarrollo** (dominio real):
- **Host UAT** (dominio real):
- **Host Producción** (dominio real — ojo, puede NO ser subdominio del
  mismo dominio que dev/uat, confirmar literal, no asumir):
- **TLS `secretName`** — si no se da, **se pregunta siempre** (no se
  asume `gmontecristo-secret` aunque sea el más común):
  - Desarrollo/UAT:
  - Producción:

## 5. Variables de entorno (`.env`)

- **¿El repo tiene `.env`/`.env.example`?** Path si no es el default
  (`/.env.example`) — 🔍 lo busco yo si no se especifica.
- Se procesa con el entrypoint versionado
  `Convert-AdoEnvFileClassification.ps1 -PopulateRealValues`
  (valores reales directo en ConfigMap y Secret — política vigente para
  todos los pipelines de esta org, ver memoria `feedback-real-env-secrets-in-k8s-manifests-authorized`).
  El switch conserva una aprobación puntual porque materializa secretos; sin
  él, el wrapper produce únicamente la clasificación redactada. Si ALGUNA vez
  se quisiera excluir `-PopulateRealValues` para un repo puntual, avisar
  explícitamente.

## 6. Cosas que reviso yo solo (no hace falta llenarlas)

- 🔍 Puerto real de la app (`EXPOSE`/`nginx.conf`/`listen`).
- 🔍 Sondas — `path` real de health check (o `/` si es una SPA sin backend).
- 🔍 Si necesita `volumeMounts`/`volumes` (logs a archivo).
- 🔍 Si necesita `ServiceAccount`/`Role`/`RoleBinding` (acceso a la API de
  K8s en runtime).
- 🔍 Clasificación de variables del `.env` (build-time vs runtime vs
  secreto vs pipeline).

## 7. Casos especiales / opcionales

- **Agrupación de merges ("gana el más nuevo")** — activa por defecto en
  todo pipeline nuevo. Avisar explícitamente solo si esta app NO la
  necesita (ej. app de bajo tráfico, cada push debe buildear individual).
- **`BatchWindowMinutes`** si distinto del default (`5`):
- **`DeployTaskGroupName`** si distinto del default (`Deployment-Azur-Aks-v3`
  para Producción; `Deployment-MultiStage-Cluster-Desarrollo` para
  Desarrollo/UAT es el patrón ya usado, confirmar si aplica igual acá).

---

## Qué NO entra en esta plantilla (siempre aparte, con su propia aprobación)

- Crear los recursos reales en Azure DevOps (Library + Build + Release) —
  requiere plan validado + aprobación explícita, nunca se dispara solo
  por llenar esta plantilla.
- Encolar el primer Build, crear la primera Release real, aprobar un
  stage, desplegar a Producción.
- Cualquier secreto de infraestructura de Azure DevOps en sí (PAT,
  Service Connections nuevas) — esas son recursos preexistentes que se
  referencian por nombre, nunca se crean desde este flujo.
