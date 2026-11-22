'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const items = new Map();
function item(id) {
  if (!items.has(id)) {
    items.set(id, {
      value: '', items: [],
      addEventListener(event, handler) { this[event] = handler; },
      showModal() { this.open = true; },
      close() { this.open = false; },
      replaceChildren() { this.items = []; this.value = ''; },
      append(option) { this.items.push(option); this.value ||= option.value; }
    });
  }
  return items.get(id);
}
const calls = [];
const responses = [];
const contract = 'SqlServerLab.LicenseProfileStatusGuidance/1.0';
const profileId = 'sql2016-test';
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/license-profile-status.js'), 'utf8');
vm.runInNewContext(source, {
  document: { getElementById: item, createElement: () => ({}) },
  URLSearchParams,
  async sqlServerLabUiFetch(url, options) {
    assert.equal(options.method, undefined);
    assert.equal(options.cache, 'no-store');
    calls.push(url);
    return { ok: true, json: async () => ({ ContractVersion: contract, ...responses.shift() }) };
  }
});
const el = id => item('license-profile-status-' + id);
const submit = () => el('form').submit({ preventDefault() {} });
(async () => {
  responses.push({ Status: 'UNSUPPORTED', Profiles: [] });
  await el('open').click();
  assert.equal(el('read').disabled, true);
  assert.match(el('result').textContent, /Windows und DPAPI/);
  el('close').click();
  responses.push({ Status: 'LISTED', Profiles: [
    { Id: profileId, Product: 'SqlServer', Version: '2016', Edition: 'Standard', Channel: 'Retail', KeyAvailable: true }
  ] });
  await el('open').click();
  assert.equal(el('selection').items.length, 1);
  assert.match(el('selection').items[0].textContent, /Standard.*Retail/);
  responses.push({ Id: profileId, Status: 'READY', OnlineActivationTested: false, Key: 'raw-key-must-not-render' });
  await submit();
  assert.equal(calls.at(-1), '/api/license-profile-status?profileId=' + profileId);
  assert.match(el('result').textContent, /strukturell verwendbar/);
  assert.doesNotMatch(el('result').textContent, /raw-key/);
  responses.push({ Id: profileId, Status: 'READY', OnlineActivationTested: true });
  await submit();
  assert.match(el('result').textContent, /konnte nicht abgeschlossen/);
  console.log('LICENSE PROFILE STATUS BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
