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
    selectedOptions: [], showModal() {}, close() {}, reset() {},
  });
  return items.get(id);
};
const runId = '11111111-1111-1111-1111-111111111111';
const collectionId = '22222222-2222-2222-2222-222222222222';
const targetKey = runId + '/primary';
const fields = ['RunId','InstanceId','CollectionId','Action','QueryId','FixtureRevision','TargetModelKey','Resume'];
const command = { Name: 'Invoke-SqlServerLabAiPersistentRetrieval', RequiresConfirmation: true,
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: fields.map(Name => ({
    Name, Mandatory: ['RunId','CollectionId'].includes(Name), Sensitive: false, IsCredential: false,
  })) }] };
const calls = [];
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/ai-persistent-retrieval-fixture.js'), 'utf8');
vm.runInNewContext(source, {
  document: { getElementById: item }, publicCommandCatalog: [command],
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  crypto: { randomUUID: () => collectionId },
  workflow: { ActiveLabs: [{ State: 'RUNNING', RunId: runId, Instances: [
    { Id: 'primary', Provider: 'docker', SqlVersion: '2025-CU9' },
    { Id: 'legacy', Provider: 'podman', SqlVersion: '2022' },
  ] }] },
  openConfirmation(...args) { calls.push(args); },
});
const el = name => item('persistent-fixture-' + name);
const submit = () => el('form').submit({ preventDefault() {} });
el('open').click();
assert.deepEqual(el('target').options.map(option => option.value), ['', targetKey]);
el('target').value = targetKey;
el('action').value = 'remove';
submit();
assert.equal(calls.length, 0, 'remove is outside the guided demo');
el('action').value = 'backup';
el('action').change();
assert.equal(el('collection').value, '');
el('collection').value = collectionId;
el('resume').checked = true;
submit();
assert.equal(calls[0][2], '__PublicCommand');
assert.deepEqual(JSON.parse(JSON.stringify(calls[0][3].parameters)), {
  RunId: runId, InstanceId: 'primary', CollectionId: collectionId, Action: 'Query', QueryId: 'backup',
});
el('open').click();
el('target').value = targetKey;
el('action').value = 'migrate';
el('action').change();
el('collection').value = collectionId;
el('resume').checked = true;
submit();
assert.deepEqual(JSON.parse(JSON.stringify(calls[1][3].parameters)), {
  RunId: runId, InstanceId: 'primary', CollectionId: collectionId, Action: 'Migrate',
  FixtureRevision: 'Delta', TargetModelKey: 'ollama-nomic-embed-text-v2-moe', Resume: true,
});
console.log('PERSISTENT RETRIEVAL FIXTURE BROWSER UI: PASS');
