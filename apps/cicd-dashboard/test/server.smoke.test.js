'use strict';

// Smoke test del servidor Express con ADO y Teams mockeados (sin red).
const test = require('node:test');
const assert = require('node:assert');
const path = require('path');

// Stub de fetch global para que teams.postCard no salga a la red si se invoca.
global.fetch = async () => ({ ok: true, status: 200, json: async () => ({}), text: async () => '' });

const { app, refresh, state } = require('../src/server');
const ado = require('../src/ado');

// Monkeypatch de las funciones de red del cliente ADO.
ado.getBuilds = async () => ([
  ado.normalizeBuild({
    id: 100, definition: { name: 'cicd-dashboard-Build' }, buildNumber: '20260921.1',
    sourceBranch: 'refs/heads/release', sourceVersion: 'deadbeefcafe',
    status: 'completed', result: 'succeeded', requestedFor: { displayName: 'Pablo' },
    queueTime: new Date().toISOString(),
  }),
]);
ado.getReleases = async () => ([
  ado.normalizeRelease({
    id: 200, releaseDefinition: { name: 'Deploy-cicd-dashboard' }, name: 'Release-1',
    environments: [{ name: 'produccion', status: 'succeeded' }],
    createdBy: { displayName: 'Pablo' }, createdOn: new Date().toISOString(),
  }),
]);

const http = require('node:http');

function req(server, urlPath) {
  return new Promise((resolve, reject) => {
    const addr = server.address();
    http.get({ host: '127.0.0.1', port: addr.port, path: urlPath }, (res) => {
      let body = '';
      res.on('data', (c) => (body += c));
      res.on('end', () => resolve({ status: res.statusCode, body }));
    }).on('error', reject);
  });
}

test('refresh puebla el estado desde ADO (mock) sin notificar en primer snapshot', async () => {
  await refresh();
  assert.strictEqual(state.items.length, 2);
  assert.ok(state.updatedAt);
});

test('endpoints /healthz, /api/runs e index responden', async () => {
  const server = app.listen(0, '127.0.0.1');
  await new Promise((r) => server.once('listening', r));
  try {
    const h = await req(server, '/healthz');
    assert.strictEqual(h.status, 200);
    assert.match(h.body, /"ok":true/);

    const runs = await req(server, '/api/runs');
    assert.strictEqual(runs.status, 200);
    const j = JSON.parse(runs.body);
    assert.strictEqual(j.count, 2);
    assert.ok(j.items.some((x) => x.kind === 'build'));
    assert.ok(j.items.some((x) => x.kind === 'release'));

    const idx = await req(server, '/index.html');
    assert.strictEqual(idx.status, 200);
    assert.match(idx.body, /CI\/CD Dashboard/);
  } finally {
    server.close();
  }
});
