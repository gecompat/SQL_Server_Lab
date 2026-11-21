'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const elements = new Map();
const element = id => {
  if (!elements.has(id)) elements.set(id, {
    value: '', addEventListener(name, handler) { this[name] = handler; },
    replaceChildren(...items) { this.options = items; this.value = ''; },
    add(option) { this.options.push(option); },
    showModal() { this.open = true; }, close() { this.open = false; },
  });
  return elements.get(id);
};
const runId = '5defd56c-a51a-4d32-bc4f-8bf10662e7bd';
const calls = [];
const bundle = { ContractVersion: 'SqlServerLab.DiagnosticBundle/1.0', Status: 'OBSERVED',
  Capabilities: { MutationAllowed: false, SqlProbe: 'NOT_EXECUTED' }, Readiness: { EvidenceStatus: 'NOT_EXECUTED' },
  Binding: { Provider: 'docker' }, History: { RunState: 'STOPPED', RecoveryStatus: 'UNKNOWN', ErrorCount: 1 },
  Cleanup: { Status: 'UNKNOWN' } };
vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, '../../../Ui/diagnostic-bundle.js'), 'utf8'), {
  document: { getElementById: element }, URLSearchParams,
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  workflow: { ActiveLabs: [{ RunId: runId, Instances: [{ Id: 'primary', Provider: 'docker' }] }] },
  async sqlServerLabUiFetch(url, init) { calls.push({ url, init }); return { ok: true, json: async () => bundle }; },
});
const ui = id => element('diagnostic-bundle-' + id);
const submit = () => ui('form').submit({ preventDefault() {} });
(async () => {
  ui('open').click();
  assert.equal(ui('target').options.length, 2);
  assert.equal(calls.length, 0);
  ui('target').value = ui('target').options[1].value;
  ui('target').change();
  await submit();
  assert.equal(calls[0].url, '/api/diagnostic-bundle?runId=' + runId + '&instanceId=primary&provider=docker');
  assert.equal(calls[0].init.method, undefined);
  assert.equal(ui('errors').textContent, '1');
  assert.equal(ui('result').hidden, false);
  bundle.Capabilities.MutationAllowed = true;
  await submit();
  assert.equal(ui('result').hidden, true);
  assert.match(ui('status').textContent, /konnte nicht/);
  console.log('DIAGNOSTIC BUNDLE BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
