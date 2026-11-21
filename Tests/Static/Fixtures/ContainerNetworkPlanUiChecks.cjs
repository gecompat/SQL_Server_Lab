'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const items = new Map();
const item = id => {
  if (!items.has(id)) items.set(id, {
    addEventListener(event, callback) { this[event] = callback; },
    showModal() {},
    close() {},
    reset() {},
  });
  return items.get(id);
};
const provider = { Name: 'Provider', TypeName: 'System.String', Mandatory: true, Sensitive: false, IsCredential: false };
const preview = { Name: 'WhatIf', TypeName: 'System.Management.Automation.SwitchParameter', Mandatory: false, Sensitive: false, IsCredential: false };
const command = { Name: 'Move-SqlServerLabContainerNetwork', RequiresConfirmation: true, SupportsShouldProcess: true,
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: [provider, preview] }] };
const calls = [];
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/container-network-plan.js'), 'utf8');
vm.runInNewContext(source, {
  document: { getElementById: item }, publicCommandCatalog: [command],
  openConfirmation(...args) { calls.push(args); },
});
const el = name => item('container-network-plan-' + name);
const submit = () => el('form').submit({ preventDefault() {} });
el('open').click();
el('provider').value = 'other';
submit();
assert.equal(calls.length, 0);
el('provider').value = 'podman';
command.ParameterSets[0].Parameters.pop();
submit();
assert.equal(calls.length, 0, 'WhatIf must be available');
command.ParameterSets[0].Parameters.push(preview);
submit();
assert.equal(calls[0][2], '__PublicCommand');
assert.deepEqual(JSON.parse(JSON.stringify(calls[0][3].parameters)), { Provider: 'podman', WhatIf: true });
console.log('CONTAINER NETWORK PLAN BROWSER UI: PASS');
