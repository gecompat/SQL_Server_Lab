'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const items = new Map();
function item(id) {
  if (!items.has(id)) {
    items.set(id, {
      addEventListener(event, handler) { this[event] = handler; },
      showModal() { this.open = true; },
      close() { this.open = false; }
    });
  }
  return items.get(id);
}
const reads = [];
const script = fs.readFileSync(path.resolve(__dirname, '../../../Ui/hyperv-storage-preview.js'), 'utf8');
vm.runInNewContext(script, {
  document: { getElementById: item },
  sqlServerLabUiFetch(url, init) {
    assert.equal(url, '/api/hyperv-storage-preview');
    assert.equal(init.method, undefined);
    assert.equal(init.cache, 'no-store');
    return new Promise(resolve => reads.push(resolve));
  },
});
const el = id => item('hyperv-storage-preview-' + id);
const view = {
  LabDataRoot: 'Synthetic/Lab_Data', FreeBytes: '2147483648', SystemVolume: true,
  Targets: ['Run', 'Build', 'Image', 'Staging', 'Recovery'].map(ResourceClass => ({
    ResourceClass, ClassRoot: 'Synthetic/Lab_Data/' + ResourceClass
  }))
};
const response = (body = view) => ({ ok: true, json: async () => body });

(async () => {
  assert.equal(reads.length, 0, 'startup leaves the storage catalog untouched');
  const first = el('open').click();
  reads[0](response());
  await first;
  assert.equal(el('result').hidden, false);
  assert.match(el('result').textContent, /2 GiB/);
  assert.match(el('result').textContent, /Recovery: Synthetic/);
  assert.match(el('status').textContent, /Systemvolume/);

  const older = el('refresh').click();
  const newer = el('refresh').click();
  reads[2](response({ ...view, Targets: [view.Targets[0]] }));
  await newer;
  reads[1](response());
  await older;
  assert.equal(el('result').hidden, true, 'an older success does not replace a current error');
  assert.match(el('status').textContent, /Grundkonfiguration/);

  const closed = el('refresh').click();
  el('close').click();
  reads[3](response());
  await closed;
  assert.equal(el('result').hidden, true);
  console.log('HYPERV STORAGE PREVIEW BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
