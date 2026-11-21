'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../../..');
const app = fs.readFileSync(path.join(root, 'Ui/app.js'), 'utf8');
const markup = fs.readFileSync(path.join(root, 'Ui/index.html'), 'utf8');
const start = app.indexOf('async function readLlamaRuntimeInventory()');
const listener = "$('#llama-runtime-inventory-read').addEventListener('click', readLlamaRuntimeInventory);";
const end = app.indexOf(listener, start) + listener.length;
assert.ok(start >= 0 && end > start);
const elements = Object.fromEntries(['read', 'status', 'items'].map(id => {
  const selector = '#llama-runtime-inventory-' + id;
  assert.ok(markup.includes('id="' + selector.slice(1) + '"'));
  return [selector, {
    disabled: false, textContent: '', rows: [],
    addEventListener(event, handler) { assert.equal(event, 'click'); this.click = handler; },
    replaceChildren() { this.rows = []; },
    append(row) { this.rows.push(row); },
  }];
}));
const [button, status, items] = Object.values(elements);
const calls = [];
let response;
vm.runInNewContext(app.slice(start, end), {
  $: selector => elements[selector],
  document: { createElement(tag) { assert.equal(tag, 'li'); return {}; } },
  sqlServerLabUiFetch(url, options) { calls.push(url); assert.equal(options.cache, 'no-store'); return response; },
});

(async () => {
  assert.equal(calls.length, 0);
  const view = { EvidenceStatus: 'FILES_ONLY', ScanStatus: 'COMPLETED', Items: [{ Backend: 'LlamaCppCuda', Build: '9223372036854775807' }] };
  response = { ok: true, json: async () => view };
  const reading = button.click();
  await button.click();
  await reading;
  assert.deepEqual(calls, ['/api/llama-runtime-inventory']);
  assert.equal(items.rows[0].textContent, 'Backend LlamaCppCuda · Build 9223372036854775807');
  assert.match(status.textContent, /SQL-Embedding-Bereitschaft bleiben ungeprüft/);
  view.Items = [];
  view.ScanStatus = 'PARTIAL';
  await button.click();
  assert.ok(items.hidden);
  assert.match(status.textContent, /Suche unvollständig/);
  view.Items = [{ Backend: 'PRIVATE_CANARY', Build: '22' }];
  await button.click();
  assert.ok(items.hidden);
  assert.match(status.textContent, /nicht verfügbar/);
  assert.doesNotMatch(status.textContent, /PRIVATE_CANARY/);
  assert.equal(button.disabled, false);
  console.log('LLAMA RUNTIME INVENTORY UI: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
