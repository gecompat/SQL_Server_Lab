'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/app.js'), 'utf8');
const start = source.indexOf('const operationPriorityLabels = ');
const end = source.indexOf('function renderActiveLabs(', start);
assert.ok(start >= 0 && end > start);

const handlers = new Map();
const requests = [];
const errors = [];
let refreshes = 0;
let resolveRequest;
const context = vm.createContext({
  document: { addEventListener: (name, handler) => handlers.set(name, handler) },
  escapeHtml: value => String(value).replaceAll('&', '&amp;').replaceAll('"', '&quot;'),
  sqlServerLabUiFetch(url, init) {
    requests.push({ url, method: init.method, ...JSON.parse(init.body) });
    return new Promise(resolve => { resolveRequest = resolve; });
  },
  refresh: async () => { refreshes++; },
  showError: error => errors.push(error.message)
});
vm.runInContext(source.slice(start, end), context);

const first = { operationId: 'operation-first', status: 'Queued', priority: 'Normal', queuePosition: 1 };
const second = { operationId: 'operation-second', status: 'Paused', priority: 'Normal', queuePosition: 2 };
const waiting = [first, second];
const markup = item => context.renderOperationOrderingControls(item, waiting);

assert.match(markup(first), /data-operation-command="MoveDown"/);
assert.doesNotMatch(markup(first), /data-operation-command="MoveUp"/);
assert.match(markup(second), /data-operation-command="MoveUp"/);
const samePosition = { ...second, queuePosition: first.queuePosition };
assert.match(context.renderOperationOrderingControls(first, [first, samePosition]), /data-operation-command="MoveDown"/);
assert.match(context.renderOperationOrderingControls(samePosition, [first, samePosition]), /data-operation-command="MoveUp"/);
assert.match(markup(second), /<option value="Normal" selected>Normal<\/option>/);
assert.equal(markup({ ...first, status: 'Running' }), '');
assert.equal(context.renderOperationOrderingControls(first, [first]), '');
assert.doesNotMatch(context.renderOperationOrderingControls(first, [first, { ...second, priority: 'Low' }]), /Move(?:Up|Down)/);
assert.match(markup({ ...first, operationId: 'id"quoted' }), /data-operation-priority="id&quot;quoted"/);

(async () => {
  const select = { dataset: { operationPriority: first.operationId, currentPriority: 'Normal' }, value: 'Normal' };
  const change = () => handlers.get('change')({ target: { closest: () => select } });
  await change();
  select.value = 'Bogus';
  await change();
  assert.equal(requests.length, 0);

  select.value = 'High';
  const changePending = change();
  assert.equal(select.disabled, true);
  assert.match(markup(first), /data-current-priority="Normal" disabled/);
  await assert.rejects(context.runOperationCommand(first.operationId, 'MoveDown'), /bereits geändert/);
  assert.deepEqual(requests, [{ url: '/api/operations', method: 'POST', operationId: first.operationId, command: 'PriorityHigh' }]);
  resolveRequest({ ok: true });
  await changePending;
  assert.equal(refreshes, 1);
  assert.equal(select.disabled, false);

  select.value = 'Low';
  const changeRejected = change();
  resolveRequest({ ok: false, text: async () => 'SYNTHETIC_REJECTION' });
  await changeRejected;
  assert.equal(select.value, 'Normal');
  assert.equal(select.disabled, false);
  assert.deepEqual(errors, ['SYNTHETIC_REJECTION']);

  const movePending = context.runOperationCommand(first.operationId, 'MoveDown');
  resolveRequest({ ok: true });
  await movePending;
  assert.equal(requests.at(-1).command, 'MoveDown');
  console.log('OPERATION ORDERING UI: PASS');
})().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
