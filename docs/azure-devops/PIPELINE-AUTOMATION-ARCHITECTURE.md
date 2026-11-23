# Arquitectura de automatización — Azure DevOps Pipelines

Organización `Shared-Service-GM`, proyecto de pipelines `DevOps`. Este
documento describe cómo Claude Code opera pipelines clásicos y YAML de
Azure DevOps en este repositorio; el procedimiento operativo día a día
vive en la skill, no acá.

## Fuentes de verdad

| Qué | Dónde |
|-----|-------|
| Procedimiento operativo, modos, enrutamiento | `.claude/skills/manage-azure-devops-pipelines/SKILL.md` |
| Guías originales de la organización (alta desde cero, playbook genérico, caso Buklo) | `.claude/skills/manage-azure-devops-pipelines/references/` |
| Mapa de endpoints REST para brechas clásicas | `.claude/skills/manage-azure-devops-pipelines/references/ado-api-map.md` |
| Matriz de aprobación | `.claude/skills/manage-azure-devops-pipelines/references/approval-matrix.md` |
| Autorización detallada | `.claude/rules/azure-devops-pipelines/authorization.md` |
| Seguridad detallada (PAT, secretos, MCP vs REST) | `.claude/rules/azure-devops-pipelines/security.md` |
| Instrucciones originales de esta incorporación | `docs/azure-devops/INSTRUCCIONES-CLAUDE-AZURE-DEVOPS-PIPELINES.md` |

## Decisión técnica: MCP oficial primero, REST controlado para brechas clásicas

```text
┌─────────────────────────────────────────────────────────────┐
│                    Solicitud del usuario                     │
└───────────────────────────┬───────────────────────────────────┘
                             ▼
                 ¿El MCP oficial "azure-devops"
                 (@azure-devops/mcp) lo cubre?
                             │
              ┌──────────────┴──────────────┐
              ▼ Sí                            ▼ No (brecha clásica)
     Usar el MCP directamente         scripts/*.ps1 → Apply-AdoClassicPlan.ps1
     (inventario, builds, logs,       → Invoke-AdoRest.ps1 (Variable Group,
      releases, artefactos,           Build clásico, Release clásico — API
      pipelines YAML)                 REST 7.1, documentada en ado-api-map.md)
              │                                    │
              └──────────────┬─────────────────────┘
                             ▼
              Flujo: intake → inventario → plan →
              validación independiente → aprobación →
              apply → readback → reporte → memoria
```

El MCP oficial (`@azure-devops/mcp`, versión fijada — ver
`.mcp.json`) es siempre la primera opción. La brecha conocida a la fecha
de esta incorporación: el toolset oficial no cubre crear de punta a punta
un pipeline **clásico** completo (Variable Group + Build clásico + Release
clásico). Para esa brecha, y solo para ella, se usan los scripts
PowerShell deterministas de `scripts/` sobre las APIs REST oficiales.
Nunca se sustituye una llamada MCP rechazada por REST — REST solo aplica
cuando la capacidad no existe en el MCP.

## Separación de familias

Dos familias de pipelines, nunca mezcladas:

| | App → AKS | Base de datos (DACPAC/SSDT) |
|--|-----------|------------------------------|
| Library | Una por app (`Produccion-<Producto>-<App>`) | Una compartida (`Bases Datos SQL`) |
| Task group Build | File Creator + Build (Docker/ACR) | Build-DataBases + ventana de agrupación/HU |
| Task group Release | Deployment-Azur-Aks-v3 | Deployment-DataBases |
| Artefacto | Imagen ACR + YAML K8s | DACPAC |
| Publica hacia | AKS (kubectl apply) | SQL (`Apply` — escritura real, aprobación de alto riesgo) |

## Flujo obligatorio de creación

```text
1. intake         → confirmar familia, app/base, ambientes, sin placeholders
2. inventario      → MCP oficial (o REST GET de ado-api-map.md), solo lectura
3. plan             → New-AdoClassicAksPlan.ps1 / New-AdoClassicDatabasePlan.ps1
4. validación       → Test-AdoClassicPlan.ps1 + agente ado-pipeline-reviewer
5. aprobación       → explícita del usuario, plan completo enumerado
6. apply            → Apply-AdoClassicPlan.ps1 (script separado de Invoke-AdoClassicPlan.ps1, dry-run exclusivo; solo tras aprobación)
7. readback         → Test-AdoCreatedResources.ps1
8. reporte          → resumen sanitizado al usuario
9. memoria          → .claude/agent-memory/ado-pipeline-*/ (solo aprendizaje real)
```

Ninguna fase se salta. `apply` nunca corre sobre un plan sin
`validated=true`. Ningún paso de este flujo encola el primer Build, crea
el primer Release real ni despliega a Producción — esas acciones exigen
su propia aprobación separada (ver `authorization.md`).

## Agentes

| Agente | Rol | Acceso |
|--------|-----|--------|
| `ado-pipeline-builder` | Intake, inventario, plan, apply aprobado | `Read, Grep, Glob, Bash` — corre los scripts de la skill |
| `ado-pipeline-diagnoser` | Diagnóstico de solo lectura de fallos de Build/Release/deploy | `Read, Grep, Glob` — recibe datos ya obtenidos, no llama al MCP directamente |
| `ado-pipeline-reviewer` | Revisión independiente de un plan antes de aplicarlo (`Apply-AdoClassicPlan.ps1`) | `Read, Grep, Glob` — nunca modifica ni aplica |

Los tres tienen `memory: project` con carpeta propia bajo
`.claude/agent-memory/`, según `.claude/rules/agent-memory.md`.

## Estado a la fecha de esta incorporación

Esta arquitectura quedó preparada y validada en modo local: estructura de
skill/agentes/hooks/reglas creada, MCP oficial configurado en `.mcp.json`
con la versión estable fijada. La conexión se verificó con
`claude mcp get azure-devops` (handshake/health-check del servidor,
`√ Connected`) — **no** con consultas reales a través de las tools del
MCP en esta sesión: esas tools no se cargaron porque el servidor se
agregó a `.mcp.json` después de que la sesión ya estaba corriendo.
Confirmar proyectos/definiciones reales vía las tools del MCP queda
pendiente de reiniciar/recargar la sesión de Claude Code. Ningún
pipeline, Build, Release, Variable Group ni DACPAC real fue creado,
modificado, ejecutado ni eliminado como parte de esta incorporación. La
primera creación real de un pipeline se hará después, con los datos
exactos de la aplicación/base y una aprobación explícita del usuario para
esa operación puntual.

## Primera corrida real (2026-09-10) — app-analytics: bugs corregidos y convención cross-project

La primera ejecución de punta a punta del flujo (ciclo `app-analytics`,
familia `web`, vía la skill `orchestrate-application-pipeline-cycle`)
confirmó que la automatización funciona y destapó tres bugs reales de los
scripts, ya corregidos, más una convención nueva. Se dejan documentados
para no re-descubrirlos.

> **Principio rector (no negociable, confirmado por el usuario
> 2026-09-10):** NUNCA asumir ni generar un artefacto (manifiesto,
> payload, plan) a partir de una plantilla genérica de `references/` o por
> suposición. SIEMPRE validar primero contra (1) el recurso/modelo VIVO
> equivalente ya en producción (ej. el hermano web `sso-web` Build 635),
> (2) las guías/steering y esta doc, (3) las memorias y lecciones
> guardadas, y (4) el código real de la app (Dockerfile, nginx.conf,
> project.json). Recién con esa evidencia generar, y luego VERIFICAR el
> resultado en vivo. Los manifiestos de esta primera corrida se generaron
> con una plantilla API por saltarse este paso — de ahí los bugs #4 y #5.

### Recursos creados (evidencia de que el pipeline funciona)

- Variable Groups: `Desarrollo-Buklo-app-analytics-web` (468),
  `UAT-Buklo-app-analytics-web` (469),
  `Produccion-Buklo-app-analytics-web` (470).
- Build definition `Build-Buklo-app-analytics-web` (id **638**), carpeta
  `\buklo`.
- DNS Cloudflare: `analytics-web-dev.gmontecristo.com` y
  `analytics-web-uat.gmontecristo.com` (A → 177.93.30.165, sin proxy).
- El Build encoló, clonó el commit real de `development`, usó
  `Dockerfile.app-analytics` y llegó a compilar — falló por **error de
  código** de la app (TypeScript en el feature `pace`), NO por el
  pipeline. Error de código = se reporta con evidencia, nunca se corrige
  automáticamente ni se abre PR; no se consume Release.

### Bugs corregidos en los scripts (portabilidad Linux/WSL + validación)

1. **`Invoke-AdoRest.ps1` — ruta del journal de ejecuciones no portable.**
   `Get-AdoExecutionsDir` tenía `$script:AdoProductionExecutionsDir`
   definido con comillas SIMPLES y separadores Windows
   (`'$env:REPO_ROOT\.local\azure-devops\executions'`): `$env:REPO_ROOT`
   nunca expandía y en Linux `Join-Path` lo interpretaba como un drive
   inexistente → `Apply-AdoClassicPlan.ps1` abortaba con *"A drive with
   the name '$env' does not exist"* reportando **cero escrituras**. Fix:
   derivar la ruta con `Join-Path` desde `$env:REPO_ROOT` (o `$PSScriptRoot`
   si falta) y separadores portables. Correr siempre con `REPO_ROOT`
   seteado (`export REPO_ROOT="$(pwd)"` tras `source env/.env`).

2. **`Test-AdoClassicPlan.ps1` — inventario "en el futuro".** En hosts con
   offset negativo (WSL −06:00) el validador rechazaba todo inventario
   como `generatedAtUtc esta en el futuro`: `ConvertFrom-Json` coacciona el
   timestamp a `[DateTime] Kind=Unspecified` (pierde la `Z`) y
   `.ToUniversalTime()` lo trataba como hora local, restando el offset.
   Fix: parsear con `AssumeUniversal | AdjustToUniversal` + `InvariantCulture`
   y comparar contra `[DateTime]::UtcNow`. (Es fix de raíz — ya no hace
   falta el workaround `TZ=UTC`, aunque no estorba.)

3. **Repo cross-project (Build en `DevOps` que source-a un repo de otro
   proyecto).** `buklo-web` vive en el proyecto **Buklo**
   (GUID `9f3ddab6-2d4c-491c-87b0-93888be32260`), invisible para el
   inventario DevOps-scoped, y `Test-AdoClassicPlan.ps1` no tenía bypass
   para un create-build. Fix versionado, sin relajar el caso normal:
   - `New-AdoClassicAksPlan.ps1` acepta `-RepoProject` y `-RepoId`.
   - `Test-AdoClassicPlan.ps1` acepta `repo.project != plan.project`
     **solo** si trae `repo.id` (GUID) resuelto en vivo y `repo.project`
     está en la allow-list → warning, no blocker. El GUID se resuelve con
     `az repos show`. Nunca se falsifica `validated=true`/`validationHash`.

4. **Trigger CI del Build con `pathFilters=[]` (path filters vacíos).**
   Observado en vivo en el Build 638 (rev 1): el trigger quedó con
   `branchFilters` correctos pero `pathFilters` VACÍO, pese a que el plan
   traía `repo.pathFilter = "+apps/app-analytics/**"`. Causa: en
   `New-AdoBuildDefinitionPayload` (y `Set-AdoBuildTriggerPathFilter`) el
   filtro se armaba con `@([string]$Plan.repo.pathFilter)` — un array de
   UN elemento que `ConvertTo-Json` desenvuelve a **string escalar**, y
   Azure DevOps descarta un `pathFilters` que no es lista → queda `[]`.
   Consecuencia real: el Build dispara con **cualquier** commit al
   monorepo `buklo-web`, no solo con los de su propia app. Fix: coma
   unaria `,@(...)` en el generador; para un Build ya creado, asignar
   `[string[]]@('+apps/<app>/**')` al nodo `triggers[0].pathFilters` y
   PUT de la definición completa (sube revisión). **Verificar SIEMPRE en
   vivo el trigger del Build recién creado** (`pathFilters` no vacío) —
   no basta con que el plan lo declare. Build 638 corregido a rev 3 con
   `pathFilters=['+apps/app-analytics/**']`.

5. **`deployment-*.yml` generados con plantilla de API, no de web.** El
   Build 638 se creó con los `references/deployment-*.yml` genéricos, que
   son de un **backend/API** — no de un web frontend. Datos ajenos que
   traían: puerto `3000`, sondas en `/api/v1/health`, `ServiceAccount` +
   `Role` + `RoleBinding` (RBAC de API), Ingress hardcodeado
   (`gateway-buklo-dev.gmontecristo.com` / `gmontecristo-secret`), y
   `deployment-prod` con `ingressClassName: internal-ingress`. El código
   real de `app-analytics` (Angular servido por nginx) escucha en **8080**
   con health en **`/health`**, sin RBAC. Corrección: los manifiestos web
   se derivan del **patrón web VIVO** (sso-web Build 635 / shell 579) MÁS
   el Dockerfile real de la app. Para `app-analytics` (Build 638 rev 4):
   - Puerto contenedor `8080`; Service `80 → 8080`; sondas `/health:8080`.
   - Recursos: ConfigMap + Deployment + Service + HPA + Ingress. **Sin RBAC.**
   - HPA `minReplicas=maxReplicas=1` (patrón web establecido).
   - Ingress por ambiente (no tokenizado en el YAML, hardcode por
     ambiente): dev/uat `ingressClassName: nginx`,
     `analytics-web-{dev,uat}.gmontecristo.com`, `gmontecristo-secret`;
     prod según FQDN del INPUT (`analytics-web.grupomontecristo.com`,
     Grupo A `nginx`).
   - `nodeSelector agentpool=userpool03` **solo en prod**; File Creator de
     prod queda `enabled=false` hasta la Aprobación 2.
   - **securityContext y volúmenes según el Dockerfile de ESA app**: los
     web vivos corren root (`/var/cache/nginx`, `/var/log/nginx`) porque
     usan otro Dockerfile; `Dockerfile.app-analytics` corre **no-root
     (uid 10001)** con nginx en `/tmp/nginx`, `/tmp/cache`, `/tmp/logs`,
     así que su manifiesto usa `runAsNonRoot: true`/`runAsUser: 10001` y
     esos `emptyDir`. La imagen manda sobre el pod — no copiar ciegamente
     el securityContext del hermano web.
   **Lección operativa:** verificar SIEMPRE en vivo el `filecontent` de los
   File Creator del Build recién creado; no basta con que exista una
   plantilla en `references/`.

   **Detalles finos del manifiesto web (copiar del modelo vivo sso-web
   Build 635, no simplificar):**
   - Incluir `Secret` (`stringData`) además del `ConfigMap`; si no hay
     `.env` real, usar valores dummy `DUMMY-...` (nunca un secreto real de
     otra app). `envFrom` lleva `configMapRef` **y** `secretRef`.
   - Label `version: "#{tag}#"` en `metadata.labels` y en
     `template.metadata.labels`. La imagen usa el token `#{servicesname}#`
     (`#{containerregistries}#/#{servicesname}##{ambiente}#:#{tag}#`), no
     `#{image}#`.
   - **Service `name: #{servicesname}#` SIN sufijo `-service`** — el
     `-service` es convención de API/backend, no de web. El backend del
     Ingress apunta a `#{servicesname}#`.
   - Ingress con el **set completo de anotaciones nginx** del modelo
     (buffering, proxy timeouts, upstream-keepalive, proxy-buffer,
     affinity cookie/persistent/session-cookie, proxy-next-upstream), no
     un subconjunto.
   - `imagePullSecrets: acr-pull-secret` **solo en dev/uat**, NO en prod.
   - prod: `ingressClassName: internal-ingress` (no `nginx`),
     `nodeSelector agentpool=userpool03`, `NG_APP_TEST_USERS_ENABLED:
     "false"`.

### Confirmación del gate de Producción (VS402896)

Confirmado en vivo: el Release se crea con Producción `isAutomated=true`
(sin approver) y el gate real (`Release Executers`) se fija en un
`update-release-definition` **posterior** que solo puede hashearse tras
conocer el Release ID. Es un proceso obligatorio de 2 pasos por la API de
ADO, no una ampliación de alcance.

### Regla (2026-09-10): el AGENTE genera el Release desde cero, NO clona

Coexisten dos enfoques en las referencias y hay que elegir el correcto:
- `devops-guide.md` describe el flujo **manual histórico de CLONAR** en la
  UI de ADO (clic derecho → clone), tras el cual el CD trigger y el
  artifact filter quedan mal y "hay que verificarlos". Es un manual de
  operación HUMANA.
- `ado-classic-from-scratch.md` + `New-AdoReleaseDefinitionPayload` es el
  flujo **canónico del refactor y el que el AGENTE debe seguir**: generar
  la definición **desde cero** con los scripts versionados
  (`New-AdoClassicCreatePlan.ps1` → `Test-AdoClassicPlan.ps1` →
  `Apply-AdoClassicPlan.ps1`), usando `Release-modelo-web.json` y el
  Release vivo hermano (sso-web 391) SOLO como **referencia de lectura**.

En esta primera corrida el Release 394 se creó **clonando la definición
viva 391 por REST (GET + POST)** — un atajo tomado porque el `spawn_run`
del builder fue rechazado por memoria. Fue el método equivocado: el clon
arrastró el alias `_Build-Buklo-sso-web` (causa directa del bug #6). El
generador versionado arma las `conditions`/artifact filter con el alias
correcto y no deja residuos. **Deuda técnica:** el 394 quedó
funcionalmente correcto tras las correcciones, pero idealmente debe
regenerarse con `New-AdoReleaseDefinitionPayload` para ser idéntico a lo
que el flujo produce. **No clonar por REST de nuevo, ni siquiera si un
spawn es rechazado por memoria — hacerlo secuencial en la sesión pero con
el generador.**

### Bug #6 (2026-09-10): artifact filter por stage apuntando al alias viejo tras clonar

Al crear el Release definition de app-analytics (id **394**) clonando el
modelo web vivo `sso-web` (Release **391**), el **artifact filter por rama
de cada stage quedó Disabled** en la UI. Causa: el filtro por rama vive en
`environments[].conditions[]` con `conditionType: "artifact"`, cuyo `name`
es el **alias del artifact** y `value` un JSON con `sourceBranch`. Al
clonar, se renombró el alias en `artifacts[]` (`_Build-Buklo-app-analytics-web`)
pero **NO** en esas conditions, que seguían con `_Build-Buklo-sso-web` →
el filtro apuntaba a un artifact inexistente y ADO lo mostraba Disabled.
Fix: renombrar el alias del artifact **en `artifacts[]` Y en las
conditions de los 3 stages**, y PUT. Verificado en vivo (394 rev 2):
Desarrollo→`development`, UAT→`uat`, Producción→`release`. **Verificar
siempre en vivo que cada stage filtra por su rama tras crear/clonar un
Release.**

### Mejora de proceso (2026-09-10): el Release definition NO espera al Build verde

En la primera corrida se difirió erróneamente la creación del Release a
"después de que el Build ejecute verde" (se trató como Fase 2). **Es
incorrecto y deja el pipeline a medias.** La regla correcta, ya reflejada
en `orchestrate-application-pipeline-cycle` (Etapa 1 + `approval-envelope.md`):

- **La definición del Release se crea en la Etapa 1, junto con el
  Build/VG/DNS**, aunque el Build no se haya ejecutado o haya fallado.
- Crear el Release definition solo requiere que el **Build definition
  exista** (para referenciarlo como artifact source por su ID).
- Un **Build verde es requisito para EJECUTAR una instancia** del Release,
  jamás para crear su definición ni para fijar el gate de Producción.
- El "ID del Release" del paso 2 del gate (VS402896) es el del Release
  **definition** (existe apenas se crea), no el de una instancia.
- Si el Build falla, se corrige el código y se re-encola; las definiciones
  Build + Release ya quedan completas y revisables.

### Bug #7 (2026-09-10): CD trigger Disabled y stage Producción sin approver

Tras clonar el 391, el Release 394 quedó con dos huecos que la UI mostró:
1. **Continuous deployment trigger Disabled** — el trigger vive en
   `triggers[]` a nivel de Release como
   `{triggerType: "artifactSource", artifactAlias: "..."}`; el clon lo trajo
   con el alias viejo `_Build-Buklo-sso-web`, apuntando a un artifact
   inexistente → UI lo mostraba Disabled. Fix: un único trigger
   `artifactSource` con el alias correcto `_Build-Buklo-app-analytics-web`.
2. **Stage Producción sin approver** — el modelo vivo (sso-web 391) venía
   con Prod `isAutomated: true` sin approver, así que el clon lo heredó
   incompleto. Prod SIEMPRE lleva el gate: `preDeployApprovals` con
   `isAutomated: false` y `approver` = grupo **`Release Executers`**
   (`originId 397ddbfe-1d60-4533-a4c9-b099f80ac154`,
   `[Shared-Service-GM]\Release Executers`). Es el **paso 2 del gate
   VS402896**. Fix aplicado y verificado (394 rev 4).

   > No copiar el `isAutomated: true` de un modelo vivo como si fuera
   > correcto — algunos releases vivos quedaron sin el gate configurado. El
   > generador desde cero arma ambos (CD trigger + approver) bien.
