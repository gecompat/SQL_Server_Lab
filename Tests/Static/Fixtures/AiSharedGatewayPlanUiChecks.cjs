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
  replaceChildren() {
    this.children = [];
    this.value = '';
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
const preflight = item('preflight');
const paths = Object.fromEntries(['RuntimePath', 'ModelPath', 'CertificatePath', 'PrivateKeyPath', 'CertificateAuthorityPath']
  .map(name => [name, { value: '', focus() {} }]));
preflight.hidden = true;
const registrationConfirmation = { checked: false, required: false };
preflight.elements = { namedItem: name => name === 'ConfirmRegistration' ? registrationConfirmation : paths[name] };
preflight.reportValidity = () => Object.values(paths).every(path => path.value) &&
  (!registrationConfirmation.required || registrationConfirmation.checked);
preflight.reset = () => {
  for (const path of Object.values(paths)) path.value = '';
  registrationConfirmation.checked = false;
};
item('open-preflight').focus = () => {};
item('open-registration').focus = () => {};
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
item('session-dialog').showModal = function () { this.open = true; };
item('session-dialog').close = function () { this.open = false; return this.fire('close'); };
item('session-start').reportValidity = () => true;
item('session-start').reset = () => {
  item('session-lease').value = '900';
  item('session-upstream-reference').value = '';
  item('session-start-confirmed').checked = false;
};
const requests = [];
const statusCalls = [];
const observedJobs = new Map();
const jobLineCache = {};
const statusCommand = {
  Name: 'Get-SqlServerLabAiSharedGatewayStatus', SupportsShouldProcess: false, RequiresConfirmation: false,
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: [
    { Name: 'Plan', TypeName: 'System.Object', Mandatory: true, Sensitive: false, IsCredential: false }
  ] }]
};
const upstreamCommand = {
  ...statusCommand, Name: 'Test-SqlServerLabAiSharedGatewayUpstream',
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: [
    { Name: 'Plan', TypeName: 'System.Object', Mandatory: true, Sensitive: false, IsCredential: false },
    { Name: 'ApiKey', TypeName: 'System.Security.SecureString', Mandatory: false, Sensitive: true, IsCredential: false }
  ] }]
};
const preflightCommand = {
  ...statusCommand, Name: 'Test-SqlServerLabAiSharedGatewayPreflight', RequiresConfirmation: true,
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: [
    statusCommand.ParameterSets[0].Parameters[0],
    ...Object.keys(paths).map(Name => ({ Name, TypeName: 'System.String', Mandatory: true,
      Sensitive: Name === 'PrivateKeyPath', IsCredential: false }))
  ] }]
};
const registerCommand = {
  ...preflightCommand, Name: 'Register-SqlServerLabAiSharedGatewayStorage', SupportsShouldProcess: true,
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: [
    ...preflightCommand.ParameterSets[0].Parameters,
    { Name: 'StateRoot', TypeName: 'System.String', Mandatory: false, Sensitive: false, IsCredential: false },
    { Name: 'WhatIf', TypeName: 'System.Management.Automation.SwitchParameter', Mandatory: false, Sensitive: false, IsCredential: false }
  ] }]
};
const serviceCommand = {
  ...statusCommand, Name: 'Get-SqlServerLabAiSharedGatewayServicePlan',
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: [
    statusCommand.ParameterSets[0].Parameters[0],
    { Name: 'ServiceMode', TypeName: 'System.String', Mandatory: false, Sensitive: false, IsCredential: false }
  ] }]
};
const context = vm.createContext({
  document: { querySelector: selector => ids.get(selector.slice(1)), createElement: () => new Control() },
  sqlServerLabUiFetch(url, options) {
    return new Promise(resolve => requests.push({ url, options, resolve }));
  },
  publicCommandCatalog: [statusCommand, upstreamCommand, preflightCommand, registerCommand, serviceCommand],
  observedJobs, jobLineCache,
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
  await item('probe-upstream').fire('click');
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
  const renewed = form.fire('submit');
  respond(requests.at(-1), canonical(payload.Consumer));
  await renewed;
  check('Preparing a new plan sends no upstream probe', statusCalls.length === 1 && !item('probe-upstream').disabled);
  const probing = item('probe-upstream').fire('click');
  await item('probe-upstream').fire('click');
  await item('read-status').fire('click');
  const upstreamCall = statusCalls[1];
  check('The guided upstream request is bound once to the displayed plan without credentials', statusCalls.length === 2 &&
    upstreamCall.command === upstreamCommand && upstreamCall.confirmed === false &&
    Object.keys(upstreamCall.parameters).join() === 'Plan' &&
    JSON.stringify(upstreamCall.parameters.Plan) === JSON.stringify(JSON.parse(item('plan-result').value)));
  await form.fire('input');
  upstreamCall.resolve();
  await probing;
  check('Editing hides both bound actions while an upstream request finishes', item('probe-upstream').disabled &&
    item('read-status').disabled && !item('plan-status').textContent.includes('Auftragsprotokoll'));
  const shownForFiles = form.fire('submit');
  respond(requests.at(-1), canonical(payload.Consumer));
  await shownForFiles;
  await item('open-preflight').fire('click');
  paths.PrivateKeyPath.value = '/synthetic/key.pem';
  await item('cancel-preflight').fire('click');
  check('Opening and cancelling file verification clears its key path without a job',
    preflight.hidden && paths.PrivateKeyPath.value === '' && statusCalls.length === 2);
  await item('open-preflight').fire('click');
  for (const name of Object.keys(paths)) paths[name].value = '/synthetic/' + name;
  const checking = preflight.fire('submit');
  await preflight.fire('submit');
  await item('read-status').fire('click');
  const preflightCall = statusCalls[2];
  check('Only confirmation dispatches the exact displayed plan and five paths once',
    statusCalls.length === 3 && preflightCall.command === preflightCommand && preflightCall.confirmed === true &&
    Object.keys(preflightCall.parameters).length === 6 &&
    preflightCall.parameters.PrivateKeyPath === '/synthetic/PrivateKeyPath' &&
    JSON.stringify(preflightCall.parameters.Plan) === JSON.stringify(JSON.parse(item('plan-result').value)));
  check('The form does not retain paths during submission', preflight.hidden && Object.values(paths).every(path => path.value === ''));
  await form.fire('input');
  preflightCall.resolve();
  await checking;
  check('A completed submission cannot restore file verification for an edited plan',
    preflight.hidden && item('open-preflight').disabled && !item('plan-status').textContent.includes('Auftragsprotokoll'));
  const registrationPlan = form.fire('submit');
  respond(requests.at(-1), canonical(payload.Consumer));
  await registrationPlan;
  await item('open-preflight').fire('click');
  paths.PrivateKeyPath.value = '/synthetic/previous-file.pem';
  await item('open-registration').fire('click');
  check('Switching to registration clears the previous paths and explains the protected copy',
    paths.PrivateKeyPath.value === '' && registrationConfirmation.required &&
    !item('registration-confirmation').hidden && item('file-action-effect').textContent.includes('einschließlich des Schlüssels'));
  for (const name of Object.keys(paths)) paths[name].value = '/synthetic/' + name;
  await preflight.fire('submit');
  await item('cancel-preflight').fire('click');
  check('Unconfirmed submission and cancel send no registration', statusCalls.length === 3 && preflight.hidden);
  await item('open-registration').fire('click');
  for (const name of Object.keys(paths)) paths[name].value = '/synthetic/' + name;
  registrationConfirmation.checked = true;
  const registering = preflight.fire('submit');
  await preflight.fire('submit');
  const registration = statusCalls[3];
  check('Registration dispatches the bound plan and five paths once with explicit confirmation',
    statusCalls.length === 4 && registration.command === registerCommand && registration.confirmed === true &&
    Object.keys(registration.parameters).length === 6 && !('StateRoot' in registration.parameters) &&
    JSON.stringify(registration.parameters.Plan) === JSON.stringify(JSON.parse(item('plan-result').value)));
  check('Submitting registration clears paths and consent', preflight.hidden && !registrationConfirmation.checked &&
    Object.values(paths).every(path => path.value === ''));
  registration.resolve();
  await registering;
  check('A displayed plan only exposes the service control and defaults to Auto',
    !item('service-controls').hidden && !item('prepare-service').disabled && item('service-mode').value === 'Auto' && statusCalls.length === 4);
  item('service-mode').value = 'Unrecognized';
  await item('prepare-service').fire('click');
  check('Unknown service mode dispatches no request', statusCalls.length === 4);
  item('service-mode').value = 'WindowsS4U';
  const servicePlanning = item('prepare-service').fire('click');
  await item('prepare-service').fire('click');
  const servicePlan = statusCalls[4];
  check('Service planning binds the exact plan and chosen mode once',
    statusCalls.length === 5 && servicePlan.command === serviceCommand && servicePlan.confirmed === false &&
    servicePlan.parameters.ServiceMode === 'WindowsS4U' && Object.keys(servicePlan.parameters).length === 2 &&
    JSON.stringify(servicePlan.parameters.Plan) === JSON.stringify(JSON.parse(item('plan-result').value)));
  await form.fire('input');
  servicePlan.resolve();
  await servicePlanning;
  check('Changing the plan resets the service mode and discards stale output',
    item('service-controls').hidden && item('prepare-service').disabled && item('service-mode').value === 'Auto' &&
    !item('plan-status').textContent.includes('Auftragsprotokoll'));
  const handoffPlanRequest = form.fire('submit');
  respond(requests.at(-1), canonical(payload.Consumer));
  await handoffPlanRequest;
  item('service-mode').value = 'WindowsS4U';
  const handoffRequest = item('prepare-service').fire('click');
  const jobId = '1'.repeat(32);
  statusCalls[5].resolve({ id: jobId });
  await handoffRequest;
  const currentServicePlan = {
    Contract: { Name: 'SqlServerLab.AiSharedGatewayServicePlan', Version: '1.0' },
    Status: 'READY', GatewayId: baseFields.GatewayId, GatewayPlanKey: 'e'.repeat(64),
    PlanKey: 'f'.repeat(64), ServiceMode: 'WINDOWS_S4U_TASK'
  };
  const jobAction = 'Command: ' + serviceCommand.Name;
  const receiptLine = plan => '[ERGEBNIS] ' + JSON.stringify({ Command: serviceCommand.Name,
    ParameterSet: '__AllParameterSets', Result: [plan] });
  observedJobs.set(jobId, { State: 'Running', Action: jobAction });
  jobLineCache[jobId] = [receiptLine(currentServicePlan)];
  item('service-plan-json').value = JSON.stringify({ ...currentServicePlan, GatewayPlanKey: '0'.repeat(64) });
  await item('use-plan').fire('click');
  check('Pending jobs and foreign plans never populate the service form', item('service-plan-json').value === '');
  observedJobs.set(jobId, { State: 'Completed', Action: jobAction });
  jobLineCache[jobId] = [receiptLine({ ...currentServicePlan, Status: 'BLOCKED' })];
  await item('use-plan').fire('click');
  check('Completed blocked plans are never transferred as ready', item('service-plan-json').value === '');
  jobLineCache[jobId] = [receiptLine(currentServicePlan)];
  await item('use-plan').fire('click');
  check('Explicit transfer fills both plan fields for the matching completed job and reads no vault',
    JSON.parse(item('service-plan-json').value).PlanKey === currentServicePlan.PlanKey &&
    JSON.parse(item('plan-json').value).PlanKey === currentServicePlan.GatewayPlanKey &&
    item('service-secret-result').textContent.includes('Der passende bereite Dienstplan ist übernommen') && statusCalls.length === 6);
  item('service-mode').value = 'SystemdUser';
  await item('use-plan').fire('click');
  check('Changing the service mode clears an incompatible transferred plan', item('service-plan-json').value === '');
  const unavailable = item('open-session-start').fire('click');
  const unavailableRequest = requests.at(-1);
  respond(unavailableRequest, { VaultAvailable: false, Items: [] });
  await unavailable;
  item('session-start-confirmed').checked = true;
  await item('session-start-confirmed').fire('change');
  await item('session-start').fire('submit');
  check('Unavailable Vault disables a session start without dispatching it',
    unavailableRequest.url === '/api/ai-shared-gateway/sessions' && !unavailableRequest.options.method &&
    requests.at(-1) === unavailableRequest && item('session-start-submit').disabled);
  await item('session-close').fire('click');
  const sessionOpening = item('open-session-start').fire('click');
  const sessionRead = requests.at(-1);
  respond(sessionRead, { VaultAvailable: true, Items: [] });
  await sessionOpening;
  await item('session-start').fire('submit');
  check('Start remains blocked until the local Vault read and worker start are selected',
    requests.at(-1) === sessionRead && item('session-start-submit').disabled);
  item('session-start-confirmed').checked = true;
  await item('session-start-confirmed').fire('change');
  item('session-lease').value = '60';
  const sessionStart = item('session-start').fire('submit');
  const sessionDispatch = requests.at(-1);
  const sentSession = JSON.parse(sessionDispatch.options.body);
  await item('session-start').fire('submit');
  check('One bound start posts only the plan and reference, with no secret value or job',
    requests.at(-1) === sessionDispatch && sentSession.Action === 'Start' && sentSession.Confirmed === true &&
    sentSession.LeaseSeconds === 60 && sentSession.UpstreamReference === '' && sentSession.Plan.PlanKey === 'e'.repeat(64) &&
    Object.keys(sentSession).length === 5 && item('session-close').disabled && statusCalls.length === 6);
  const ownerSessionId = '11111111-2222-4333-8444-555555555555';
  respond(sessionDispatch, { Status: 'SESSION_ENDPOINT_VERIFIED', PlanKey: sentSession.Plan.PlanKey, OperationId: ownerSessionId });
  await sessionStart;
  check('Only a matching start receipt confirms the endpoint',
    item('session-status').textContent.includes('Gateway-Endpunkt wurde bestätigt') && !item('session-close').disabled);
  const refreshedSessions = item('session-read').fire('click');
  const ownerRead = requests.at(-1);
  respond(ownerRead, { VaultAvailable: true, Items: [{ OperationId: ownerSessionId, Port: 18443, GatewayId: baseFields.GatewayId, Status: 'OWNED_SESSION' }] });
  await refreshedSessions;
  item('session-selection').value = ownerSessionId;
  await item('session-selection').fire('change');
  await item('session-stop').fire('click');
  check('Stop requires confirmation after selecting a listed session',
    requests.at(-1) === ownerRead && item('session-stop').disabled);
  item('session-stop-confirmed').checked = true;
  await item('session-stop-confirmed').fire('change');
  const sessionStopping = item('session-stop').fire('click');
  const stopRequest = requests.at(-1);
  const stopPayload = JSON.parse(stopRequest.options.body);
  check('The stop request binds exactly the confirmed selected operation',
    stopPayload.Action === 'Stop' && stopPayload.Confirmed === true &&
    stopPayload.OperationId === ownerSessionId && Object.keys(stopPayload).length === 3);
  respond(stopRequest, { Status: 'CLEANUP_SUCCEEDED', OperationId: ownerSessionId });
  await sessionStopping;
  check('Confirmed Stop reports cleanup without retrying',
    item('session-status').textContent.includes('temporärer Zustand bereinigt') && item('session-stop').disabled && requests.at(-1) === stopRequest);
  await item('session-close').fire('click');
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
