'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const items = new Map();
const get = id => {
  if (!items.has(id)) items.set(id, {
    value: '', addEventListener(name, callback) { this[name] = callback; },
    showModal() { this.open = true; }, close() { this.open = false; },
    replaceChildren(...options) { this.options = options; this.value = ''; },
    add(option) { this.options.push(option); },
  });
  return items.get(id);
};
const el = name => get('container-tool-check-' + name);
const requests = [];
const run = '11111111-2222-4333-8444-555555555555';
vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, '../../../Ui/container-tool-check.js'), 'utf8'), {
  document: { getElementById: get },
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  workflow: { ActiveLabs: [{ State: 'RUNNING', RunId: run, Instances: [{ Id: 'primary', Provider: 'docker' }, { Id: 'windows', Provider: 'hyperv' }] }] },
  publicCommandCatalog: [{ Name: 'Test-SqlServerLabContainerTool', ParameterSets: [{
    Name: '__AllParameterSets',
    Parameters: ['RunId', 'InstanceId', 'StateRoot'].map(Name => ({ Name, Sensitive: false, IsCredential: false })),
  }] }],
  openConfirmation(...args) { requests.push(args); },
});
const submit = () => el('form').submit({ preventDefault() {} });
el('open').click();
assert.equal(el('target').options.length, 2);
submit();
assert.equal(requests.length, 0);
el('target').value = el('target').options[1].value;
submit();
assert.equal(requests[0][2], '__PublicCommand');
assert.equal(JSON.stringify(requests[0][3].parameters), JSON.stringify({ RunId: run, InstanceId: 'primary' }));
assert.equal(el('dialog').open, false);
submit();
assert.equal(requests.length, 1);
console.log('CONTAINER TOOL GUIDANCE BROWSER: PASS');
