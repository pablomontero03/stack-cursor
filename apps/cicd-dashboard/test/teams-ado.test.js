'use strict';

const test = require('node:test');
const assert = require('node:assert');
const teams = require('../src/teams');
const ado = require('../src/ado');

// --- Teams card builders ---

test('build card started tiene color Good y estado en ejecución', () => {
  const b = { name: 'p1', buildNumber: '20260921.1', branch: 'release', commit: 'abcd1234', requestedFor: 'Pablo', url: 'https://x/build' };
  const card = teams.buildBuildCard(b, 'started', null);
  const content = card.attachments[0].content;
  assert.strictEqual(content.body[0].color, 'Good');
  assert.match(content.body[0].text, /Build iniciado/);
});

test('build card completed OK tiene color Good', () => {
  const b = { name: 'p1', result: 'succeeded', buildNumber: '1', branch: 'release', commit: 'a', requestedFor: 'Pablo', url: 'u' };
  const card = teams.buildBuildCard(b, 'completed', null);
  assert.strictEqual(card.attachments[0].content.body[0].color, 'Good');
  assert.match(card.attachments[0].content.body[0].text, /Build OK/);
});

test('build card failed incluye el bloque de error del log', () => {
  const b = { name: 'p1', result: 'failed', buildNumber: '1', branch: 'release', commit: 'a', requestedFor: 'Pablo', url: 'u' };
  const failure = [{ task: 'Build image', issues: ['SQL71501: reference not found', 'segundo error'] }];
  const card = teams.buildBuildCard(b, 'completed', failure);
  const content = card.attachments[0].content;
  assert.strictEqual(content.body[0].color, 'Attention');
  const detail = content.body[2].text;
  assert.match(detail, /Error del log/);
  assert.match(detail, /SQL71501/);
  assert.match(detail, /Build image/);
});

test('build card incluye link markdown a ADO', () => {
  const b = { name: 'p1', result: 'succeeded', buildNumber: '1', branch: 'release', commit: 'a', requestedFor: 'Pablo', url: 'https://dev.azure.com/x/_build/results?buildId=5' };
  const card = teams.buildBuildCard(b, 'completed', null);
  assert.match(card.attachments[0].content.body[2].text, /\[p1\]\(https:\/\/dev\.azure\.com/);
});

test('release card completed rejected es Attention', () => {
  const r = { name: 'r1', releaseName: 'Release-3', createdBy: 'Pablo', url: 'u' };
  const card = teams.buildReleaseCard(r, 'completed', 'produccion', 'rejected');
  assert.strictEqual(card.attachments[0].content.body[0].color, 'Attention');
  assert.match(card.attachments[0].content.body[0].text, /Release ERROR/);
});

test('card usa contentType adaptive de Teams', () => {
  const card = teams.buildReleaseCard({ name: 'r', createdBy: 'x', url: 'u' }, 'started', 'prod', 'inProgress');
  assert.strictEqual(card.type, 'message');
  assert.strictEqual(card.attachments[0].contentType, 'application/vnd.microsoft.card.adaptive');
  assert.strictEqual(card.attachments[0].content.version, '1.4');
});

test('postCard sin webhook devuelve skipped sin lanzar', async () => {
  // teams.WEBHOOK se lee al cargar el módulo; con env vacío debe skip.
  const res = await teams.postCard({ any: 'card' });
  assert.strictEqual(res.ok, false);
});

// --- ADO normalizers / links ---

test('normalizeBuild limpia refs/heads y recorta commit', () => {
  const b = ado.normalizeBuild({
    id: 42, definition: { name: 'pipe' }, buildNumber: '1.2',
    sourceBranch: 'refs/heads/release', sourceVersion: 'abcdef1234567890',
    status: 'completed', result: 'succeeded', requestedFor: { displayName: 'Pablo' },
  });
  assert.strictEqual(b.branch, 'release');
  assert.strictEqual(b.commit, 'abcdef12');
  assert.strictEqual(b.kind, 'build');
  assert.match(b.url, /buildId=42/);
});

test('normalizeRelease mapea stages con status', () => {
  const r = ado.normalizeRelease({
    id: 7, releaseDefinition: { name: 'reldef' }, name: 'Release-7',
    environments: [{ name: 'produccion', status: 'succeeded' }],
    createdBy: { displayName: 'Pablo' },
  });
  assert.strictEqual(r.stages.length, 1);
  assert.strictEqual(r.stages[0].name, 'produccion');
  assert.strictEqual(r.stages[0].status, 'succeeded');
  assert.match(r.url, /releaseId=7/);
});

test('buildWebUrl y releaseWebUrl apuntan al proyecto', () => {
  assert.match(ado.buildWebUrl(5), /_build\/results\?buildId=5/);
  assert.match(ado.releaseWebUrl(9), /_release\?releaseId=9/);
});
