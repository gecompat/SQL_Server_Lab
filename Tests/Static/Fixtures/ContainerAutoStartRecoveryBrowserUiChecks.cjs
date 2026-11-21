'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../../..');
const app = fs.readFileSync(path.join(root, 'Ui/app.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'Ui/index.html'), 'utf8');
const start = app.indexOf('function setupContainerAutoStartRecovery()');
const end = app.indexOf('setupContainerAutoStartRecovery();', start) + 'setupContainerAutoStartRecovery();'.length;
assert.ok(start >= 0 && end > start);
const elements = {};
for (const name of ['open', 'dialog', 'target', 'confirm', 'status', 'read', 'apply', 'close']) {
  const id = 'autostart-recovery-' + name;
  assert.ok(html.includes('id="' + id + '"'));
  elements[name] = {
    listeners: {}, rows: [], value: '', checked: false, open: false,
    addEventListener(type, listener) { this.listeners[type] = listener; },
    emit(type, event) { return this.listeners[type](event); },
    replaceChildren() { this.rows = []; this.value = ''; },
    append(row) { this.rows.push(row); },
    showModal() { this.open = true; },
    close() { this.open = false; this.emit('close'); },
  };
}
const calls = [];
let response;
const token = 'a'.repeat(32);
const view = { Items: [{ Selection: token, RunId: 'ab6767bf-a085-4332-aeff-104716087188',
  Provider: 'docker', InstanceId: 'primary', TargetAutoStart: 'on' }] };
vm.runInNewContext(app.slice(start, end), {
  $: selector => elements[selector.replace('#autostart-recovery-', '')],
  document: { createElement() { return {}; } },
  sqlServerLabUiFetch(url, options) { calls.push({ url, options }); return response; },
});

(async () => {
  response = { ok: true, json: async () => view };
  await elements.open.emit('click');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].options.method, undefined);
  elements.target.value = token;
  elements.target.emit('change');
  await elements.apply.emit('click');
  assert.equal(calls.length, 1);
  elements.confirm.checked = true;
  elements.confirm.emit('change');
  let release;
  response = new Promise(resolve => { release = resolve; });
  const applying = elements.apply.emit('click');
  assert.equal(calls.length, 2);
  assert.equal(calls[1].url, '/api/container-autostart-recovery');
  assert.equal(calls[1].options.method, 'POST');
  assert.deepEqual(JSON.parse(calls[1].options.body), { Confirmed: true, Selection: token });
  let prevented = false;
  elements.dialog.emit('cancel', { preventDefault() { prevented = true; } });
  assert.ok(prevented);
  release({ ok: true, json: async () => ({ Status: 'RECOVERY_SUCCEEDED' }) });
  await applying;
  assert.match(elements.status.textContent, /Recovery abgeschlossen/);
  assert.ok(elements.apply.disabled && !elements.confirm.checked);
  await elements.apply.emit('click');
  assert.equal(calls.length, 2);
  console.log('CONTAINER AUTOSTART RECOVERY BROWSER UI: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
