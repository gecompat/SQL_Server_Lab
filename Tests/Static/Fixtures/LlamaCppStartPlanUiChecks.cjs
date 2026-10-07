'use strict';
const fs = require('fs');
const path = require('path');
const vm = require('vm');
const assert = require('assert/strict');
const root = path.resolve(__dirname, '../../..');
const source = fs.readFileSync(path.join(root, 'Ui/llama-start-plan.js'), 'utf8');
let checks = 0;
function check(name, value) { assert.ok(value, name); checks++; }
const ids = ['open', 'dialog', 'runtime', 'model', 'backend', 'accelerator', 'dimension', 'pooling', 'port', 'timeout', 'lease', 'context', 'status', 'result', 'preview', 'close'];
function fixture() {
  const elements = new Map(ids.map(id => [id, { value: '', textContent: '', disabled: false, open: false, listeners: {}, addEventListener(event, fn) { (this.listeners[event] ||= []).push(fn); }, showModal() { this.open = true; }, close() { this.open = false; for (const fn of this.listeners.close || []) fn(); }, async emit(event) { for (const fn of this.listeners[event] || []) await fn(); } }]));
  const calls = []; const responses = [];
  const context = vm.createContext({ document: { querySelector(selector) { const id = selector.replace('#llama-start-plan-', ''); assert.ok(elements.has(id)); return elements.get(id); } }, sqlServerLabUiFetch(url, options) { calls.push({ url, options }); return responses.shift()(); } });
  vm.runInContext(source, context, { filename: 'llama-start-plan.js' });
  return { elements, context, calls, responses, get: id => elements.get(id), run: code => vm.runInContext(code, context) };
}
function populate(f) { f.get('runtime').value = 'PRIVATE_RUNTIME_CANARY'; f.get('model').value = 'PRIVATE_MODEL_CANARY'; }
function plan(inputs) {
  return { Contract: { Name: 'SqlServerLab.LlamaCppStartPlan', Version: '1.0' }, Mode: 'PLAN_ONLY', Status: 'BLOCKED', Actions: [], ExecutionSupported: false, MutationAllowed: false,
    Backend: inputs.Backend, Accelerator: inputs.Accelerator, Dimension: inputs.Dimension, Pooling: inputs.Pooling, Port: inputs.Port, StartTimeoutSeconds: inputs.StartTimeoutSeconds, LeaseSeconds: inputs.LeaseSeconds, ContextSize: inputs.ContextSize,
    RuntimeEvidence: 'FILES_ONLY', ModelFormat: 'GGUF', InputObservation: 'METADATA_STABLE_NOT_CAS', DeviceReadiness: 'NOT_CHECKED', PortAvailability: 'NOT_CHECKED', EmbeddingReadiness: 'NOT_CHECKED', TlsReadiness: 'NOT_CHECKED', PrivateKeyMatch: 'NOT_CHECKED', SanTrust: 'NOT_CHECKED', SqlReadiness: 'NOT_CHECKED',
    Blockers: ['LIVE_READINESS_NOT_CHECKED', 'TLS_AND_SECRETS_NOT_SUPPLIED', 'SQL_EMBEDDING_NOT_CHECKED'], NextSteps: ['SELECT_EXPLICIT_START_INPUTS', 'VALIDATE_TLS_AND_DEVICE_READINESS_SEPARATELY', 'USE_EXISTING_START_WITH_FRESH_INPUT_VALIDATION'] };
}
function goodResponse(f, mutate = () => {}) { f.responses.push(async () => { const inputs = JSON.parse(f.calls.at(-1).options.body).Parameters; const view = plan(inputs); mutate(view); return { ok: true, json: async () => view }; }); }
async function open(f) { await f.get('open').emit('click'); populate(f); }
(async () => {
  const f = fixture(); await open(f);
  check('Open and explicit edits do zero HTTP/file reads', f.calls.length === 0);
  await f.get('runtime').emit('input'); check('Input invalidates without HTTP', f.calls.length === 0);
  await f.get('close').emit('click'); check('Back closes and clears RAM inputs without preview', !f.get('dialog').open && f.get('runtime').value === '' && f.get('model').value === '' && f.calls.length === 0);
  await open(f); await f.get('dialog').emit('cancel'); check('Escape/cancel clears every input and does zero dispatch', Object.values(Object.fromEntries(f.elements)).filter(e => typeof e.value === 'string').every(e => e.value === '') && f.calls.length === 0);
  await open(f); goodResponse(f); await f.get('preview').emit('click');
  const payload = JSON.parse(f.calls[0].options.body);
  check('Exactly one dedicated POST with explicit ten fields', f.calls.length === 1 && f.calls[0].url === '/api/llama-start-plan' && f.calls[0].options.method === 'POST' && Object.keys(payload).sort().join() === 'Action,Parameters' && payload.Action === 'Preview' && Object.keys(payload.Parameters).length === 10);
  check('Fixed PLAN_ONLY output without path or caller text', f.get('result').textContent.includes('PLAN_ONLY / BLOCKED') && f.get('result').textContent.includes('NOT_CHECKED') && !f.get('result').textContent.includes('PRIVATE_') && !f.get('status').textContent.includes('PRIVATE_'));
  await f.get('dimension').emit('input'); check('Edit clears prior result without another request', f.get('result').textContent === '' && f.calls.length === 1);
  for (const [field, value] of [['port', '1e4'], ['dimension', '0'], ['runtime', ''], ['backend', 'llamacppcuda'], ['lease', '120'], ['accelerator', 'NPU']]) {
    const invalid = fixture(); await open(invalid); invalid.get(field).value = value; await invalid.get('preview').emit('click'); check('Invalid ' + field + ' zero HTTP', invalid.calls.length === 0 && !invalid.get('status').textContent.includes('PRIVATE_'));
  }
  for (const [name, mutate] of [['execution', p => { p.ExecutionSupported = true; }], ['extra path', p => { p.PrivatePath = 'PRIVATE_RESPONSE_CANARY'; }], ['string bool', p => { p.MutationAllowed = 'false'; }], ['changed scalar', p => { p.Port++; }], ['unknown status', p => { p.Status = 'READY'; }], ['raw blocker', p => { p.Blockers[0] = 'PRIVATE_RESPONSE_CANARY'; }], ['wrong contract', p => { p.Contract.Version = '2.0'; }]]) {
    const invalid = fixture(); await open(invalid); goodResponse(invalid, mutate); await invalid.get('preview').emit('click'); check('Unsafe DTO ' + name + ' fixed rejection', invalid.get('result').textContent === '' && !invalid.get('status').textContent.includes('PRIVATE_') && invalid.get('status').textContent.includes('nicht bestätigt'));
  }
  const busy = fixture(); await open(busy); let resolve;
  busy.responses.push(() => new Promise(done => { resolve = done; })); const pending = busy.get('preview').emit('click'); await busy.get('preview').emit('click');
  check('Busy prevents duplicate requests and disables inputs', busy.calls.length === 1 && busy.get('runtime').disabled && busy.get('preview').disabled);
  await busy.get('close').emit('click'); resolve({ ok: true, json: async () => plan(JSON.parse(busy.calls[0].options.body).Parameters) }); await pending;
  check('Close invalidates late success without restoring fields/result', busy.get('result').textContent === '' && busy.get('runtime').value === '' && !busy.get('runtime').disabled);
  const late = fixture(); await open(late); let reject;
  late.responses.push(() => new Promise((done, fail) => { reject = fail; })); const failure = late.get('preview').emit('click'); await late.get('dialog').emit('cancel'); reject(new Error('PRIVATE_ERROR_CANARY')); await failure;
  check('Cancel invalidates late failure, fixed neutral status remains', late.get('status').textContent === 'Noch keine Dateien gelesen.' && late.get('result').textContent === '');
  const changed = fixture(); await open(changed); let finish;
  changed.responses.push(() => new Promise(done => { finish = done; })); const old = changed.get('preview').emit('click'); changed.get('port').value = '19436'; await changed.get('port').emit('input'); finish({ ok: true, json: async () => plan(JSON.parse(changed.calls[0].options.body).Parameters) }); await old;
  check('Revision change also ignores late response while dialog stays open', changed.get('result').textContent === '' && changed.get('dialog').open);
  const raw = fixture(); await open(raw); raw.responses.push(async () => { throw new Error('PRIVATE_ERROR_CANARY'); }); await raw.get('preview').emit('click'); check('Raw transport error never rendered', raw.get('result').textContent === '' && !raw.get('status').textContent.includes('PRIVATE_'));
  check('No persistence/jobs/Start route or innerHTML in actual new JS', !/localStorage|sessionStorage|innerHTML|\/api\/commands|\/api\/actions|llama-sessions|Start-SqlServerLab/.test(source));
  console.log('LLAMA_START_PLAN_JS_CHECKS: ' + checks + ' PASS; 0 FAIL');
})().catch(error => { console.error(error); process.exitCode = 1; });
