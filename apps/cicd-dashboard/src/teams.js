'use strict';

/**
 * Notificador a Microsoft Teams vía webhook de Power Automate.
 * Replica el formato Adaptive Card 1.4 que ya usa el flujo n8n ScHmSyNcOrCh0001,
 * envuelto en { type:'message', attachments:[...] }.
 *
 * El webhook apunta al canal Notificaciones-DevOps (TEAMS_WEBHOOK_URL en env).
 */

const WEBHOOK = process.env.TEAMS_WEBHOOK_URL || '';

/**
 * Construye el sobre Adaptive Card estándar de Teams/Power Automate.
 * color: 'Good' (verde), 'Accent' (azul), 'Attention' (rojo), 'Warning' (amarillo)
 */
function buildCard({ title, statusLabel, color, lines }) {
  return {
    type: 'message',
    attachments: [
      {
        contentType: 'application/vnd.microsoft.card.adaptive',
        contentUrl: null,
        content: {
          $schema: 'http://adaptivecards.io/schemas/adaptive-card.json',
          type: 'AdaptiveCard',
          version: '1.4',
          body: [
            {
              type: 'TextBlock',
              size: 'Large',
              weight: 'Bolder',
              text: title,
              wrap: true,
              color,
            },
            {
              type: 'TextBlock',
              text: statusLabel,
              wrap: true,
              weight: 'Bolder',
              color,
            },
            { type: 'TextBlock', text: lines.join('\n\n'), wrap: true },
          ],
        },
      },
    ],
  };
}

/**
 * Tarjeta para un evento de BUILD (started | completed).
 * failureDetail: array [{task, issues:[...]}] opcional cuando result=failed.
 */
function buildBuildCard(build, phase, failureDetail) {
  const started = phase === 'started';
  const ok = build.result === 'succeeded' || build.result === 'partiallySucceeded';
  // Builds: verde (Good) para inicio y éxito, rojo (Attention) para error
  const color = (!started && !ok) ? 'Attention' : 'Good';

  let icon;
  let title;
  let statusLabel;
  if (started) {
    icon = '🟢';
    title = `${icon} Build iniciado – ${build.name}`;
    statusLabel = '🟢 Estado: En ejecución';
  } else if (ok) {
    icon = '🟢';
    title = `${icon} Build OK – ${build.name}`;
    statusLabel = '🟢 Estado: Éxito';
  } else {
    icon = '🔴';
    title = `${icon} Build ERROR – ${build.name}`;
    statusLabel = '🔴 Estado: Error';
  }

  const lines = [
    `**Pipeline:** ${build.name}`,
    `**Build:** ${build.buildNumber || build.id}`,
    `**Rama:** ${build.branch || 'N/D'}`,
    `**Commit:** ${build.commit || 'N/D'}`,
    `**Solicitado por:** ${build.requestedFor}`,
    `**Ver en Azure DevOps:** [${build.name}](${build.url})`,
  ];

  if (!started && !ok && Array.isArray(failureDetail) && failureDetail.length) {
    const errBlock = failureDetail
      .slice(0, 5)
      .map((f) => {
        const msgs = (f.issues || []).slice(0, 3).map((m) => String(m).slice(0, 500));
        return `• ${f.task}:\n${msgs.map((m) => '   ' + m).join('\n')}`;
      })
      .join('\n');
    lines.push(`**Error del log:**\n${errBlock}`);
  }

  return buildCard({ title, statusLabel, color, lines });
}

/**
 * Tarjeta para un evento de RELEASE (started | completed).
 * stage: nombre del stage; stageStatus: succeeded|rejected|inProgress...
 */
function buildReleaseCard(release, phase, stage, stageStatus) {
  const started = phase === 'started';
  const ok = stageStatus === 'succeeded';
  // Releases: azul (Accent) para inicio y éxito, rojo (Attention) para error
  const color = (!started && !ok) ? 'Attention' : 'Accent';

  let icon;
  let title;
  let statusLabel;
  if (started) {
    icon = '🔵';
    title = `${icon} Release iniciado – ${release.name}`;
    statusLabel = `🔵 Estado: Desplegando (${stage || 'stage'})`;
  } else if (ok) {
    icon = '🔵';
    title = `${icon} Release OK – ${release.name}`;
    statusLabel = `🔵 Estado: Éxito (${stage || 'stage'})`;
  } else {
    icon = '🔴';
    title = `${icon} Release ERROR – ${release.name}`;
    statusLabel = `🔴 Estado: Error (${stage || 'stage'})`;
  }

  const lines = [
    `**Release definition:** ${release.name}`,
    `**Release:** ${release.releaseName || release.id}`,
    `**Stage:** ${stage || 'N/D'} — ${stageStatus || 'N/D'}`,
    `**Creado por:** ${release.createdBy}`,
    `**Ver en Azure DevOps:** [${release.name}](${release.url})`,
  ];

  return buildCard({ title, statusLabel, color, lines });
}

/**
 * Postea una tarjeta al webhook de Teams. Devuelve {ok, status}.
 * No lanza si el webhook no está configurado: registra y sigue (el dashboard no debe caer por esto).
 */
async function postCard(card) {
  if (!WEBHOOK) {
    return { ok: false, status: 0, skipped: 'TEAMS_WEBHOOK_URL vacío' };
  }
  const res = await fetch(WEBHOOK, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify(card),
  });
  return { ok: res.ok, status: res.status };
}

module.exports = {
  buildCard,
  buildBuildCard,
  buildReleaseCard,
  postCard,
};
