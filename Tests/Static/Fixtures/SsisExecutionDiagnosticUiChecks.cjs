'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../../..');
const source = fs.readFileSync(path.join(root, 'Ui/ssis-execution-diagnostic.js'), 'utf8');
const elements = new Map();
const inputs = { RunId: '11111111-1111-1111-1111-111111111111', InstanceId: 'primary',
  ExecutionId: '9007199254740993', ProjectLsn: '9007199254740995', CatalogDatabaseGuid: '22222222-2222-2222-2222-222222222222' };
function element(id) {
  if (!elements.has(id)) elements.set(id, {
    disabled: false, open: false, textContent: '', reset() {},
    elements: { namedItem: field => ({ value: inputs[field] }) },
    addEventListener(event, callback) { this[event] = callback; },
    showModal() { this.open = true; },
    closeDialog() { this.open = false; this.close(); },
  });
  return elements.get(id);
}
let calls = 0;
let capabilityCalls = 0;
let capabilityClick;
const browserWindow = {};
let capabilityView = {
  Status: 'READY_FOR_FIXTURE_IMPLEMENTATION', Reason: 'NONE', Sql: 'SQL_2025_OBSERVED',
  Components: 'OBSERVED', Catalog: 'ONLINE_CATALOG_OBSERVED',
};
let result = Promise.resolve({ Status: 'OBSERVED', Reason: 'NONE', ExecutionStatus: 7, Worker: 'NOT_REPORTED', ErrorCodes: [] });
vm.runInNewContext(source, {
  window: browserWindow,
  document: { getElementById: element, addEventListener: (name, callback) => {
    assert.equal(name, 'click');
    capabilityClick = callback;
  } },
  escapeHtml: value => value.replaceAll('"','&quot;').replaceAll('<','&lt;'),
  async sqlServerLabUiFetch(url, options) {
    if (url === '/api/ssis-catalog-capability') {
      assert.equal(options.method, 'POST');
      assert.deepEqual(JSON.parse(options.body), { RunId: inputs.RunId, InstanceId: 'primary' });
      capabilityCalls++;
      return { ok: true, json: async () => capabilityView };
    }
    assert.equal(url, '/api/ssis-execution-diagnostic');
    assert.equal(options.method, 'POST');
    assert.deepEqual(JSON.parse(options.body), inputs);
    calls++;
    return { ok: true, json: () => result };
  },
});
(async () => {
  const click = element('ssis-execution-open').click;
  const form = element('ssis-execution-form');
  const status = element('ssis-execution-status');
  const event = { preventDefault() {} };
  click();
  assert.equal(calls, 0);
  const pending = form.submit(event);
  await form.submit(event);
  await pending;
  assert.equal(calls, 1);
  assert.match(status.textContent, /Katalogstatus 7/);
  let complete;
  result = new Promise(resolve => { complete = resolve; });
  const late = form.submit(event);
  await Promise.resolve();
  element('ssis-execution-dialog').closeDialog();
  complete({ Status: 'OBSERVED', Reason: 'NONE', ExecutionStatus: 4, Worker: 'NOT_REPORTED', ErrorCodes: [] });
  await late;
  assert.equal(status.textContent, '');
  click();
  result = Promise.resolve({ Status: 'OBSERVED', Reason: 'PRIVATE_CANARY', ExecutionStatus: 7, Worker: 'NOT_REPORTED', ErrorCodes: [] });
  await form.submit(event);
  assert.match(status.textContent, /fehlgeschlagen/);
  assert.doesNotMatch(status.textContent, /PRIVATE_CANARY/);
  const render = browserWindow.sqlServerLabSsisCapability.renderAction;
  const item = { RunId: inputs.RunId, InstanceId: 'primary', SqlVersion: 2025, Name: '<fixture"' };
  assert.equal(render(item, false), '');
  assert.equal(render({ ...item, InstanceId: '" private' }, true), '');
  assert.match(render(item, true), /&lt;fixture&quot;/);
  capabilityClick({ target: { closest: () => ({ dataset: { run: item.RunId, instance: 'primary', labName: item.Name } }) } });
  assert.equal(capabilityCalls, 0);
  assert.equal(element('ssis-capability-target').textContent, '<fixture" / primary');
  const capabilityForm = element('ssis-capability-form');
  const capabilityStatus = element('ssis-capability-status');
  const readPending = capabilityForm.submit(event);
  await capabilityForm.submit(event);
  await readPending;
  assert.equal(capabilityCalls, 1);
  assert.match(capabilityStatus.textContent, /SSISDB-Katalog online/);
  capabilityView = { ...capabilityView, Reason: 'PRIVATE_CANARY' };
  await capabilityForm.submit(event);
  assert.match(capabilityStatus.textContent, /konnten nicht gelesen werden/);
  assert.doesNotMatch(capabilityStatus.textContent, /PRIVATE_CANARY/);
  element('ssis-capability-dialog').closeDialog();
  await capabilityForm.submit(event);
  assert.equal(capabilityCalls, 2);
  const trusted = { checked: false };
  const packageElements = new Map();
  const packageValues = { RunId: inputs.RunId, InstanceId: 'primary', PackagePath: '/private/secret-name.dtsx',
    PackageName: '', ExpectedSha256: 'A'.repeat(64) };
  let packageCalls = 0;
  let resets = 0;
  const packageElement = id => {
    if (!packageElements.has(id)) packageElements.set(id, {
      disabled: false, open: false, textContent: '', reset() { trusted.checked = false; resets++; },
      elements: { namedItem: field => field === 'TrustConfirmed' ? trusted : { value: packageValues[field] } },
      addEventListener(event, callback) { this[event] = callback; },
      showModal() { this.open = true; },
    });
    return packageElements.get(id);
  };
  const packageSource = fs.readFileSync(path.join(root, 'Ui/ssis-package-diagnostic.js'), 'utf8');
  vm.runInNewContext(packageSource, {
    document: { getElementById: packageElement },
    sqlServerLabUiFetch(url, options) {
      assert.equal(url, '/api/ssis-package-diagnostic');
      assert.deepEqual(JSON.parse(options.body), { ...packageValues, TrustConfirmed: true });
      assert.equal(trusted.checked, false);
      assert.equal(resets, 2);
      packageCalls++;
      return { ok: true, json: async () => ({ Status: 'LOAD_FAILED', LoadStatus: 'FAILED', EventCodes: [123] }) };
    },
  });
  packageElement('ssis-package-open').click();
  await packageElement('ssis-package-form').submit(event);
  assert.equal(packageCalls, 0);
  trusted.checked = true;
  await packageElement('ssis-package-form').submit(event);
  assert.equal(packageCalls, 1);
  assert.match(packageElement('ssis-package-status').textContent, /Paketladung fehlgeschlagen · Ereigniscodes 123/);
  assert.doesNotMatch(packageElement('ssis-package-status').textContent, /secret-name/);
  console.log('SSIS DIAGNOSTICS BROWSER UI: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
