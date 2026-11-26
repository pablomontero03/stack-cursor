# Guía: Integrar un webapp Node.js+oauth2-proxy como tab de Teams

Documentado el 2026-09-22 durante la construcción del **cicd-dashboard**.
Referencia completa: `apps/cicd-dashboard/`.

---

## Prerrequisitos

- Webapp Node.js/Express ya desplegado con oauth2-proxy como proxy de autenticación
- App Registration de Azure AD con `client-id` y tenant conocidos
- Dominio público con HTTPS (ej. `cicd-dashboard.grupomontecristo.com`)

---

## 1. Azure AD — Expose an API

En `portal.azure.com` → App Registrations → tu app → **Expose an API**:

1. **Application ID URI**: `api://<dominio>/<client-id>`  
   Ej: `api://cicd-dashboard.grupomontecristo.com/45f7a5e0-...`

2. **Add a scope**: `access_as_user`  
   - Who can consent: `Admins and users`
   - Admin display name: `Access <app> as user`

3. **Authorized client applications** (agrega los dos):
   - `1fec8e78-bce4-4aaf-ab1b-5451cc387264` → Teams desktop/mobile
   - `5e3ce6c0-2b1f-4285-8d4b-75ee78787346` → Teams web

---

## 2. oauth2-proxy — skip-auth-routes

Agrega a los args del deployment de oauth2-proxy:

```yaml
- --skip-auth-route=GET=/teams-config
- --skip-auth-route=HEAD=/teams-config
- --skip-auth-route=GET=/teams-tab
- --skip-auth-route=HEAD=/teams-tab
- --skip-auth-route=^/api/          # regex: aplica a /api/runs, /api/approvals, etc.
- --skip-auth-route=POST=^/api/
```

> ⚠️ Usar `^/api/` (con regex) — `GET=/api/` solo aplica al path exacto, no a subrutas.  
> ⚠️ Incluir siempre HEAD además de GET — Teams hace preflight HEAD antes de cargar el iframe.

---

## 3. Teams App Manifest

```json
{
  "$schema": "https://developer.microsoft.com/en-us/json-schemas/teams/v1.17/MicrosoftTeams.schema.json",
  "manifestVersion": "1.17",
  "version": "1.0.0",
  "id": "<UUID-único>",
  "packageName": "com.grupomontecristo.<appname>",
  "developer": {
    "name": "Grupo Montecristo DevOps",
    "websiteUrl": "https://<dominio>",
    "privacyUrl": "https://<dominio>",
    "termsOfUseUrl": "https://<dominio>"
  },
  "name": { "short": "<Nombre App>", "full": "<Nombre completo>" },
  "description": { "short": "...", "full": "..." },
  "icons": { "color": "color.png", "outline": "outline.png" },
  "accentColor": "#0078D4",
  "configurableTabs": [{
    "configurationUrl": "https://<dominio>/teams-config",
    "canUpdateConfiguration": false,
    "scopes": ["team", "groupChat"],
    "context": ["channelTab", "privateChatTab"]
  }],
  "staticTabs": [{
    "entityId": "<app-id>",
    "name": "<Nombre>",
    "contentUrl": "https://<dominio>/teams-tab",
    "websiteUrl": "https://<dominio>",
    "scopes": ["personal"]
  }],
  "permissions": ["identity", "messageTeamMembers"],
  "validDomains": ["<dominio>"]
}
```

> ✅ **NO** agregar `webApplicationInfo` — no es necesario y puede causar problemas.  
> ✅ `color.png`: 192x192px. `outline.png`: 32x32px fondo **transparente** (Teams lo exige).

---

## 4. Endpoint /teams-config (Express)

```javascript
// Usa teams-js@2.0.0 de jsdelivr (NO la versión de office.net CDN)
// setValidityState(true) SOLO tras interacción del usuario — NO al initialize()
app.get('/teams-config', (_req, res) => {
  res.send(`<!DOCTYPE html>
<html><head>
  <script src="https://cdn.jsdelivr.net/npm/@microsoft/teams-js@2.0.0/dist/MicrosoftTeams.min.js"></script>
</head><body>
<div onclick="select()">Mi App — clic para seleccionar</div>
<script>
  (async function() {
    await microsoftTeams.app.initialize();
    microsoftTeams.pages.config.registerOnSaveHandler(function(saveEvent) {
      microsoftTeams.pages.config.setConfig({
        contentUrl: 'https://<dominio>/teams-tab',
        entityId: '<app-id>',
        suggestedDisplayName: '<Nombre>',
        websiteUrl: 'https://<dominio>'
      });
      saveEvent.notifySuccess();
    });
  })();
  function select() {
    microsoftTeams.pages.config.setValidityState(true); // Solo tras clic
  }
</script>
</body></html>`);
});
```

---

## 5. Endpoint /teams-tab (Express)

```javascript
// Sirve el HTML de la app con el Teams SDK inyectado antes de </head>
app.get('/teams-tab', (_req, res) => {
  const fs = require('fs');
  let html = fs.readFileSync(path.join(__dirname, 'public', 'index.html'), 'utf8');
  
  const teamsBootstrap = `
  <script src="https://cdn.jsdelivr.net/npm/@microsoft/teams-js@2.0.0/dist/MicrosoftTeams.min.js"></script>
  <script>
    window.__TEAMS_MODE = true;
    microsoftTeams.app.initialize().then(function() {
      microsoftTeams.authentication.getAuthToken({
        successCallback: function(token) { window.__TEAMS_TOKEN = token; },
        failureCallback: function(err) { console.warn('Teams SSO failed:', err); }
      });
    }).catch(function(){});
  </script>`;
  
  html = html.replace('</head>', teamsBootstrap + '</head>');
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.send(html);
});
```

---

## 6. Backend — middleware para token de Teams

```javascript
// Antes de todas las rutas /api/*
// Extrae el email del JWT de Teams e inyecta como x-forwarded-email
// (mismo header que usa oauth2-proxy — todos los handlers funcionan sin cambios)
app.use('/api', (req, _res, next) => {
  const token = req.headers['x-teams-token'];
  if (token && !req.headers['x-forwarded-email']) {
    try {
      const payload = JSON.parse(
        Buffer.from(token.split('.')[1], 'base64').toString()
      );
      const email = (payload.preferred_username || payload.upn || payload.email || '')
        .toLowerCase().trim();
      if (email) req.headers['x-forwarded-email'] = email;
    } catch (_) {}
  }
  next();
});
```

---

## 7. Frontend — apiFetch helper

```javascript
// Reemplaza fetch() para todas las llamadas a /api/*
// Agrega x-teams-token cuando está en modo Teams
function apiFetch(url, opts) {
  opts = opts || {};
  var token = window.__TEAMS_TOKEN;
  if (token) {
    opts.headers = opts.headers || {};
    opts.headers['x-teams-token'] = token;
  }
  return fetch(url, opts);
}

// Al startup, delay el primer load() cuando está en Teams
// para darle tiempo a getAuthToken() de resolver
if (window.__TEAMS_MODE) {
  setTimeout(function() { load(); loadApprovals(); }, 800);
} else {
  load();
  loadApprovals();
}
```

---

## 8. Instalar la app en Teams

1. Empaqueta `manifest.json` + `color.png` + `outline.png` en un ZIP
2. En `admin.teams.microsoft.com` → Teams apps → Manage apps → **Upload** → selecciona el ZIP
3. Una vez subida, en el canal → `+` → busca tu app → selecciona → clic en la opción → **Save**

> 🔄 Para actualizar: incrementar `version` en `manifest.json` y hacer **Update** en el Admin Center.  
> ⚠️ Teams desktop cachea agresivamente — después de actualizar puede requerir `Reload tab`.

---

## Troubleshooting

| Síntoma | Causa | Fix |
|---------|-------|-----|
| Iframe en blanco al instalar | `setValidityState(true)` automático, Teams no ejecuta el JS | Llamarlo solo tras interacción del usuario |
| "There was a problem" al primer load | `getAuthToken()` no resolvió antes del primer fetch | Delay 800ms en modo Teams |
| "There was a problem" en todos los loads | HEAD request no está en skip-auth-routes | Agregar `--skip-auth-route=HEAD=/teams-tab` |
| `/api/runs` devuelve 302 | `--skip-auth-route=GET=/api/` no aplica a subrutas | Usar regex `^/api/` |
| Save button siempre gris | `configurationUrl` devuelve 302 (oauth2-proxy bloquea) | Agregar `--skip-auth-route=GET=/teams-config` |
| Versión vieja en Teams desktop | Caché del cliente | `%appdata%\Local\Packages\MSTeams_*\LocalCache\...\EBWebView` → borrar |

---

## Patrón avanzado: hub que embebe apps con autenticación propia

Documentado el 2026-09-24 durante la construcción del **k8s-dashboard-hub**.
Referencia completa: `apps/k8s-dashboard-hub/` y `docs/K8S-DASHBOARD-HUB-LECCIONES-APRENDIDAS.md`.

### El problema

Cuando la app que quieres embeber en un iframe tiene su **propia autenticación**
(cookies de sesión propias, login screen, oauth2-proxy con redirect), simplemente
poner la URL en el iframe no funciona: el iframe carga la pantalla de login, no la app.

Esto aplica al **Kubernetes Dashboard** y a cualquier app similar.

### La solución: proxy intermedio en el servidor de la app

En lugar de que el browser cargue la app directamente, un microservicio Node.js
(**`k8s-dashboard-proxy`**) actúa como intermediario:

1. El iframe apunta a `https://<cluster>/k8s-proxy/` — path público (skip-auth)
2. El proxy recibe la request del browser
3. El proxy hace HTTP al `dashboard-injector` interno con el Host header correcto
4. El injector inyecta el Bearer token del ServiceAccount readonly
5. La respuesta llega al browser como si viniera directamente del dashboard

El browser nunca interactúa con la app directamente. El proxy la "representa".

### Requisitos del proxy

- Configurar `skip-auth-route` en el oauth2-proxy **del cluster de la app** (no del hub)
- Añadir path `/k8s-proxy` al Ingress del cluster → `k8s-dashboard-proxy:80`
- El proxy debe pasar el `Host` header correcto al backend interno
- Usar imagen base Debian (no Alpine) para evitar problemas de TLS: `node:22`

### Hub server.js: embedUrl vs url

```javascript
const CLUSTERS = [
  {
    name: 'Producción On-Prem',
    url: 'https://cluster-onprem-01.grupomontecristo.com',      // acceso directo (login propio)
    embedUrl: 'https://cluster-onprem-01.grupomontecristo.com/teams-tab',  // embed vía proxy
  },
  // ...
];
```

El frontend usa `embedUrl` si existe (iframe embed vía proxy). Si no existe, abre en nueva pestaña.

### Troubleshooting específico del proxy embebido

| Síntoma | Causa | Fix |
|---------|-------|-----|
| iframe en blanco, injector log: `connect() failed (111)` | kubernetes-dashboard aún arrancando | Esperar ~20s, el dashboard hace cold-start |
| `upstream prematurely closed connection` en injector | dashboard reiniciándose | Transitorio, esperar |
| Proxy devuelve 502 siempre | Host header incorrecto — nginx no matchea el vhost | Verificar `DASHBOARD_HOST` == hostname exacto del ingress |
| EPERM al conectar TLS desde proxy pod | Alpine Linux + securityContext restrictivo | Cambiar a `node:22` (Debian) |
| `/k8s-proxy/` da 404 | Ingress path no agregado o path order incorrecto | Agregar paths `/teams-tab` y `/k8s-proxy` ANTES del `/` catch-all |
| HTTP 000 desde curl externo a AKS | Ingress usa `internal-ingress` — IP privada | Normal para AKS con ingress interno; el hub accede vía Cloudflare/VPN |

---

## Patrón: hub proxy same-origin para resolver restricciones de Teams desktop

Documentado el 2026-09-24 durante el fix del iframe negro en Teams desktop (k8s-dashboard-hub).

### El problema de cross-origin en Teams desktop

Teams desktop usa Chromium con políticas más estrictas que Chrome normal. Cuando un iframe carga contenido de **otro dominio** (cross-origin), Teams desktop bloquea:
- Acceso a `localStorage` / `sessionStorage`
- Cookies sin `SameSite=None; Secure`
- Service Workers cross-origin

Esto hace que SPAs (como el Kubernetes Dashboard Angular) queden en **negro** — el JS carga pero falla silenciosamente al intentar acceder al storage.

**Teams móvil no tiene esta restricción** — funciona con cross-origin. Por eso el mismo iframe que falla en desktop funciona en móvil.

### La solución: proxy same-origin en el hub

En lugar de que el iframe apunte al dominio del cluster, el **hub mismo** hace el proxy:

```javascript
// En hub/src/server.js
app.use('/proxy/:clusterId', (req, res) => {
  const cluster = CLUSTERS.find(c => c.id === req.params.clusterId);
  // proxyTarget puede ser HTTPS externo o HTTP interno (service k8s)
  const targetUrl = new URL(cluster.proxyTarget);
  const transport = targetUrl.protocol === 'https:' ? https : http;
  
  const opts = {
    hostname: targetUrl.hostname,
    port: targetUrl.port || (targetUrl.protocol === 'https:' ? 443 : 80),
    path: targetUrl.pathname + (req.url || '/'),
    method: req.method,
    headers: { ...req.headers, 'host': targetUrl.hostname },
    rejectUnauthorized: false,
  };
  delete opts.headers['x-frame-options'];    // remover para que el browser no bloquee
  delete opts.headers['content-security-policy'];
  
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

El CLUSTERS config usa rutas relativas como `embedUrl`:
```javascript
{
  id: 'aks-0004',
  embedUrl: '/proxy/aks-0004/',             // MISMO dominio del hub
  proxyTarget: 'https://cluster-services-prod.grupomontecristo.com/k8s-proxy',
}
```

El oauth2-proxy del hub necesita `--skip-auth-route=^/proxy/` para que el iframe sea público.

### Hub en el mismo cluster que un backend

Cuando el hub corre en el **mismo cluster** que uno de sus backends (ej. prod-onprem-01), el pod no puede resolver el DNS externo del cluster desde dentro. Usar el service name interno:

```javascript
{
  id: 'prod-onprem-01',
  embedUrl: '/proxy/prod-onprem-01/',
  // Service interno — el hub está en el mismo cluster
  proxyTarget: 'http://k8s-dashboard-proxy.kubernetes-dashboard.svc.cluster.local:80/k8s-proxy',
  // healthUrl: null → usa proxyTarget para el health check
  healthUrl: null,
}
```

### Teams Admin Center: Built for your org vs upload manual

| Método | Dónde aparece | Permite tab de canal |
|---|---|---|
| Teams desktop → Apps → Upload an app | Solo en "Manage your apps" del usuario | No (solo personal) |
| Admin Center → Manage apps → Upload | "Built for your org" para toda la org | Sí |

Siempre subir al Admin Center para que la app sea instalable como tab de canal.

### Troubleshooting: Teams desktop iframe negro

| Síntoma | Causa probable | Fix |
|---|---|---|
| Negro solo en desktop, móvil funciona | Cross-origin storage restriction | Proxy same-origin en el hub |
| Negro en todos, Chrome normal también | kubernetes-dashboard en CrashLoop | `emptyDir` en `/tmp` del pod |
| Negro intermitente | kubernetes-dashboard reiniciándose | El injector da 502 ~20s tras reinicio |
| Versión vieja después de update | Caché agresivo Teams desktop | Bump `version` en manifest.json y Update en Admin Center |
| App no aparece en "Built for your org" | Subida manualmente, no por Admin Center | Re-subir desde admin.teams.microsoft.com |
