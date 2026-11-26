# Lecciones aprendidas — k8s-dashboard-hub

Documentado el 2026-09-24 durante la construcción del **k8s-dashboard-hub**.
Referencia completa: `apps/k8s-dashboard-hub/`.

---

## Problema central: embeber el K8s Dashboard en un iframe

El Kubernetes Dashboard usa sesión propia con cookies. Si el usuario no está logueado,
el dashboard redirige a su propia pantalla de login. Desde un iframe eso es invisible:
el iframe carga la pantalla de login sin que el usuario lo sepa y queda en blanco o
muestra un error de X-Frame-Options.

Las soluciones exploradas y su resultado:

| Enfoque | Resultado | Razón del descarte |
|---|---|---|
| oauth2-proxy del hub hace proxy al dashboard del cluster | ❌ No funciona | Las cookies de sesión del K8s Dashboard son para su propio dominio; el usuario no está autenticado en el dashboard interno |
| Redirigir al usuario al cluster en nueva pestaña | ⚠️ Funciona pero no embebido | El usuario necesita login en el cluster — no sirve para iframe |
| Proxy Node.js en el cluster que inyecta el token del SA readonly | ✅ Solución final | Bypassa la autenticación del dashboard por completo, el proxy la hace él mismo |

---

## Solución: microservicio proxy por cluster

### Componentes necesarios en CADA cluster

1. **`dashboard-injector`** (nginx) — ya existe en todos los clusters. Recibe HTTP, inyecta el Bearer token del ServiceAccount `dashboard-readonly-sa`, y lo manda al K8s Dashboard por HTTPS interno. Es el que realmente autentica contra el dashboard.

2. **`k8s-dashboard-proxy`** (Node.js, imagen en ACR) — nuevo. Expone dos paths:
   - `GET /teams-tab` — devuelve HTML con un iframe apuntando a `/k8s-proxy/`
   - `GET /k8s-proxy/*` — hace HTTP proxy a `dashboard-injector:80` con el Host header correcto

3. **Ingress del cluster** — dos paths nuevos:
   - `/teams-tab` → `k8s-dashboard-proxy:80`
   - `/k8s-proxy` → `k8s-dashboard-proxy:80`

4. **oauth2-proxy del cluster** — skip-auth-routes para que estos paths sean públicos:
   - `--skip-auth-route=GET=/teams-tab`
   - `--skip-auth-route=HEAD=/teams-tab`
   - `--skip-auth-route=^/k8s-proxy/`

### Por qué HTTP (no HTTPS) del proxy al injector

El injector escucha en HTTP puerto 80 dentro del cluster. TLS termina en el Ingress.
El proxy habla HTTP al injector en `dashboard-injector.<ns>.svc.cluster.local:80`.
Intentar HTTPS directo al dashboard (HTTPS 443 internamente) falló con EPERM en
Alpine Linux por restricciones del securityContext. El HTTP al injector elimina ese problema.

### Variables de entorno del proxy (`k8s-dashboard-proxy`)

```
PORT=8090
INJECTOR_HOST=dashboard-injector.<namespace>.svc.cluster.local
INJECTOR_PORT=80
DASHBOARD_HOST=<hostname-del-cluster>  # ej: cluster-onprem-01.grupomontecristo.com
```

El `DASHBOARD_HOST` se usa como header `Host` en la request al injector para que nginx
del injector sepa qué virtual host servir.

---

## Lección 1: el Host header es crítico

El `dashboard-injector` (nginx) tiene un `server_name` configurado con el hostname del
cluster. Si el request llega sin ese header o con el hostname del pod (ej.
`dashboard-injector.kubernetes-dashboard.svc.cluster.local`), nginx no matchea el
virtual host y devuelve 502.

**Siempre pasar** `Host: <cluster-hostname>` en el request del proxy al injector.

```javascript
http.request({
  hostname: process.env.INJECTOR_HOST,
  port: parseInt(process.env.INJECTOR_PORT || '80'),
  path: proxyPath,
  method: req.method,
  headers: {
    ...req.headers,
    'host': process.env.DASHBOARD_HOST,
    'x-forwarded-proto': 'https',
    'x-forwarded-host': process.env.DASHBOARD_HOST,
  }
})
```

---

## Lección 2: EPERM en Alpine Linux con TLS

La primera versión del proxy usó `node:22-alpine` y falló con `EPERM` al intentar
conectar por HTTPS al kubernetes-dashboard internamente.

**Causa**: Alpine Linux tiene un securityContext más restrictivo. Las conexiones TLS
salientes desde pods con `runAsNonRoot: true` pueden fallar con EPERM al intentar
acceder a los certificados del sistema.

**Fix**: usar `node:22` (Debian full) en el Dockerfile. La imagen es más grande pero
elimina todos los problemas de TLS.

```dockerfile
FROM node:22  # Debian full — no Alpine
```

---

## Lección 3: `upstream prematurely closed connection` al inicio

El injector muestra este error en los primeros segundos después de que el kubernetes-dashboard
se reinicia. Es normal: el dashboard tarda ~15-20s en arrancar y el nginx del injector intenta
conectar antes de que esté listo.

**No es un error del proxy.** Después de que el dashboard está up, las requests pasan sin problema.
En producción el kubernetes-dashboard raramente se reinicia, así que este error es transitorio.

---

## Lección 4: kubernetes-dashboard CrashLoop por permisos en /tmp (k3s-dev)

El pod del kubernetes-dashboard en k3s-dev crasheaba con:
```
log: cannot create log: open /tmp/dashboard.kubernetes-dashboard-*.nonroot.log.WARNING.*: permission denied
```

**Causa**: el pod corre con `runAsNonRoot: true` y el directorio `/tmp` en el contenedor
no tiene permisos de escritura para el usuario no-root.

**Fix**: montar un `emptyDir` en `/tmp` del pod. Un `emptyDir` siempre es escribible por cualquier usuario.

```bash
kubectl -n k8s-dashboard patch deployment kubernetes-dashboard --type=json -p='[
  {"op":"add","path":"/spec/template/spec/volumes","value":[{"name":"tmp-dir","emptyDir":{}}]},
  {"op":"add","path":"/spec/template/spec/containers/0/volumeMounts","value":[{"name":"tmp-dir","mountPath":"/tmp"}]}
]'
```

> ⚠️ Si el deployment ya tiene `volumes` o `volumeMounts`, usar `op: add` con la ruta
> específica del elemento (ej. `/spec/template/spec/volumes/-`) para agregar al array,
> no reemplazarlo.

---

## Lección 5: AKS 0001 requiere abrir la NSG antes de operar

El API server de `gmon-prod-aks-eastus2-0001` (`10.4.0.10:443`) está detrás de la
regla NSG `PRODAKS1_Rule` en Deny por defecto. Un timeout al conectar (`i/o timeout`)
es la NSG, no un problema de auth.

**Ciclo obligatorio**:
```bash
# 1. Abrir
az network nsg rule update --name PRODAKS1_Rule \
  --nsg-name gmon-hub-ComputeSubnet-nsg-eastus2-0001 \
  --resource-group gmon_hub_rg_eastus2_0001 --access Allow

# 2. Esperar ~25s y operar
sleep 25 && kubectl --context gmon-prod-aks-eastus2-0001 ...

# 3. Cerrar SIEMPRE
az network nsg rule update ... --access Deny
```

---

## Lección 6: ingress path order importa (Prefix pathType)

Al agregar los paths `/teams-tab` y `/k8s-proxy` al ingress del cluster, deben ir
**antes** del path raíz `/` (que suele ser el path catch-all del kubernetes-dashboard).

Con `pathType: Prefix`, nginx evalúa los paths en orden de especificidad. Si `/` va primero,
matchea todo y los paths específicos nunca se evalúan.

**Fix**: usar `op: add` con index `0` y `1` para insertar al inicio del array de paths:
```json
[
  {"op":"add","path":"/spec/rules/0/http/paths/0","value":{"path":"/teams-tab","pathType":"Prefix",...}},
  {"op":"add","path":"/spec/rules/0/http/paths/1","value":{"path":"/k8s-proxy","pathType":"Prefix",...}}
]
```

---

## Lección 7: skip-auth-route en oauth2-proxy — regex vs path exacto

En el oauth2-proxy del cluster (no del hub), las rutas públicas deben incluir:
- `--skip-auth-route=GET=/teams-tab` — path exacto para GET
- `--skip-auth-route=HEAD=/teams-tab` — **siempre incluir HEAD** (el iframe hace preflight)
- `--skip-auth-route=^/k8s-proxy/` — regex para el proxy y todos sus sub-paths

Sin el HEAD, el browser intenta cargar el iframe, el oauth2-proxy responde con redirect 302
al login del cluster, y el iframe queda en blanco.

---

## Arquitectura final resumida

```
browser/Teams iframe
  → k8s-hub.grupomontecristo.com  (hub Express + oauth2-proxy Azure AD)
    → GET /api/clusters  →  lista los 4 clusters
    → usuario hace clic en un cluster
    → hub pone iframe src="https://<cluster>/teams-tab"

  → https://<cluster>/teams-tab  (público, skip-auth en oauth2-proxy del cluster)
    → k8s-dashboard-proxy (Node.js) en namespace k8s-dashboard
      → sirve HTML: <iframe src="/k8s-proxy/"></iframe>

  → https://<cluster>/k8s-proxy/  (público, skip-auth en oauth2-proxy del cluster)
    → k8s-dashboard-proxy
      → HTTP proxy a dashboard-injector.<ns>.svc.cluster.local:80
        con Host: <cluster-hostname>
        con x-forwarded-proto: https
      → nginx del injector inyecta Authorization: Bearer <token SA readonly>
      → kubernetes-dashboard HTTPS 443 interno
      → responde HTML del dashboard
```

---

## Configuración por cluster

| Cluster | Contexto kubectl | Namespace | Host ingress | Injector svc |
|---|---|---|---|---|
| prod-onprem-01 | `prod-onprem-01` | `kubernetes-dashboard` | `cluster-onprem-01.grupomontecristo.com` | `dashboard-injector.kubernetes-dashboard.svc.cluster.local` |
| k3s-dev | `k3s-dev` | `k8s-dashboard` | `cluster-dev.gmontecristo.com` | `dashboard-injector.k8s-dashboard.svc.cluster.local` |
| AKS 0004 | `gmon-prod-aks-eastus2-0004` | `k8s-dashboard` | `cluster-services-prod.grupomontecristo.com` | `dashboard-injector.k8s-dashboard.svc.cluster.local` |
| AKS 0001 | `gmon-prod-aks-eastus2-0001` | `k8s-dashboard` | `cluster-sites-prod.grupomontecristo.com` | `dashboard-injector.k8s-dashboard.svc.cluster.local` |

---

## Imagen Docker del proxy

```
gmonhubacreastus20001.azurecr.io/k8s-dashboard-proxy:v2
```

Para actualizar el proxy en todos los clusters:
1. Build y push con nueva tag: `docker build -t ...proxy:v3 && docker push`
2. Actualizar el `image` en cada deployment:
   ```bash
   for CTX in prod-onprem-01 k3s-dev gmon-prod-aks-eastus2-0004 gmon-prod-aks-eastus2-0001; do
     NS=$([ "$CTX" = "prod-onprem-01" ] && echo "kubernetes-dashboard" || echo "k8s-dashboard")
     kubectl --context $CTX -n $NS set image deployment/k8s-dashboard-proxy \
       proxy=gmonhubacreastus20001.azurecr.io/k8s-dashboard-proxy:v3
   done
   ```

---

## Pendientes

- [ ] Subir `apps/k8s-dashboard-hub/k8s-hub-teams-app.zip` al Teams Admin Center y agregar como tab al canal Notificaciones-DevOps (mismo proceso que cicd-dashboard)

---

## Segunda sesión: Teams desktop — iframe negro y solución same-origin

Documentado el 2026-09-24 (continuación). Todo lo de abajo ocurrió **después** de que el hub funcionara correctamente en Chrome y en Teams móvil — pero en Teams desktop el iframe quedaba completamente negro.

---

### Síntoma: iframe negro solo en Teams desktop

- En Chrome normal: `https://cluster-xxx.grupomontecristo.com/k8s-proxy/` carga perfectamente ✅
- En Teams móvil (Android): carga correctamente ✅
- En Teams desktop (Windows): iframe completamente negro ❌

El header del hub sí aparecía (título del cluster seleccionado), lo que confirmaba que **el hub cargaba** y el usuario hacía clic en un cluster. El iframe del dashboard era el que quedaba negro.

---

### Diagnóstico progresivo

#### Hipótesis 1: Triple iframe anidado
La arquitectura original era:
```
Teams iframe → hub /teams-tab → cluster /teams-tab → cluster /k8s-proxy/
```
Eso son **3 niveles de iframe**. Teams desktop tiene restricciones sobre iframes anidados. Se cambió a 2 niveles apuntando `embedUrl` directamente a `/k8s-proxy/`:
```
Teams iframe → hub /teams-tab → cluster /k8s-proxy/
```
**Resultado**: el móvil seguía funcionando, Teams desktop seguía negro. No era solo el triple iframe.

#### Hipótesis 2: Caché de Teams desktop
Teams desktop cachea agresivamente el manifest de la app. Se bumpeó la versión de `1.0.0` a `1.0.1` en el manifest y se hizo Update en Teams Admin Center.

**Resultado**: Teams desktop recargó el app. Seguía negro. No era caché.

#### Hipótesis 3: CrashLoop del kubernetes-dashboard en los clusters AKS
AKS 0004 y AKS 0001 tenían el mismo bug que k3s-dev: `permission denied /tmp/dashboard.*.log`. El kubernetes-dashboard se reiniciaba constantemente.

**Fix aplicado en los 4 clusters**: montar `emptyDir` en `/tmp`.

**Resultado**: los clusters de AKS empezaron a funcionar. prod-onprem-01 seguía negro en Teams desktop.

#### Hipótesis 4 (correcta): Cross-origin storage restrictions en Teams desktop
Teams desktop (Chromium con políticas más estrictas) bloquea el acceso a `localStorage`/`sessionStorage` desde iframes **cross-origin**. El kubernetes-dashboard SPA Angular usa localStorage para guardar el token de sesión. Cuando el iframe carga `https://cluster-xxx.grupomontecristo.com/k8s-proxy/` desde dentro de `k8s-hub.grupomontecristo.com`, es un contexto cross-origin.

**Evidencia**: `cluster-dev.gmontecristo.com` y los clusters AKS funcionaron con el proxy same-origin. `cluster-onprem-01` seguía fallando porque el hub no podía resolver su DNS externo.

---

### Solución final: proxy same-origin en el hub

En lugar de que el iframe apunte directamente al dominio del cluster, el hub expone `/proxy/:clusterId/*` que hace el proxy internamente. El browser carga todo desde `k8s-hub.grupomontecristo.com` — mismo dominio, sin restricciones cross-origin.

```
Teams iframe → k8s-hub.grupomontecristo.com/teams-tab
  → iframe src="/proxy/aks-0004/"  (MISMO dominio del hub)
    → hub Node.js hace HTTPS proxy a cluster-services-prod.grupomontecristo.com/k8s-proxy
      → k8s-dashboard-proxy → dashboard-injector → kubernetes-dashboard
```

**Código en hub server.js:**
```javascript
app.use('/proxy/:clusterId', (req, res) => {
  const cluster = CLUSTERS.find(c => c.id === req.params.clusterId);
  const targetUrl = new URL(cluster.proxyTarget);
  const isHttps = targetUrl.protocol === 'https:';
  const transport = isHttps ? https : http;
  
  const opts = {
    hostname: targetUrl.hostname,
    port: targetUrl.port || (isHttps ? 443 : 80),
    path: targetUrl.pathname + (req.url || '/'),
    method: req.method,
    headers: {
      ...req.headers,
      'host': targetUrl.hostname,
      'x-forwarded-proto': 'https',
    },
    rejectUnauthorized: false,
  };
  
  const proxy = transport.request(opts, (proxyRes) => {
    const headers = { ...proxyRes.headers };
    delete headers['x-frame-options'];
    delete headers['content-security-policy'];
    res.writeHead(proxyRes.statusCode, headers);
    proxyRes.pipe(res);
  });
  // ...
});
```

**oauth2-proxy del hub** necesita `--skip-auth-route=^/proxy/` para que sea público.

---

### Lección 8: prod-onprem-01 usa service interno (DNS externo no resuelve desde el pod)

El hub corre en el mismo cluster que prod-onprem-01. El pod del hub **no puede resolver** `cluster-onprem-01.grupomontecristo.com` (DNS externo/Cloudflare no está disponible dentro del cluster). Para prod-onprem-01, el `proxyTarget` debe apuntar al service interno:

```javascript
proxyTarget: 'http://k8s-dashboard-proxy.kubernetes-dashboard.svc.cluster.local:80/k8s-proxy',
healthUrl: null,  // usar proxyTarget para health check
```

Para los clusters AKS (remotos), se usa HTTPS externo:
```javascript
proxyTarget: 'https://cluster-services-prod.grupomontecristo.com/k8s-proxy',
```

---

### Lección 9: oauth2-proxy — operar sobre el deployment correcto

En `tools-devops` hay **dos** oauth2-proxy:
- `oauth2-proxy` — del cicd-dashboard
- `oauth2-proxy-k8s-hub` — del k8s-dashboard-hub

Siempre parchear `oauth2-proxy-k8s-hub` para cambios del hub. Parchear `oauth2-proxy` afecta el cicd-dashboard.

```bash
kubectl -n tools-devops get deployments | grep oauth2
# cicd-dashboard usa: oauth2-proxy
# k8s-dashboard-hub usa: oauth2-proxy-k8s-hub
```

---

### Lección 10: Teams Admin Center — "Built for your org" vs upload manual

- **Upload manual** (desde Teams desktop → Apps → Upload an app): instala solo para el usuario que lo sube. No aparece en "Built for your org". No permite agregar como tab de canal desde la tienda org.
- **Upload desde Admin Center** (admin.teams.microsoft.com → Manage apps → Upload): publica para toda la organización. Aparece en "Built for your org" y permite instalar como tab de canal.

El K8s Dashboards app estuvo en upload manual durante el desarrollo — no aparecía en "Built for your org". Una vez subido al Admin Center apareció en la tienda y pudo agregarse como tab al canal Notificaciones-DevOps.

---

### Arquitectura final completa

```
Teams desktop/móvil
  → k8s-hub.grupomontecristo.com/teams-tab  (autenticado Azure AD via oauth2-proxy-k8s-hub)
    → SPA: grid de 4 clusters con status indicators

  Usuario hace clic en un cluster:
    → iframe src="/proxy/<clusterId>/"  (MISMO dominio del hub)
      → hub Node.js /proxy/:clusterId/* (skip-auth-route=^/proxy/)
        ↓ (dependiendo del cluster)
        
        prod-onprem-01:
          → http://k8s-dashboard-proxy.kubernetes-dashboard.svc.cluster.local:80/k8s-proxy/*
            → dashboard-injector (inyecta Bearer token SA readonly)
            → kubernetes-dashboard:443 interno
        
        k3s-dev:
          → https://cluster-dev.gmontecristo.com/k8s-proxy/*
            → (igual: proxy → injector → dashboard)
        
        AKS 0004:
          → https://cluster-services-prod.grupomontecristo.com/k8s-proxy/*
        
        AKS 0001:
          → https://cluster-sites-prod.grupomontecristo.com/k8s-proxy/*
```

---

### Estado final de los clusters

| Cluster | Contexto kubectl | Namespace | proxyTarget | Status indicator |
|---|---|---|---|---|
| prod-onprem-01 | `prod-onprem-01` | `kubernetes-dashboard` | service interno HTTP | ✅ Accesible |
| k3s-dev | `k3s-dev` | `k8s-dashboard` | `https://cluster-dev.gmontecristo.com/k8s-proxy` | ✅ Accesible |
| AKS 0004 | `gmon-prod-aks-eastus2-0004` | `k8s-dashboard` | `https://cluster-services-prod.grupomontecristo.com/k8s-proxy` | ✅ Accesible |
| AKS 0001 | `gmon-prod-aks-eastus2-0001` | `k8s-dashboard` | `https://cluster-sites-prod.grupomontecristo.com/k8s-proxy` | ✅ Accesible |

### Archivos clave del hub (estado final)

```
apps/k8s-dashboard-hub/
├── src/
│   ├── server.js           # Hub Express: /proxy/:clusterId/*, /api/clusters, /teams-tab
│   └── public/index.html   # SPA: grid de clusters, iframe embed, back button
├── proxy/
│   ├── server.js           # Proxy por cluster: /healthz, /k8s-proxy/* (en cada cluster)
│   └── Dockerfile          # node:22 Debian (no Alpine — EPERM con TLS en Alpine)
├── k8s/
│   └── deployment-prod.yml # Manifest K8s del hub en tools-devops
└── k8s-hub-teams-app.zip   # Teams App manifest v1.0.1 (publicado en Built for your org)
```

### Comandos para actualizar el proxy en todos los clusters

```bash
# Si se actualiza proxy/server.js:
# 1. Build y push nueva imagen
cd apps/k8s-dashboard-hub/proxy
docker build -t gmonhubacreastus20001.azurecr.io/k8s-dashboard-proxy:v3 .
docker push gmonhubacreastus20001.azurecr.io/k8s-dashboard-proxy:v3

# 2. Actualizar en los 4 clusters
for CTX_NS in "prod-onprem-01:kubernetes-dashboard" "k3s-dev:k8s-dashboard" \
              "gmon-prod-aks-eastus2-0004:k8s-dashboard" "gmon-prod-aks-eastus2-0001:k8s-dashboard"; do
  CTX=${CTX_NS%:*}; NS=${CTX_NS#*:}
  # AKS 0001 requiere abrir NSG primero
  kubectl --context $CTX -n $NS set image deployment/k8s-dashboard-proxy \
    proxy=gmonhubacreastus20001.azurecr.io/k8s-dashboard-proxy:v3
done

# Si se actualiza hub/src/server.js (sin esperar build/release):
kubectl --context prod-onprem-01 -n tools-devops create configmap k8s-hub-server \
  --from-file=server.js=apps/k8s-dashboard-hub/src/server.js \
  --dry-run=client -o yaml | kubectl --context prod-onprem-01 apply -f -
kubectl --context prod-onprem-01 -n tools-devops rollout restart deployment/k8s-dashboard-hub
```

---

## Tercera sesión: Incidentes post-deploy (2026-09-24 tarde)

---

### Lección 11: NUNCA usar `latest` en producción — oauth2-proxy v7.15.4 breaking change

La imagen `quay.io/oauth2-proxy/oauth2-proxy:latest` se actualizó a `v7.15.4` cuando se reinició el pod. En esta versión el default de `--http-address` cambió de `0.0.0.0:4180` a `127.0.0.1:4180`. El pod arrancaba, logueaba sus mensajes de inicio normalmente, y luego escuchaba solo en loopback — invisible para el cluster. Kubernetes lo marcaba como `Ready: True` (no tenía liveness probe). El resultado: 502 en producción sin ninguna señal de error evidente.

**Fix universal para todos los oauth2-proxy del stack:**
```yaml
args:
  - --http-address=0.0.0.0:4180   # SIEMPRE explícito — nunca confiar en el default
```

**Diagnóstico**: si el pod está `Running/Ready` pero conexiones externas dan ECONNREFUSED, verificar que el proceso escucha en `0.0.0.0` y no en `127.0.0.1`.

**Prevención permanente**: pinear la imagen a una versión específica en lugar de `latest`:
```yaml
image: quay.io/oauth2-proxy/oauth2-proxy:v7.15.4   # pinear versión exacta
```

---

### Lección 12: oauth2-proxy SameSite=Lax rompe el callback de OAuth en iframes

El flujo OAuth tiene un redirect cross-site: `Azure AD → hub`. Ese redirect llega como POST cross-origin. Con `SameSite=Lax` (default), el browser bloquea la cookie del CSRF token en ese POST → oauth2-proxy no puede validar el callback → 403 "Unable to find a valid CSRF token".

**Config correcta para apps embebidas en Teams (iframes):**
```
--cookie-samesite=none      # permite cookies en contexto cross-origin
--cookie-secure=true        # requerido cuando samesite=none
```

El botón "Sign in" no hacía nada porque el ciclo se repetía sin fin: Azure AD autenticaba → callback fallaba por CSRF → redirigía a Sign in → loop.

---

### Lección 13: Prefijo `__Host-` en cookie name incompatible con SameSite=None en algunos browsers

El prefijo `__Host-` requiere que la cookie no tenga un `Domain` attribute y solo funcione en HTTPS. En combinación con `SameSite=None`, algunos browsers (Teams desktop Chromium) lo rechazan silenciosamente.

**Fix**: quitar el prefijo `__Host-`:
```
--cookie-name=oauth2_proxy_k8s_hub    # sin __Host-
```

Cambiar el nombre de la cookie invalida TODAS las sesiones activas en Redis. Después del cambio hacer `redis-cli -n <db> FLUSHDB` para limpiar sesiones rotas que causan estado inconsistente.

---

### Lección 14: `--skip-auth-route=^/proxy/` se pierde en patches sucesivos

Cuando se hacen múltiples `kubectl patch deployment --type=json` con `op:add` al array de args, y alguno de esos patches falla o se hace sobre un índice incorrecto, el estado del deployment puede quedar con args faltantes sin ninguna advertencia visible.

**Síntoma**: después de fixes, el `/proxy/` volvió a requerir autenticación → iframe negro.

**Prevención**: después de múltiples patches a un deployment, siempre verificar el estado final completo:
```bash
kubectl -n tools-devops get deployment oauth2-proxy-k8s-hub \
  -o jsonpath='{.spec.template.spec.containers[0].args}' | python3 -m json.tool
```

**Lista completa de skip-auth-routes del hub (estado correcto):**
```
--skip-auth-route=GET=/teams-config
--skip-auth-route=HEAD=/teams-config
--skip-auth-route=GET=/teams-tab
--skip-auth-route=HEAD=/teams-tab
--skip-auth-route=^/api/
--skip-auth-route=POST=^/api/
--skip-auth-route=^/proxy/          ← CRÍTICO — sin esto el dashboard es negro en Teams
```

---

### Lección 15: `--oidc-email-claim=upn` — tokens Azure sin claim `email`

En algunos tenants de Azure AD los tokens OIDC no incluyen el claim `email` — solo incluyen `upn` (User Principal Name). oauth2-proxy v7.x por default busca el claim `email` para validar el `--email-domain`. Si no lo encuentra, devuelve 403.

**Fix**:
```
--oidc-email-claim=upn    # usar UPN como fuente del email
```

Aplicar a TODOS los oauth2-proxy del stack para prevenir el problema.

---

### Config final completa del oauth2-proxy-k8s-hub (estado producción 2026-09-24)

```yaml
args:
  - --provider=azure
  - --azure-tenant=33dd4184-3068-47da-891d-a70e02f8c0c9
  - --client-id=45f7a5e0-ac18-4417-9949-934af65a25d2
  - --client-secret-file=/etc/oauth2-proxy/client-secret
  - --cookie-secret-file=/etc/oauth2-proxy/cookie-secret
  - --redirect-url=https://k8s-hub.grupomontecristo.com/oauth2/callback
  - --upstream=http://k8s-dashboard-hub.tools-devops.svc.cluster.local:8080
  - --http-address=0.0.0.0:4180          # EXPLÍCITO — v7.x+ default es 127.0.0.1
  - --reverse-proxy=true
  - --cookie-name=oauth2_proxy_k8s_hub   # sin __Host- prefix
  - --cookie-path=/
  - --cookie-secure=true
  - --cookie-samesite=none               # NECESARIO para OAuth callback en iframe
  - --cookie-expire=5h
  - --email-domain=grupomontecristo.com
  - --skip-provider-button=true
  - --oidc-issuer-url=https://login.microsoftonline.com/33dd4184-3068-47da-891d-a70e02f8c0c9/v2.0
  - --whitelist-domain=.grupomontecristo.com
  - --upstream-timeout=30s
  - --session-store-type=redis
  - --redis-connection-url=redis://oauth2-redis.kubernetes-dashboard.svc.cluster.local:6379/2
  - --pass-user-headers=true
  - --set-xauthrequest=true
  - --skip-auth-route=GET=/teams-config
  - --skip-auth-route=HEAD=/teams-config
  - --skip-auth-route=GET=/teams-tab
  - --skip-auth-route=HEAD=/teams-tab
  - --skip-auth-route=^/api/
  - --skip-auth-route=POST=^/api/
  - --skip-auth-route=^/proxy/           # CRÍTICO — dashboard público en iframe
  - --oidc-email-claim=upn               # tokens Azure sin claim email
```
