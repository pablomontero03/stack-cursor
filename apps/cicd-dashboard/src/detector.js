'use strict';

/**
 * Detector de transiciones de estado para builds y releases.
 * Función pura: recibe el snapshot previo y el actual, devuelve la lista de
 * eventos de notificación (started / completed) que hay que enviar a Teams.
 *
 * Regla:
 *  - Build pasa a inProgress y antes no existía o no estaba inProgress  -> started
 *  - Build pasa a completed y antes no estaba completed                 -> completed (ok/error segun result)
 *  - Release stage pasa a inProgress                                    -> started
 *  - Release stage pasa a succeeded|rejected|partiallySucceeded|canceled-> completed
 *
 * prevMap / curMap: Map<string, obj normalizado>. La key es `${kind}:${id}`.
 */

function indexById(items) {
  const m = new Map();
  for (const it of items) m.set(`${it.kind}:${it.id}`, it);
  return m;
}

function buildEvents(prevMap, builds) {
  const events = [];
  for (const b of builds) {
    const prev = prevMap.get(`build:${b.id}`);
    const wasInProgress = prev && prev.status === 'inProgress';
    const wasCompleted = prev && prev.status === 'completed';

    if (b.status === 'inProgress' && !wasInProgress && !wasCompleted) {
      events.push({ type: 'build', phase: 'started', item: b });
    }
    if (b.status === 'completed' && !wasCompleted) {
      events.push({ type: 'build', phase: 'completed', item: b });
    }
  }
  return events;
}

function stageStatusOf(prevRelease, stageName) {
  if (!prevRelease || !Array.isArray(prevRelease.stages)) return undefined;
  const s = prevRelease.stages.find((x) => x.name === stageName);
  return s ? s.status : undefined;
}

const RELEASE_TERMINAL = new Set([
  'succeeded',
  'rejected',
  'partiallySucceeded',
  'canceled',
]);

function releaseEvents(prevMap, releases) {
  const events = [];
  for (const r of releases) {
    const prev = prevMap.get(`release:${r.id}`);
    for (const stage of r.stages || []) {
      const before = stageStatusOf(prev, stage.name);
      if (stage.status === 'inProgress' && before !== 'inProgress' && !RELEASE_TERMINAL.has(before)) {
        events.push({ type: 'release', phase: 'started', item: r, stage: stage.name, stageStatus: stage.status });
      }
      if (RELEASE_TERMINAL.has(stage.status) && before !== stage.status) {
        events.push({ type: 'release', phase: 'completed', item: r, stage: stage.name, stageStatus: stage.status });
      }
    }
  }
  return events;
}

/**
 * Devuelve todos los eventos de notificación entre dos snapshots.
 * prevItems / curItems: arrays normalizados (mezcla de builds y releases).
 * En el primer arranque (prevItems vacío) NO emite nada (evita spam de estado inicial).
 */
function detectEvents(prevItems, curItems) {
  const prevMap = indexById(prevItems || []);
  if (!prevItems || prevItems.length === 0) {
    // primer snapshot: sembrar estado, no notificar
    return [];
  }
  const builds = curItems.filter((x) => x.kind === 'build');
  const releases = curItems.filter((x) => x.kind === 'release');
  return [...buildEvents(prevMap, builds), ...releaseEvents(prevMap, releases)];
}

module.exports = { detectEvents, indexById, buildEvents, releaseEvents };
