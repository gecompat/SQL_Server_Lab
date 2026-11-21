'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const elements = new Map();
const element = id => {
  if (!elements.has(id)) elements.set(id, {
    value: '', addEventListener(name, handler) { this[name] = handler; },
    replaceChildren(...children) { this.children = children; this.value = ''; },
    append(child) { this.children.push(child); }, add(option) { this.append(option); },
    showModal() { this.open = true; }, close() { this.open = false; },
  });
  return elements.get(id);
};
const runId = '5defd56c-a51a-4d32-bc4f-8bf10662e7bd';
const calls = [];
const point = { CreatedAt: '2026-11-21T00:00:00Z', Kind: 'PRODUCTION', RecoveryPointId: runId };
const plan = { ContractVersion: 'SqlServerLab.HyperVRecoveryPointPlan/1.0', RunId: runId, InstanceId: 'primary',
  Provider: 'hyperv', Status: 'READY', ExecutionImplemented: false, RecoveryPoints: [point], Blockers: [] };
vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, '../../../Ui/hyperv-recovery-point-plan.js'), 'utf8'), {
  document: { getElementById: element, createElement: () => ({}) }, URLSearchParams,
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  workflow: { HyperVLabs: [{ RunId: runId, InstanceId: 'primary' }, { RunId: runId, InstanceId: null }] },
  async sqlServerLabUiFetch(url, init) { calls.push({ url, init }); return { ok: true, json: async () => plan }; },
});
const ui = id => element('hyperv-recovery-points-' + id);
const submit = () => ui('form').submit({ preventDefault() {} });
(async () => {
  ui('open').click();
  assert.equal(ui('target').children.length, 2);
  assert.equal(ui('read').disabled, true);
  ui('target').value = runId;
  ui('target').change();
  await submit();
  assert.equal(calls[0].url, '/api/hyperv-recovery-point-plan?runId=' + runId + '&instanceId=primary');
  assert.equal(calls[0].init.method, undefined);
  assert.equal(ui('result').children[0].textContent, Object.values(point).join(' · '));
  plan.InstanceId = 'foreign';
  await submit();
  assert.equal(ui('result').hidden, true);
  assert.match(ui('status').textContent, /konnten nicht/);
  console.log('HYPER-V RECOVERY POINT PLAN BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
