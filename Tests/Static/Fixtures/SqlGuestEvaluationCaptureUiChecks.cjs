'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../../..');
const app = fs.readFileSync(path.join(root, 'Ui/sql-guest-evaluation-evidence.js'), 'utf8');
const runId = '11111111-1111-1111-1111-111111111111';
const items = new Map();
const element = id => {
  if (!items.has(id)) items.set(id, {
    options: [], selectedOptions: [], value: '', disabled: false,
    addEventListener(event, callback) { this[event] = callback; },
    replaceChildren(option) { this.options = [option]; this.value = option.value; },
    add(option) { this.options.push(option); },
    showModal() { this.open = true; },
    close() { this.open = false; },
  });
  return items.get(id);
};
const flags = { Name: 'RunId', TypeName: 'System.Guid', Sensitive: false, IsCredential: false, Mandatory: true };
const parameterSet = { Name: '__AllParameterSets', IsDefault: false, Parameters: [flags], MandatoryNames: ['RunId'] };
const command = { Name: 'Update-SqlServerLabSqlGuestEvaluationEvidence', RequiresConfirmation: true, ParameterSets: [parameterSet] };
const confirmations = [];
vm.runInNewContext(app, {
  document: { getElementById: element },
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  publicCommandCatalog: [command],
  workflow: { HyperVLabs: [
    { RunId: runId, State: 'RUNNING', VMState: 'Running', Workload: 'sql', SqlVersion: '2025', Name: 'SQL Lab' },
    { RunId: '22222222-2222-2222-2222-222222222222', State: 'RUNNING', VMState: 'Running', Workload: 'sql', SqlVersion: '2022' },
  ] },
  openConfirmation(...values) { confirmations.push(values); },
});
const item = id => element('sql-guest-evidence-' + id);
item('open').click();
assert.deepEqual(item('run').options.map(option => option.value), ['', runId]);
item('next').click();
assert.equal(confirmations.length, 0);
item('run').value = runId;
item('run').selectedOptions = [item('run').options[1]];
item('run').change();
flags.TypeName = 'System.String';
item('next').click();
assert.equal(confirmations.length, 0);
assert.match(item('status').textContent, /nicht verfügbar/);
flags.TypeName = 'System.Guid';
item('next').click();
assert.equal(confirmations.length, 1);
assert.equal(confirmations[0][2], '__PublicCommand');
assert.deepEqual(JSON.parse(JSON.stringify(confirmations[0][3].parameters)), { RunId: runId });
console.log('SQL GUEST EVALUATION BROWSER UI: PASS');

const triggerSource = fs.readFileSync(path.join(root, 'Ui/evaluation-watch-trigger.js'), 'utf8');
const triggerField = (Name, TypeName) => ({ Name, TypeName, Sensitive: false, IsCredential: false, Mandatory: false });
const switchField = triggerField('RecordEvents', 'System.Management.Automation.SwitchParameter');
const triggerCommand = {
  Name: 'Invoke-SqlServerLabEvaluationWatchTrigger', RequiresConfirmation: true,
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: [
    triggerField('IntervalSeconds', 'System.Int32'), triggerField('MaximumChecks', 'System.Int32'), switchField,
  ] }],
};
const trigger = id => element('evaluation-trigger-' + id);
trigger('form').reset = () => { trigger('interval').valueAsNumber = 60; trigger('count').valueAsNumber = 2; trigger('record').checked = false; };
confirmations.length = 0;
vm.runInNewContext(triggerSource, {
  document: { getElementById: element }, publicCommandCatalog: [triggerCommand],
  openConfirmation(...values) { confirmations.push(values); },
});
trigger('open').click();
const submitTrigger = () => trigger('form').submit({ preventDefault() {} });
trigger('count').valueAsNumber = 1441;
submitTrigger();
assert.equal(confirmations.length, 0);
trigger('count').valueAsNumber = 2;
switchField.Sensitive = true;
submitTrigger();
assert.equal(confirmations.length, 0);
assert.match(trigger('status').textContent, /nicht verfügbar/);
switchField.Sensitive = false;
submitTrigger();
assert.equal(confirmations[0][2], '__PublicCommand');
assert.deepEqual(JSON.parse(JSON.stringify(confirmations[0][3].parameters)), { IntervalSeconds: '60', MaximumChecks: '2' });
trigger('open').click();
trigger('record').checked = true;
submitTrigger();
assert.equal(confirmations[1][3].parameters.RecordEvents, true);
assert.match(confirmations[1][1], /lokal gespeichert/);
console.log('EVALUATION WATCH TRIGGER BROWSER UI: PASS');
