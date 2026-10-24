'use strict';
// Execute the real component. DOM and HTTP are synthetic, never native proof.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../../..');
class Element {
  constructor() { this.value = ''; this.children = []; this.events = {}; this.dataset = {}; this.disabled = false; this.textContent = ''; }
  addEventListener(k, f) { this.events[k] = f; }
  append(...v) { this.children.push(...v); }
  replaceChildren(...v) { this.children = v; }
  setAttribute(k, v) { this[k] = v; }
  showModal() { this.open = true; }
  close() { this.open = false; }
}
let passed = 0, calls = [], post, get = () => ({ Targets: [], CreationBlocked: false }), timer, now = Date.parse('2026-10-24T06:00:00Z');
const elements = new Map(), events = {};
const element = (id) => { if (!elements.has(id)) elements.set(id, new Element()); return elements.get(id); };
const document = { getElementById: element, createElement: () => new Element(), addEventListener: (k, f) => { events[k] = f; } };
const window = { confirm: () => true, addEventListener: (k, f) => { events[k] = f; }, clearTimeout: () => {},
  setTimeout: (f, ms) => { if (ms <= 2000) Promise.resolve().then(f); else timer = f; return 1; } };
class Clock extends Date { static now() { return now; } }
const id = '2'.repeat(32);
function view() { return { Ref: id, Status: 'COMPLETE', Provider: 'docker', Version: '2025-CU9', LabName: '<synthetic>',
  RunId: '33333333-3333-3333-3333-333333333333', RunState: 'RUNNING', Port: 15000, Encrypt: true, TrustServerCertificate: false, ActionStatus: 'NONE', LiveResult: null }; }
const context = vm.createContext({ document, window, Date: Clock, AbortController, crypto: { randomUUID: () => '11111111-1111-1111-1111-111111111111' },
  sqlServerLabUiFetch: async (url, options) => { calls.push({ url, options }); return { ok: true, json: async () => options?.method === 'POST' ? post(url, JSON.parse(options.body)) : get(url) }; } });
vm.runInContext(fs.readFileSync(path.join(root, 'Ui/tls-authenticated-creation.js'), 'utf8'), context);
const component = window.sqlServerLabTlsCreation;
function check(name, f) { f(); passed++; console.log('PASS ' + name); }
async function submit() { return element('tls-auth-create-form').events.submit({ preventDefault() {}, submitter: { value: 'default' } }); }
(async () => {
  check('Only initial readonly session lookup, creation disabled before response', () => { assert.equal(calls.length, 1); assert.equal(calls[0].url, '/api/tls-created-targets'); assert.equal(calls[0].options.method, undefined); assert.equal(element('tls-auth-create-open').disabled, true); });
  await new Promise((resolve) => setImmediate(resolve)); calls = [];
  component.setAvailable(true);
  for (const [name, value] of Object.entries({ provider: 'docker', version: '2025-CU9', profile: 'compact', name: 'synthetic-lab', candidate: '44444444-4444-4444-4444-444444444444',
    controller: '55555555-5555-5555-5555-555555555555', location: '66666666-6666-6666-6666-666666666666', password: 'SYNTHETIC_ONLY!a9', 'password-repeat': 'wrong' })) element('tls-auth-' + name).value = value;
  await submit(); check('Password mismatch has no dispatch', () => assert.equal(calls.length, 0));
  element('tls-auth-password-repeat').value = 'SYNTHETIC_ONLY!a9';
  post = () => ({ Ref: id, Status: 'ACCEPTED' }); get = () => view();
  await submit();
  check('One explicit create, exact accepted-ref polling and no browser root', () => {
    assert.equal(calls.filter((c) => c.options?.method === 'POST').length, 1);
    assert.equal(calls[0].url, '/api/tls-creation'); assert.equal(calls[1].url, '/api/tls-created-targets/' + id);
    const payload = JSON.parse(calls[0].options.body); assert.equal(Object.keys(payload).length, 9); assert.equal(payload.Version, '2025-CU9');
    assert.equal(payload.StateRoot, undefined); assert.equal(payload.DataRoot, undefined); assert.equal(element('tls-auth-password').value, '');
  });
  check('Target renders with literal text and separate False settings', () => {
    const card = element('tls-created-targets').children[0]; assert.equal(card.children[0].textContent, '<synthetic> · docker');
    assert.match(card.children[1].textContent, /TrustServerCertificate=False/); assert.equal(card.innerHTML, undefined);
  });
  let liveCalls = 0;
  post = (url, payload) => { assert.equal(url, '/api/tls-created-targets/action'); assert.equal(payload.Ref, id); assert.equal(payload.Action, 'Live'); liveCalls++; return { Ref: id, Status: 'ACCEPTED' }; };
  get = () => { const v = view(); v.ActionStatus = 'COMPLETE'; v.LiveResult = { ContractVersion: 'SqlServerLab.TlsLiveQualificationResult/0.1', Status: 'QUALIFIED_AT_OBSERVATION', RunId: v.RunId, InstanceId: 'primary', Provider: 'docker', SqlVersion: '2025', Patch: 'cu9', SqlBuild: '17.0.5005.3',
    Evidence: 'FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD', WireCertificateFingerprint: 'NOT_OBSERVED', Encrypt: true, TrustServerCertificate: false, ClientChecks: ['SYSTEM_DATA_SQLCLIENT', 'ODBC_SQLCMD'], QualifiedAtUtc: new Date(now).toISOString(), ObservedAtUtc: new Date(now).toISOString(), ExpiresAtUtc: new Date(now + 60000).toISOString() }; return v; };
  await element('tls-created-targets').children[0].children[3].events.click();
  check('Live action bound to created reference and actual two-stack result', () => { assert.equal(liveCalls, 1); assert.match(element('tls-created-targets').children[0].children[2].textContent, /Beide Clients erfolgreich/); });
  const before = calls.length; timer();
  check('Expiry invalidates without SQL replay', () => { assert.equal(calls.length, before); assert.match(element('tls-created-targets').children[0].children[2].textContent, /Keine aktuelle/); });
  const goodLive = get;
  for (const [version, year, patch, build] of [['2019-CU32', '2019', 'cu32', '15.0.4430.1'], ['2022-CU27', '2022', 'cu27', '16.0.4295.3']]) {
    get = () => ({ Targets: [{ ...view(), Version: version }], CreationBlocked: false });
    await element('tls-created-refresh').events.click();
    check('Selected authenticated SQL profile renders ' + version, () => assert.match(element('tls-created-targets').children[0].children[1].textContent, new RegExp(version.replace('-', ' '))));
    get = () => { const v = goodLive(); v.Version = version; Object.assign(v.LiveResult, { SqlVersion: year, Patch: patch, SqlBuild: build }); return v; };
    await element('tls-created-targets').children[0].children[3].events.click();
    check('Exact selected profile accepts fresh two-stack result ' + version, () => assert.match(element('tls-created-targets').children[0].children[2].textContent, /Beide Clients erfolgreich/));
    const matchingLive = get;
    get = () => { const v = goodLive(); v.Version = '2025-CU9'; return v; };
    await element('tls-created-targets').children[0].children[3].events.click();
    check('Polling cannot replace the requested target profile ' + version, () => {
      assert.doesNotMatch(element('tls-created-targets').children[0].children[2].textContent, /Beide Clients erfolgreich/);
      assert.match(element('tls-created-targets').children[0].children[1].textContent, new RegExp(version.replace('-', ' ')));
    });
    for (const drift of [{ SqlVersion: '2025' }, { Patch: 'cu0' }, { SqlBuild: '0.0.0.0' }]) {
      get = () => { const v = matchingLive(); Object.assign(v.LiveResult, drift); return v; };
      await element('tls-created-targets').children[0].children[3].events.click();
      check('Cross-profile live result is rejected ' + version, () => assert.doesNotMatch(element('tls-created-targets').children[0].children[2].textContent, /Beide Clients erfolgreich/));
    }
  }
  get = () => ({ Targets: [view()], CreationBlocked: false });
  await element('tls-created-refresh').events.click();
  for (const change of [(r) => { r.ClientChecks = ['SYSTEM_DATA_SQLCLIENT|ODBC_SQLCMD']; },
    (r) => { r.ClientChecks = [['SYSTEM_DATA_SQLCLIENT'], ['ODBC_SQLCMD']]; },
    (r) => { r.ClientChecks = ['SYSTEM_DATA_SQLCLIENT', 'ODBC_SQLCMD', 'ODBC_SQLCMD']; },
    (r) => { r.ExpiresAtUtc = 'INVALID_DATE'; }, (r) => { r.Extra = 'SYNTHETIC_UNKNOWN'; }]) {
    get = () => { const v = goodLive(); change(v.LiveResult); return v; };
    await element('tls-created-targets').children[0].children[3].events.click();
    check('Malformed two-stack/freshness result never renders success', () => assert.doesNotMatch(element('tls-created-targets').children[0].children[2].textContent, /Beide Clients erfolgreich/));
  }
  get = () => ({ Targets: [view()], CreationBlocked: false }); await element('tls-created-refresh').events.click();
  check('Explicit refresh only reads the session list', () => assert.equal(calls.at(-1).url, '/api/tls-created-targets'));
  get = () => ({ Targets: [{ ...view(), TrustServerCertificate: 'false' }], CreationBlocked: false }); await element('tls-created-refresh').events.click();
  check('Invalid typed DTO is not promoted to a new target', () => assert.equal(element('tls-created-targets').children.length, 1));
  post = () => { throw new Error('SYNTHETIC_NETWORK_UNKNOWN'); };
  element('tls-auth-password').value = element('tls-auth-password-repeat').value = 'SYNTHETIC_ONLY!a9'; await submit();
  const after = calls.length; await submit();
  check('Unknown create response never retries automatically or on second submit', () => { assert.equal(calls.length, after); assert.equal(element('tls-auth-create-submit').disabled, true); });
  get = () => ({ Targets: [{ ...view(), Status: 'UNCONFIRMED', RunId: '', RunState: 'UNKNOWN', Port: 0 }], CreationBlocked: true });
  vm.runInContext(fs.readFileSync(path.join(root, 'Ui/tls-authenticated-creation.js'), 'utf8'), context);
  window.sqlServerLabTlsCreation.setAvailable(true);
  check('Reload remains disabled while initial status lookup is pending', () => assert.equal(element('tls-auth-create-submit').disabled, true));
  await new Promise((resolve) => setImmediate(resolve));
  const reloaded = calls.length; await submit();
  check('Reloaded unconfirmed server ticket blocks new creation', () => { assert.equal(calls.length, reloaded); assert.equal(element('tls-auth-create-open').disabled, true); assert.match(element('tls-created-status').textContent, /Frühere Erstellung unbestätigt/); });
  console.log(JSON.stringify({ Status: 'PASS', Cases: passed, ProviderActions: 0 }));
})().catch((e) => { console.error(e); process.exitCode = 1; });
