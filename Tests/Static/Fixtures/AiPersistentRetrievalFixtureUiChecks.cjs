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
    selectedOptions: [], showModal() { this.open = true; }, close() { this.open = false; }, reset() {},
  });
  return items.get(id);
};
const runId = '11111111-1111-1111-1111-111111111111';
const collectionId = '22222222-2222-2222-2222-222222222222';
const targetKey = runId + '/primary';
const fields = ['RunId','InstanceId','CollectionId','Action','QueryId','FixtureRevision','TargetModelKey','Resume','KeepGenerations','Documents','ExpectedDocuments','Question','EmbeddingModelKey'];
const command = { Name: 'Invoke-SqlServerLabAiPersistentRetrieval', RequiresConfirmation: true,
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: fields.map(Name => ({
    Name, Mandatory: ['RunId','CollectionId'].includes(Name), Sensitive: false, IsCredential: false,
  })) }] };
const calls = [];
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/ai-persistent-retrieval-fixture.js'), 'utf8');
vm.runInNewContext(source, {
  document: { getElementById: item }, publicCommandCatalog: [command], TextDecoder,
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  crypto: { randomUUID: () => '33333333-3333-3333-3333-333333333333' },
  workflow: { ActiveLabs: [{ State: 'RUNNING', RunId: runId, Instances: [
    { Id: 'primary', Provider: 'docker', SqlVersion: '2025-CU9' },
    { Id: 'legacy', Provider: 'podman', SqlVersion: '2022' },
  ] }] },
  openConfirmation(...args) { calls.push(args); },
});
const el = name => item('persistent-fixture-' + name);
const submit = () => el('form').submit({ preventDefault() {} });
el('action').value = 'initial';
el('open').click();
assert.deepEqual(el('target').options.map(option => option.value), ['', targetKey]);
el('target').value = targetKey;
el('action').value = 'remove';
el('action').change();
submit();
assert.equal(calls.length, 0, 'remove requires a deliberately entered ID');
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
el('action').value = 'prune';
el('action').change();
el('retention').value = '32';
submit();
assert.equal(calls.length, 2, 'out of range retention is rejected');
el('retention').value = '3';
el('resume').checked = true;
submit();
assert.match(calls[2][1], /aktive Generation/);
assert.equal(calls[2][4], 'Dauerhaft löschen');
assert.deepEqual(JSON.parse(JSON.stringify(calls[2][3].parameters)), {
  RunId: runId, InstanceId: 'primary', CollectionId: collectionId, Action: 'Prune', KeepGenerations: 3,
});
el('action').value = 'remove';
el('action').change();
submit();
assert.match(calls[3][1], /gesamte Collection-Datenbank/);
assert.equal(calls[3][4], 'Dauerhaft löschen');
assert.deepEqual(JSON.parse(JSON.stringify(calls[3][3].parameters)), {
  RunId: runId, InstanceId: 'primary', CollectionId: collectionId, Action: 'Remove',
});
const mockFile = payload => {
  const bytes = new TextEncoder().encode(JSON.stringify(payload));
  return { name: 'sample.json', size: bytes.length, arrayBuffer: async () => bytes.buffer };
};
async function testDocuments() {
  el('open').click();
  el('target').value = targetKey;
  el('action').value = 'own-sync';
  el('action').change();
  el('collection').value = collectionId;
  const Documents = [{ Id: 'test-doc', Content: 'Synthetic new' }];
  const ExpectedDocuments = [{ Id: 'test-doc', Content: 'Synthetic old' }];
  el('document').files = [mockFile({ Documents })];
  await submit();
  assert.equal(calls.length, 4, 'sync requires the expected prior documents');
  el('document').files = [mockFile({ Documents, ExpectedDocuments, RunId: 'foreign' })];
  await submit();
  assert.equal(calls.length, 4, 'the document file cannot change the bound run');
  el('document').files = [mockFile({ Documents, ExpectedDocuments })];
  const pending = submit();
  el('dialog').close();
  await pending;
  assert.equal(calls.length, 4, 'closing during file read cancels confirmation');
  el('dialog').showModal();
  await submit();
  assert.match(calls[4][1], /Bestand von 1 Dokumenten/);
  assert.doesNotMatch(calls[4][1], /Synthetic|sample\.json/);
  assert.deepEqual(JSON.parse(JSON.stringify(calls[4][3].parameters)), {
    RunId: runId, InstanceId: 'primary', CollectionId: collectionId, Action: 'Sync', Documents, ExpectedDocuments,
  });
}
testDocuments().then(() => console.log('PERSISTENT RETRIEVAL FIXTURE BROWSER UI: PASS')).catch(error => {
  console.error(error);
  process.exitCode = 1;
});
