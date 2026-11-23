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
const plan = { ScenarioId: 'vector-core-ci', Version: '1.0', Status: 'CATALOG_SUPPORTED',
  RunId: null, InstanceId: null, PlanKey: 'a'.repeat(64), Blockers: [], RequiredCapabilities: ['sql2025-vector-core'] };
vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, '../../../Ui/ai-scenario-plan.js'), 'utf8'), {
  document: { getElementById: element }, URLSearchParams,
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  workflow: { ActiveLabs: [{ RunId: runId, State: 'RUNNING', Instances: [
    { Id: 'primary', SqlVersion: '2025-CU9', Provider: 'docker' },
    { Id: 'legacy', SqlVersion: '2022', Provider: 'docker' },
  ] }] },
  async sqlServerLabUiFetch(url, init) { calls.push({ url, init }); return { ok: true, json: async () => plan }; },
});
const ui = id => element('ai-scenario-plan-' + id);
const submit = () => ui('form').submit({ preventDefault() {} });
(async () => {
  ui('open').click();
  assert.equal(ui('target').options.length, 2);
  await submit();
  assert.equal(calls[0].url, '/api/ai-scenario-plan');
  assert.equal(calls[0].init.method, undefined);
  assert.equal(ui('verdict').textContent, 'Im Katalog unterstützt');
  ui('target').value = ui('target').options[1].value;
  ui('target').change();
  await submit();
  assert.equal(ui('result').hidden, true);
  Object.assign(plan, { RunId: runId, InstanceId: 'primary', Status: 'BLOCKED', Blockers: ['AI_SCENARIO_INTENT_NOT_DECLARED'] });
  await submit();
  assert.equal(calls[2].url, '/api/ai-scenario-plan?runId=' + runId + '&instanceId=primary');
  assert.equal(ui('blockers').textContent, 'AI_SCENARIO_INTENT_NOT_DECLARED');
  assert.equal(ui('result').hidden, false);
  console.log('AI SCENARIO PLAN BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
