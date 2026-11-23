# Notas — modelo canónico `web` (Build-modelo-web.json / Release-modelo-web.json)

## Origen

Export real, agregado por el usuario el 2026-09-08: Build 579
(`Build-Buklo-shell-web`) y Release 361
(`Deploy-Desarrollo-UAT-Produccion-Buklo-shell-web`), app `shell` dentro
de `buklo-web` — el shell/portal que hostea el resto de micro-frontends
(module federation Angular), no una app de negocio simple como
`app-directory`/`app-sso`.

Ambos archivos fueron saneados antes de commitear: contenían el password
real de ACR en texto plano (`containerRegistryPassword`, los 3
ambientes) y 3 secretos reales de la app `shell`
(`NG_APP_HEADERS_API_KEY`, `NG_APP_BASE_SECRET_KEY`,
`NG_APP_BASE_IV_ENCRYPT`) — reemplazados por placeholders. El valor real
solo vive en el Build 579 en vivo.

De paso se encontró y saneó el mismo password de ACR ya commiteado (sin
placeholder) en 3 archivos preexistentes de este repo:
`docs/azure-devops/Release-modelo-backend.json`,
`docs/azure-devops/Buklo-frontend-portal-Build.json`,
`docs/azure-devops/Desarrollo-UAT-Produccion-Buklo-frontend-portal.json`,
más sus duplicados en `env/`. Estos 2 últimos además tenían: un client
secret real de MSAL, un password real de Elasticsearch, 2 keys reales de
Azure (Speech, OpenAI) y 2 keys reales de Firebase (API key, VAPID) — ya
redactados.

## Qué coincide con el patrón ya automatizado (sin ajuste)

- Build: mecanismo de batching (`Batch_Gate` → `Batch_Window` → `Job_1`
  con `Gana-el-mas-nuevo`, `Replace tokens`, 3 File Creator dev/uat/prod,
  Task group `Build`, `Reportar-resultado-HU`) — igual al que ya genera
  `New-AdoClassicPayloads.ps1`.
- Release: 3 stages con VG propio por ambiente, Task group
  `Deployment-MultiStage-Cluster-Desarrollo` en Desarrollo/UAT,
  `Deployment-Azur-Aks-v3` en Producción, aprobación de Producción vía el
  grupo `Release Executers` — igual al patrón ya usado para
  `app-directory`/`app-sso`.

## Decisiones tomadas 2026-09-08 sobre las diferencias encontradas

Shell tiene 4 diferencias reales frente al patrón ya automatizado. Se
revisaron una por una con el usuario — estas son las decisiones, para que
ninguna sesión futura copie ciegamente el archivo de shell sin este
contexto:

1. **Ingress host/TLS**: el comentario de cada `deployment-*.yml` de
   shell declara tokens `host`/`tlsecret`/`gatewayhost`/`gatewayhostip`,
   pero el Ingress real nunca los usa — hardcodea el FQDN
   (`shell-web-dev.gmontecristo.com`) y el `secretName`
   (`gmontecristo-secret`) directo. **Decisión: mantener el patrón
   tokenizado que ya usa el generador** (más reusable) — no adoptar el
   hardcodeo de shell.
2. **Dominio de Producción**: shell usa `ingressClassName: internal-ingress`
   + dominio `buklo.dev` (Grupo B). **Decisión: shell es caso especial
   (portal interno) — el modelo web sigue con el default ya decidido
   (Grupo A: `grupomontecristo.com`, sin proxy, `ingressClassName:
   nginx`)**, salvo que una app puntual pida Grupo B explícitamente (ver
   `pipeline-cycle-production-dns-convention` en memoria).
3. **HPA**: shell define `minReplicas:1 maxReplicas:1` con `replicas:2`
   fijo — el autoscaling nunca puede escalar en la práctica. **Decisión:
   dejarlo igual que shell** al usar este archivo como referencia — no es
   un valor a "corregir" al copiar el patrón, es específico de esta app.
4. **Tasks NSG en Producción**: shell trae 2 tasks deshabilitadas
   (`PROD AKS NSG TEMP ALLOW` / `DENY`) alrededor del deploy AKS, que no
   están en el patrón ya usado para `app-directory`/`app-sso`. **Decisión:
   omitirlas del modelo estándar** — no se replican para apps nuevas.

## Estado del export sanitizado de la familia `web`

Antes de este export, `input-contract.md` § "Modelo canónico sin export
sanitizado todavía" documentaba que `web` no tenía export sanitizado
propio (`app-directory`/`app-sso` se construyeron con
`canonical_model_live_reference` apuntando a Build 633/634 en vivo, nunca
con `Build-modelo-backend.json`, que es de otra familia). Con este export
agregado, **una app nueva de tipo `web` puede usar
`build_export_candidates: [Build-modelo-web.json]` /
`release_export: Release-modelo-web.json` directamente**, sin depender de
una consulta en vivo — con las 4 salvedades de arriba en mente al adaptar
el contenido a la app real.
