'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const items = new Map();
function element(id) {
  if (!items.has(id)) {
    items.set(id, {
      children: [], value: '',
      addEventListener(event, handler) { this[event] = handler; },
      showModal() { this.open = true; },
      close() { this.open = false; },
      replaceChildren() { this.children = []; this.value = ''; },
      append(child) { this.children.push(child); this.value ||= child.value; }
    });
  }
  return items.get(id);
}
const calls = [];
const contract = 'SqlServerLab.SmtpStatusGuidance/1.0';
const firstRun = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
const secondRun = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
vm.runInNewContext(fs.readFileSync(path.resolve(__dirname, '../../../Ui/smtp-status.js'), 'utf8'), {
  document: { getElementById: element, createElement: () => ({}) },
  URLSearchParams,
  sqlServerLabUiFetch(url, options) {
    assert.equal(options.method, undefined);
    assert.equal(options.cache, 'no-store');
    return new Promise(resolve => calls.push({ url, resolve }));
  }
});
const el = id => element('smtp-status-' + id);
const submit = () => el('form').submit({ preventDefault() {} });
const reply = (index, data) => calls[index].resolve({ ok: true, json: async () => ({ ContractVersion: contract, ...data }) });
(async () => {
  const listing = el('open').click();
  assert.ok(el('read').disabled);
  assert.equal(calls[0].url, '/api/smtp-status');
  reply(0, { Candidates: [{ RunId: firstRun, Name: '<synthetic>' }, { RunId: secondRun, Name: 'Second' }] });
  await listing;
  assert.equal(el('lab').children.length, 2);
  assert.match(el('lab').children[0].textContent, /<synthetic>/);
  const stale = submit();
  assert.equal(calls[1].url, '/api/smtp-status?runId=' + firstRun);
  el('lab').value = secondRun;
  el('lab').change();
  const ready = submit();
  reply(2, { RunId: secondRun, Provider: 'docker', Status: 'READY', Url: 'synthetic-url' });
  await ready;
  reply(1, { RunId: firstRun, Provider: 'podman', Status: 'STOPPED' });
  await stale;
  assert.match(el('result').textContent, /docker.*läuft/);
  assert.doesNotMatch(el('result').textContent, /synthetic-url|podman/);
  el('lab').value = 'unregistered';
  el('lab').change();
  await submit();
  assert.equal(calls.length, 3);
  console.log('SMTP STATUS BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
