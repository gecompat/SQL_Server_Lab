'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const items = new Map();
function item(id) {
  if (!items.has(id)) items.set(id, {
    addEventListener(event, handler) { this[event] = handler; },
    showModal() { this.open = true; }, close() { this.open = false; }
  });
  return items.get(id);
}
const pending = [];
vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, '../../../Ui/runtime-maintenance-preview.js'), 'utf8'), {
  document: { getElementById: item },
  sqlServerLabUiFetch(url, init) {
    assert.equal(url, '/api/runtime-maintenance-preview');
    assert.equal(init.method, undefined);
    return new Promise(resolve => pending.push(resolve));
  }
});
const el = id => item('runtime-maintenance-preview-' + id);
const value = {
  ContractVersion: 'SqlServerLab.RuntimeMaintenancePreview/1.0',
  Status: 'UNVERIFIABLE',
  Providers: [
    { Provider: 'docker', Status: 'AVAILABLE' }, { Provider: 'podman', Status: 'UNAVAILABLE' },
    { Provider: 'hyperv', Status: 'NOT_INSTALLED' }
  ],
  Summary: { Actions: 2, SafeAutomatic: 1, ScopedCleanup: 1, LegacyApproval: 0, ReviewOnly: 0 }
};
const respond = data => ({ ok: true, json: async () => data });
(async () => {
  el('open').click();
  assert.equal(pending.length, 0);
  const first = el('read').click();
  await el('read').click();
  assert.equal(pending.length, 1);
  pending[0](respond(value));
  await first;
  assert.equal(el('result').hidden, false);
  assert.match(el('status').textContent, /Mindestens ein Provider/);
  assert.match(el('result').textContent, /podman: UNAVAILABLE/);
  assert.match(el('result').textContent, /Vorgeschlagene Aktionen: 2/);
  const stale = el('read').click();
  el('close').click();
  el('open').click();
  pending[1](respond(value));
  await stale;
  assert.equal(el('result').hidden, true);
  const malformed = el('read').click();
  pending[2](respond({ ...value, Summary: { ...value.Summary, Actions: -1 } }));
  await malformed;
  assert.equal(el('result').hidden, true);
  assert.match(el('status').textContent, /konnte nicht gelesen/);
  const app = fs.readFileSync(path.resolve(__dirname, '../../../Ui/app.js'), 'utf8');
  const fullBinding = app.split(/\r?\n/).find(line => line.startsWith("$('#full-maintenance-preview-open').addEventListener("));
  assert.ok(fullBinding);
  const fullCalls = [];
  vm.runInNewContext(fullBinding, {
    $: selector => item(selector.slice(1)),
    startAction(action, parameters) {
      fullCalls.push({ action, keys: Object.keys(parameters) });
      return Promise.resolve();
    },
    showError(error) { throw error; }
  });
  assert.equal(fullCalls.length, 0);
  await item('full-maintenance-preview-open').click();
  assert.deepEqual(fullCalls, [{ action: 'ReadFullMaintenancePreview', keys: [] }]);
  console.log('RUNTIME MAINTENANCE PREVIEW BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
