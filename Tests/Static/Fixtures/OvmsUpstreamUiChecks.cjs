'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const items = new Map();
const item = id => {
  if (!items.has(id)) items.set(id, {
    addEventListener(event, callback) { this[event] = callback; },
    showModal() { this.open = true; },
    close() { this.open = false; },
    reset() {},
  });
  return items.get(id);
};
const model = { Name: 'RuntimeModel', TypeName: 'System.String', Mandatory: true, Sensitive: false, IsCredential: false };
const field = (Name, TypeName, Mandatory = true) => ({ Name, TypeName, Mandatory, Sensitive: false, IsCredential: false });
const command = { Name: 'Test-SqlServerLabOvmsUpstreamEndpoint', RequiresConfirmation: false,
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: [
    field('Location', 'System.String'), model, field('Dimension', 'System.Int32'), field('TimeoutSeconds', 'System.Int32', false),
  ] }] };
const calls = [];
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/ovms-upstream.js'), 'utf8');
vm.runInNewContext(source, {
  document: { getElementById: item }, publicCommandCatalog: [command],
  openConfirmation(...args) { calls.push(args); },
});
const el = name => item('ovms-upstream-' + name);
const submit = () => el('form').submit({ preventDefault() {} });
el('open').click();
el('address').value = '192.0.2.7';
el('port').valueAsNumber = 9000;
el('model').value = 'example/model';
el('dimension').valueAsNumber = 768;
el('timeout').valueAsNumber = 30;
submit();
assert.equal(calls.length, 0, 'only explicit loopback values are accepted');
el('address').value = '[::1]';
model.Sensitive = true;
submit();
assert.equal(calls.length, 0, 'catalog schema must be suitable');
model.Sensitive = false;
submit();
assert.equal(calls.length, 1);
assert.equal(calls[0][2], '__PublicCommand');
assert.deepEqual(JSON.parse(JSON.stringify(calls[0][3].parameters)), {
  Location: 'http://[::1]:9000/v3/embeddings', RuntimeModel: 'example/model', Dimension: '768', TimeoutSeconds: '30',
});
console.log('OVMS UPSTREAM BROWSER UI: PASS');
