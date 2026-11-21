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
    showModal() { this.open = true; },
    close() { this.open = false; },
    reset() {},
  });
  return items.get(id);
};
const first = '11111111-1111-1111-1111-111111111111';
const second = '22222222-2222-2222-2222-222222222222';
const third = '33333333-3333-3333-3333-333333333333';
const field = { Name: 'ComparisonPair', TypeName: 'System.Object[]', Mandatory: true, Sensitive: false, IsCredential: false };
const command = { Name: 'Test-SqlServerLabRelationalCoreComparison', RequiresConfirmation: false,
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: [field] }] };
const calls = [];
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/relational-core-comparison.js'), 'utf8');
vm.runInNewContext(source, {
  document: { getElementById: item },
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  publicCommandCatalog: [command],
  workflow: { ActiveLabs: [
    { RunId: first, State: 'RUNNING', Name: 'Docker', Instances: [{ Id: 'primary', Provider: 'docker' }] },
    { RunId: second, State: 'RUNNING', Name: 'Podman', Instances: [{ Id: 'other', Provider: 'podman' }] },
    { RunId: third, State: 'STOPPED', Instances: [{ Id: 'primary', Provider: 'docker' }] },
  ] },
  openConfirmation(...args) { calls.push(args); },
});
const el = name => item('relational-compare-' + name);
const submit = () => el('form').submit({ preventDefault() {} });
el('open').click();
assert.deepEqual(el('source').options.map(option => option.value), ['', first + '/primary', second + '/other']);
el('source').value = first + '/primary';
el('source').change();
assert.deepEqual(el('target').options.map(option => option.value), ['', second + '/other']);
el('target').value = first + '/primary';
el('source-name').value = 'DbOne';
el('target-name').value = 'DbTwo';
submit();
assert.equal(calls.length, 0, 'same instance is rejected');
el('target').value = second + '/other';
el('source-name').value = 'Bad-Name';
submit();
assert.equal(calls.length, 0, 'invalid database name is rejected');
el('source-name').value = 'DbOne';
field.TypeName = 'System.String';
submit();
assert.equal(calls.length, 0, 'unexpected parameters cannot be submitted');
field.TypeName = 'System.Object[]';
submit();
assert.equal(calls.length, 1);
assert.equal(calls[0][2], '__PublicCommand');
assert.deepEqual(JSON.parse(JSON.stringify(calls[0][3].parameters)), { ComparisonPair: [{
  PairId: 'GuidedComparison', SourceRunId: first, SourceInstanceId: 'primary', SourceDatabaseName: 'DbOne',
  TargetRunId: second, TargetInstanceId: 'other', TargetDatabaseName: 'DbTwo',
}] });
console.log('RELATIONAL CORE COMPARISON BROWSER UI: PASS');
