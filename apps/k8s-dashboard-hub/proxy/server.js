'use strict';
/**
 * k8s-dashboard-proxy
 * Sirve /teams-tab como ruta pública e inyecta el K8s Dashboard via HTTP
 * al dashboard-injector (nginx que ya tiene el SA Bearer token configurado).
 * No usa TLS directo al dashboard — evita las restricciones de seccomp de k3s.
 */

const express = require('express');
const http = require('http');

const PORT = parseInt(process.env.PORT || '8090', 10);

// dashboard-injector service (HTTP, no TLS)
const INJECTOR_HOST = process.env.INJECTOR_HOST ||
  'dashboard-injector.k8s-dashboard.svc.cluster.local';
const INJECTOR_PORT = parseInt(process.env.INJECTOR_PORT || '80', 10);

// Host header que el injector espera (su server_name en nginx)
const DASHBOARD_HOST = process.env.DASHBOARD_HOST || 'cluster-dev.gmontecristo.com';

const app = express();
app.disable('x-powered-by');

// Healthz
app.get('/healthz', (_req, res) => res.json({ ok: true }));

// /teams-tab — público (skip-auth-route en oauth2-proxy del cluster)
// Sirve una página HTML con el K8s Dashboard en un iframe interno
app.get('/teams-tab', (_req, res) => {
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.setHeader('X-Frame-Options', 'ALLOWALL');
  res.setHeader('Content-Security-Policy',
    "frame-ancestors 'self' https://k8s-hub.grupomontecristo.com " +
    'https://*.teams.microsoft.com https://*.teams.cloud.microsoft');
  res.send(`<!DOCTYPE html>
<html>
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width,initial-scale=1">
  <script src="https://cdn.jsdelivr.net/npm/@microsoft/teams-js@2.0.0/dist/MicrosoftTeams.min.js"></script>
  <style>
    html,body{margin:0;padding:0;height:100%;overflow:hidden}
    iframe{width:100%;height:100vh;border:none;display:block}
  </style>
</head>
<body>
<iframe src="/k8s-proxy/" allow="fullscreen" title="Kubernetes Dashboard"></iframe>
<script>
  window.__TEAMS_MODE = true;
  microsoftTeams.app.initialize().catch(function(){});
</script>
</body>
</html>`);
});

// /k8s-proxy/* — proxy HTTP al dashboard-injector
// El injector ya inyecta el Bearer token del SA readonly en cada request
app.use('/k8s-proxy', (req, res) => {
  const targetPath = req.url || '/';

  const opts = {
    hostname: INJECTOR_HOST,
    port: INJECTOR_PORT,
    path: targetPath,
    method: req.method,
    headers: {
      ...req.headers,
      'host': DASHBOARD_HOST,
      'x-forwarded-proto': 'https',
      'x-forwarded-host': DASHBOARD_HOST,
      'x-forwarded-for': req.ip || '',
    },
  };
  delete opts.headers['x-teams-token'];
  delete opts.headers['connection'];
  delete opts.headers['transfer-encoding'];

  const proxy = http.request(opts, (proxyRes) => {
    const headers = { ...proxyRes.headers };
    delete headers['x-frame-options'];
    headers['x-frame-options'] = 'ALLOWALL';
    headers['content-security-policy'] =
      "frame-ancestors 'self' https://k8s-hub.grupomontecristo.com " +
      'https://*.teams.microsoft.com https://*.teams.cloud.microsoft';

    if (headers['location']) {
      headers['location'] = headers['location']
        .replace(/^https?:\/\/[^/]+/, '/k8s-proxy');
    }

    res.writeHead(proxyRes.statusCode, headers);
    proxyRes.pipe(res);
  });

  proxy.on('error', (err) => {
    console.error('Proxy error:', err.message);
    if (!res.headersSent) res.status(502).send('Injector unavailable: ' + err.message);
  });

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    req.pipe(proxy);
  } else {
    proxy.end();
  }
});

app.listen(PORT, '0.0.0.0', () => {
  console.log(`k8s-dashboard-proxy en http://0.0.0.0:${PORT}`);
  console.log(`Injector: ${INJECTOR_HOST}:${INJECTOR_PORT} host=${DASHBOARD_HOST}`);
});
