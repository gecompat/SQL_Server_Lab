'use strict';
// Actual component and synthetic DOM/HTTP leaves, no browser or SQL proof.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../../..');
const source = fs.readFileSync(path.join(root, 'Ui/tls-live-qualification.js'), 'utf8');
let now = Date.parse('2026-10-23T12:00:00Z'), expiry, passed = 0;
const events = {}, windowEvents = {}, requests = [];
class Element {
  constructor() { this.textContent = ''; this.disabled = false; this.dataset = {}; this.events = {}; this.children = []; }
  append(...items) { this.children.push(...items); }
  setAttribute(k, v) { this[k] = v; }
  addEventListener(k, f) { this.events[k] = f; }
}
const document = { hidden: false, createElement: () => new Element(), addEventListener: (k, f) => { events[k] = f; } };
const window = { addEventListener: (k, f) => { windowEvents[k] = f; },
  setTimeout: (f, ms) => { if (ms <= 1000) Promise.resolve().then(f); else expiry = f; return 1; }, clearTimeout: () => { expiry = null; } };
class Clock extends Date { static now() { return now; } }
let postReply, pollReply, workflowReply;
const context = vm.createContext({ window, document, Date: Clock, console,
  sqlServerLabUiFetch: async (url, options) => {
    requests.push({ url, options });
    if (url === '/api/workflow') return workflowReply();
    return options?.method === 'POST' ? postReply() : pollReply();
  } });
vm.runInContext(source, context);
const component = window.sqlServerLabTlsLiveQualification;
const target = { runId: '11111111-1111-4111-8111-111111111111', instanceId: 'primary', provider: 'docker',
  settings: { Status: 'CONFIGURED_CONNECTION_STRING', Encrypt: true, TrustServerCertificate: false } };
const id = 'a'.repeat(32);
function result() {
  return { ContractVersion: 'SqlServerLab.TlsLiveQualificationResult/0.1', Status: 'QUALIFIED_AT_OBSERVATION',
    RunId: target.runId, InstanceId: 'primary', Provider: 'docker', SqlVersion: '2025', Patch: 'cu9', SqlBuild: '17.0.5005.3',
    Encrypt: true, TrustServerCertificate: false, QualifiedAtUtc: new Date(now + 1).toISOString(),
    ObservedAtUtc: new Date(now + 2).toISOString(), ExpiresAtUtc: new Date(now + 900000).toISOString(),
    ClientChecks: ['SYSTEM_DATA_SQLCLIENT', 'ODBC_SQLCMD'], Evidence: 'FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD', WireCertificateFingerprint: 'NOT_OBSERVED' };
}
function mount(selection = target) {
  const article = new Element(), container = { querySelectorAll: () => [article] };
  component.mount(container, [selection]);
  return { article, button: article.children[0], status: article.children[1] };
}
function responses(value) {
  postReply = async () => ({ ok: true, json: async () => ({ Status: 'ACCEPTED', Id: id }) });
  pollReply = async () => { now += 10; return { ok: true, json: async () => ({ Status: 'COMPLETE', Id: id, Result: value }) }; };
}
function check(name, body) { body(); passed++; console.log('PASS ' + name); }
(async () => {
  let view = mount();
  check('Unavailable capability disables action and metadata rendering makes zero SQL requests', () => { assert.equal(view.button.disabled, true); assert.equal(requests.length, 0); });
  component.setAvailable(true); view = mount();
  responses(result()); await view.button.events.click();
  check('Explicit click submits exactly the selected tuple and polls only the accepted job', () => {
    assert.deepEqual(JSON.parse(requests[0].options.body), { RunId: target.runId, InstanceId: 'primary', Provider: 'docker' });
    assert.equal(requests[1].url, '/api/tls-live-qualification/' + id); assert.match(view.status.textContent, /Beide Clients erfolgreich/);
    assert.doesNotMatch(view.status.textContent, /QUALIFIED|17\.0|StateRoot|Passwor/);
  });
  check('Observation expires without another workflow fetch or SQL check', () => { const before = requests.length; expiry(); assert.match(view.status.textContent, /Keine aktuelle/); assert.equal(requests.length, before); });
  for (const change of [
    (r) => { r.RunId = '22222222-2222-4222-8222-222222222222'; },
    (r) => { r.Provider = 'podman'; }, (r) => { r.ExtraSecret = 'SYNTHETIC_SECRET'; },
    (r) => { r.QualifiedAtUtc = new Date(now - 1).toISOString(); },
    (r) => { r.ExpiresAtUtc = new Date(now - 1).toISOString(); },
    (r) => { r.TrustServerCertificate = 'false'; }, (r) => { r.ClientChecks = ['SYSTEM_DATA_SQLCLIENT']; },
    (r) => { r.SqlBuild = '17.0.1000.7'; }
  ]) {
    view = mount(); const value = result(); change(value); responses(value); await view.button.events.click();
    check('Foreign, stale, untyped or unclosed response cannot show qualification', () => assert.match(view.status.textContent, /nicht bestätigt/));
  }
  view = mount(); let release;
  postReply = () => new Promise((resolve) => { release = resolve; });
  const before = requests.length, pending = view.button.events.click();
  await Promise.resolve();
  const replacement = mount();
  check('Workflow refresh keeps an outstanding job locked and does not start a replacement', () => { assert.equal(replacement.button.disabled, true); assert.equal(requests.length, before + 1); });
  const value = result(); pollReply = async () => { now += 10; return { ok: true, json: async () => ({ Status: 'COMPLETE', Id: id, Result: value }) }; };
  release({ ok: true, json: async () => ({ Status: 'ACCEPTED', Id: id }) }); await pending;
  check('Late success from a previous workflow generation is discarded', () => { assert.match(replacement.status.textContent, /Keine aktuelle/); assert.equal(replacement.button.disabled, false); });
  view = mount(); responses(result()); await view.button.events.click();
  events.click({ target: { closest: () => ({}) } });
  check('Another button or lifecycle action invalidates an earlier observation', () => assert.match(view.status.textContent, /Keine aktuelle/));
  view = mount(); responses(result()); await view.button.events.click(); document.hidden = true; events.visibilitychange();
  check('Backgrounding the page clears an observation', () => assert.match(view.status.textContent, /Keine aktuelle/));
  view = mount({ ...target, settings: { ...target.settings, TrustServerCertificate: true } });
  check('True/default or unsupported target has no live action', () => assert.equal(view.article.children.length, 0));
  const app = fs.readFileSync(path.join(root, 'Ui/app.js'), 'utf8');
  vm.runInContext(app.slice(app.indexOf('async function refresh(mediaRoot'), app.indexOf('async function refreshUiConfig()')), context);
  let renders = 0;
  context.workflowRefreshTimer = null;
  context.renderWorkflow = () => { renders++; component.invalidate(); };
  workflowReply = async () => ({ ok: true, json: async () => ({ Refreshing: false, Snapshot: {} }) });
  view = mount();
  postReply = () => new Promise((resolve) => { release = resolve; });
  const active = view.button.events.click(); await Promise.resolve();
  const requestsBeforeBackground = requests.length;
  await context.refresh(undefined, true);
  check('Automatic workflow refresh defers while the actual live job is pending', () => {
    assert.equal(requests.length, requestsBeforeBackground); assert.equal(renders, 0); assert.equal(view.button.disabled, true);
  });
  const current = result(); pollReply = async () => { now += 10; return { ok: true, json: async () => ({ Status: 'COMPLETE', Id: id, Result: current }) }; };
  release({ ok: true, json: async () => ({ Status: 'ACCEPTED', Id: id }) }); await active;
  check('A long live job can publish its fresh result before automatic rendering resumes', () => assert.match(view.status.textContent, /Beide Clients erfolgreich/));
  await context.refresh(undefined, true);
  check('Automatic refresh resumes and invalidates the completed observation', () => { assert.equal(renders, 1); assert.match(view.status.textContent, /Keine aktuelle/); });
  let releaseWorkflow;
  workflowReply = () => new Promise((resolve) => { releaseWorkflow = resolve; });
  const inFlightRefresh = context.refresh(undefined, true); await Promise.resolve();
  postReply = () => new Promise((resolve) => { release = resolve; });
  const duringRefresh = view.button.events.click(); await Promise.resolve();
  releaseWorkflow({ ok: true, json: async () => ({ Refreshing: false, Snapshot: {} }) }); await inFlightRefresh;
  check('An automatic workflow response already in flight cannot invalidate a new live job', () => assert.equal(renders, 1));
  workflowReply = async () => ({ ok: true, json: async () => ({ Refreshing: false, Snapshot: {} }) });
  await context.refresh();
  check('Explicit workflow refresh still invalidates the pending observation immediately', () => { assert.equal(renders, 2); assert.match(view.status.textContent, /Keine aktuelle/); });
  const late = result(); pollReply = async () => { now += 10; return { ok: true, json: async () => ({ Status: 'COMPLETE', Id: id, Result: late }) }; };
  release({ ok: true, json: async () => ({ Status: 'ACCEPTED', Id: id }) }); await duringRefresh;
  check('Explicit refresh continues to veto the late SQL result', () => assert.match(view.status.textContent, /Keine aktuelle/));
  view = mount();
  workflowReply = () => new Promise((resolve) => { releaseWorkflow = resolve; });
  const beforeErrorRefresh = context.refresh(undefined, true); await Promise.resolve();
  postReply = async () => ({ ok: true, json: async () => ({ Status: 'ACCEPTED', Id: id }) });
  pollReply = async () => ({ ok: false });
  await view.button.events.click();
  assert.match(view.status.textContent, /nicht bestätigt/);
  const rendersBeforeErrorResponse = renders;
  releaseWorkflow({ ok: true, json: async () => ({ Refreshing: false, Snapshot: {} }) }); await beforeErrorRefresh;
  check('A background response started before the probe cannot erase its completed rejection', () => {
    assert.equal(renders, rendersBeforeErrorResponse); assert.match(view.status.textContent, /nicht bestätigt/);
  });
  view = mount();
  workflowReply = () => new Promise((resolve) => { releaseWorkflow = resolve; });
  const beforeSuccessRefresh = context.refresh(undefined, true); await Promise.resolve();
  responses(result()); await view.button.events.click();
  const rendersBeforeSuccessResponse = renders;
  releaseWorkflow({ ok: true, json: async () => ({ Refreshing: false, Snapshot: {} }) }); await beforeSuccessRefresh;
  check('A background response started before the probe cannot erase its completed success', () => {
    assert.equal(renders, rendersBeforeSuccessResponse); assert.match(view.status.textContent, /Beide Clients erfolgreich/);
  });
  const server = fs.readFileSync(path.join(root, 'Tools/Start-SqlServerLabUi.ps1'), 'utf8');
  check('Actual route remains after operator guard and uses bounded body reader and async custody', () => {
    const route = server.indexOf("if ($path -eq '/api/tls-live-qualification')");
    assert.ok(route > server.indexOf('Get-UiOperatorDecision -Request'));
    const block = server.slice(route, server.indexOf("if ($path -eq '/api/container-autostart-preview')", route));
    assert.match(block, /Read-UiJsonRequestBody -Request \$context.Request -MaxBytes 2048/);
    assert.match(block, /Start-UiTlsLiveQualificationJob/); assert.match(block, /TLS_LIVE_HTTP_REJECTED/);
    assert.doesNotMatch(block, /Exception\.Message|Test-SqlServerLabTlsQualification -/);
  });
  console.log(`Ergebnis: ${passed} PASS, 0 FAIL`);
})().catch((error) => { console.error(error); process.exitCode = 1; });
