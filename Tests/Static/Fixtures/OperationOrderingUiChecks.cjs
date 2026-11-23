'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const uiRoot = path.resolve(__dirname, '../../../Ui');
const source = fs.readFileSync(path.join(uiRoot, 'app.js'), 'utf8');
const queueSource = fs.readFileSync(path.join(uiRoot, 'operation-queue.js'), 'utf8');
const html = fs.readFileSync(path.join(uiRoot, 'index.html'), 'utf8');
assert.match(html, /<script src="operation-queue\.js"><\/script>\s+<script src="app\.js"><\/script>/);
assert.match(html, /id="operation-host-start" type="button"/);
assert.match(html, /<button type="button"[^>]*data-confirmation-cancel>Abbrechen<\/button>/);

const handlers = new Map();
let completed = false;
process.once('beforeExit', () => {
  if (!completed && !process.exitCode) {
    console.error('OPERATION ORDERING UI did not complete its assertions');
    process.exitCode = 1;
  }
});
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

const browserDraftForm = {
  elements: { batchName: { value: '  Mixed draft  ' }, priority: { value: 'High' } },
  addEventListener: (name, handler) => handlers.set('batch-draft-' + name, handler),
  reset() { this.resetCalled = true; }
};
const document = {
  addEventListener: (name, handler) => handlers.set(name, handler),
  createElement: element,
  getElementById: id => id === 'batch-draft-form' ? browserDraftForm : null
};
const queueElement = { innerHTML: 'previous rendering' };
const confirmationDialog = {
  id: 'confirmation-dialog', open: true, querySelectorAll: () => [],
  close() { this.open = false; }
};
const elements = new Map([
  ['#confirmation-form', { addEventListener: (name, handler) => handlers.set(name, handler) }],
  ['#confirmation-dialog', confirmationDialog],
  ['#notice', element('p')],
  ['#operation-host-start', element('button')],
  ['#batch-draft-status', element('p')],
  ['#batch-draft-positions', element('div')],
  ['#operation-queue', queueElement],
  ['#batch-overview-rows', element('tbody')],
  ['#batch-overview-table', element('table')],
  ['#batch-overview-status', element('p')]
]);
const requests = [];
const errors = [];
const confirmations = [];
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
  openConfirmation: (_, message, action, parameters) => confirmations.push({ message, action, parameters }),
  showError: error => errors.push(error.message)
});
vm.runInContext(queueSource, context);
const cancelStart = source.indexOf('function cancelDialog(');
const cancelEnd = source.indexOf("document.addEventListener('click',", cancelStart);
assert.ok(cancelStart >= 0 && cancelEnd > cancelStart);
vm.runInContext(source.slice(cancelStart, cancelEnd), context);
const submitStart = source.indexOf("$('#confirmation-form').addEventListener");
const submitEnd = source.indexOf("$('#artifact-name-form').addEventListener", submitStart);
assert.ok(submitStart >= 0 && submitEnd > submitStart);
vm.runInContext(source.slice(submitStart, submitEnd), context);

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
  const rollback = rows.children[2].children[0].children[0];
  assert.equal(rollback.dataset.batchRollback, closedBatchId);
  const clickFilter = button => handlers.get('click')({ target: { closest: selector => selector === '[data-queue-batch]' ? button : null } });
  await clickFilter(filter);
  assert.match(queueElement.innerHTML, /operation-first/);
  assert.doesNotMatch(queueElement.innerHTML, /operation-second/);
  assert.match(queueElement.innerHTML, /data-operation-command="MoveDown"/);
  assert.equal(rows.children[0].children[0].children[0].attributes['aria-pressed'], 'true');
  document.activeElement = { matches: selector => selector.includes('[data-queue-batch]') };
  context.renderBatchOverview([], { items: [] }, true);
  assert.equal(rows.childElementCount, 3);
  document.activeElement = null;
  context.renderOperationQueue({ items: [second] });
  assert.match(queueElement.innerHTML, /Keine offenen Vorgänge in diesem Batch/);
  await clickFilter(status.children[0]);
  assert.match(queueElement.innerHTML, /operation-second/);
  assert.equal(requests.length, 0);

  const select = { dataset: { operationPriority: first.operationId, currentPriority: 'Normal' }, value: 'Normal' };
  const change = () => handlers.get('change')({ target: {
    closest: selector => selector === '[data-operation-priority]' ? select : null
  } });
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

  const stopButton = rows.children[0].children[0].children[1];
  assert.equal(stopButton.dataset.batchStop, firstBatchId);
  const startStop = handlers.get('click')({ target: { closest: selector => selector === '[data-batch-stop]' ? stopButton : null } });
  assert.equal(stopButton.disabled, true);
  assert.deepEqual(requests.at(-1), { url: '/api/operations', method: 'POST', command: 'BatchStopPreview', batchId: firstBatchId });

  const previewId = '1'.repeat(32);
  resolveRequest({ ok: true, json: async () => ({ BatchId: firstBatchId, PreviewId: previewId, Pending: 2, Running: 1 }) });
  await startStop;
  assert.equal(stopButton.disabled, false);
  assert.equal(confirmations.length, 1);
  assert.equal(confirmations[0].action, '__BatchStop');
  assert.match(confirmations[0].message, /2 unfertige Positionen, davon 1 laufend/);
  assert.ok(!requests.some(request => request.command === 'BatchStopApply'));

  context.pendingConfirmation = confirmations[0];
  const submit = handlers.get('submit')({ preventDefault() {} });
  assert.deepEqual(requests.at(-1), { url: '/api/operations', method: 'POST', command: 'BatchStopApply', batchId: firstBatchId, previewId, confirmed: true });
  resolveRequest({ ok: true, json: async () => ({ BatchId: firstBatchId, Requested: 2 }) });
  await submit;
  assert.equal(context.pendingConfirmation, null);
  assert.match(elements.get('#notice').textContent, /Stopp für 2 Positionen angenommen/);

  const prepareRollback = handlers.get('click')({ target: { closest: selector => selector === '[data-batch-rollback]' ? rollback : null } });
  assert.deepEqual(requests.at(-1), { url: '/api/operations', method: 'POST', command: 'BatchRollbackPreview', batchId: closedBatchId });
  resolveRequest({ ok: true, json: async () => ({ BatchId: closedBatchId, PreviewId: previewId, Pending: 1, Running: 0, Finished: 1 }) });
  await prepareRollback;
  context.pendingConfirmation = confirmations.at(-1);
  assert.match(context.pendingConfirmation.message, /Ressourcen fertiger Positionen entfernen/);
  const applyRollback = handlers.get('submit')({ preventDefault() {} });
  assert.deepEqual(requests.at(-1), { url: '/api/operations', method: 'POST', command: 'BatchRollbackApply', batchId: closedBatchId, previewId, confirmed: true });
  resolveRequest({ ok: true, json: async () => ({ BatchId: closedBatchId, Requested: 1 }) });
  await applyRollback;
  assert.match(elements.get('#notice').textContent, /Rückbau für 1 Positionen angenommen/);

  const schedulerButton = elements.get('#operation-host-start');
  const clickScheduler = () => handlers.get('click')({ target: {
    closest: selector => selector === '#operation-host-start' ? schedulerButton : null
  } });
  const countBeforeScheduler = requests.length;
  await clickScheduler();
  const schedulerConfirmation = confirmations.at(-1);
  assert.equal(schedulerConfirmation.action, '__StartOperationHost');
  assert.match(schedulerConfirmation.message, /alle freigegebenen Vorgänge/);
  context.pendingConfirmation = schedulerConfirmation;
  confirmationDialog.open = true;
  context.cancelDialog(confirmationDialog);
  assert.equal(context.pendingConfirmation, null);
  assert.equal(confirmationDialog.open, false);
  assert.equal(requests.length, countBeforeScheduler);

  context.pendingConfirmation = schedulerConfirmation;
  const requestScheduler = handlers.get('submit')({ preventDefault() {} });
  assert.equal(schedulerButton.disabled, true);
  assert.deepEqual(requests.at(-1), { url: '/api/operations', method: 'POST', command: 'StartOperationHost', confirmed: true });
  await clickScheduler();
  assert.equal(confirmations.at(-1), schedulerConfirmation);
  resolveRequest({ ok: true, json: async () => ({ state: 'Requested' }) });
  await requestScheduler;
  assert.equal(schedulerButton.disabled, false);
  assert.match(elements.get('#notice').textContent, /^Scheduler angefordert/);
  assert.equal(requests.length, countBeforeScheduler + 1);

  const syntheticPosition = values => ({ querySelector: selector => {
    const [, name] = /^\[name="([^"]+)"\]$/.exec(selector) || [];
    return name ? { value: values[name] } : {};
  } });
  const positions = elements.get('#batch-draft-positions');
  positions.append(syntheticPosition({
    kind: 'SqlEnvironment', environmentName: 'sql-browser', count: '2', version: '2025',
    provider: 'podman', secretReference: 'SQL_SERVER_LAB_SECRET_BROWSER_DRAFT_TEST'
  }));
  positions.append(syntheticPosition({
    kind: 'WindowsEnvironment', environmentName: 'win-browser', count: '1',
    operatingSystem: 'Windows Server 2025', variant: 'Desktop', cpu: '4', memoryMB: '8192'
  }));
  const draftTemplate = { cloneNode: () => syntheticPosition({ kind: 'SqlEnvironment' }) };
  elements.set('#batch-draft-position', { content: { firstElementChild: draftTemplate } });
  const save = handlers.get('batch-draft-submit')({ currentTarget: browserDraftForm, preventDefault() {} });
  assert.deepEqual(requests.at(-1), {
    url: '/api/batches', method: 'POST', command: 'SaveGuidedDraft', name: 'Mixed draft', priority: 'High',
    items: [
      { kind: 'SqlEnvironment', name: 'sql-browser', count: 2, version: '2025', provider: 'podman',
        secretReference: 'SQL_SERVER_LAB_SECRET_BROWSER_DRAFT_TEST' },
      { kind: 'WindowsEnvironment', name: 'win-browser', count: 1, operatingSystem: 'Windows Server 2025',
        variant: 'Desktop', cpu: 4, memoryMB: 8192 }
    ]
  });
  assert.equal(browserDraftForm.inert, true);
  resolveRequest({ ok: true, status: 201, json: async () =>
    ({ BatchId: firstBatchId, Status: 'Validated', Positions: 3, Dependencies: 1 }) });
  await save;
  assert.equal(browserDraftForm.inert, false);
  assert.equal(browserDraftForm.resetCalled, true);
  assert.match(elements.get('#batch-draft-status').textContent, /gespeichert · 3 Umgebungen · 1 gemeinsame Abhängigkeiten/);
  assert.equal(positions.childElementCount, 1);

  context.renderBatchOverview([batchRow(firstBatchId, 'Validated')], context.workflow.Queue);
  const submitDraft = rows.children[0].children[0].children[1];
  assert.equal(submitDraft.dataset.batchSubmit, firstBatchId);
  const beginDraftSubmit = handlers.get('click')({ target: {
    closest: selector => selector === '[data-batch-submit]' ? submitDraft : null
  } });
  assert.deepEqual(requests.at(-1), { url: '/api/operations', method: 'POST', command: 'BatchSubmitPreview', batchId: firstBatchId });
  resolveRequest({ ok: true, json: async () =>
    ({ BatchId: firstBatchId, PreviewId: previewId, Positions: 3, Docker: 2, Podman: 0, HyperV: 1, Dependencies: 1 }) });
  await beginDraftSubmit;
  assert.equal(confirmations.at(-1).action, '__BatchSubmit');
  assert.match(confirmations.at(-1).message, /Docker 2, Podman 0, Hyper-V 1/);
  assert.ok(!requests.some(request => request.command === 'BatchSubmitApply'));
  context.pendingConfirmation = confirmations.at(-1);
  const applyDraft = handlers.get('submit')({ preventDefault() {} });
  assert.deepEqual(requests.at(-1), {
    url: '/api/operations', method: 'POST', command: 'BatchSubmitApply', batchId: firstBatchId, previewId, confirmed: true
  });
  resolveRequest({ ok: true, json: async () => ({ BatchId: firstBatchId, Status: 'Queued' }) });
  await applyDraft;
  assert.match(elements.get('#notice').textContent, /^Batch eingereiht/);

  completed = true;
  console.log('OPERATION ORDERING UI: PASS');
})().catch(error => {
  console.error(error.message);
  process.exitCode = 1;
});
