'use strict';
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../../..');
const html = fs.readFileSync(path.join(root, 'Ui/index.html'), 'utf8');
const source = fs.readFileSync(path.join(root, 'Ui/evaluation-refresh-plan.js'), 'utf8');
class Element {
  constructor() { this.value = ''; this.textContent = ''; this.disabled = false; this.open = false; this.children = []; this.events = new Map(); }
  addEventListener(type, callback) { this.events.set(type, [...(this.events.get(type) || []), callback]); }
  replaceChildren() { this.children = []; this.value = ''; }
  appendChild(child) { this.children.push(child); }
  showModal() { this.open = true; }
  close() { this.open = false; return this.fire('close'); }
  async fire(type) { for (const callback of this.events.get(type) || []) await callback({}); }
}
const nodes = new Map([...html.matchAll(/\bid="(evaluation-refresh-[^"]+)"/g)].map(match => [match[1], new Element()]));
const node = id => { const value = nodes.get('evaluation-refresh-' + id); assert.ok(value, 'Actual HTML ' + id); return value; };
node('mode').value = 'FREE_SLOT_REPLACEMENT';
const requests = [];
const context = vm.createContext({ document: { querySelector: selector => nodes.get(selector.slice(1)), createElement: () => new Element() },
  sqlServerLabUiFetch(url, options) { assert.equal(url, '/api/evaluation-refresh-plan'); let resolve; const promise = new Promise(done => { resolve = done; }); requests.push({ options, resolve }); return promise; },
  queueBackgroundAction() { throw new Error('FORBIDDEN_JOB'); }, startPublicCommand() { throw new Error('FORBIDDEN_GENERIC_COMMAND'); }, console });
vm.runInContext(source, context, { timeout: 5000 });
const own = { RunId: '33333333-3333-4333-8333-333333333333', ScopeId: '44444444-4444-4444-8444-444444444444', InstanceId: 'primary', State: 'RUNNING', Digest: 'a'.repeat(64) };
const metadata = { ContractVersion: 'SqlServerLab.EvaluationRefreshBrowser/1.0', Status: 'METADATA_ONLY', Runs: [own], SqlReadiness: 'NOT_CHECKED', Actions: [], MutationAllowed: false, ExecutionSupported: false };
const steps = {
  FREE_SLOT_REPLACEMENT: ['Freien Slot und getrennte Restlaufzeiten prüfen.', 'Neue Medien und Zielbindung separat bestätigen; ein Clone erneuert keine Evaluation.'],
  RECONSTRUCT_LAB: ['Deklarative Rekonstruktion und entbehrlichen Zustand klären.', 'Datenübernahme, Gleichwertigkeit und Rückfall separat nachweisen.'],
  STATEFUL_MIGRATION: ['Serverobjekte, Schlüssel und externe Abhängigkeiten getrennt inventarisieren.', 'DATABASE_FILES_ONLY ist kein vollständiger Instanztransfer; Cutover und Rückfall fehlen.']
};
const result = mode => ({ ContractVersion: metadata.ContractVersion, Status: 'BLOCKED', Mode: mode, RunId: own.RunId, ScopeId: own.ScopeId, InstanceId: own.InstanceId,
  Evaluations: [{ Component: 'Windows', Status: 'CRITICAL', DeadlineSource: 'PERSISTED_WINDOWS_ACTIVATION', EvidenceStatus: 'HISTORICAL_METADATA', EvaluationExpiresAt: '2030-01-01T00:00:00.1234567Z', DaysRemaining: 3 },
    { Component: 'SqlServer', Status: 'UNKNOWN', DeadlineSource: 'EVIDENCE_MISSING', EvidenceStatus: 'EVIDENCE_MISSING', EvaluationExpiresAt: null, DaysRemaining: null }],
  Blockers: ['CURRENT_WINDOWS_LICENSE_PROOF_NOT_AVAILABLE', 'SQL_EVALUATION_EVIDENCE_REQUIRED'], NextSteps: steps[mode], SqlReadiness: 'NOT_CHECKED', FreshWindowsLicenseProof: false, FullInstanceMigration: false, EquivalenceStatus: 'NOT_VERIFIED', TransferAuthority: 'NONE', Actions: [], MutationAllowed: false, ExecutionSupported: false });
const respond = (request, body, ok = true) => request.resolve({ ok, async json() { return body; } });
let checks = 0;
const check = (label, value) => { assert.ok(value, label); checks++; console.log('PASS ' + label); };
async function readMetadata(body = metadata) { const pending = node('read').fire('click'); respond(requests.at(-1), body); await pending; }
(async () => {
  await node('open').fire('click'); await node('close').fire('click');
  check('Open back has zero requests or dispatch', requests.length === 0);
  await node('open').fire('click'); node('root').value = 'SYNTHETIC_REGISTERED_ROOT';
  const pending = node('read').fire('click'); await node('read').fire('click');
  check('Busy read is single with editing disabled', requests.length === 1 && node('run').disabled && node('root').disabled);
  await node('dialog').fire('cancel'); node('dialog').open = false; respond(requests[0], metadata); await pending;
  check('Escape late metadata cannot restore selection', node('run').children.length === 0 && node('result').textContent === '');
  await node('open').fire('click'); await readMetadata();
  check('Actual choices show own SQL instance provider state', node('run').children[0].textContent.includes('primary · Hyper-V · RUNNING'));
  check('Read shape contains only explicit root and action', Object.keys(JSON.parse(requests.at(-1).options.body)).sort().join(',') === 'Action,DataRoot');
  for (const mode of Object.keys(steps)) {
    node('mode').value = mode; await node('mode').fire('change'); const count = requests.length;
    const preview = node('preview').fire('click'); await node('preview').fire('click');
    const payload = JSON.parse(requests.at(-1).options.body);
    check('Exact RAM selection and public mode ' + mode, requests.length === count + 1 && payload.Mode === mode && Object.keys(payload).sort().join(',') === 'Action,DataRoot,Mode,Selection' && JSON.stringify(payload.Selection) === JSON.stringify(own));
    respond(requests.at(-1), result(mode)); await preview;
    check('Blocked separate Windows SQL display ' + mode, node('status').textContent.includes('BLOCKED') && node('result').textContent.includes('Windows: CRITICAL') && node('result').textContent.includes('SQL Server: UNKNOWN') && node('status').textContent.includes('NOT_CHECKED') && node('result').textContent.includes('Nächste Schritte'));
  }
  const late = node('preview').fire('click'); await node('close').fire('click'); respond(requests.at(-1), result('STATEFUL_MIGRATION')); await late;
  check('Close late preview is ignored without adoption', node('result').textContent === '' && node('run').children.length === 0);
  await node('open').fire('click'); await readMetadata();
  const lateFailure = node('preview').fire('click'); node('mode').value = 'RECONSTRUCT_LAB'; await node('mode').fire('change'); respond(requests.at(-1), { Code: 'PRIVATE_SECRET_CANARY' }, false); await lateFailure;
  check('Late failure after mode change cannot erase newer selection or show canary', node('run').children.length === 1 && !node('status').textContent.includes('PRIVATE_SECRET'));
  const changing = node('preview').fire('click'); node('root').value = 'CHANGED_ROOT'; await node('root').fire('input'); respond(requests.at(-1), result('RECONSTRUCT_LAB')); await changing;
  check('Changed root invalidates late preview and disables preview', node('run').children.length === 0 && node('result').textContent === '' && node('preview').disabled);
  for (const bad of [{ ...metadata, MutationAllowed: true }, { ...metadata, Extra: 'PRIVATE_HOST_CANARY' }, { ...metadata, Runs: [{ ...own, State: 'RECOVERY_REQUIRED' }] }, { ...metadata, Runs: [own, own] }]) {
    await readMetadata(bad); check('Invalid metadata cleared with fixed safe message', node('run').children.length === 0 && node('status').textContent.includes('nicht bestätigt') && !node('status').textContent.includes('PRIVATE_HOST'));
  }
  const mutations = [body => { body.ExecutionSupported = true; }, body => { body.Actions = ['Apply']; }, body => { body.ScopeId = own.RunId; }, body => { body.NextSteps = ['PRIVATE_SECRET_CANARY', 'x']; }, body => { body.Evaluations[0].DeadlineSource = 'PRIVATE_HOST_CANARY'; }, body => { body.Evaluations[1].DaysRemaining = '0'; }, body => { body.Extra = 'PRIVATE_CANARY'; }];
  for (const mutate of mutations) {
    await readMetadata(); const mode = node('mode').value; const body = result(mode); mutate(body);
    const request = node('preview').fire('click'); respond(requests.at(-1), body); await request;
    check('Invalid authority shape code text rejected without raw display', node('result').textContent === '' && node('run').children.length === 0 && !node('status').textContent.includes('PRIVATE_'));
  }
  await readMetadata(); const count = requests.length; node('run').value = 'foreign'; await node('run').fire('change'); await node('preview').fire('click');
  check('Forged selection has zero preview dispatch', requests.length === count);
  check('All requests dedicated POST no job apply or event', requests.every(item => item.options.method === 'POST') && !source.includes('localStorage') && !source.includes('innerHTML'));
  console.log('EVALUATION_REFRESH_UI_CHECKS: ' + checks + ' PASS; 0 FAIL');
})().catch(error => { console.error(error); process.exitCode = 1; });
