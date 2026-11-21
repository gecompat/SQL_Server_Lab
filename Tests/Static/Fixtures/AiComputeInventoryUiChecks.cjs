'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../../..');
const app = fs.readFileSync(path.join(root, 'Ui/app.js'), 'utf8');
const start = app.indexOf("$('#ai-compute-inventory-read').addEventListener");
const end = app.indexOf("$('#llama-session-open').addEventListener", start);
assert.ok(start >= 0 && end > start);
const button = { disabled: false, addEventListener(name, handler) { assert.equal(name, 'click'); this.click = handler; } };
const status = {};
const items = [{ Kind: 'CPU', Count: 1 }, { Kind: 'GPU', Count: 0 }, { Kind: 'NPU', Count: null }];
let calls = 0;
let view = { Status: 'INCOMPLETE', Platform: 'Windows', Items: items };
vm.runInNewContext(app.slice(start, end), {
  $: selector => selector === '#ai-compute-inventory-read' ? button : status,
  sqlServerLabUiFetch(url, options) {
    calls++;
    assert.equal(url, '/api/ai-compute-inventory');
    assert.equal(options.method, undefined);
    return { ok: true, json: async () => view };
  },
});
(async () => {
  assert.equal(calls, 0);
  const reading = button.click();
  await button.click();
  await reading;
  assert.equal(calls, 1);
  assert.match(status.textContent, /Erfassung unvollständig · CPU: 1 · GPU: 0 · NPU: unbekannt/);
  view = { Status: 'COMPLETE', Platform: 'PRIVATE_CANARY', Items: items };
  await button.click();
  assert.match(status.textContent, /nicht verfügbar/);
  assert.doesNotMatch(status.textContent, /PRIVATE_CANARY/);
  assert.equal(button.disabled, false);
  console.log('AI COMPUTE INVENTORY UI: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
