'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../../..');
const html = fs.readFileSync(path.join(root, 'Ui/index.html'), 'utf8');
const script = fs.readFileSync(path.join(root, 'Ui/ai-shared-gateway-plan.js'), 'utf8');

class Control {
  constructor() { this.events = new Map(); this.value = ''; this.checked = false; this.options = []; }
  addEventListener(name, handler) { this.events.set(name, handler); }
  fire(name) { return this.events.get(name)?.({preventDefault() {}}); }
  replaceChildren(...options) { this.options = options; this.value = options[0]?.value || ''; }
  add(option) { this.options.push(option); }
}

const controls = new Map([...html.matchAll(/id="(external-model-sql-lifecycle-[^"]+)"/g)].map(match => [match[1],new Control()]));
const element = name => controls.get('external-model-sql-lifecycle-' + name);
const form = element('form');
const dialog = element('dialog');
form.reportValidity = () => true;
form.reset = () => {
  for (const name of ['source','stage','secret']) element(name).value = '';
  element('confirm').checked = false;
};
dialog.showModal = () => { dialog.open = true; };
dialog.close = () => { dialog.open = false; dialog.fire('close'); };

const preflightId = 'a'.repeat(32);
const expiredId = 'b'.repeat(32);
const runningId = 'c'.repeat(32);
const applyId = 'd'.repeat(32);
const cleanupId = 'e'.repeat(32);
const embeddingId = 'f'.repeat(32);
const certificate = {
  Contract:{Name:'SqlServerLab.AiExternalModelSqlPreflightReceipt',Version:'1.0'},
  Status:'SQL_PREFLIGHT_VERIFIED',SqlPlanKey:'f'.repeat(64),RunId:'11111111-2222-4333-8444-555555555555',
  InstanceId:'primary',DatabaseName:'_FixtureDb',VerifiedAtUtc:new Date().toISOString()
};
const applied = {...certificate, Contract:{...certificate.Contract,Name:'SqlServerLab.AiExternalModelSqlApplyReceipt'},Status:'SQL_EXTERNAL_MODEL_APPLIED'};
const observedJobs = new Map();
function addJob(id, action, receipt, state = 'Completed') {
  observedJobs.set(id, {Action:action,State:state,ExternalModelSqlMutationSubmitted:false,ExternalModelSqlReceipt:receipt});
}
addJob(preflightId, 'ReadExternalModelSqlPreflight', certificate);
addJob(expiredId, 'ReadExternalModelSqlPreflight', {...certificate,VerifiedAtUtc:'2020-01-01T00:00:00Z'});
addJob(runningId, 'ReadExternalModelSqlPreflight', certificate, 'Running');

const requests = [];
let refreshes = 0;
let area = '';
vm.runInNewContext(script, {
  document:{querySelector:selector => controls.get(selector.slice(1))},
  Option:class {constructor(text,value) { this.text = text; this.value = value; }},
  observedJobs,
  readUiJobResponse(url,options) {
    return new Promise(resolve => requests.push({url,options,resolve}));
  },
  refreshJobs:async () => { refreshes++; },
  showWorkspaceArea:value => { area = value; }
});

(async () => {
  await element('open').fire('click');
  assert.deepEqual(element('source').options.map(x => x.value), ['',preflightId]);
  assert.ok(element('source').options[1].text.includes('_FixtureDb'));
  element('source').value = preflightId;
  await element('source').fire('change');
  assert.deepEqual(element('stage').options.map(x => x.value), ['', 'apply']);
  element('stage').value = 'apply';
  await element('stage').fire('change');
  element('secret').value = 'SYNTHETIC_CREDENTIAL';
  await form.fire('submit');
  assert.equal(requests.length, 0);

  element('confirm').checked = true;
  observedJobs.get(preflightId).ExternalModelSqlMutationSubmitted = true;
  await form.fire('submit');
  assert.equal(requests.length, 0);
  observedJobs.get(preflightId).ExternalModelSqlMutationSubmitted = false;
  const pending = form.fire('submit');
  assert.equal(requests.length, 1);
  assert.equal(element('secret').value, '');
  assert.equal(element('confirm').checked, false);
  assert.equal(requests[0].url, '/api/ai-external-model/sql-apply');
  assert.deepEqual(JSON.parse(requests[0].options.body), {SourceJobId:preflightId,Confirmed:true,CredentialSecret:'SYNTHETIC_CREDENTIAL'});
  await form.fire('submit');
  assert.equal(requests.length, 1);
  requests[0].resolve({id:applyId,action:'ApplyExternalModelSql'});
  await pending;
  assert.equal(dialog.open, false);
  assert.equal(area, 'messages');

  observedJobs.get(preflightId).ExternalModelSqlMutationSubmitted = true;
  addJob(applyId,'ApplyExternalModelSql',applied);
  await element('open').fire('click');
  assert.deepEqual(element('source').options.map(x => x.value), ['',applyId]);
  element('source').value = applyId;
  await element('source').fire('change');
  assert.deepEqual(element('stage').options.map(x => x.value), ['', 'embedding', 'cleanup']);
  element('stage').value = 'embedding';
  await element('stage').fire('change');
  assert.equal(element('secret').disabled, true);
  element('confirm').checked = true;
  const probe = form.fire('submit');
  assert.deepEqual(JSON.parse(requests[1].options.body), {SourceJobId:applyId,Confirmed:true});
  requests[1].resolve({id:embeddingId,action:'ReadExternalModelSqlEmbedding'});
  await probe;

  await element('open').fire('click');
  element('source').value = applyId;
  await element('source').fire('change');
  element('stage').value = 'cleanup';
  await element('stage').fire('change');
  await form.fire('submit');
  assert.equal(requests.length, 2);
  element('confirm').checked = true;
  const cleanup = form.fire('submit');
  assert.equal(requests[2].url, '/api/ai-external-model/sql-cleanup');
  assert.deepEqual(JSON.parse(requests[2].options.body), {SourceJobId:applyId,Confirmed:true});
  requests[2].resolve({id:cleanupId,action:'RemoveExternalModelSql'});
  await cleanup;
  assert.equal(refreshes, 3);
  console.log('GUIDED EXTERNAL MODEL SQL LIFECYCLE UI: PASS');
})().catch(error => { console.error(error);process.exitCode = 1; });
