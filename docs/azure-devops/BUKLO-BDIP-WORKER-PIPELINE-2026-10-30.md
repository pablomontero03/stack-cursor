# Buklo BDIP worker — Pipeline clásico creado y cerrado end-to-end (2026-10-29/30)

**Servicio:** `service-bdip` (worker NestJS del monorepo `buklo-backend`)
**Org/Proyecto:** `Shared-Service-GM` / `DevOps`
**Nombre del recurso k8s (final):** `worker-bdip` (pods `worker-bdip-0/-1`)
**Imagen ACR:** `worker-bdipdev:<buildId>`
**Build:** `Build-Buklo-Backend-BDIP` id=697 · **Release:** `Deploy-...-BDIP` id=435
**Resultado:** Release dev **8309 succeeded** end-to-end por pipeline (auto-disparado por el Build).

---

## Topología del worker

- Build: `Dockerfile.bdip --target worker` → `dist/main.worker.js`, HTTP 4013.
- Readiness `/health/worker`, liveness `/health`.
- **StatefulSet, 2 réplicas**, Service headless (`clusterIP: None`, requerido por `serviceName` del STS).
- Arranque "infra viva / jobs apagados" (SQL_ONLY). Ambos workers comparten el pool `bdip:dev:pool`.
- **Dev/UAT → k3s-dev (`172.16.2.43`, srv-desarrollo-5)**, NO AKS (como cotizadores/microservicios Buklo). **Prod → Azure/AKS** (CSI/Key Vault, fase aparte, aprobación separada).
- DB por ambiente: dev `172.16.2.30`, uat `172.16.2.34`, ambos `buklo_lab` (tomados del `microservice-auth-core-api-secret` del ns respectivo).

## RBAC (opción 1, least-privilege)

- ServiceAccount dedicada `worker-bdip` + `automountServiceAccountToken: false`, SIN Role/RoleBinding (el worker no llama a la API de K8s, coordina por SQL).
- Consecuencia importante: la SA dedicada **NO hereda** el `acr-pull-secret` que el deploy TG ata a la SA `default`. Hay que poner **`imagePullSecrets: [acr-pull-secret]` en el pod spec** (patrón Buklo nuevo: auth/engine/billing lo tienen así en el pod spec, la SA vacía). Sin eso → `ImagePullBackOff 401`.

---

## Causas raíz que costaron tiempo (y cómo se resolvieron)

### 1. El deploy por pipeline fallaba: `docker login` cortaba el task SSH

- **Síntoma:** stage `rejected`; el log del task SSH `apply deployment` cortaba
  tras `echo *** | docker login ... 2>/dev/null` sin imprimir `Login Succeeded`.
- **Causa raíz REAL:** `containerRegistryPassword` declarada **a nivel de STAGE**
  (`environments[N].variables`, Desarrollo+UAT) como `isSecret:true` y **vacía**.
  La variable de stage **pisa** la del Variable Group → `$(containerRegistryPassword)`
  se resolvía vacío → `docker login` unauthorized → `set -euo pipefail` aborta.
- **Delator:** en el log aparece `echo ***` (enmascarado) donde el pipeline hermano
  `Buklo-logistics-web` (Release 388, mismo deploy TG) lo muestra **en claro**.
  Comparar el log de apply del hermano exitoso vs el fallido fue el atajo al diagnóstico.
- **Fix:** `containerRegistryPassword` como **NO-secret literal** (valor real del ACR),
  en el VG **y** a nivel de stage Desarrollo/UAT (PUT directo de la def 435, rev3).
  Produccion intacto. → Release 8309 succeeded.

### Trampas de diagnóstico que me desviaron (documentadas para no repetir)

- **Caché de docker:** `docker login` a mano en el `.43` daba "Login Succeeded"
  aunque el password fuera inválido, por credencial cacheada en `~/.docker/config.json`.
  → SIEMPRE `docker logout <registry>` antes de una prueba de login real.
- **readyTimeout:** teoricé que el `readyTimeout=20000` del task SSH mataba el primer
  `docker pull`. Falso: el task corta a ~1.3s del login, no a los 20s. (El cambio a
  180000 quedó aplicado, inofensivo, pero NO era la causa.)
- **No era el agente ADO ni la service connection ni la red:** el `.43`, el ACR, el
  script y el password eran idénticos a logistics-web. La diferencia era 100% la
  variable de stage vacía. Un release hermano exitoso del usuario (8305) fue lo que
  destrabó la comparación.

### 2. Secret de VG no se puede verificar por readback

Un GET de VG nunca devuelve el valor de una variable `isSecret=true` (`value:null`);
no se distingue "secret bueno" de "secret vacío". El helper vg-update **preserva** el
`isSecret` existente aunque se pase valor plano. Para forzar secret→no-secret o fijar
el valor con certeza: **PUT explícito** del VG con `{value:..., isSecret:false}`.

---

## Método correcto para disparar el deploy (no activar el stage a mano)

La def 435 tiene trigger `artifactSource` + condición `ReleaseStarted` (igual que
logistics-web). La vía correcta es **encolar el Build y dejar que el trigger cree el
Release y despliegue solo** (reason `continuousIntegration`). Activar el stage por API
(reason `manual`) sobre un release viejo NO es el camino.

---

## Fixes/helpers agregados a la skill `manage-azure-devops-pipelines`

Todos aditivos, con tests de regresión verdes (suite `scripts/tests/run-script-tests.ps1`),
respaldos en `/home/cursor/stack-cursor/.local/respaldos/skill-ado-pipelines/`:

- **vg-update** (`New-AdoVariableGroupUpdatePlan.ps1` + Fase 1b en `Apply-AdoClassicPlan.ps1`):
  actualizar variables de un VG existente preservando las demás; soporta variable secreta
  vía `{secretEnvVar: ADO_SECRET_...}` → placeholder + isSecret + SecretReferences.
- **tg-update** con mutaciones declarativas (switch cerrado `Invoke-AdoTaskGroupMutation`):
  `ExposeInput`, `MapTaskInput` (setea cualquier input de task por DisplayName/TaskId —
  se usó para `arguments=--target worker` y para `readyTimeout`), `ReplaceInTaskCommands`
  (editar script de task por subcadena exacta).
- **tg-create** (`New-AdoTaskGroupCreatePlan.ps1`) + bypass de inventario en Apply
  (`$updateOnlyFamilies`).
- **Splice `Set-AdoReleaseEnvironmentDeployTaskGroup`**: repunta el deploy TG de un stage.
- **Fix approver Release** (emite `approver={id}` + `releaseCreatorCanBeApprover`).
- **Exención secret-scan** para `--password-stdin`/`$(macro)` en bodies de TG.
- **File Creator por ambiente** con manifiesto embebido (Secret base64 embebido, autorizado
  por Pablo asumiendo el riesgo de la regla de oro; NO patrón cotizadores yml viejo).

---

## Artefactos del pipeline (estado final)

- VG: **Desarrollo=521, UAT=522, Produccion=523** (`servicesname`=`image`=`worker-bdip`;
  `containerRegistryPassword` NO-secret literal en dev/uat).
- Build 697 rev8 (image=worker-bdip, File Creators con imagePullSecrets, TG build worker
  `--target worker`).
- Release 435 rev3 (Desarrollo+UAT → deploy TG STS `Deployment-MultiStage-STS-Worker`
  db8b2c06, `containerRegistryPassword` no-secret en stage; Produccion → `Deployment-Azur-Aks-v3`
  con CSI/Key Vault, aprobación manual).
- Deploy TG STS: clon de fc4043e2 con `rollout status statefulset/$(servicesname) --timeout=600s`
  (subido de 180s → 600s en rev posterior, ver sección "Rollout atascado" abajo).

---

## Rollout atascado: `OrderedReady` bloqueado por pod viejo NotReady (confirmado 2026-10-30, Release 8310→8312)

### Síntoma

Un deploy por pipeline con **imagen nueva** (build de hoy, tag distinto) quedaba el stage
`rejected`: el task SSH corría completo (login ✅, pull ✅, `kubectl apply` → STS `configured` ✅)
y fallaba SOLO en `rollout status ... --timeout=180s` → `timed out waiting for the condition`.
Los pods quedaban `0/2 Ready`, aún con imagen nueva.

### Causa raíz (NO es el timeout, NO es el pipeline)

Dos cosas combinadas:

1. **Código de app (reporte al dev, no se toca):** el worker devuelve `/health/worker` **HTTP 500**
   cuando su **sesión SQL caducó** (`BDIP_WORKER_SESSION_NOT_LIVE: heartbeat rejected`). Un pod que
   lleva horas vivo con la ventana de sesión vencida queda **Running pero NotReady** indefinidamente.
2. **Infra (esto SÍ se corrige):** el STS tenía **`podManagementPolicy: OrderedReady`** (default).
   Con OrderedReady el RollingUpdate recrea/arranca los pods **de a uno, esperando que cada uno quede
   Ready antes de tocar el siguiente**. Con el pod viejo (posición 0) atascado en NotReady, el update
   a la imagen nueva **NO progresa nunca** — por eso subir `--timeout` NO ayuda: no es que falte
   esperar, es que el rollout está **bloqueado**, no esperando.

> Trampa de diagnóstico: los pods seguían con `AGE 12h` e imagen vieja cuando el `apply` ya había
> cambiado la spec a la imagen nueva — porque el RollingUpdate aún no había recreado el pod-0
> (esperaba que el viejo quedara Ready, cosa que nunca pasó).

### Fix aplicado (eficiente, sin número mágico)

El worker **no tiene `volumeClaimTemplates` (sin PVCs)**, los 2 pods son **simétricos** y se registran
solos en SQL por `metadata.name` → no necesitan arranque ordenado ni identidad estable por ordinal.
Por eso:

1. **`podManagementPolicy: Parallel`** en el manifiesto (File Creators dev+uat del Build 697 rev10) —
   arranca/recrea los 2 pods **a la vez**, sin que uno quede rehén del otro. Es la forma correcta de
   "esperar lo que haya que esperar": espera el pull+boot **real** en paralelo, no en serie, y ningún
   pod viejo lo atasca.
2. **`rollout status --timeout=600s`** (TG deploy db8b2c06) — red de seguridad holgada para el pull
   de ~800MB de una imagen nueva (antes 180s, muy corto para la primera baja de un tag nuevo).

**`podManagementPolicy` es INMUTABLE** en un STS existente (`apply`/`patch` da `field is immutable`):
hay que **borrar el STS con `--cascade=orphan`** (deja los pods corriendo, no cae el servicio) y dejar
que el próximo deploy lo recree con la estrategia nueva.

### Evidencia del cierre

- Release **8312 / Desarrollo = `succeeded`** (CI automático), STS `podManagementPolicy=Parallel`,
  `2/2 Ready`, imagen `worker-bdipdev:26781`, ambos pods `/health/worker` 200 (sesiones 1070/1071).
- Operativo inmediato (mientras se armaba el fix): un pod caducado se recupera recreándolo
  (`kubectl delete pod ...`, el STS lo recrea y re-registra sesión) — no por pipeline.

## Pendiente

- **UAT:** desplegar por pipeline (host 172.16.2.34; VG 522 y stage UAT ya con el password corregido).
- **Prod:** fase aparte (AKS/CSI/Key Vault, aprobación separada, nunca automático). Verificar que
  el stage Produccion no tenga el mismo problema de password de stage antes de la fase prod.
