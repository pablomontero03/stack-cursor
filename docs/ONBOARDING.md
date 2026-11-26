> En Cursor este árbol no se usa. Las rutas de trabajo son `.cursor/rules/`, `.cursor/skills/`, `.cursor/agents/`, `.cursor/memories/`, `.cursor/mcp.json` y `.local/sesiones-kiro/`. Lo de abajo es el mapa viejo de Kiro Crew.

# Onboarding — Primer día en `automation-kiro`

> Guía de arranque para quien opera este stack por primera vez. Complementa
> el `README.md` (visión general) con el detalle práctico del primer día.
> Actualizado: 2026-09-14.

---

## 1. Qué es este stack y para qué sirve

`automation-kiro` es el stack de automatización operativa de **Grupo Montecristo**,
ejecutado por el agente **Kiro** (Kiro Crew). Kiro actúa como un operador técnico
asistido: administra pipelines de aplicación (Azure DevOps clásico Build/Release),
infraestructura Azure (ARM), Kubernetes/AKS, permisos de Azure DevOps, Cloudflare,
sincronización de esquemas SQL → SSDT, monitoreo n8n y servidores Linux/Windows —
todo bajo un único contrato de seguridad: **el agente planifica, el humano aprueba,
el agente ejecuta y verifica.** Nunca escribe sin un plan aprobado, y toda eliminación
o despliegue a Producción exige su propia aprobación separada. El flujo invariante de
cada dominio es `inventario en vivo → plan → aprobación → apply → readback`.

---

## 2. Pre-requisitos del entorno

### Sistema y herramientas

| Requisito | Cómo instalarlo / verificarlo |
|-----------|-------------------------------|
| Ubuntu 22.04+ / WSL2 | `lsb_release -a` |
| PowerShell Core 7+ (`pwsh`) | `sudo apt install -y powershell` → `pwsh --version` (los scripts NUNCA corren en Windows PowerShell) |
| Azure CLI (`az`) | `curl -sL https://aka.ms/InstallAzureCLIDeb \| sudo bash` → `az version` |
| `kubectl`, `helm`, `cilium`, `hubble` | En `~/.local/bin` (los coloca `./setup-cursor.sh`) |
| `kubelogin` | Necesario para el handshake AAD de los AKS privados |
| Cursor en esta carpeta | abrir `/home/cursor/stack-cursor` |

### Credenciales y variables

- Las credenciales reales viven en `env/.env` (**chmod 600, NO versionado**).
  Copiar la plantilla y llenarla con valores reales:
  ```bash
  cp env/.env.example env/.env
  chmod 600 env/.env
  ```
- Variables clave que este stack espera en `env/.env`:
  - `REPO_ROOT` — raíz del proyecto; todas las rutas relativas se interpretan desde aquí.
  - `AZURE_DEVOPS_PAT` — PAT compartido por los dominios Pipelines y Permissions. **Nunca se imprime.**
  - `CLOUDFLARE_API_TOKEN` — token de Cloudflare (nunca el Global API Key).
- **Nunca** imprimir, copiar ni almacenar passwords, PAT, tokens, webhooks o
  connection strings completas. En planes y documentación usar placeholders
  `${NOMBRE_VARIABLE}`.

### Sesiones ya establecidas (no re-autenticar desde este flujo)

- **Azure:** `az login` ya está hecho. **Nunca ejecutar** `az login` / `az logout` /
  `az account clear`. Verificar con `az account show`.
- **Kubernetes:** kubeconfig en `~/.kube/config`. Nunca copiarlo al repositorio.
- Suscripción activa: `Hospital Metropolitano` (`69dc43ec-5f24-4203-9239-a8d0f8506d44`),
  tenant `Grupo Montecristo` (`33dd4184-3068-47da-891d-a70e02f8c0c9`).

### Arranque

```bash
./setup-cursor.sh      # variables, PATH y login de az
az account show      # verificar sesión Azure
Abrir /home/cursor/stack-cursor en Cursor. Las rules de .cursor/rules/ entran solas.
```

---

## 3. Primer ciclo paso a paso: plantilla → subagente → aprobación → pod running

El caso canónico de un primer día es crear (o redesplegar) el pipeline de una
aplicación AKS. El flujo, del más maduro de los dominios:

1. **Plantilla.** Partir de `docs/PLANTILLA-CICLO-CREACION-PIPELINE-APLICACION-LIGERA.md`.
   Reunir el intake: nombre de la app, repo, subdirectorio del monorepo, entornos
   (dev/uat/prod), y confirmar `appname` leyéndolo del `project.json` de la app
   (nunca inventarlo).

2. **Inventario en vivo.** El agente confirma contra ADO/AKS/Cloudflare los ids,
   pools, service connections, task groups y clusters vigentes. **Nunca se asume
   que un id de la documentación sigue vigente.**

3. **Subagente preparatorio.** El coordinador delega a `ado-pipeline-builder` la
   generación de planes DEV/UAT, Variable Groups, manifests y hashes. Este
   subagente **prepara y valida**; el `Apply` real lo ejecuta el coordinador (o el
   builder solo si el mensaje de tarea lo autoriza explícitamente).

4. **Validación.** `Test-AdoClassicPlan.ps1 -InventoryPath …` sobre el plan DEV/UAT
   resuelve ids pendientes (p. ej. `buildTaskGroup.id`) y produce el `validationHash`.

5. **Aprobación (una sola).** El coordinador presenta el plan completo con su
   `validationHash`. Una sola aprobación cubre Libraries + definiciones Build/Release
   no destructivas.

6. **Apply.** El coordinador ejecuta `Apply-AdoClassicPlan.ps1` con el hash aprobado.

7. **Primer Build de prueba.** Encolar desde la rama **`development`** (nunca
   `release` para una prueba dev/uat). Los stages Dev y UAT se disparan por CI en
   `development` y `uat` respectivamente.

8. **Readback → pod running.** Verificar el rollout en AKS: el pod debe quedar
   `1/1 Running`. Si falla (`ErrImagePull`, `OOMKilled`, `CrashLoopBackOff`), ver
   las FAQ más abajo.

> **Regla de oro:** cualquier recurso que el propio ciclo haya creado y que estorbe
> en un re-deploy (ingress en conflicto, registro DNS), lo corrige el agente mismo
> — no se le pide al usuario que lo borre.

---

## 4. Mapa de agentes (25)

El stack define **1 coordinador + 24 subagentes especializados**. El **coordinador**
es la sesión principal de Kiro: es el único que presenta el plan final, ejecuta los
scripts `Apply-*` y verifica el resultado. Los subagentes se agrupan por rol:
`-diagnoser` (solo lectura, primera causa), `-reviewer` (revisión independiente del
plan antes de aplicar), `-operator`/`-builder` (inventario, plan y ejecución aprobada).

| # | Agente | Qué hace |
|---|--------|----------|
| 0 | **coordinador** (sesión Kiro) | Presenta el plan final, ejecuta los `Apply-*`, verifica el readback. Único autorizado a escribir en producción. |
| 1 | `aks-diagnoser` | Diagnóstico de solo lectura de clusters AKS: eventos, logs, métricas, scheduling, red, DNS, almacenamiento, ingress, autoscaling, nodos, salud. |
| 2 | `aks-operator` | Inventario, planificación y ejecución aprobada de cambios AKS (kubectl/Helm/Azure CLI/MCP). Corre `Apply-AksChangePlan.ps1`. |
| 3 | `aks-reviewer` | Revisa independientemente un plan de cambio AKS (impacto, seguridad, respaldos, rollback, readback) antes de aplicar. |
| 4 | `azure-diagnoser` | Diagnóstico de solo lectura de recursos ARM: Activity Log, estado, Resource Graph, locks, RBAC, redes, salud. |
| 5 | `azure-finops-analyst` | Análisis FinOps de la suscripción Hospital Metropolitano: costos, consumo, anomalías, pronósticos, recursos ociosos, reservas, reportes. |
| 6 | `azure-operator` | Inventario, planificación y ejecución aprobada de cambios ARM. Corre `Apply-AzureChangePlan.ps1` / `Apply-AzureDeletePlan.ps1`. |
| 7 | `azure-reviewer` | Revisa independientemente un plan de cambio Azure antes de aplicar. |
| 8 | `ado-pipeline-builder` | Prepara, valida y (si el coordinador lo autoriza) aplica planes de pipelines clásicos ADO (AKS o DACPAC) para Shared-Service-GM/DevOps. |
| 9 | `ado-pipeline-diagnoser` | Analiza builds, releases, logs y artefactos fallidos de ADO clásico (AKS o DACPAC). |
| 10 | `ado-pipeline-reviewer` | Revisa independientemente un plan de pipeline clásico ADO contra guías e inventario antes de aplicar. |
| 11 | `ado-permissions-builder` | Administra grupos de seguridad de proyecto, membresías y permisos Git de ADO a partir de intake + inventario + plan aprobado. |
| 12 | `ado-permissions-diagnoser` | Diagnostica fallas de MCP/Graph/Security API, PAT/scopes, descriptores, tokens, herencia y readback del dominio de permisos. |
| 13 | `ado-permissions-reviewer` | Revisa independientemente un plan de grupos/membresías/permisos Git contra la matriz definida antes de aplicar. |
| 14 | `cloudflare-diagnoser` | Diagnóstico de solo lectura Cloudflare: DNS, propagación, SSL/TLS, WAF, cache, Workers, Pages, Zero Trust, Tunnels, LB, logs. |
| 15 | `cloudflare-operator` | Inventario, planificación y ejecución aprobada de cambios Cloudflare (API REST, MCP, Terraform, Wrangler). Corre `Apply-Cloudflare*Plan.ps1`. |
| 16 | `cloudflare-reviewer` | Revisa independientemente un plan de cambio/eliminación Cloudflare antes de aplicar. |
| 17 | `linux-server-diagnoser` | Analiza en solo lectura Linux, recursos, servicios, Docker/systemd y aplicativos del catálogo `docs/servers/servers.json` a partir de salidas ya obtenidas. |
| 18 | `linux-server-reviewer` | Revisa independientemente cualquier cambio propuesto para un servidor Linux del catálogo antes de aplicar. |
| 19 | `windows-server-diagnoser` | Analiza en solo lectura Windows, recursos, servicios y aplicativos del catálogo `docs/servers/windows/servers.json`. |
| 20 | `windows-server-reviewer` | Revisa independientemente cualquier cambio propuesto para un servidor Windows del catálogo antes de aplicar. |
| 21 | `n8n-monitoring-diagnoser` | Analiza ejecuciones fallidas de workflows n8n de monitoreo SQL o del workflow `AIA-CC-MAIA-Chat`. |
| 22 | `n8n-monitoring-reviewer` | Revisa independientemente clones de packs de monitoreo SQL y cambios masivos (timeouts) sobre workflows n8n antes de aplicar. |
| 23 | `schema-sync-diagnoser` | Analiza logs y resultados de Schema Sync, SqlPackage, DacFx, SSDT, Git, ADO y n8n. |
| 24 | `schema-sync-reviewer` | Revisa independientemente cambios de Schema Sync, SSDT, catálogos y workflows, con énfasis en seguridad de solo lectura. |

> **Regla clave sobre roles:** un agente `-diagnoser` no tiene `Bash`/`PowerShell`/MCP
> en vivo garantizados — nunca delegarle una fase de polling. Para monitoreo activo
> usar un `-operator` o la sesión principal.

---

## 5. Preguntas frecuentes

### ¿Por qué no debo usar `.kiro/rules/`?

Porque **`.kiro/rules/` no existe**. Es una ruta fantasma heredada de una etapa
anterior (`.claude/rules/`, ya borrada). Las reglas de autorización y seguridad de
cada dominio viven en los archivos de **steering** (`.cursor/rules/<dominio>.mdc`),
que se inyectan automáticamente al agente al iniciar sesión. Si un prompt o skill
apunta a `.kiro/rules/…` o `authorization.md`/`security.md`, la referencia está rota
y el agente terminaría operando **sin cargar las guardrails que cree tener** — el
riesgo más grave del stack (ver `docs/ROADMAP-MADUREZ.md`, Fase 0). Siempre leer el
steering, nunca `.kiro/rules/`.

### ¿Qué pasa si el Build queda en `notStarted`?

Un Build que queda en `notStarted` por 7+ minutos casi siempre es el **pool hosted**
(Azure Pipelines, id 127, `isHosted`) **sin slot libre** — no un pool sin agentes ni
una restricción de la definición. Los pools hosted fluctúan por disponibilidad. El
fix: **cancelar** el build colgado (`PATCH status=cancelling`) y **re-encolar**
(`POST pipelines/<id>/runs`); el nuevo slot lo toma de inmediato y pasa a
`inProgress`. Luego actualizar el `AgenticCycleState` con el nuevo `build_id`. **No**
reasignar la definición a otro pool ni diagnosticar como "pool sin agentes", y **no**
dejar el build colgado esperando indefinidamente.

### ¿Cómo corrijo un `OOMKilled`?

`OOMKilled` significa que el contenedor superó su límite de memoria (`limmem`). Pasos:

1. Confirmar con `kubectl describe pod <pod> -n <ns>` (buscar `Reason: OOMKilled`) y
   `kubectl top pod` para ver el consumo real.
2. Los recursos se definen **por ambiente** en el Variable Group y se embeben en el
   manifest del Build. Valores de referencia para web tipo analytics en `mod-ag-test`:
   Dev/UAT `reqcpu=25 reqmem=32 limcpu=75 limmem=64`; Prod `reqcpu=75 reqmem=128
   limcpu=300 limmem=300`. **Nunca** copiar los valores de Prod a Dev/UAT.
3. Subir `limmem` (y `reqmem` si aplica) en el Variable Group del ambiente afectado,
   regenerar el plan, aprobar y re-aplicar. El límite vive en el pipeline definition,
   así que el cambio pasa por el flujo `plan → aprobación → apply`, no por un `kubectl
   edit` manual.

---

## 6. Glosario

| Término | Significado |
|---------|-------------|
| **AgenticCycleState** | Estado persistido (JSON) de una corrida agéntica del ciclo de pipeline, en `docs/pipeline-cycles/<runId>.json`. Captura app, hashes del plan aprobado, fase actual, último estado observado por dominio y timestamps. Solo **registra**; nunca ejecuta `Apply-*` ni decide Producción. Lo crea/actualiza `New-AgenticCycleState.ps1`. |
| **validationHash** | Hash SHA-256 que identifica de forma única un plan validado. El agente solo puede ejecutar el plan con el hash exacto que el usuario aprobó; cualquier cambio invalida la aprobación. Es la garantía de que se aplica exactamente lo aprobado. |
| **Apply** | La ejecución real de un plan aprobado, siempre vía un script `Apply-*.ps1` (p. ej. `Apply-AdoClassicPlan.ps1`, `Apply-AksChangePlan.ps1`). Es el único momento en que el stack escribe en sistemas reales. Lo corre el coordinador. |
| **plan** | Documento/objeto que enumera todos los efectos de un cambio: operaciones exactas, ids, dependencias, impacto, respaldo, verificación y rollback. Se genera con `New-*Plan.ps1` y se valida con `Test-*Plan.ps1` antes de aprobarse. |
| **steering** | Los archivos `.cursor/rules/<dominio>.mdc`: la fuente de verdad de las reglas y guardrails de cada dominio. Se inyectan automáticamente al agente al iniciar sesión. Reemplazan a la ruta fantasma `.kiro/rules/`. |
| **skill** | Procedimiento técnico en disco (`.cursor/skills/<dominio>/SKILL.md` + scripts + references). Describe cómo ejecutar una operación del dominio; el agente lo lee antes de operar. |
