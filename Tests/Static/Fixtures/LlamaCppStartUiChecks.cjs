'use strict';
const fs = require('fs'); const path = require('path'); const vm = require('vm'); const assert = require('assert/strict'); const { TextEncoder } = require('util');
const root = path.resolve(__dirname, '../../..');
const source = fs.readFileSync(path.join(root, 'Ui/llama-start.js'), 'utf8');
let checks = 0;
function check(name, value) { assert.ok(value, name); checks++; }
const ids = ['open', 'dialog', 'runtime', 'backend', 'accelerator', 'model', 'alias', 'dimension', 'pooling', 'port', 'certificate', 'private-key', 'api-key', 'trusted-root', 'timeout', 'lease', 'context', 'confirm', 'status', 'result', 'start', 'whatif', 'close'];
function fixture() {
  const elements = new Map(ids.map(id => [id, { value: '', checked: false, textContent: '', disabled: false, open: false, listeners: {}, addEventListener(event, fn) { (this.listeners[event] ||= []).push(fn); }, showModal() { this.open = true; }, close() { this.open = false; for (const fn of this.listeners.close || []) fn(); }, async emit(event) { for (const fn of this.listeners[event] || []) await fn(); } }]));
  const calls = []; const responses = [];
  const context = vm.createContext({ TextEncoder, document: { querySelector(selector) { const id = selector.replace('#llama-start-', ''); assert.ok(elements.has(id)); return elements.get(id); } }, fetch(url, options) { calls.push({ url, options }); return responses.shift()(); } });
  vm.runInContext(source, context, { filename: 'llama-start.js' });
  return { elements, context, calls, responses, get: id => elements.get(id) };
}
async function open(f) {
  await f.get('open').emit('click');
  for (const id of ['runtime', 'model', 'certificate', 'private-key']) f.get(id).value = 'PRIVATE_PATH_CANARY';
  f.get('alias').value = 'PRIVATE_ALIAS_CANARY'; f.get('api-key').value = 'x'.repeat(32);
}
function result(status = 'ENDPOINT_VERIFIED') { return { Contract: 'SqlServerLab.BrowserLlamaStartResult/1.0', Status: status, OperationId: status === 'ENDPOINT_VERIFIED' ? '11111111-2222-4333-8444-555555555555' : null, SqlReadiness: 'NOT_CHECKED', PossibleOwnSession: status !== 'WHATIF_ONLY', SameModuleRequired: true, AutoStopAllowed: false, RetryAllowed: false }; }
function good(f, status, mutate = () => {}) { f.responses.push(async () => { const view = result(status); mutate(view); return { ok: true, json: async () => view }; }); }
(async () => {
  const f = fixture(); await open(f); await f.get('runtime').emit('input');
  check('Opening/editing does no HTTP or ambient reads', f.calls.length === 0);
  await f.get('start').emit('click'); check('Unconfirmed Start zero dispatch', f.calls.length === 0);
  await f.get('close').emit('click'); check('Pre-dispatch Back clears key/paths and does zero dispatch', !f.get('dialog').open && f.get('api-key').value === '' && f.get('runtime').value === '' && f.calls.length === 0);
  await open(f); await f.get('dialog').emit('cancel'); check('Escape clears transient inputs zero dispatch', f.get('api-key').value === '' && f.calls.length === 0);
  await open(f); f.get('confirm').checked = true; good(f); await f.get('start').emit('click');
  const payload = JSON.parse(f.calls[0].options.body);
  check('Exact dedicated Start envelope fifteen fields', f.calls.length === 1 && f.calls[0].url === '/api/llama-start' && payload.Action === 'Start' && payload.Confirmed === true && Object.keys(payload).sort().join() === 'Action,Confirmed,Parameters' && Object.keys(payload.Parameters).length === 15);
  check('Secret cleared after request, fixed result without paths/key/alias', f.get('api-key').value === '' && f.get('runtime').value === '' && f.get('result').textContent.includes('11111111-') && !f.get('result').textContent.includes('PRIVATE_') && !f.get('status').textContent.includes('PRIVATE_'));
  await f.get('start').emit('click'); check('No implicit retry of completed intent', f.calls.length === 1 && f.get('start').disabled);
  const whatif = fixture(); await open(whatif); good(whatif, 'WHATIF_ONLY'); await whatif.get('whatif').emit('click');
  const dry = JSON.parse(whatif.calls[0].options.body);
  check('Conscious WhatIf without effect checkbox uses Confirmed false', dry.Action === 'WhatIf' && dry.Confirmed === false && whatif.get('status').textContent.includes('kein Start') && whatif.get('api-key').value === '');
  for (const [field, value] of [['api-key', 'short'], ['dimension', '1.2'], ['port', '1023'], ['backend', 'LlamaCppCPU'], ['accelerator', 'NPU'], ['alias', 'bad/path'], ['lease', '120'], ['private-key', 'x'.repeat(4097)]]) {
    const bad = fixture(); await open(bad); bad.get('confirm').checked = true; bad.get(field).value = value; await bad.get('start').emit('click'); check('Invalid ' + field + ' zero dispatch', bad.calls.length === 0 && !bad.get('status').textContent.includes('PRIVATE_'));
  }
  const aggregate = fixture(); await open(aggregate); aggregate.get('confirm').checked = true; for (const id of ['runtime', 'model', 'certificate', 'private-key', 'trusted-root']) aggregate.get(id).value = '"'.repeat(4096); await aggregate.get('start').emit('click'); check('Aggregate JSON escaping bound rejects combination of per-field maxima', aggregate.calls.length === 0);
  for (const [name, mutate] of [['extra secret', p => { p.Key = 'PRIVATE_RESPONSE_CANARY'; }], ['wrong SQL', p => { p.SqlReadiness = 'READY'; }], ['grant', p => { p.AutoStopAllowed = true; }], ['string bool', p => { p.PossibleOwnSession = 'true'; }], ['invalid id', p => { p.OperationId = 'PRIVATE_RESPONSE_CANARY'; }], ['unknown status', p => { p.Status = 'PRIVATE_RESPONSE_CANARY'; }]]) {
    const bad = fixture(); await open(bad); bad.get('confirm').checked = true; good(bad, 'ENDPOINT_VERIFIED', mutate); await bad.get('start').emit('click'); check('Malformed DTO ' + name + ' fixed unconfirmed no raw echo', bad.get('result').textContent === '' && bad.get('status').textContent.includes('nicht bestätigt') && !bad.get('status').textContent.includes('PRIVATE_'));
  }
  const falseDry = fixture(); await open(falseDry); good(falseDry); await falseDry.get('whatif').emit('click'); check('WhatIf response cannot uplift to endpoint success', falseDry.get('result').textContent === '' && falseDry.get('status').textContent.includes('nicht bestätigt'));
  for (const status of ['NOT_CONFIRMED', 'RECOVERY_REQUIRED']) { const failed = fixture(); await open(failed); failed.get('confirm').checked = true; good(failed, status); await failed.get('start').emit('click'); check('Fixed ' + status + ' preserves no-retry notice', failed.get('result').textContent === '' && failed.get('start').disabled && failed.get('status').textContent.includes(status === 'RECOVERY_REQUIRED' ? status : 'nicht bestätigt')); }
  const busy = fixture(); await open(busy); busy.get('confirm').checked = true; let finish;
  busy.responses.push(() => new Promise(done => { finish = done; })); const pending = busy.get('start').emit('click'); await busy.get('start').emit('click');
  check('Busy disables fields/dispatch and clears key immediately', busy.calls.length === 1 && busy.get('runtime').disabled && busy.get('api-key').value === '');
  await busy.get('close').emit('click'); finish({ ok: true, json: async () => result() }); await pending;
  check('Cancel after dispatch does not stop and ignores late success', busy.calls.length === 1 && busy.get('result').textContent === '' && busy.get('status').textContent.includes('aktiv sein'));
  const late = fixture(); await open(late); late.get('confirm').checked = true; let reject;
  late.responses.push(() => new Promise((done, fail) => { reject = fail; })); const old = late.get('start').emit('click'); await late.get('dialog').emit('cancel'); reject(new Error('PRIVATE_SECRET_CANARY')); await old;
  check('Late failure cannot replace cancel status or expose exception', late.get('result').textContent === '' && late.get('status').textContent.includes('aktiv sein') && !late.get('status').textContent.includes('PRIVATE_'));
  check('Actual JS has no storage/raw HTML/job/session-stop action', !/localStorage|sessionStorage|innerHTML|\/api\/actions|\/api\/commands|\/api\/llama-sessions/.test(source));
  console.log('LLAMA_START_JS_CHECKS: ' + checks + ' PASS; 0 FAIL');
})().catch(error => { console.error(error); process.exitCode = 1; });
