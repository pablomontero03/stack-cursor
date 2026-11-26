'use strict';

/**
 * Cliente REST de Azure DevOps para el dashboard CI/CD.
 * Solo lectura: consulta Builds y Releases del proyecto configurado.
 * El PAT vive en el proceso (env), nunca se expone al navegador.
 */

const ORG = process.env.AZURE_DEVOPS_ORG || 'Shared-Service-GM';
const PROJECT = process.env.AZURE_DEVOPS_PROJECT || 'DevOps';
const PAT = process.env.AZURE_DEVOPS_PAT || '';

const BASE = `https://dev.azure.com/${encodeURIComponent(ORG)}/${encodeURIComponent(PROJECT)}`;
const VSRM = `https://vsrm.dev.azure.com/${encodeURIComponent(ORG)}/${encodeURIComponent(PROJECT)}`;

function authHeader() {
  // Basic con usuario vacío + PAT (patrón estándar de ADO).
  const token = Buffer.from(`:${PAT}`).toString('base64');
  return `Basic ${token}`;
}

async function adoGet(url) {
  const res = await fetch(url, {
    headers: { Authorization: authHeader(), Accept: 'application/json' },
  });
  if (!res.ok) {
    const body = await res.text().catch(() => '');
    throw new Error(`ADO GET ${res.status} ${res.statusText} :: ${body.slice(0, 300)}`);
  }
  return res.json();
}

/**
 * Deep link a un Build run en la UI de ADO.
 */
function buildWebUrl(buildId) {
  return `${BASE}/_build/results?buildId=${buildId}&view=results`;
}

/**
 * Deep link a un Release en la UI de ADO.
 */
function releaseWebUrl(releaseId) {
  return `${BASE}/_release?releaseId=${releaseId}&_a=release-summary`;
}

/**
 * Normaliza un Build de la API al shape que consume el front.
 */
function normalizeBuild(b) {
  return {
    kind: 'build',
    id: b.id,
    name: (b.definition && b.definition.name) || 'build',
    buildNumber: b.buildNumber || '',
    branch: (b.sourceBranch || '').replace('refs/heads/', ''),
    commit: (b.sourceVersion || '').slice(0, 8),
    status: b.status || '',            // notStarted | inProgress | completed | cancelling | postponed
    result: b.result || null,          // succeeded | partiallySucceeded | failed | canceled | null
    requestedFor:
      (b.requestedFor && (b.requestedFor.displayName || b.requestedFor.uniqueName)) || 'N/D',
    queueTime: b.queueTime || null,
    startTime: b.startTime || null,
    finishTime: b.finishTime || null,
    url: buildWebUrl(b.id),
  };
}

/**
 * Normaliza una instancia de Release al shape del front.
 */
function normalizeRelease(r) {
  const envs = Array.isArray(r.environments) ? r.environments : [];
  const stages = envs.map((e) => ({
    name: e.name,
    status: e.status, // notStarted | inProgress | succeeded | rejected | canceled | partiallySucceeded
  }));

  // Derive a top-level status from stages (mirrors build status for uniform UI treatment)
  let status = 'notStarted';
  const stageStatuses = stages.map((s) => s.status);
  if (stageStatuses.some((s) => s === 'inProgress')) status = 'inProgress';
  else if (stageStatuses.some((s) => s === 'rejected' || s === 'canceled')) status = 'completed';
  else if (stageStatuses.every((s) => s === 'succeeded' || s === 'partiallySucceeded')) status = 'completed';
  else if (stageStatuses.some((s) => s === 'succeeded' || s === 'partiallySucceeded')) status = 'inProgress';

  // Derive result from stages
  let result = null;
  if (status === 'completed') {
    if (stageStatuses.some((s) => s === 'rejected')) result = 'failed';
    else if (stageStatuses.some((s) => s === 'canceled')) result = 'canceled';
    else if (stageStatuses.every((s) => s === 'succeeded')) result = 'succeeded';
    else result = 'partiallySucceeded';
  }

  return {
    kind: 'release',
    id: r.id,
    name: (r.releaseDefinition && r.releaseDefinition.name) || r.name || 'release',
    releaseName: r.name || '',
    status,
    result,
    createdOn: r.createdOn || null,
    modifiedOn: r.modifiedOn || null,
    createdBy:
      (r.createdBy && (r.createdBy.displayName || r.createdBy.uniqueName)) || 'N/D',
    stages,
    url: releaseWebUrl(r.id),
  };
}

/**
 * Trae los últimos N builds del proyecto.
 */
async function getBuilds(top = 30) {
  const url = `${BASE}/_apis/build/builds?$top=${top}&queryOrder=queueTimeDescending&api-version=7.1`;
  const data = await adoGet(url);
  return (data.value || []).map(normalizeBuild);
}

/**
 * Trae los últimos N releases del proyecto (con environments expandidos).
 */
async function getReleases(top = 30) {
  const url = `${VSRM}/_apis/release/releases?$top=${top}&$expand=environments&api-version=7.1`;
  const data = await adoGet(url);
  return (data.value || []).map(normalizeRelease);
}

/**
 * Timeline de un build: para extraer el error del log cuando falla.
 * Devuelve las tareas con result=failed y su issue/log breve.
 */
async function getBuildFailureDetail(buildId) {
  const url = `${BASE}/_apis/build/builds/${buildId}/timeline?api-version=7.1`;
  const data = await adoGet(url);
  const records = Array.isArray(data.records) ? data.records : [];
  const failed = records
    .filter((r) => r.result === 'failed' && r.type === 'Task')
    .map((r) => {
      const issues = Array.isArray(r.issues)
        ? r.issues
            .filter((i) => i.type === 'error')
            .map((i) => i.message)
            .filter(Boolean)
        : [];
      return { task: r.name, issues };
    })
    .filter((x) => x.issues.length > 0);
  return failed;
}

/**
 * Trae las aprobaciones de release pendientes (estado = pending).
 */
async function getPendingApprovals() {
  const url = `${VSRM}/_apis/release/approvals?statusFilter=pending&api-version=7.1`;
  const data = await adoGet(url);
  return (data.value || []).map((a) => ({
    approvalId:  a.id,
    releaseId:   a.release && a.release.id,
    releaseName: a.release && a.release.name,
    definitionName: a.releaseDefinition && a.releaseDefinition.name,
    stageName:   a.releaseEnvironment && a.releaseEnvironment.name,
    approvalType: a.approvalType,   // preDeploy | postDeploy
    approvedBy:  a.approver && (a.approver.displayName || a.approver.uniqueName),
    createdOn:   a.createdOn,
    url: `${VSRM.replace('vsrm.', 'dev.')}/_release?releaseId=${a.release && a.release.id}&_a=release-summary`,
  }));
}

/**
 * Aprueba o rechaza una aprobación de release.
 * action: 'approved' | 'rejected'
 */
async function patchApproval(approvalId, action, comment) {
  const url = `${VSRM}/_apis/release/approvals/${approvalId}?api-version=7.1`;
  const body = JSON.stringify({ status: action, comments: comment || '' });
  const res = await fetch(url, {
    method: 'PATCH',
    headers: {
      Authorization: authHeader(),
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body,
  });
  if (!res.ok) {
    const b = await res.text().catch(() => '');
    throw new Error(`PATCH approval ${res.status} ${res.statusText} :: ${b.slice(0, 300)}`);
  }
  return res.json();
}

/**
 * Pull Requests activos en TODA la organización donde el usuario
 * o Release Executers es reviewer. Usa el endpoint a nivel de org.
 */
async function getPendingPRs(reviewerIdentity) {
  const BASE_ORG = `https://dev.azure.com/${encodeURIComponent(ORG)}`;
  let url = `${BASE_ORG}/_apis/git/pullrequests?searchCriteria.status=active&$top=200&api-version=7.1`;
  if (reviewerIdentity) {
    url += `&searchCriteria.reviewerId=${encodeURIComponent(reviewerIdentity)}`;
  }
  const data = await adoGet(url);
  return (data.value || []).map((pr) => ({
    pullRequestId: pr.pullRequestId,
    repoId: pr.repository && pr.repository.id,
    repoName: pr.repository && pr.repository.name,
    projectName: pr.repository && pr.repository.project && pr.repository.project.name,
    title: pr.title || '',
    sourceBranch: (pr.sourceRefName || '').replace('refs/heads/', ''),
    targetBranch: (pr.targetRefName || '').replace('refs/heads/', ''),
    status: pr.status || 'active',
    isDraft: pr.isDraft || false,
    createdBy: (pr.createdBy && (pr.createdBy.displayName || pr.createdBy.uniqueName)) || 'N/D',
    creationDate: pr.creationDate || null,
    reviewers: (pr.reviewers || []).map((r) => ({
      id: r.id,
      displayName: r.displayName || '',
      vote: r.vote || 0,         // 10=aprobado, 5=aprobado con sugerencias, 0=sin voto, -5=esperando, -10=rechazado
      isRequired: r.isRequired || false,
    })),
    url: `https://dev.azure.com/${encodeURIComponent(ORG)}/${encodeURIComponent((pr.repository && pr.repository.project && pr.repository.project.name) || PROJECT)}/_git/${encodeURIComponent((pr.repository && pr.repository.name) || '')}/pullrequest/${pr.pullRequestId}`,
  }));
}

/**
 * Vota en un Pull Request.
 * vote: 10 (aprobado) | -10 (rechazado) | 0 (reset)
 * projectName: the ADO project that owns the repo (e.g. 'CORE-PLT', 'Buklo')
 */
async function patchPRVote(repoId, pullRequestId, vote, reviewerId, projectName) {
  const proj = projectName || PROJECT;
  const base = `https://dev.azure.com/${encodeURIComponent(ORG)}/${encodeURIComponent(proj)}`;
  const url = `${base}/_apis/git/repositories/${encodeURIComponent(repoId)}/pullrequests/${pullRequestId}/reviewers/${encodeURIComponent(reviewerId)}?api-version=7.1`;
  const body = JSON.stringify({ vote, isFlagged: false, hasDeclined: vote === -10 });
  const res = await fetch(url, {
    method: 'PUT',
    headers: {
      Authorization: authHeader(),
      'Content-Type': 'application/json',
      Accept: 'application/json',
    },
    body,
  });
  if (!res.ok) {
    const b = await res.text().catch(() => '');
    throw new Error(`PATCH PR vote ${res.status} ${res.statusText} :: ${b.slice(0, 300)}`);
  }
  return res.json();
}

/**
 * Ensure a user identity is in the PR reviewer list (idempotent PUT).
 * ADO requires the individual user to be listed as reviewer before they can cast a vote.
 * projectName: the ADO project that owns the repo
 */
async function ensurePRReviewer(repoId, pullRequestId, reviewerId, projectName) {
  const proj = projectName || PROJECT;
  const base = `https://dev.azure.com/${encodeURIComponent(ORG)}/${encodeURIComponent(proj)}`;
  const url = `${base}/_apis/git/repositories/${encodeURIComponent(repoId)}/pullrequests/${pullRequestId}/reviewers/${encodeURIComponent(reviewerId)}?api-version=7.1`;
  const body = JSON.stringify({ vote: 0, isFlagged: false });
  const res = await fetch(url, {
    method: 'PUT',
    headers: { Authorization: authHeader(), 'Content-Type': 'application/json' },
    body,
  });
  if (!res.ok) {
    const b = await res.text();
    throw new Error(`ensurePRReviewer ${res.status} ${res.statusText} :: ${b.slice(0, 300)}`);
  }
}

module.exports = {
  ORG,
  PROJECT,
  BASE,
  VSRM,
  authHeader,
  adoGet,
  buildWebUrl,
  releaseWebUrl,
  normalizeBuild,
  normalizeRelease,
  getBuilds,
  getReleases,
  getBuildFailureDetail,
  getPendingApprovals,
  patchApproval,
  getPendingPRs,
  patchPRVote,
  ensurePRReviewer,
};
