'use strict';

const path = require('path');
const express = require('express');
const https = require('https');
const http = require('http');

const PORT = parseInt(process.env.PORT || '8080', 10);
const HOST = process.env.HOST || '0.0.0.0';

// ─── Catálogo de clusters ─────────────────────────────────────────────────────
// embedUrl usa /proxy/:id/ (mismo dominio del hub) para evitar restricciones
// de cookies/storage cross-origin en Teams desktop.
const CLUSTERS = [
  {
    id: 'prod-onprem-01',
    name: 'prod-onprem-01',
    label: 'Producción On-Prem 01',
    description: 'k3s · DataHub + MCP Buklo · srvdesarrollo03 (172.16.2.31)',
    url: 'https://cluster-onprem-01.grupomontecristo.com',
    // Hub corre en el mismo cluster — usar service interno directamente
    proxyTarget: 'http://k8s-dashboard-proxy.kubernetes-dashboard.svc.cluster.local:80/k8s-proxy',
    // healthUrl: usar el proxy interno para el health check
    healthUrl: null,
    embedUrl: '/proxy/prod-onprem-01/',
    env: 'prod',
  },
  {
    id: 'k3s-dev',
    name: 'k3s-dev',
    label: 'Desarrollo On-Prem',
    description: 'k3s · Entorno de desarrollo · srvdesarrollo05 (172.16.2.43)',
    url: 'https://cluster-dev.gmontecristo.com',
    proxyTarget: 'https://cluster-dev.gmontecristo.com/k8s-proxy',
    embedUrl: '/proxy/k3s-dev/',
    env: 'dev',
  },
  {
    id: 'aks-0004',
    name: 'gmon-prod-aks-eastus2-0004',
    label: 'AKS Producción 0004',
    description: 'AKS Azure · East US 2 · Servicios productivos',
    url: 'https://cluster-services-prod.grupomontecristo.com',
    proxyTarget: 'https://cluster-services-prod.grupomontecristo.com/k8s-proxy',
    embedUrl: '/proxy/aks-0004/',
    env: 'prod',
  },
  {
    id: 'aks-0001',
    name: 'gmon-prod-aks-eastus2-0001',
    label: 'AKS Producción 0001',
    description: 'AKS Azure · East US 2 · Sites productivos',
    url: 'https://cluster-sites-prod.grupomontecristo.com',
    proxyTarget: 'https://cluster-sites-prod.grupomontecristo.com/k8s-proxy',
    embedUrl: '/proxy/aks-0001/',
    env: 'prod',
  },
];

// ─── Health check de cada cluster (timeout 4s) ────────────────────────────────
function checkClusterHealth(cluster) {
  const urlStr = cluster.healthUrl !== undefined ? cluster.healthUrl : cluster.url;
  // Si healthUrl es null, usar proxyTarget directamente (service interno HTTP)
  if (!urlStr) {
    const target = cluster.proxyTarget;
    return new Promise((resolve) => {
      const parsed = new URL(target + '/');
      const transport = parsed.protocol === 'https:' ? https : http;
      const req = transport.request(
        { hostname: parsed.hostname, port: parsed.port || (parsed.protocol === 'https:' ? 443 : 80),
          path: parsed.pathname, method: 'HEAD', timeout: 4000 },
        (res) => resolve(res.statusCode < 500 ? 'up' : 'degraded')
      );
      req.on('error', () => resolve('unreachable'));
      req.on('timeout', () => { req.destroy(); resolve('unreachable'); });
      req.end();
    });
  }
  return new Promise((resolve) => {
    const parsed = new URL(urlStr);
    const req = https.request(
      { hostname: parsed.hostname, port: 443, path: '/', method: 'HEAD', timeout: 4000,
        rejectUnauthorized: false },
      (res) => resolve(res.statusCode < 500 ? 'up' : 'degraded')
    );
    req.on('error', () => resolve('unreachable'));
    req.on('timeout', () => { req.destroy(); resolve('unreachable'); });
    req.end();
  });
}

// ─── Express app ─────────────────────────────────────────────────────────────
const app = express();
app.disable('x-powered-by');
app.use(express.json());

// Healthz
app.get('/healthz', (_req, res) => res.json({ ok: true }));

// API: estado de los clusters
app.get('/api/clusters', async (_req, res) => {
  const results = await Promise.all(
    CLUSTERS.map(async (c) => ({
      ...c,
      status: await checkClusterHealth(c),
    }))
  );
  res.json(results);
});

// ─── Teams: página de configuración ──────────────────────────────────────────
app.get('/teams-config', (_req, res) => {
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.send(`<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>K8s Dashboard Hub — Configurar</title>
  <script src="https://cdn.jsdelivr.net/npm/@microsoft/teams-js@2.0.0/dist/MicrosoftTeams.min.js"></script>
  <style>
    * { box-sizing: border-box; margin: 0; padding: 0; }
    body { font-family: 'Segoe UI', sans-serif; background: #1a1a2e; color: #e0e0e0;
           min-height: 100vh; display: flex; align-items: center; justify-content: center; }
    .app { max-width: 480px; width: 100%; padding: 2rem; }
    h2 { font-size: 18px; font-weight: 600; margin-bottom: 8px; }
    p { font-size: 13px; color: #aaa; margin-bottom: 24px; }
    .item { background: #252838; border: 1px solid #2a2d3e; padding: 16px; cursor: pointer;
            margin-bottom: 8px; display: flex; align-items: center; gap: 12px; }
    .item:hover, .item.selected { border-color: #0078d4; background: rgba(0,120,212,0.1); }
    .radio { width: 16px; height: 16px; border: 2px solid #555; border-radius: 50%;
             flex-shrink: 0; display: flex; align-items: center; justify-content: center; }
    .item.selected .radio { border-color: #0078d4; }
    .dot { width: 8px; height: 8px; background: #0078d4; border-radius: 50%; display: none; }
    .item.selected .dot { display: block; }
    .label { font-size: 14px; font-weight: 600; }
    .desc { font-size: 12px; color: #888; margin-top: 2px; }
  </style>
</head>
<body>
<div class="app">
  <h2>⎈ K8s Dashboard Hub</h2>
  <p>Selecciona el hub para agregar al canal.</p>
  <div class="item" id="opt" onclick="selectHub()">
    <div class="radio"><div class="dot"></div></div>
    <div>
      <div class="label">Kubernetes Dashboard Hub</div>
      <div class="desc">Selector de los 4 clusters de Grupo Montecristo</div>
    </div>
  </div>
</div>
<script>
  (async function() {
    try {
      await microsoftTeams.app.initialize();
      microsoftTeams.pages.config.registerOnSaveHandler(function(saveEvent) {
        microsoftTeams.pages.config.setConfig({
          contentUrl: '${process.env.HUB_BASE_URL || 'https://k8s-hub.grupomontecristo.com'}/teams-tab',
          entityId: 'k8s-dashboard-hub',
          suggestedDisplayName: 'K8s Dashboards',
          websiteUrl: '${process.env.HUB_BASE_URL || 'https://k8s-hub.grupomontecristo.com'}'
        });
        saveEvent.notifySuccess();
      });
    } catch(e) { console.error('Teams init error:', e); }
  })();
  function selectHub() {
    document.getElementById('opt').classList.add('selected');
    microsoftTeams.pages.config.setValidityState(true);
  }
</script>
</body>
</html>`);
});

// ─── Teams: tab de canal (hub principal) ─────────────────────────────────────
app.get('/teams-tab', (_req, res) => {
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  const fs = require('fs');
  const htmlPath = path.join(__dirname, 'public', 'index.html');
  let html = fs.readFileSync(htmlPath, 'utf8');

  const teamsBootstrap = `
  <script src="https://cdn.jsdelivr.net/npm/@microsoft/teams-js@2.0.0/dist/MicrosoftTeams.min.js"></script>
  <script>
    window.__TEAMS_MODE = true;
    microsoftTeams.app.initialize().then(function() {
      microsoftTeams.authentication.getAuthToken({
        successCallback: function(token) {
          window.__TEAMS_TOKEN = token;
          if (typeof loadUser === 'function') loadUser();
        },
        failureCallback: function(err) { console.warn('Teams SSO failed:', err); }
      });
    }).catch(function(){});
  </script>`;
  html = html.replace('</head>', teamsBootstrap + '</head>');
  res.send(html);
});

// ─── Proxy same-origin al k8s-dashboard de cada cluster ──────────────────────
// Sirve /proxy/:clusterId/* desde el mismo dominio del hub (k8s-hub.grupomontecristo.com)
// Esto evita restricciones de cookies/storage cross-origin en Teams desktop.
app.use('/proxy/:clusterId', (req, res) => {
  const cluster = CLUSTERS.find(c => c.id === req.params.clusterId);
  if (!cluster) return res.status(404).send('Cluster not found');

  const targetUrl = new URL(cluster.proxyTarget);
  const isHttps = targetUrl.protocol === 'https:';
  const transport = isHttps ? https : http;

  // Path: /proxy/aks-0004/api/v1/... → /k8s-proxy/api/v1/...
  // req.url ya viene sin el /proxy/:id prefix gracias al app.use mount
  const targetPath = req.url || '/';

  const opts = {
    hostname: targetUrl.hostname,
    port: targetUrl.port || (isHttps ? 443 : 80),
    path: targetUrl.pathname + (targetPath === '/' ? '/' : targetPath),
    method: req.method,
    headers: {
      ...req.headers,
      'host': targetUrl.hostname,
      'x-forwarded-proto': 'https',
      'x-forwarded-host': req.headers.host || '',
      'origin': `https://${targetUrl.hostname}`,
    },
    rejectUnauthorized: false,
  };
  delete opts.headers['x-teams-token'];
  delete opts.headers['connection'];
  delete opts.headers['transfer-encoding'];

  const proxy = transport.request(opts, (proxyRes) => {
    const headers = { ...proxyRes.headers };
    // Eliminar restricciones de iframe — el hub ya maneja la autenticación
    delete headers['x-frame-options'];
    delete headers['content-security-policy'];
    // Reescribir Location si hay redirect
    if (headers['location']) {
      headers['location'] = headers['location']
        .replace(cluster.proxyTarget, `/proxy/${cluster.id}`)
        .replace(/^\/k8s-proxy/, `/proxy/${cluster.id}`);
    }
    res.writeHead(proxyRes.statusCode, headers);
    proxyRes.pipe(res);
  });

  proxy.on('error', (err) => {
    console.error(`Proxy error [${cluster.id}]:`, err.message);
    if (!res.headersSent) res.status(502).send('Cluster proxy error: ' + err.message);
  });

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    req.pipe(proxy);
  } else {
    proxy.end();
  }
});

// ─── Estáticos ────────────────────────────────────────────────────────────────
app.use(express.static(path.join(__dirname, 'public'), {
  etag: false,
  lastModified: false,
  setHeaders: (res) => {
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate');
  },
}));

// ─── Arranque ────────────────────────────────────────────────────────────────
if (require.main === module) {
  app.listen(PORT, HOST, () => {
    console.log(`k8s-dashboard-hub escuchando en http://${HOST}:${PORT}`);
    console.log(`Clusters: ${CLUSTERS.length} configurados`);
  });
}

module.exports = { app, CLUSTERS };
