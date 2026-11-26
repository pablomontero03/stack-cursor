'use strict';
// Lanzador de DEMO local: sirve el dashboard con datos mock (sin tocar ADO real).
// Uso: node test/demo-local.js  (puerto 8099)
process.env.PORT = process.env.PORT || '8099';
process.env.HOST = '127.0.0.1';
process.env.POLL_INTERVAL_MS = '999999999';

global.fetch = async () => ({ ok: true, status: 200, json: async () => ({}), text: async () => '' });

const ado = require('../src/ado');
const now = Date.now();
const iso = (minAgo) => new Date(now - minAgo * 60000).toISOString();

ado.getBuilds = async () => ([
  ado.normalizeBuild({ id: 20260921, definition: { name: 'pull-request-cherry-pick-buklo-frontend' }, buildNumber: '20260921.5', sourceBranch: 'refs/heads/main', sourceVersion: 'd08eedb1', status: 'completed', result: 'succeeded', requestedFor: { displayName: 'Edson Alvarez Obando' }, queueTime: iso(4), finishTime: iso(4) }),
  ado.normalizeBuild({ id: 20260922, definition: { name: 'Build-mod-ag-test-portal' }, buildNumber: '20260921.7', sourceBranch: 'refs/heads/uat', sourceVersion: '68b0b05a', status: 'inProgress', result: null, requestedFor: { displayName: 'Edson Alvarez Obando' }, queueTime: iso(7) }),
  ado.normalizeBuild({ id: 20260923, definition: { name: 'Buklo-frontend-portal-Build' }, buildNumber: '2.0.215', sourceBranch: 'refs/heads/uat', sourceVersion: '68b0b05a', status: 'completed', result: 'failed', requestedFor: { displayName: 'Edson Alvarez Obando' }, queueTime: iso(6), finishTime: iso(6) }),
]);
ado.getReleases = async () => ([
  ado.normalizeRelease({ id: 7396, releaseDefinition: { name: 'Deploy-Produccion-Buklo-Mcp-k3s-ado-query' }, name: 'Release-42', environments: [{ name: 'produccion', status: 'succeeded' }], createdBy: { displayName: 'Pablo Montero' }, createdOn: iso(12), modifiedOn: iso(9) }),
  ado.normalizeRelease({ id: 7397, releaseDefinition: { name: 'Deploy-cicd-dashboard' }, name: 'Release-1', environments: [{ name: 'produccion', status: 'inProgress' }], createdBy: { displayName: 'Pablo Montero' }, createdOn: iso(3), modifiedOn: iso(1) }),
]);

require('../src/server').start();
