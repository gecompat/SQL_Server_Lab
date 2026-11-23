'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../../..');
const app = fs.readFileSync(path.join(root, 'Ui/ai-compute-overview.js'), 'utf8');
const start = app.indexOf("$('#ai-compute-inventory-read').addEventListener");
const end = app.indexOf("$('#ai-runtime-capability-read').addEventListener", start);
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
const capabilityButton = { ...button };
const capabilityStatus = {};
let capability = { Status: 'NO_PACKAGES', Items: [] };
const capabilityStart = app.indexOf("$('#ai-runtime-capability-read').addEventListener");
const capabilityEnd = app.indexOf("})();", capabilityStart);
assert.ok(capabilityStart >= 0 && capabilityEnd > capabilityStart);
vm.runInNewContext(app.slice(capabilityStart, capabilityEnd), {
  $: selector => selector === '#ai-runtime-capability-read' ? capabilityButton : capabilityStatus,
  sqlServerLabUiFetch(url, options) {
    assert.equal(url, '/api/ai-runtime-capability');
    assert.equal(options.method, undefined);
    return { ok: true, json: async () => capability };
  },
});
(async () => {
  await capabilityButton.click();
  assert.match(capabilityStatus.textContent, /Keine llama.cpp-Pakete/);
  capability = { Status: 'FILES_HASHED_NOT_EXECUTED', Items: [{ Backend: 'LlamaCppOpenVino', Kind: 'NPU', Eligible: false, CombinationCount: 0 }] };
  await capabilityButton.click();
  assert.match(capabilityStatus.textContent, /LlamaCppOpenVino · NPU · kein passendes Gerät gefunden/);
  assert.match(capabilityStatus.textContent, /0 Gerätekombinationen/);
  assert.match(capabilityStatus.textContent, /keine Runtime ausgeführt/);
  capability.Items[0].Backend = 'PRIVATE_CANARY';
  await capabilityButton.click();
  assert.match(capabilityStatus.textContent, /nicht ermittelt/);
  assert.doesNotMatch(capabilityStatus.textContent, /PRIVATE_CANARY/);
  assert.equal(capabilityButton.disabled, false);
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
