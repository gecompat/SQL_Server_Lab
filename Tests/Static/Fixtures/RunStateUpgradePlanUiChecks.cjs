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
const runId = '11111111-2222-4333-8444-555555555555';
const calls = [];
const view = { RunId: runId, Source: 'UNVERSIONED_LEGACY', Target: 'SqlServerLab.RunState/1.0',
  Status: 'READY', SyntheticFixture: true, Changes: ['SET_CONTRACT_VERSION'], Blockers: [] };
vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, '../../../Ui/run-state-upgrade-plan.js'), 'utf8'), {
  document: { getElementById: element },
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  workflow: { ActiveLabs: [{ RunId: runId }], HyperVLabs: [{ RunId: runId }] },
  async sqlServerLabUiFetch(url, init) { calls.push({ url, init }); return { ok: true, json: async () => view }; },
});
const ui = id => element('run-state-upgrade-plan-' + id);
const submit = () => ui('form').submit({ preventDefault() {} });
(async () => {
  ui('open').click();
  assert.equal(ui('target').options.length, 2, 'identische Run-ID nur einmal');
  await submit();
  assert.equal(calls.length, 0);
  ui('target').value = ui('target').options[1].value;
  ui('target').change();
  await submit();
  assert.equal(calls[0].url, '/api/run-state-upgrade-plan?runId=' + runId);
  assert.equal(calls[0].init.method, undefined);
  assert.equal(ui('changes').textContent, 'SET_CONTRACT_VERSION');
  assert.equal(ui('result').hidden, false);
  view.SyntheticFixture = false;
  await submit();
  assert.equal(ui('result').hidden, true);
  assert.match(ui('status').textContent, /konnte nicht/);
  console.log('RUN STATE UPGRADE PLAN BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
