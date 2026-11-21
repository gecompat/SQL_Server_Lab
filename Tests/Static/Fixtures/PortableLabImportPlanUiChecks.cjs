'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const items = new Map();
const item = id => {
  if (!items.has(id)) items.set(id, {
    addEventListener(event, callback) { this[event] = callback; },
    replaceChildren(option) { this.options = [option]; this.value = option.value; },
    add(option) { this.options.push(option); },
    showModal() { this.open = true; }, close() { this.open = false; }, reset() {},
  });
  return items.get(id);
};
const targetRun = '33333333-3333-3333-3333-333333333333';
const packageId = '11111111-1111-1111-1111-111111111111';
const pkg = { ContractVersion: 'SqlServerLab.PortableLabPackage/1.1', PackageId: packageId,
  Source: { Provider: 'podman', SqlMajorVersion: '17' }, BackupReferences: [] };
const requests = [];
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/portable-lab-import-plan.js'), 'utf8');
vm.runInNewContext(source, {
  document: { getElementById: item },
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  workflow: { ActiveLabs: [{ RunId: targetRun, State: 'STOPPED', Instances: [{ Provider: 'docker' }, { Provider: 'docker' }] }] },
  async sqlServerLabUiFetch(url, init) {
    requests.push({ url, init });
    return { ok: true, json: async () => ({ ContractVersion: 'SqlServerLab.PortableContainerTransferPlan/1.0',
      ExecutionImplemented: false, Status: 'READY', PackageId: packageId, TargetRunId: targetRun,
      TargetProvider: 'docker', BackupReferences: [], Blockers: [] }) };
  },
});
const el = name => item('portable-import-plan-' + name);
const submit = () => el('form').submit({ preventDefault() {} });
const file = text => ({name: 'package.json', size: text.length, text: async () => text});
(async () => {
  el('open').click();
  assert.deepEqual(el('target').options.map(option => option.value), ['', targetRun + '/docker']);
  el('target').value = targetRun + '/docker';
  el('file').files = [file(JSON.stringify({ ...pkg, Extra: 'PRIVATE_CANARY' }))];
  await submit();
  assert.equal(requests.length, 0);
  const raw = JSON.stringify(pkg, null, 2);
  el('file').files = [file(raw)];
  await submit();
  assert.equal(requests.length, 1);
  assert.equal(requests[0].url, '/api/portable-lab-import-plan');
  assert.ok(requests[0].init.body.includes(raw), 'unmodified document retained for duplicate-sensitive validation');
  assert.deepEqual(JSON.parse(requests[0].init.body), { TargetRunId: targetRun, TargetProvider: 'docker', Package: pkg });
  assert.match(el('status').textContent, /Importplan bereit/);
  console.log('PORTABLE LAB IMPORT PLAN BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
