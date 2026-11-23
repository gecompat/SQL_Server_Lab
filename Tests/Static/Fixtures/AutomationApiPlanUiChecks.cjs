'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const items = new Map();
const item = id => {
  if (!items.has(id)) items.set(id, {
    addEventListener(event, callback) { this[event] = callback; },
    showModal() { this.open = true; }, close() { this.open = false; }, reset() {},
  });
  return items.get(id);
};
const response = { ContractVersion: 'SqlServerLab.AutomationApiPlan/1.0', Status: 'READY',
  Request: { Action: 'PortableLabImport', LocalOnly: true }, ExecutionImplemented: false,
  Result: { Status: 'NOT_EXECUTED', ActionCommand: null, ExecutionImplemented: false },
  Plan: { Command: 'Get-SqlServerLabPortableLabImportPlan', ContractVersion: 'SqlServerLab.PortableContainerTransferPlan/1.0',
    RequiredParameters: ['PackagePath', 'TargetProvider', 'TargetRunId'], Mutation: 'NONE' },
};
const reads = [];
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/automation-api-plan.js'), 'utf8');
vm.runInNewContext(source, {
  document: { getElementById: item },
  async sqlServerLabUiFetch(url, init) { reads.push({url, init}); return { ok: true, json: async () => response }; },
});
const el = name => item('automation-api-plan-' + name);
const submit = () => el('form').submit({ preventDefault() {} });
(async () => {
  el('open').click();
  el('action').value = 'PortableLabImport';
  await submit();
  assert.equal(reads[0].url, '/api/automation-plan?action=PortableLabImport');
  assert.equal(reads[0].init.method, undefined);
  assert.equal(el('result').hidden, false);
  assert.equal(el('command').textContent, response.Plan.Command);
  assert.equal(el('execution').textContent, 'nicht verfügbar');
  el('action').value = 'Reconcile';
  el('action').change();
  await submit();
  assert.equal(el('result').hidden, true, 'mismatched receipt is suppressed');
  assert.match(el('status').textContent, /konnte nicht/);
  console.log('AUTOMATION API PLAN BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
