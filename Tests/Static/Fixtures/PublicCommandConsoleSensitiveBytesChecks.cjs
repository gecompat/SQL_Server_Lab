const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const source = fs.readFileSync(path.join(__dirname, '../../../Ui/app.js'), 'utf8');
function actualFunction(name) {
  const match = new RegExp('^function ' + name + '\\(', 'm').exec(source);
  assert.ok(match); const rest = source.slice(match.index), next = /\n(?:async )?function \w+\(/.exec(rest);
  return next ? rest.slice(0, next.index) : rest;
}
const descriptor = { Name: 'ExportBytes', TypeName: 'System.Byte[]', Sensitive: true, Mandatory: true };
const element = { value: '[65,66]', dataset: { commandKind: 'json' } };
const context = vm.createContext({ descriptor, document: { querySelector: () => element }, CSS: { escape: value => value },
  escapeHtml: value => String(value), selectedPublicCommandParameterSet: () => ({ Parameters: [descriptor] }) });
for (const name of ['publicCommandAllowedValues', 'renderPublicCommandParameter', 'collectPublicCommandParameters']) vm.runInContext(actualFunction(name), context);
const html = vm.runInContext('renderPublicCommandParameter(descriptor)', context);
assert.ok(html.includes('type="password"') && html.includes('data-command-kind="json"') && html.includes('autocomplete="off"'));
assert.ok(!html.includes('<textarea') && !html.includes('value="'));
assert.equal(JSON.stringify(vm.runInContext('collectPublicCommandParameters()', context)), '{"ExportBytes":[65,66]}');
element.value = '["SYNTHETIC_INPUT_CANARY"';
assert.throws(() => vm.runInContext('collectPublicCommandParameters()', context), error => error.message === 'ExportBytes muss gültiges JSON enthalten.');
descriptor.Sensitive = false;
assert.ok(vm.runInContext('renderPublicCommandParameter(descriptor)', context).includes('<textarea'));
console.log('PUBLIC COMMAND SENSITIVE BYTES UI: 5 PASS; synthetic DOM only; no browser/runtime claim');
