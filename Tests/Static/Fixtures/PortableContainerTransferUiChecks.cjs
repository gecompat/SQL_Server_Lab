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
const id = digit => Array.from([8, 4, 4, 4, 12], n => digit.repeat(n)).join('-');
const first = id('1');
const second = id('2');
const backupId = id('3');
const intentId = id('4');
const ignoredId = id('5');
const command = (name, keys) => ({ Name: 'Invoke-SqlServerLabPortableContainerTransfer' + name, RequiresConfirmation: true,
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: keys.map(Name => ({ Name, Mandatory: true, Sensitive: false, IsCredential: false })) }] });
const common = ['DataRoot', 'SourceRunId', 'SourceInstanceId'];
const preflight = command('Preflight', [...common, 'TargetRunId', 'TargetInstanceId', 'DatabaseTransfers']);
const transfer = command('', [...common, 'SourceDatabaseName', 'TargetDatabaseName', 'BackupSetId', 'OperationId']);
const calls = [];
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/portable-container-transfer.js'), 'utf8');
const entry = { BackupSetId: backupId, Availability: 'SELECTABLE', SourceSqlMajorVersion: '17', SourceRunId: first,
  SourceInstanceId: 'primary', SourceProvider: 'docker', HasFileStream: false, IsEncrypted: false, DatabaseName: 'Demo', Bytes: 128 };
vm.runInNewContext(source, {
  document: { getElementById: item },
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  crypto: { randomUUID: () => intentId },
  publicCommandCatalog: [preflight, transfer],
  workflow: { Defaults: { DataRoot: 'synthetic-lab-data' },
    BackupLibrary: [entry, { ...entry, BackupSetId: ignoredId, SourceRunId: second }],
    ActiveLabs: [
      { RunId: first, State: 'RUNNING', Name: 'Docker', Instances: [{ Id: 'primary', Provider: 'docker' }] },
      { RunId: second, State: 'RUNNING', Name: 'Podman', Instances: [{ Id: 'other', Provider: 'podman' }] },
    ] },
  openConfirmation(...args) { calls.push(args); },
});
const el = name => item('portable-transfer-' + name);
const submit = () => el('form').submit({ preventDefault() {} });
const selectBackup = () => { el('backup').value = backupId; el('backup').change(); };
item('portable-media-open').click();
assert.deepEqual(el('backup').options.map(option => option.value), ['', backupId]);
selectBackup();
assert.deepEqual(el('target').options.map(option => option.value), ['', second + '/other']);
el('target').value = first + '/primary';
submit();
assert.equal(calls.length, 0);
el('target').value = second + '/other';
submit();
assert.equal(calls[0][2], '__PublicCommand');
assert.deepEqual(JSON.parse(JSON.stringify(calls[0][3].parameters)), {
  DataRoot: 'synthetic-lab-data', SourceRunId: first, SourceInstanceId: 'primary', TargetRunId: second,
  TargetInstanceId: 'other', DatabaseTransfers: [{ SourceDatabaseName: 'Demo', TargetDatabaseName: 'Demo', BackupSetId: backupId }],
});
el('open').click();
selectBackup();
assert.equal(el('intent').value, intentId);
el('database').value = 'master';
submit();
assert.equal(calls.length, 1);
el('database').value = 'DemoCopy';
submit();
assert.equal(calls[1][2], '__PublicCommand');
assert.deepEqual(JSON.parse(JSON.stringify(calls[1][3].parameters)), {
  DataRoot: 'synthetic-lab-data', SourceRunId: first, SourceInstanceId: 'primary', OperationId: intentId,
  SourceDatabaseName: 'Demo', TargetDatabaseName: 'DemoCopy', BackupSetId: backupId,
});
console.log('PORTABLE CONTAINER TRANSFER BROWSER UI: PASS');
