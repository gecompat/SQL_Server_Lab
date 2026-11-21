'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '../../..');
const app = fs.readFileSync(path.join(root, 'Ui/app.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'Ui/index.html'), 'utf8');
const start = app.indexOf('function setupContainerAutoStartChange()');
const end = app.indexOf('async function readLlamaRuntimeInventory()', start);
assert.ok(start >= 0 && end > start);
const elements = {};
for (const name of ['open', 'dialog', 'target', 'policy', 'confirm', 'status', 'read', 'plan', 'apply', 'close']) {
  const id = 'autostart-change-' + name;
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
let view;
const target = 'a'.repeat(32);
const plan = 'b'.repeat(32);
vm.runInNewContext(app.slice(start, end), {
  $: selector => elements[selector.replace('#autostart-change-', '')],
  document: { createElement() { return {}; } },
  sqlServerLabUiFetch(url, options) { calls.push({ url, options }); return { ok: true, json: async () => view }; },
});

(async () => {
  view = { Items: [{ Selection: target, RunId: 'ab6767bf-a085-4332-aeff-104716087188',
    Provider: 'docker', InstanceId: 'primary' }] };
  await elements.open.emit('click');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].options.method, undefined);
  elements.target.value = target;
  elements.policy.value = 'on';
  elements.target.emit('change');
  view = { Selection: plan, Current: 'OFF', Desired: 'ON', NoChange: false };
  await elements.plan.emit('click');
  assert.deepEqual(JSON.parse(calls[1].options.body), { Action: 'Plan', AutoStart: 'on', Selection: target });
  assert.match(elements.status.textContent, /Aktuell OFF · Ziel ON/);
  await elements.apply.emit('click');
  assert.equal(calls.length, 2);
  elements.confirm.checked = true;
  elements.policy.value = 'off';
  elements.policy.emit('change');
  await elements.apply.emit('click');
  assert.equal(calls.length, 2);
  assert.ok(!elements.confirm.checked);
  view = { Selection: null, Current: 'OFF', Desired: 'OFF', NoChange: true };
  await elements.plan.emit('click');
  assert.match(elements.status.textContent, /Bereits eingestellt/);
  assert.ok(elements.apply.disabled);
  elements.policy.value = 'on';
  elements.policy.emit('change');
  view = { Selection: plan, Current: 'OFF', Desired: 'ON', NoChange: false };
  await elements.plan.emit('click');
  elements.confirm.checked = true;
  elements.confirm.emit('change');
  view = { Status: 'SUCCEEDED' };
  await elements.apply.emit('click');
  assert.deepEqual(JSON.parse(calls[4].options.body), { Action: 'Apply', Confirmed: true, Selection: plan });
  assert.equal(calls[4].url, '/api/container-autostart-change');
  assert.match(elements.status.textContent, /Autostart geändert/);
  await elements.apply.emit('click');
  assert.equal(calls.length, 5);
  console.log('CONTAINER AUTOSTART CHANGE BROWSER UI: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
