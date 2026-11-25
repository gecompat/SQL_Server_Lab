'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../../..');
const html = fs.readFileSync(path.join(root, 'Ui/index.html'), 'utf8');
const script = fs.readFileSync(path.join(root, 'Ui/ai-shared-gateway-plan.js'), 'utf8');

class Control {
  constructor() {
    this.events = new Map();
    this.value = '';
    this.checked = false;
  }
  addEventListener(name, handler) {
    this.events.set(name, handler);
  }
  async fire(name) {
    return this.events.get(name)?.({preventDefault() {}});
  }
}

const prefix = 'external-model-endpoint-';
const controls = new Map([...html.matchAll(/id="(external-model-endpoint-[^"]+)"/g)].map(match => [match[1],new Control()]));
const item = id => controls.get(prefix + id);
const form = item('form');
form.reportValidity = () => true;
form.reset = () => {
  for (const name of ['plan','ca','reference']) item(name).value = '';
  item('confirm').checked = false;
};
item('dialog').showModal = () => { item('dialog').open = true; };
item('dialog').close = () => {
  item('dialog').open = false;
  return item('dialog').fire('close');
};
const sent = [];
const context = vm.createContext({
  URL, TextEncoder, document: {querySelector: selector => controls.get(selector.slice(1))},
  sqlServerLabUiFetch(url, options) { return new Promise(resolve => sent.push({url,options,resolve})); }
});
vm.runInContext(script, context, {timeout: 5000});

const plan = {
  Contract:{Name:'SqlServerLab.AiExternalModelPlan',Version:'1.0'}, Status:'NOT_PROBED', EvidenceStatus:'CONFIGURATION_ONLY',
  PlanKey:'a'.repeat(64), ServerCertificateSha256:'b'.repeat(64), Backend:'LlamaCppOpenVino',
  Dimension:3, Location:'https://localhost:18443/v1/embeddings', RuntimeModel:'fixture-model'
};
const receipt = {
  Contract:{Name:'SqlServerLab.AiExternalModelEndpointReceipt',Version:'1.0'}, Status:'ENDPOINT_VERIFIED', EvidenceStatus:'LIVE_ENDPOINT',
  PlanKey:plan.PlanKey, Backend:plan.Backend, Dimension:plan.Dimension, HttpStatus:200, ServerCertificateSha256:plan.ServerCertificateSha256,
  DurationMilliseconds:3, VerifiedAtUtc:'2026-11-25T12:00:00.0000000Z', ReceiptKey:'c'.repeat(64),
  VerifiedEvidence:['HTTPS_CERTIFICATE_MATCH','OPENAI_RESPONSE_SHAPE_MATCH','RUNTIME_MODEL_MATCH','EMBEDDING_DIMENSION_MATCH','FINITE_NUMERIC_VECTOR_MATCH'],
  PendingEvidence:['RUNTIME_BINARY_MATCH','MODEL_FILE_MATCH','ACCELERATOR_RUNTIME_ATTESTATION']
};
let passed = 0;
const check = (message, result) => { assert.ok(result,message); passed++; };

(async () => {
  await item('open').fire('click');
  item('plan').value = JSON.stringify(plan);
  await item('plan').fire('input');
  await form.fire('submit');
  check('Opening or entering a plan does not contact the endpoint', sent.length === 0 && item('submit').disabled);
  check('The operator can see the intended endpoint and model', item('selection').textContent.includes('https://localhost:18443'));
  item('reference').value = 'SQL_SERVER_LAB_SECRET_FIXTURE';
  await item('reference').fire('input');
  item('confirm').checked = true;
  await item('confirm').fire('change');
  const pending = form.fire('submit');
  await form.fire('submit');
  await item('close').fire('click');
  const first = sent[0];
  check('Confirmation dispatches exactly one bounded parameter set', sent.length === 1 &&
    first.url === '/api/ai-external-model/endpoint' && item('dialog').open &&
    JSON.stringify(JSON.parse(first.options.body)) === JSON.stringify({
      Plan:plan,Confirmed:true,TrustedRootPem:'',ApiKeyReference:'SQL_SERVER_LAB_SECRET_FIXTURE'
    }));
  first.resolve({ok:true,json:async () => receipt});
  await pending;
  check('One matching confirmed receipt is available to copy',
    !item('result-box').hidden && JSON.parse(item('result').value).ReceiptKey === receipt.ReceiptKey && item('submit').disabled);
  item('confirm').checked = true;
  await item('confirm').fire('change');
  item('ca').value = 'synthetic public CA';
  await item('ca').fire('input');
  check('Editing certificate input clears the old receipt and confirmation', item('result-box').hidden && item('submit').disabled);
  item('confirm').checked = true;
  await item('confirm').fire('change');
  const drift = form.fire('submit');
  sent[1].resolve({ok:true,json:async () => ({...receipt,PlanKey:'d'.repeat(64),Private:'PRIVATE_CANARY'})});
  await drift;
  check('Foreign receipts and unknown values are withheld without retry',
    sent.length === 2 && item('result').value === '' && !item('status').textContent.includes('PRIVATE_CANARY'));
  await item('close').fire('click');
  check('Closing releases inputs and receipt', item('plan').value === '' && item('reference').value === '' && item('ca').value === '');
  console.log('GUIDED HTTPS MODEL ENDPOINT UI: PASS (' + passed + ')');
})().catch(error => {console.error(error);process.exitCode=1;});
