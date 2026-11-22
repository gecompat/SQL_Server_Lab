'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/app.js'), 'utf8');
const start = source.indexOf('let queueBatchId = ');
const end = source.indexOf('function renderActiveLabs(', start);
assert.ok(start >= 0 && end > start);

const handlers = new Map();
function element(tag) {
  return {
    tag, dataset: {}, attributes: {}, children: [], text: '',
    get childElementCount() { return this.children.length; },
    get textContent() { return this.text; },
    set textContent(value) { this.text = value; this.children = []; },
    append(child) { this.children.push(child); },
    replaceChildren() { this.children = []; },
    setAttribute(name, value) { this.attributes[name] = value; }
  };
}

const document = { addEventListener: (name, handler) => handlers.set(name, handler), createElement: element };
const queueElement = { innerHTML: 'previous rendering' };
const elements = new Map([
  ['#operation-queue', queueElement],
  ['#batch-overview-rows', element('tbody')],
  ['#batch-overview-table', element('table')],
  ['#batch-overview-status', element('p')]
]);
const requests = [];
const errors = [];
let refreshes = 0;
let resolveRequest;
const context = vm.createContext({
  document,
  $: selector => elements.get(selector) || {},
  statusClass: () => 'neutral',
  empty: message => message,
  escapeHtml: value => String(value).replaceAll('&', '&amp;').replaceAll('"', '&quot;'),
  sqlServerLabUiFetch(url, init) {
    requests.push({ url, method: init.method, ...JSON.parse(init.body) });
    return new Promise(resolve => { resolveRequest = resolve; });
  },
  refresh: async () => { refreshes++; },
  showError: error => errors.push(error.message)
});
vm.runInContext(source.slice(start, end), context);

const firstBatchId = 'batch-20261122170000-01234567';
const secondBatchId = 'batch-20261122170100-23456789';
const closedBatchId = 'batch-20261122170200-3456789a';
const first = { batchId: firstBatchId, operationId: 'operation-first', status: 'Queued', priority: 'Normal', queuePosition: 1 };
const second = { batchId: secondBatchId, operationId: 'operation-second', status: 'Paused', priority: 'Normal', queuePosition: 2 };
const waiting = [first, second];
const markup = item => context.renderOperationOrderingControls(item, waiting);

document.activeElement = { matches: selector => selector === '[data-operation-priority]' };
context.renderOperationQueue({ items: waiting }, true);
assert.equal(queueElement.innerHTML, 'previous rendering');
context.renderOperationQueue({ items: waiting });
assert.match(queueElement.innerHTML, /data-operation-priority/);
document.activeElement = null;
context.renderOperationQueue({ items: [] }, true);
assert.match(queueElement.innerHTML, /Keine offenen/);

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
  const batchRow = (BatchId, Status) => ({ BatchId, Status, Percent: 0, Total: 1, Failed: 0, Cancelled: 0 });
  context.workflow = {
    Queue: { items: waiting },
    Batches: [batchRow(firstBatchId, 'Queued'), batchRow(secondBatchId, 'Waiting'), batchRow(closedBatchId, 'Completed')]
  };
  context.renderBatchOverview(context.workflow.Batches, context.workflow.Queue);
  const rows = elements.get('#batch-overview-rows');
  const status = elements.get('#batch-overview-status');
  const filter = rows.children[0].children[0].children[0];
  assert.equal(filter.dataset.queueBatch, firstBatchId);
  assert.equal(filter.attributes['aria-pressed'], 'false');
  assert.equal(rows.children[2].children[0].childElementCount, 0);
  const clickFilter = button => handlers.get('click')({ target: { closest: selector => selector === '[data-queue-batch]' ? button : null } });
  await clickFilter(filter);
  assert.match(queueElement.innerHTML, /operation-first/);
  assert.doesNotMatch(queueElement.innerHTML, /operation-second/);
  assert.match(queueElement.innerHTML, /data-operation-command="MoveDown"/);
  assert.equal(rows.children[0].children[0].children[0].attributes['aria-pressed'], 'true');
  document.activeElement = { matches: selector => selector === '[data-queue-batch]' };
  context.renderBatchOverview([], { items: [] }, true);
  assert.equal(rows.childElementCount, 3);
  document.activeElement = null;
  context.renderOperationQueue({ items: [second] });
  assert.match(queueElement.innerHTML, /Keine offenen Vorgänge in diesem Batch/);
  await clickFilter(status.children[0]);
  assert.match(queueElement.innerHTML, /operation-second/);
  assert.equal(requests.length, 0);

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
