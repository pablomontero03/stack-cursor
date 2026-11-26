'use strict';

const test = require('node:test');
const assert = require('node:assert');
const { detectEvents } = require('../src/detector');

function build(id, status, result) {
  return { kind: 'build', id, name: 'p' + id, status, result: result || null };
}
function release(id, stages) {
  return { kind: 'release', id, name: 'r' + id, stages };
}

test('primer snapshot no emite eventos (evita spam inicial)', () => {
  const cur = [build(1, 'completed', 'succeeded')];
  assert.deepStrictEqual(detectEvents([], cur), []);
});

test('build que arranca emite started', () => {
  const prev = [build(1, 'notStarted')];
  const cur = [build(1, 'inProgress')];
  const ev = detectEvents(prev, cur);
  assert.strictEqual(ev.length, 1);
  assert.strictEqual(ev[0].type, 'build');
  assert.strictEqual(ev[0].phase, 'started');
});

test('build que termina OK emite completed succeeded', () => {
  const prev = [build(1, 'inProgress')];
  const cur = [build(1, 'completed', 'succeeded')];
  const ev = detectEvents(prev, cur);
  assert.strictEqual(ev.length, 1);
  assert.strictEqual(ev[0].phase, 'completed');
  assert.strictEqual(ev[0].item.result, 'succeeded');
});

test('build que falla emite completed failed', () => {
  const prev = [build(1, 'inProgress')];
  const cur = [build(1, 'completed', 'failed')];
  const ev = detectEvents(prev, cur);
  assert.strictEqual(ev.length, 1);
  assert.strictEqual(ev[0].item.result, 'failed');
});

test('build sin cambios no re-emite', () => {
  const prev = [build(1, 'completed', 'succeeded')];
  const cur = [build(1, 'completed', 'succeeded')];
  assert.deepStrictEqual(detectEvents(prev, cur), []);
});

test('build que salta directo a completed (poll perdió el inProgress) emite completed una sola vez', () => {
  const prev = [build(1, 'notStarted')];
  const cur = [build(1, 'completed', 'succeeded')];
  const ev = detectEvents(prev, cur);
  assert.strictEqual(ev.length, 1);
  assert.strictEqual(ev[0].phase, 'completed');
});

test('release stage que arranca emite started', () => {
  const prev = [release(10, [{ name: 'produccion', status: 'notStarted' }])];
  const cur = [release(10, [{ name: 'produccion', status: 'inProgress' }])];
  const ev = detectEvents(prev, cur);
  assert.strictEqual(ev.length, 1);
  assert.strictEqual(ev[0].type, 'release');
  assert.strictEqual(ev[0].phase, 'started');
  assert.strictEqual(ev[0].stage, 'produccion');
});

test('release stage que succeeded emite completed', () => {
  const prev = [release(10, [{ name: 'produccion', status: 'inProgress' }])];
  const cur = [release(10, [{ name: 'produccion', status: 'succeeded' }])];
  const ev = detectEvents(prev, cur);
  assert.strictEqual(ev.length, 1);
  assert.strictEqual(ev[0].phase, 'completed');
  assert.strictEqual(ev[0].stageStatus, 'succeeded');
});

test('release stage rejected emite completed error', () => {
  const prev = [release(10, [{ name: 'produccion', status: 'inProgress' }])];
  const cur = [release(10, [{ name: 'produccion', status: 'rejected' }])];
  const ev = detectEvents(prev, cur);
  assert.strictEqual(ev.length, 1);
  assert.strictEqual(ev[0].stageStatus, 'rejected');
});

test('release terminal no re-emite en el siguiente poll', () => {
  const prev = [release(10, [{ name: 'produccion', status: 'succeeded' }])];
  const cur = [release(10, [{ name: 'produccion', status: 'succeeded' }])];
  assert.deepStrictEqual(detectEvents(prev, cur), []);
});

test('mezcla build+release emite ambos', () => {
  const prev = [build(1, 'inProgress'), release(10, [{ name: 'prod', status: 'inProgress' }])];
  const cur = [build(1, 'completed', 'succeeded'), release(10, [{ name: 'prod', status: 'succeeded' }])];
  const ev = detectEvents(prev, cur);
  assert.strictEqual(ev.length, 2);
});
