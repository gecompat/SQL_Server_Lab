'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../../..');
const app = fs.readFileSync(path.join(root, 'Ui/hyperv-autostart.js'), 'utf8');
const runId = '11111111-1111-1111-1111-111111111111';
const token = 'a'.repeat(32);
const requests = [];
let recovery = false;
const elements = {};
const element = id => elements[id] ||= {
  value: '', disabled: false, checked: false, open: false,
  addEventListener(event, callback) { this[event] = callback; },
  replaceChildren(option) { this.options = [option]; this.value = option.value; },
  add(option) { this.options.push(option); },
  showModal() { this.open = true; },
};
vm.runInNewContext(app, {
  document: { getElementById: element },
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  workflow: { HyperVLabs: [{ RunId: runId, State: 'RUNNING', Name: 'Eigene VM' },
    { RunId: 'not-eligible', State: 'REMOVED' }] },
  async sqlServerLabUiFetch(url, options) {
    assert.equal(url, '/api/hyperv-autostart');
    assert.equal(options.method, 'POST');
    const packet = JSON.parse(options.body);
    requests.push(packet);
    const data = packet.Action === 'Plan' ? { Current: 'ON', Desired: packet.AutoStart.toUpperCase(), NoChange: false, Selection: token } :
      packet.Action === 'PlanRecovery' ? { Desired: 'OFF', Selection: token } :
        { Status: recovery ? 'RECOVERY_SUCCEEDED' : 'SUCCEEDED' };
    return { ok: true, json: async () => data };
  },
});
(async () => {
  const item = name => element('hyperv-autostart-' + name);
  item('open').click();
  assert.deepEqual(item('run').options.map(option => option.value), ['', runId]);
  assert.equal(requests.length, 0);
  await item('apply').click();
  assert.equal(requests.length, 0);
  item('run').value = runId;
  item('run').change();
  await item('plan').click();
  assert.deepEqual(requests[0], { Action: 'Plan', RunId: runId, AutoStart: 'off' });
  assert.match(item('status').textContent, /Aktuell ON · geplant OFF/);
  await item('apply').click();
  assert.equal(requests.length, 1);
  item('desired').change();
  item('confirm').checked = true;
  await item('apply').click();
  assert.equal(requests.length, 1);
  await item('plan').click();
  item('confirm').checked = true;
  item('confirm').change();
  assert.equal(item('apply').disabled, false);
  await item('apply').click();
  assert.deepEqual(requests[2], { Action: 'Apply', Selection: token, Confirmed: true });
  assert.match(item('status').textContent, /Startpolicy bestätigt/);
  await item('apply').click();
  assert.equal(requests.length, 3);
  recovery = true;
  item('mode').value = 'recovery';
  item('mode').change();
  assert.equal(item('desired').disabled, true);
  await item('plan').click();
  assert.deepEqual(requests[3], { Action: 'PlanRecovery', RunId: runId });
  assert.match(item('status').textContent, /nur Lab-State nachtragen/);
  item('confirm').checked = true;
  item('confirm').change();
  await item('apply').click();
  assert.match(item('status').textContent, /Autostart-Recovery abgeschlossen/);
  console.log('HYPERV AUTOSTART BROWSER UI: PASS');
})().catch(error => { console.error(error); process.exitCode = 1; });
