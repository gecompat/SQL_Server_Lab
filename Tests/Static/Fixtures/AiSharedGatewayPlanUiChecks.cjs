'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const repository = path.resolve(__dirname, '../../..');
const html = fs.readFileSync(path.join(repository, 'Ui/index.html'), 'utf8');
const source = fs.readFileSync(path.join(repository, 'Ui/ai-shared-gateway-plan.js'), 'utf8');

class Control {
  constructor() {
    this.children = [];
    this.events = new Map();
    this.value = '';
    this.textContent = '';
    this.disabled = false;
  }
  addEventListener(name, handler) {
    this.events.set(name, handler);
  }
  async fire(name) {
    return this.events.get(name)?.({ preventDefault() {} });
  }
  appendChild(row) {
    this.children.push(row);
    row.remove = () => {
      this.children = this.children.filter(child => child !== row);
    };
  }
}

const ids = new Map([...html.matchAll(/\bid="(ai-shared-gateway-[^"]+)"/g)].map(match => [match[1], new Control()]));
const item = name => ids.get('ai-shared-gateway-' + name);
const baseFields = {
  GatewayId: 'shared-embedding', Location: 'https://localhost:18443/v1/embeddings',
  UpstreamBackend: 'LlamaCppCpu', UpstreamLocation: 'http://127.0.0.1:18080/v1/embeddings',
  RuntimeModel: 'test-model', Dimension: '768', InputProfile: 'raw', ModelSha256: 'a'.repeat(64),
  RuntimeSha256: 'b'.repeat(64), ServerCertificateSha256: 'c'.repeat(64), CertificateAuthoritySha256: 'd'.repeat(64)
};
const consumerFields = {
  RunId: '11111111-1111-4111-8111-111111111111', InstanceId: 'primary',
  DatabaseId: '22222222-2222-4222-8222-222222222222', ExternalModelName: 'TestEmbedding',
  ApiKeyReference: 'SQL_SERVER_LAB_SECRET_REFERENCE_ONLY'
};
for (const name of [...Object.keys(baseFields), ...Object.keys(consumerFields)]) {
  assert.ok(html.includes('name="' + name + '"'));
}
const form = item('author');
const values = Object.fromEntries(Object.entries(baseFields).map(([name, value]) => [name, { value }]));
form.elements = { namedItem: name => values[name] };
form.reportValidity = () => true;
item('consumer-template').content = {
  firstElementChild: {
    cloneNode() {
      const row = new Control();
      const remove = new Control();
      const fields = Object.fromEntries(Object.entries(consumerFields).map(([name, value]) => [name, { value }]));
      row.querySelector = selector => selector === '[data-remove-consumer]' ? remove : fields[selector.match(/"([^"]+)"/)[1]];
      return row;
    }
  }
};
item('service-secret-panel').scrollIntoView = () => {};
const requests = [];
const statusCalls = [];
const statusCommand = {
  Name: 'Get-SqlServerLabAiSharedGatewayStatus', SupportsShouldProcess: false, RequiresConfirmation: false,
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: [
    { Name: 'Plan', TypeName: 'System.Object', Mandatory: true, Sensitive: false, IsCredential: false }
  ] }]
};
const context = vm.createContext({
  document: { querySelector: selector => ids.get(selector.slice(1)) },
  sqlServerLabUiFetch(url, options) {
    return new Promise(resolve => requests.push({ url, options, resolve }));
  },
  publicCommandCatalog: [statusCommand],
  startPublicCommand(command, parameterSet, parameters, confirmed) {
    return new Promise(resolve => statusCalls.push({ command, parameterSet, parameters, confirmed, resolve }));
  },
  startAction() { throw new Error('Gateway preview must not start an operation'); }
});
vm.runInContext(source, context, { timeout: 5000 });

const respond = (request, body, ok = true) => request.resolve({ ok, async json() { return body; } });
const canonical = consumer => ({
  Contract: { Name: 'SqlServerLab.AiSharedGatewayPlan', Version: '1.0' },
  Status: 'BLOCKED', EvidenceStatus: 'CONFIGURATION_ONLY', GatewayId: baseFields.GatewayId,
  Consumers: consumer, PlanKey: 'e'.repeat(64)
});
let checks = 0;
const check = (label, value) => { assert.ok(value, label); checks++; };

(async () => {
  check('Initial form creates one SQL consumer and no request', item('consumers').children.length === 1 && requests.length === 0);
  values.UpstreamBackend.value = 'OpenVinoModelServer';
  await form.fire('input');
  check('The upstream hint follows the selected backend', values.UpstreamLocation.placeholder.endsWith('/v3/embeddings'));
  values.UpstreamBackend.value = baseFields.UpstreamBackend;
  await item('add-consumer').fire('click');
  item('consumers').children[1].querySelector('[name="DatabaseId"]').value = '33333333-3333-4333-8333-333333333333';
  const first = form.fire('submit');
  await form.fire('submit');
  const request = requests[0];
  const payload = JSON.parse(request.options.body);
  check('Typed narrow authoring request is dispatched once', requests.length === 1 && request.url === '/api/ai-shared-gateway/plan' &&
    request.options.method === 'POST' && payload.Dimension === 768 && payload.Consumer.length === 2 &&
    Object.keys(payload).length === 12 && Object.keys(payload.Consumer[0]).length === 5);
  await form.fire('input');
  respond(request, canonical(payload.Consumer));
  await first;
  check('Input change invalidates late plan and handoff', item('use-plan').disabled && item('read-status').disabled && item('plan-result').value === '');
  const current = form.fire('submit');
  respond(requests.at(-1), canonical(payload.Consumer));
  await current;
  check('A valid response displays only the returned blocked plan', !item('use-plan').disabled &&
    JSON.parse(item('plan-result').value).PlanKey === 'e'.repeat(64) && !item('plan-result-box').hidden);
  await item('use-plan').fire('click');
  check('Operator can reuse the plan without probing the service', item('plan-json').value === item('plan-result').value &&
    item('service-secret-panel').open && requests.length === 2);
  check('Displaying a plan does not read status automatically', statusCalls.length === 0 && !item('read-status').disabled);
  statusCommand.RequiresConfirmation = true;
  await item('read-status').fire('click');
  check('Changed command metadata blocks guided dispatch', statusCalls.length === 0 && item('plan-status').textContent.includes('nicht verfügbar'));
  statusCommand.RequiresConfirmation = false;
  const reading = item('read-status').fire('click');
  await item('read-status').fire('click');
  const statusCall = statusCalls[0];
  check('Explicit click dispatches the exact plan once through the existing command path', statusCalls.length === 1 &&
    statusCall.command === statusCommand && statusCall.parameterSet.Name === '__AllParameterSets' &&
    statusCall.confirmed === false && Object.keys(statusCall.parameters).join() === 'Plan' &&
    JSON.stringify(statusCall.parameters.Plan) === JSON.stringify(JSON.parse(item('plan-result').value)));
  await form.fire('input');
  statusCall.resolve();
  await reading;
  check('An accepted status request does not resurrect its edited plan', item('read-status').disabled && item('plan-result').value === '' &&
    !item('plan-status').textContent.includes('Auftragsprotokoll'));
  const bad = form.fire('submit');
  respond(requests.at(-1), { ...canonical(payload.Consumer), Status: 'READY', Untrusted: 'SYNTHETIC_PRIVATE' });
  await bad;
  check('Forged status invalidates result and the action', item('plan-result').value === '' && item('use-plan').disabled &&
    !item('plan-status').textContent.includes('SYNTHETIC_PRIVATE'));
  for (let index = 0; index < 65; index++) await item('add-consumer').fire('click');
  check('Browser has a bounded consumer roster', item('consumers').children.length === 64 && item('add-consumer').disabled);
  await item('consumers').children[1].querySelector('[data-remove-consumer]').fire('click');
  check('Removing a consumer re-enables the bounded add path', item('consumers').children.length === 63 && !item('add-consumer').disabled);
  console.log('AI SHARED GATEWAY UI: PASS (' + checks + ')');
})().catch(error => { console.error(error); process.exitCode = 1; });
