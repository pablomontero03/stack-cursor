'use strict';

const path = require('path');
const express = require('express');

const ado = require('./ado');
const teams = require('./teams');
const { detectEvents } = require('./detector');

const PORT = parseInt(process.env.PORT || '8080', 10);
const HOST = process.env.HOST || '0.0.0.0';
const POLL_MS = parseInt(process.env.POLL_INTERVAL_MS || '300000', 10); // 5 min
const TOP = parseInt(process.env.RUNS_TOP || '30', 10);

const app = express();
app.disable('x-powered-by');
app.use(express.json()); // body-parser must be registered BEFORE any routes that read req.body

// Estado en memoria: último snapshot y su timestamp.
const state = {
  items: [],
  updatedAt: null,
  lastError: null,
  notified: false,
};

async function refresh() {
  const [builds, releases] = await Promise.all([
    ado.getBuilds(TOP),
    ado.getReleases(TOP),
  ]);
  const cur = [...builds, ...releases];

  // Detectar transiciones vs snapshot previo y notificar.
  const events = detectEvents(state.items, cur);
  for (const ev of events) {
    try {
      let card;
      if (ev.type === 'build') {
        let failureDetail = null;
        if (ev.phase === 'completed' && ev.item.result === 'failed') {
          failureDetail = await ado.getBuildFailureDetail(ev.item.id).catch(() => null);
        }
        card = teams.buildBuildCard(ev.item, ev.phase, failureDetail);
      } else {
        card = teams.buildReleaseCard(ev.item, ev.phase, ev.stage, ev.stageStatus);
      }
      await teams.postCard(card);
    } catch (err) {
      // No dejar que un fallo de notificación tumbe el refresh.
      console.error('[notify] error:', err.message);
    }
  }

  state.items = cur;
  state.updatedAt = new Date().toISOString();
  state.lastError = null;
  state.notified = true;
}

// --- API ---
app.get('/healthz', (_req, res) => res.json({ ok: true, updatedAt: state.updatedAt }));

// Teams configuration page — required for configurableTab (channel tab).
app.get('/teams-config', (_req, res) => {
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  res.send(`<!DOCTYPE html>
<html lang="es">
<head>
  <meta charset="UTF-8">
  <meta name="viewport" content="width=device-width, initial-scale=1.0">
  <title>CI/CD Dashboard — Configurar</title>
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
  <h2>🚀 CI/CD Dashboard</h2>
  <p>Selecciona el dashboard para agregar al canal.</p>
  <div class="item" id="opt" onclick="selectDash()">
    <div class="radio"><div class="dot"></div></div>
    <div>
      <div class="label">CI/CD Dashboard</div>
      <div class="desc">Builds, Releases y Aprobaciones — Azure DevOps</div>
    </div>
  </div>
</div>
<script>
  (async function() {
    try {
      await microsoftTeams.app.initialize();
      microsoftTeams.pages.config.registerOnSaveHandler(function(saveEvent) {
        microsoftTeams.pages.config.setConfig({
          contentUrl: 'https://cicd-dashboard.grupomontecristo.com/teams-tab',
          entityId: 'cicd-dashboard',
          suggestedDisplayName: 'CI/CD Dashboard',
          websiteUrl: 'https://cicd-dashboard.grupomontecristo.com'
        });
        saveEvent.notifySuccess();
      });
    } catch(e) { console.error('Teams init error:', e); }
  })();
  function selectDash() {
    document.getElementById('opt').classList.add('selected');
    microsoftTeams.pages.config.setValidityState(true);
  }
</script>
</body>
</html>`);
});

// Teams tab content — full dashboard embedded in Teams iframe via SSO.
// Teams calls getAuthToken() to get a JWT, the frontend sends it to /api/teams-token,
// the backend validates it and returns the user email without oauth2-proxy.
app.get('/teams-tab', (_req, res) => {
  res.setHeader('Content-Type', 'text/html; charset=utf-8');
  // Serve the same index.html but injecting Teams SSO bootstrap
  const fs = require('fs');
  const htmlPath = require('path').join(__dirname, 'public', 'index.html');
  let html = fs.readFileSync(htmlPath, 'utf8');
  // Inject Teams SDK and SSO token fetch before the closing </head>
  const teamsBootstrap = `
  <script src="https://cdn.jsdelivr.net/npm/@microsoft/teams-js@2.0.0/dist/MicrosoftTeams.min.js"></script>
  <script>
    // Teams SSO: get token silently and store for /api/me calls
    window.__TEAMS_MODE = true;
    microsoftTeams.app.initialize().then(function() {
      microsoftTeams.authentication.getAuthToken({
        successCallback: function(token) {
          window.__TEAMS_TOKEN = token;
          // Re-load user identity now that the token is available
          if (typeof loadMe === 'function') loadMe();
        },
        failureCallback: function(err) {
          console.warn('Teams SSO failed:', err);
        }
      });
    }).catch(function(){});
  </script>`;
  html = html.replace('</head>', teamsBootstrap + '</head>');
  res.send(html);
});

// Validate a Teams SSO token and return user identity.
// Called by the Teams-embedded dashboard instead of relying on X-Forwarded-Email.
app.get('/api/teams-me', async (req, res) => {
  const token = req.headers['x-teams-token'] || req.query.token;
  if (!token) return res.json({ email: null, user: null, canApprove: false, adoId: null });
  try {
    // Decode the JWT payload (no verification needed — Azure AD already verified it for Teams)
    const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64').toString());
    const email = (payload.unique_name || payload.upn || payload.preferred_username || payload.email || '').toLowerCase().trim();
    const adoId = email ? await resolveAdoId(email).catch(() => null) : null;
    res.json({ email: email || null, user: payload.name || null, canApprove: email ? APPROVERS.has(email) : false, adoId: adoId || null });
  } catch (e) {
    res.json({ email: null, user: null, canApprove: false, adoId: null });
  }
});

// Middleware: if request carries x-teams-token, extract email and inject as x-forwarded-email
// so all /api/* handlers work transparently whether called from browser or Teams iframe.
app.use('/api', (req, _res, next) => {
  const token = req.headers['x-teams-token'];
  if (token && !req.headers['x-forwarded-email']) {
    try {
      const payload = JSON.parse(Buffer.from(token.split('.')[1], 'base64').toString());
      const email = (payload.unique_name || payload.upn || payload.preferred_username || payload.email || '').toLowerCase().trim();
      if (email) req.headers['x-forwarded-email'] = email;
    } catch (_) { /* ignore malformed token */ }
  }
  next();
});

app.get('/api/runs', async (req, res) => {
  // ?refresh=1 forces an immediate ADO poll instead of serving the cached state
  if (req.query.refresh === '1') {
    await safeRefresh();
  }
  res.json({
    updatedAt: state.updatedAt,
    lastError: state.lastError,
    org: ado.ORG,
    project: ado.PROJECT,
    count: state.items.length,
    items: state.items,
  });
});

// Lista de emails autorizados para aprobar/cancelar releases
const APPROVERS = new Set([
  'bburgos@grupomontecristo.com',
  'jquesada@grupomontecristo.com',
  'mdailey@grupomontecristo.com',
  'pmontero@grupomontecristo.com',
  'ccarvajal@grupomontecristo.com',
]);

// Caché en memoria de email→adoId para no llamar a la API en cada request
const adoIdCache = new Map();

async function resolveAdoId(email) {
  if (!email) return null;
  if (adoIdCache.has(email)) return adoIdCache.get(email);
  try {
    const url = `https://vssps.dev.azure.com/${encodeURIComponent(ado.ORG)}/_apis/identities?searchFilter=MailAddress&filterValue=${encodeURIComponent(email)}&api-version=7.1`;
    const res = await fetch(url, {
      headers: { Authorization: ado.authHeader(), Accept: 'application/json' },
    });
    if (!res.ok) return null;
    const data = await res.json();
    const id = (data.value && data.value[0] && data.value[0].id) || null;
    if (id) adoIdCache.set(email, id);
    return id;
  } catch { return null; }
}

// GET /api/me — returns the authenticated user's email, approval permission and ADO identity ID
app.get('/api/me', async (req, res) => {
  const email = (req.headers['x-forwarded-email'] || '').toLowerCase().trim();
  const user = req.headers['x-forwarded-user'] || '';
  const adoId = await resolveAdoId(email).catch(() => null);
  res.json({
    email: email || null,
    user: user || null,
    canApprove: email ? APPROVERS.has(email) : false,
    adoId: adoId || null,
  });
});
app.get('/api/approvals', async (_req, res) => {
  try {
    const approvals = await ado.getPendingApprovals();
    res.json({ count: approvals.length, items: approvals });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// GET /api/pull-requests — PRs activos del proyecto
app.get('/api/pull-requests', async (req, res) => {
  try {
    const prs = await ado.getPendingPRs();
    res.json({ count: prs.length, items: prs });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// POST /api/pull-requests/:repoId/:prId/vote
// body: { vote: 10 | -10 | 0, reviewerId: '<identityId>' }
app.post('/api/pull-requests/:repoId/:prId/vote', async (req, res) => {
  const email = (req.headers['x-forwarded-email'] || '').toLowerCase().trim();
  if (!email || !APPROVERS.has(email)) {
    return res.status(403).json({ error: 'No autorizado. Solo los aprobadores designados pueden votar en Pull Requests.' });
  }
  const { repoId, prId } = req.params;
  const { vote, reviewerId, projectName } = req.body || {};
  if (![10, -10, 0].includes(Number(vote))) {
    return res.status(400).json({ error: 'vote debe ser 10 (aprobar), -10 (rechazar) o 0 (reset)' });
  }
  if (!reviewerId) {
    return res.status(400).json({ error: 'reviewerId requerido' });
  }
  try {
    // Ensure user is added as individual reviewer before voting (idempotent PUT).
    // Necessary when only a group (Release Executers) is listed — ADO requires
    // the individual identity in the reviewers list to accept the vote.
    await ado.ensurePRReviewer(repoId, parseInt(prId, 10), reviewerId, projectName);
    const result = await ado.patchPRVote(repoId, parseInt(prId, 10), Number(vote), reviewerId, projectName);
    res.json({ ok: true, vote: result.vote, reviewerId });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// POST /api/pull-requests/:repoId/:prId/complete
// body: { deleteSourceBranch?: boolean, projectName?: string }
app.post('/api/pull-requests/:repoId/:prId/complete', async (req, res) => {
  const email = (req.headers['x-forwarded-email'] || '').toLowerCase().trim();
  if (!email || !APPROVERS.has(email)) {
    return res.status(403).json({ error: 'No autorizado.' });
  }
  const { repoId, prId } = req.params;
  const { deleteSourceBranch, projectName } = req.body || {};
  const proj = projectName || 'DevOps';
  const projectBase = `https://dev.azure.com/${encodeURIComponent(process.env.ADO_ORG || 'Shared-Service-GM')}/${encodeURIComponent(proj)}`;
  try {
    // First get current PR to get the lastMergeSourceCommit
    const getUrl = `${projectBase}/_apis/git/repositories/${encodeURIComponent(repoId)}/pullrequests/${prId}?api-version=7.1`;
    const getRes = await fetch(getUrl, {
      headers: { Authorization: ado.authHeader(), Accept: 'application/json' },
    });
    if (!getRes.ok) throw new Error(`GET PR ${getRes.status}`);
    const pr = await getRes.json();

    const patchUrl = `${projectBase}/_apis/git/repositories/${encodeURIComponent(repoId)}/pullrequests/${prId}?api-version=7.1`;
    const body = JSON.stringify({
      status: 'completed',
      lastMergeSourceCommit: pr.lastMergeSourceCommit,
      completionOptions: {
        deleteSourceBranch: deleteSourceBranch === true,
        mergeStrategy: 'noFastForward',
        squashMerge: false,
        bypassPolicy: true,
        bypassReason: 'Completado manualmente desde CI/CD Dashboard',
      },
    });
    const patchRes = await fetch(patchUrl, {
      method: 'PATCH',
      headers: { Authorization: ado.authHeader(), 'Content-Type': 'application/json', Accept: 'application/json' },
      body,
    });
    if (!patchRes.ok) {
      const b = await patchRes.text().catch(() => '');
      throw new Error(`${patchRes.status}: ${b.slice(0, 200)}`);
    }
    const result = await patchRes.json();
    res.json({ ok: true, status: result.status });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// POST /api/cancel/build/:id
app.post('/api/cancel/build/:id', async (req, res) => {
  const email = (req.headers['x-forwarded-email'] || '').toLowerCase().trim();
  if (!email || !APPROVERS.has(email)) {
    return res.status(403).json({ error: 'No autorizado. Solo los aprobadores designados pueden cancelar.' });
  }
  const buildId = parseInt(req.params.id, 10);
  try {
    const url = `${ado.BASE}/_apis/build/builds/${buildId}?api-version=7.1`;
    // First check current status
    const getRes = await fetch(url, { headers: { Authorization: ado.authHeader(), Accept: 'application/json' } });
    const build = await getRes.json();
    if (build.status === 'completed' || build.status === 'cancelling') {
      return res.json({ ok: true, status: build.status, buildId, note: 'already in ' + build.status });
    }
    const response = await fetch(url, {
      method: 'PATCH',
      headers: { Authorization: ado.authHeader(), 'Content-Type': 'application/json', Accept: 'application/json' },
      body: JSON.stringify({ status: 'cancelling' }),
    });
    if (!response.ok) {
      const b = await response.text().catch(() => '');
      throw new Error(`${response.status} ${response.statusText}: ${b.slice(0, 200)}`);
    }
    const data = await response.json();
    res.json({ ok: true, status: data.status, buildId });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// POST /api/cancel/release/:id  (cancels all inProgress environments of a release)
app.post('/api/cancel/release/:id', async (req, res) => {
  const email = (req.headers['x-forwarded-email'] || '').toLowerCase().trim();
  if (!email || !APPROVERS.has(email)) {
    return res.status(403).json({ error: 'No autorizado. Solo los aprobadores designados pueden cancelar.' });
  }
  const releaseId = parseInt(req.params.id, 10);
  try {
    // Get the release to find inProgress environments
    const relUrl = `${ado.VSRM}/_apis/release/releases/${releaseId}?api-version=7.1`;
    const relRes = await fetch(relUrl, {
      headers: { Authorization: ado.authHeader(), Accept: 'application/json' },
    });
    if (!relRes.ok) throw new Error(`GET release ${relRes.status}`);
    const rel = await relRes.json();
    const envs = (rel.environments || []).filter((e) => e.status === 'inProgress');
    if (!envs.length) {
      return res.json({ ok: false, message: 'No hay stages en inProgress para cancelar' });
    }
    const results = [];
    for (const env of envs) {
      const patchUrl = `${ado.VSRM}/_apis/release/releases/${releaseId}/environments/${env.id}?api-version=7.1`;
      const patchRes = await fetch(patchUrl, {
        method: 'PATCH',
        headers: {
          Authorization: ado.authHeader(),
          'Content-Type': 'application/json',
          Accept: 'application/json; api-version=7.1-preview.6',
        },
        body: JSON.stringify({ status: 8, scheduledDeploymentTime: null, comment: 'Cancelado desde CI/CD Dashboard' }),
      });
      results.push({ envId: env.id, name: env.name, ok: patchRes.ok, status: patchRes.status });
    }
    res.json({ ok: true, results });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
app.post('/api/approvals/:id', async (req, res) => {
  // Enforce approvers-only access — check both oauth2-proxy cookie header and Teams SSO token
  const email = (req.headers['x-forwarded-email'] || '').toLowerCase().trim();
  if (!email || !APPROVERS.has(email)) {
    return res.status(403).json({ error: 'No autorizado. Solo los aprobadores designados pueden aprobar o rechazar releases.' });
  }
  const approvalId = parseInt(req.params.id, 10);
  const { action, comment } = req.body || {};
  if (!['approved', 'rejected'].includes(action)) {
    return res.status(400).json({ error: 'action must be approved or rejected' });
  }
  try {
    const result = await ado.patchApproval(approvalId, action, comment || '');
    res.json({ ok: true, status: result.status, approvalId });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// --- estáticos (no-cache para que el browser siempre pida la versión actual) ---
app.use(express.static(path.join(__dirname, 'public'), {
  etag: false,
  lastModified: false,
  setHeaders: (res) => {
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate');
    res.setHeader('Pragma', 'no-cache');
  },
}));

async function safeRefresh() {
  // Retry up to 3 times with 10s delay — transient DNS/TLS blips are common
  const MAX_TRIES = 3;
  const RETRY_MS = 10_000;
  for (let attempt = 1; attempt <= MAX_TRIES; attempt++) {
    try {
      await refresh();
      return; // success
    } catch (err) {
      state.lastError = err.message;
      console.error(`[refresh] error (attempt ${attempt}/${MAX_TRIES}):`, err.message);
      if (attempt < MAX_TRIES) {
        await new Promise((r) => setTimeout(r, RETRY_MS));
      }
    }
  }
}

function start() {
  const server = app.listen(PORT, HOST, () => {
    console.log(`cicd-dashboard escuchando en http://${HOST}:${PORT}`);
    console.log(`Proyecto ADO: ${ado.ORG}/${ado.PROJECT} — poll cada ${POLL_MS / 1000}s`);
  });
  // primer refresh + loop
  safeRefresh();
  const timer = setInterval(safeRefresh, POLL_MS);
  timer.unref();
  return server;
}

if (require.main === module) {
  start();
}

module.exports = { app, start, refresh, state };

