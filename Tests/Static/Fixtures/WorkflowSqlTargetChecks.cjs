'use strict';
// Executes the real browser script with a minimal DOM boundary; no server or provider.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../../..');
const html = fs.readFileSync(path.join(root, 'Ui/index.html'), 'utf8');
const source = fs.readFileSync(process.argv[2] || path.join(root, 'Ui/app.js'), 'utf8');
const nodes = new Map();
class Element {
  constructor(id) {
    this.id = id; this.value = ''; this.textContent = ''; this.innerHTML = '';
    this.hidden = false; this.disabled = false; this.open = false; this.dataset = {};
    this.events = new Map(); this.selectedOptions = []; this.options = [];
    this.classList = { add() {}, remove() {}, toggle() {} };
  }
  addEventListener(type, callback) { this.events.set(type, [...(this.events.get(type) || []), callback]); }
  showModal() { this.open = true; }
  close() { this.open = false; for (const handler of this.events.get('close') || []) handler({}); }
  setAttribute(name, value) { this[name] = value; }
  removeAttribute(name) { delete this[name]; }
  closest(selector) { return this.id === 'jobs' && selector === '.panel' ? workspaceElements.find((item) => item.dataset.workspaceArea === 'messages') : null; }
  scrollIntoView() { this.scrolled = true; }
  querySelectorAll(selector) {
    if (this.id === 'initial-setup-dialog' && selector === '[value="cancel"]') return [nodes.get('initial-setup-close'), nodes.get('initial-setup-close-bottom')];
    return this.id === 'container-operation-dialog' && selector === 'input[type="password"]'
      ? [nodes.get('container-operation-password')] : [];
  }
}
for (const match of html.matchAll(/\bid="([^"]+)"/g)) nodes.set(match[1], new Element(match[1]));
const workspaceElements = [];
for (const match of html.matchAll(/<\w+\b[^>]*\bdata-workspace-(?:area|target)="[^"]+"[^>]*>/g)) {
  const id = match[0].match(/\bid="([^"]+)"/)?.[1];
  const element = id ? nodes.get(id) : new Element('');
  for (const attribute of match[0].matchAll(/data-workspace-(area|target)="([^"]+)"/g)) element.dataset['workspace' + attribute[1][0].toUpperCase() + attribute[1].slice(1)] = attribute[2];
  element.hidden = /\bhidden\b/.test(match[0]);
  workspaceElements.push(element);
}
const hyperVButtons = [];
for (const match of html.matchAll(/<button\b[^>]*\bdata-provider-capability="hyperv"[^>]*>/g)) {
  const element = new Element(''); element.dataset.providerCapability = 'hyperv'; hyperVButtons.push(element);
}
const documentEvents = new Map();
const document = {
  querySelector(selector) {
    if (!selector.startsWith('#')) return null;
    const element = nodes.get(selector.slice(1));
    assert.ok(element, 'Real HTML must contain ' + selector);
    return element;
  },
  querySelectorAll(selector) {
    if (selector === '[data-workspace-target]') return workspaceElements.filter((item) => item.dataset.workspaceTarget);
    if (selector === '[data-workspace-area]') return workspaceElements.filter((item) => item.dataset.workspaceArea);
    if (selector.includes('[data-provider-capability="hyperv"]')) return hyperVButtons;
    return selector === 'dialog[open]' ? [...nodes.values()].filter((item) => item.open) : [];
  },
  addEventListener(type, callback) { documentEvents.set(type, [...(documentEvents.get(type) || []), callback]); }
};
const context = vm.createContext({ document, console, URLSearchParams,
  crypto: require('node:crypto').webcrypto, TextEncoder, AbortController,
  window: { setInterval() {}, setTimeout() {}, clearTimeout() {}, alert() {} },
  fetch: (...args) => { fetchRequests.push(args); return args[0] === '/api/jobs' ? Promise.resolve({ ok: true, json: async () => [] }) : new Promise(() => {}); }, setTimeout() {}, clearTimeout() {}, queued: [] });
const fetchRequests = [];
const run = (code) => vm.runInContext(code, context, { timeout: 5000 });
run(source);
run('const actualQueueBackgroundAction = queueBackgroundAction; queueBackgroundAction = (action, parameters) => queued.push({action, parameters});');
let passed = 0;
function check(name, body) { body(); passed++; console.log('PASS ' + name); }
async function waitForActualBoundary(predicate, message) {
  const deadline = Date.now() + 5000;
  while (!predicate() && Date.now() < deadline) {
    await new Promise((resolve) => require('node:timers').setTimeout(resolve, 10));
  }
  assert.ok(predicate(), message);
}
const node = (id) => nodes.get(id);
const click = (element) => { for (const handler of element.events.get('click') || []) handler({}); };
check('Nine real area buttons select only their actual destinations without dispatch', () => {
  const requestsBefore = fetchRequests.length;
  const areas = ['labs', 'testmatrix', 'templates', 'resources', 'hostmodels', 'connections', 'configuration', 'maintenance', 'queue'];
  const targets = document.querySelectorAll('[data-workspace-target]');
  for (const area of areas) {
    const button = targets.find((item) => item.dataset.workspaceTarget === area);
    assert.ok(button, area); click(button);
    assert.equal(button['aria-pressed'], 'true');
    const sections = document.querySelectorAll('[data-workspace-area]');
    assert.ok(sections.some((item) => item.dataset.workspaceArea === area));
    for (const section of sections) assert.equal(section.hidden, section.dataset.workspaceArea !== area);
  }
  assert.equal(context.queued.length, 0);
  assert.equal(fetchRequests.length, requestsBefore);
});
check('Back restores the previous area and leaves unfinished dialog input intact', () => {
  node('sources-media-root').value = 'draft-input';
  click(node('workspace-back'));
  assert.equal(run('workspaceArea'), 'maintenance');
  assert.equal(node('sources-media-root').value, 'draft-input');
  assert.equal(run('showWorkspaceArea("unknown")'), false);
  assert.equal(run('workspaceArea'), 'maintenance');
});
check('Expert commands and messages have separate destinations', () => {
  for (const area of ['commands', 'messages']) {
    click(document.querySelectorAll('[data-workspace-target]').find((item) => item.dataset.workspaceTarget === area));
    assert.equal(run('workspaceArea'), area);
  }
});
check('Real workflow refresh preserves selected area and draft input when Hyper-V is unavailable', () => {
  run('showWorkspaceArea("configuration")');
  node('sources-media-root').value = 'draft-input';
  run('renderWorkflow({Host:{HyperV:{Supported:false,Available:false}},Summary:{},WindowsBuilds:[],SqlBuilds:[],WindowsBaselines:[],SqlPreparedImages:[],AcceptanceEnvironments:[],ActiveLabs:[],HyperVLabs:[],SqlInstallationMedia:[],WindowsInstallationMedia:[]})');
  assert.equal(run('workspaceArea'), 'configuration');
  assert.equal(node('sources-media-root').value, 'draft-input');
  assert.ok(!node('notice').hidden);
  assert.ok(hyperVButtons.length >= 3);
  assert.ok(hyperVButtons.every((button) => button.disabled && button.title));
  assert.equal(node('connection-endpoints').innerHTML.includes('Keine registrierten'), true);
});
check('Global resources retain the existing sources dialog; cancel dispatches nothing', () => {
  for (const id of ['media-sources']) {
    click(node(id)); assert.ok(node('media-sources-dialog').open);
    node('media-sources-dialog').close();
  }
  assert.equal(context.queued.length, 0);
});
check('Hyper-V connection view uses real TcpPort/ConnectionString DTO and never renders credentials', () => {
  run('renderConnectionEndpoints(' + JSON.stringify({ ActiveLabs: [], HyperVLabs: [
    { Name: 'SQL VM', Workload: 'sql', InstanceId: 'primary', ConnectionString: 'Server=default-only,1433;Password=synthetic-secret;', SqlInstances: [
      { Name: 'MSSQLSERVER', InstanceId: 'primary', IsDefault: true, TcpPort: 1433, ConnectionString: 'Server=tcp:sql-primary,1433;User ID=synthetic-user;Password=synthetic-secret;' },
      { Name: 'REPORTING', InstanceId: 'named', IsDefault: false, TcpPort: 51433, ConnectionString: 'Data Source=sql-reporting\\REPORTING;Password=synthetic-secret;' },
      { Name: 'UNKNOWN', InstanceId: 'missing', TcpPort: 51434, ConnectionString: '' }
    ] },
    { Name: 'Older VM', Workload: 'sql', InstanceId: 'primary', ConnectionString: 'Server=sql-older,15433;Password=synthetic-secret;', SqlInstances: [] }
  ] }) + ')');
  const output = node('connection-endpoints').innerHTML;
  for (const endpoint of ['sql-primary,1433', 'sql-reporting,51433', 'sql-older,15433', 'Host oder Port unbekannt']) assert.ok(output.includes(endpoint));
  for (const secret of ['synthetic-secret', 'synthetic-user', 'Password=', 'User ID=', 'default-only']) assert.ok(!output.includes(secret));
  assert.equal(run('sqlConnectionEndpoint(\'Password="x;Server=synthetic-secret,1433;y";\',1433)'), 'Host oder Port unbekannt');
  assert.equal(run('sqlConnectionEndpoint("Server=sql-primary,70000;",70000)'), 'Host oder Port unbekannt');
});
const fixture = {
  ActiveLabs: [{ RunId: 'run-a', Name: 'Analyse', State: 'RUNNING', Instances: [
    { Id: 'primary', Provider: 'docker', SqlVersion: '2019-latest', Port: 14331 },
    { Id: 'analytics', Provider: 'podman', SqlVersion: '2022-latest', Port: 14332 }
  ] }],
  HyperVLabs: [{ RunId: 'run-vm', Name: 'Windows-Lab', InstanceId: 'primary', SqlVersion: '2025', State: 'RUNNING', VMState: 'Running', Workload: 'sql',
    SqlInstances: [{ InstanceId: 'primary', Name: 'MSSQLSERVER', IsDefault: true },
      { InstanceId: 'named', Name: 'REPORTING', IsDefault: false }] }]
};
function setWorkflow(value) { run('workflow = ' + JSON.stringify(value)); }
function clickOperation(dataset) {
  const button = { dataset };
  const event = { target: { closest: (selector) => selector === '[data-container-operation]' ? button : null } };
  for (const handler of documentEvents.get('click')) handler(event);
}
function open(instance, kind = 'container', runId = 'run-a') {
  clickOperation({ containerOperation: kind === 'hyperv' ? 'ExecuteHyperVLabScript' : 'ExecuteContainerScript',
    run: runId, instance, port: '14332', containerOperationKind: kind, containerOperationHost: '127.0.0.1' });
}
setWorkflow(fixture);
check('Actual renderer names both instances and retains exact action bindings', () => {
  run('renderActiveLabs(workflow.ActiveLabs)');
  const output = node('active-labs').innerHTML;
  assert.ok(output.includes('<strong>Instanz: primary</strong>'));
  assert.ok(output.includes('<strong>Instanz: analytics</strong>'));
  assert.ok(output.includes('data-run="run-a" data-instance="analytics"'));
});
check('Actual click handler opens the selected named target', () => {
  open('analytics');
  assert.equal(node('container-operation-target').textContent,
    'Umgebung: Analyse · Instanz: analytics · Provider: podman · SQL-Version: 2022-latest');
  assert.equal(node('container-operation-run').value, 'run-a');
  assert.equal(node('container-operation-instance').value, 'analytics');
  assert.ok(node('container-operation-dialog').open);
});
check('Target switch replaces all metadata instead of retaining the previous instance', () => {
  open('primary');
  assert.equal(node('container-operation-target').textContent,
    'Umgebung: Analyse · Instanz: primary · Provider: docker · SQL-Version: 2019-latest');
});
check('Hyper-V uses the same visible dialog without changing instance binding', () => {
  run('renderHyperVLabs(workflow.HyperVLabs)');
  assert.ok(node('hyperv-labs').innerHTML.includes('REPORTING'));
  assert.ok(node('hyperv-labs').innerHTML.includes('data-instance="primary"'));
  open('primary', 'hyperv', 'run-vm');
  assert.equal(node('container-operation-target').textContent,
    'Umgebung: Windows-Lab · Instanz: MSSQLSERVER · Provider: hyperv · SQL-Version: 2025');
  assert.equal(node('container-operation-instance').value, 'primary');
});
check('Named Hyper-V instance never inherits another instance SQL version', () => {
  open('named', 'hyperv', 'run-vm');
  assert.equal(node('container-operation-target').textContent,
    'Umgebung: Windows-Lab · Instanz: REPORTING · Provider: hyperv · SQL-Version: unbekannt');
});
check('Missing inventory is visibly unknown and preserves the requested binding', () => {
  open('missing', 'container', 'missing-run');
  assert.equal(node('container-operation-target').textContent,
    'Umgebung: unbekannt · Instanz: missing · Provider: unbekannt · SQL-Version: unbekannt');
  assert.equal(node('container-operation-run').value, 'missing-run');
  assert.equal(node('container-operation-instance').value, 'missing');
});
check('Ambiguous metadata never silently selects the first matching instance', () => {
  const duplicate = structuredClone(fixture); duplicate.ActiveLabs[0].Instances.push({ ...duplicate.ActiveLabs[0].Instances[1] });
  setWorkflow(duplicate); open('analytics');
  assert.ok(node('container-operation-target').textContent.endsWith('Provider: unbekannt · SQL-Version: unbekannt'));
});
check('Renderer escapes instance names and dialog uses textContent, not HTML', () => {
  const hostile = '<img src=x onerror="throw 1">&';
  const malicious = structuredClone(fixture);
  malicious.ActiveLabs[0].Name = hostile;
  malicious.ActiveLabs[0].Instances[1].Id = hostile;
  setWorkflow(malicious); run('renderActiveLabs(workflow.ActiveLabs)');
  const output = node('active-labs').innerHTML;
  assert.ok(output.includes('Instanz: &lt;img src=x onerror=&quot;throw 1&quot;&gt;&amp;'));
  assert.ok(!output.includes(hostile));
  node('container-operation-target').innerHTML = 'unchanged';
  open(hostile);
  assert.ok(node('container-operation-target').textContent.includes(hostile));
  assert.equal(node('container-operation-target').innerHTML, 'unchanged');
});
async function main() {
  setWorkflow(fixture); open('analytics');
  node('container-operation-password').value = 'synthetic-value';
  node('container-script-path').value = 'synthetic.sql';
  node('container-script-database').value = 'master';
  await node('container-operation-form').events.get('submit')[0]({ submitter: { value: 'default' }, preventDefault() {} });
  check('Actual submit retains exact API payload and excludes display metadata', () => {
    assert.equal(context.queued.length, 1);
    assert.deepEqual(JSON.parse(JSON.stringify(context.queued[0])), { action: 'ExecuteContainerScript', parameters: {
      BuildId: 'run-a', InstanceId: 'analytics', HostName: '127.0.0.1', Port: 14332,
      SaPassword: 'synthetic-value', ScriptPath: 'synthetic.sql', Database: 'master'
    } });
  });
  open('named', 'hyperv', 'run-vm');
  await node('container-operation-form').events.get('submit')[0]({ submitter: { value: 'default' }, preventDefault() {} });
  check('Actual Hyper-V submit preserves instance and guest credential parameter', () => {
    assert.equal(context.queued.length, 2);
    assert.deepEqual(JSON.parse(JSON.stringify(context.queued[1])), { action: 'ExecuteHyperVLabScript', parameters: {
      BuildId: 'run-vm', InstanceId: 'named', HostName: '127.0.0.1', Port: 14332,
      GuestPassword: 'synthetic-value', ScriptPath: 'synthetic.sql', Database: 'master'
    } });
  });
  check('Escape clears credentials, closes the dialog and submits nothing', () => {
    for (const handler of documentEvents.get('keydown')) handler({ key: 'Escape', preventDefault() {} });
    assert.equal(node('container-operation-password').value, '');
    assert.equal(node('container-operation-dialog').open, false);
    assert.equal(context.queued.length, 2);
  });
  const evaluationFetches = [];
  let evaluationPayload = { GeneratedAt: '2026-01-01T00:00:00Z', Scope: 'Registrierte Instanzen; keine Liveprüfung',
    Notice: 'Historische Evidence', EmptyMessage: 'Keine Einträge; kein Nachweis gültiger Lizenzen.', Rows: [
      { Id: '0', Label: 'Vorlage · Windows', Summary: 'Unbekannt; keine gültige Fristaussage', Fields: [
        { Label: 'Quelle', Value: 'Vorlagenmetadaten' }, { Label: 'Aktualität', Value: 'Historisch; nicht live geprüft' }] },
      { Id: '1', Label: '<img src=x onerror="throw 1">', Summary: 'Veraltet', Fields: [
        { Label: 'Nächster Schritt', Value: '<b>Evidence prüfen</b>' }] }
    ] };
  context.fetch = async (url, options) => {
    evaluationFetches.push({ url, options });
    return { ok: true, json: async () => evaluationPayload };
  };
  const openEvaluation = () => node('evaluation-watch-open').events.get('click')[0]();
  const readEvaluation = () => node('evaluation-watch-read').events.get('click')[0]();
  const escape = () => { for (const handler of documentEvents.get('keydown')) handler({ key: 'Escape', preventDefault() {} }); };
  openEvaluation(); escape();
  check('Evaluation dialog open and cancel neither reads nor starts any action', () => {
    assert.equal(evaluationFetches.length, 0);
    assert.equal(context.queued.length, 2);
    assert.equal(node('evaluation-watch-dialog').open, false);
  });
  openEvaluation(); await readEvaluation();
  check('Evaluation uses dedicated read-only GET and displays scope plus explicit unknown status', () => {
    assert.equal(evaluationFetches.length, 1);
    assert.equal(evaluationFetches[0].url, '/api/evaluation-watch');
    assert.equal(evaluationFetches[0].options.method, undefined);
    assert.equal(evaluationFetches[0].options.body, undefined);
    assert.ok(node('evaluation-watch-selection').innerHTML.includes('Unbekannt; keine gültige Fristaussage'));
    assert.ok(node('evaluation-watch-scope').textContent.includes('keine Liveprüfung'));
  });
  node('evaluation-watch-selection').value = '0';
  node('evaluation-watch-selection').events.get('change')[0]();
  check('Evaluation selection displays source and freshness without any second request', () => {
    assert.ok(node('evaluation-watch-details').innerHTML.includes('Aktualität'));
    assert.equal(evaluationFetches.length, 1);
    assert.equal(node('evaluation-watch-details').hidden, false);
  });
  node('evaluation-watch-selection').value = '1';
  node('evaluation-watch-selection').events.get('change')[0]();
  check('Evaluation labels and fields are escaped and previous target details replaced', () => {
    assert.ok(!node('evaluation-watch-selection').innerHTML.includes('<img'));
    assert.ok(node('evaluation-watch-details').innerHTML.includes('&lt;b&gt;Evidence prüfen&lt;/b&gt;'));
    assert.ok(!node('evaluation-watch-details').innerHTML.includes('Vorlagenmetadaten'));
  });
  evaluationPayload = { ...evaluationPayload, Rows: [] };
  await readEvaluation();
  check('Empty evaluation inventory explicitly denies a validity conclusion', () => {
    assert.ok(node('evaluation-watch-status').textContent.includes('kein Nachweis'));
    assert.equal(node('evaluation-watch-selection').disabled, true);
    assert.equal(node('evaluation-watch-details').hidden, true);
  });
  context.fetch = async () => ({ ok: false });
  await readEvaluation();
  check('Evaluation read error clears previous data and offers an explicit next step', () => {
    assert.ok(node('evaluation-watch-status').textContent.includes('Leserechte prüfen'));
    assert.equal(node('evaluation-watch-selection').disabled, true);
    assert.equal(node('evaluation-watch-read').disabled, false);
  });
  let release;
  context.fetch = () => new Promise((resolve) => { release = resolve; });
  const pendingRead = readEvaluation();
  escape(); openEvaluation();
  release({ ok: true, json: async () => evaluationPayload });
  await pendingRead;
  check('Cancelled evaluation response cannot overwrite a newly opened dialog', () => {
    assert.ok(node('evaluation-watch-status').textContent.startsWith('Noch nicht gelesen'));
    assert.equal(node('evaluation-watch-read').disabled, false);
    assert.equal(context.queued.length, 2);
  });
  escape();
  run('queueBackgroundAction = actualQueueBackgroundAction; showWorkspaceArea("labs")');
  setWorkflow(fixture); open('analytics');
  node('container-operation-password').value = 'synthetic-value';
  node('container-script-path').value = 'synthetic.sql';
  const actionRequests = [];
  let acceptAction;
  context.fetch = (url, options) => {
    actionRequests.push({ url, options });
    if (url === '/api/actions') return new Promise((resolve) => { acceptAction = resolve; });
    assert.equal(url, '/api/jobs');
    return Promise.resolve({ ok: true, json: async () => [{ Id: 'synthetic-job', Action: 'ExecuteContainerScript', State: 'Completed', Lines: ['SYNTHETIC_RESULT'] }] });
  };
  await node('container-operation-form').events.get('submit')[0]({ submitter: { value: 'default' }, preventDefault() {} });
  // The real queue is intentionally fire-and-forget. Wait for its asynchronous
  // nonsecret identity digest and actual POST boundary, not server acceptance.
  await waitForActualBoundary(() => typeof acceptAction === 'function', 'Real queued action must reach the POST boundary');
  assert.equal(typeof acceptAction, 'function', 'Real queued action must reach the POST boundary');
  check('Real form/queue/startAction chain exposes live log before server acceptance', () => {
    assert.equal(run('workspaceArea'), 'messages');
    assert.ok(!node('jobs').closest('.panel').hidden);
    assert.ok(node('jobs').closest('.panel').scrolled);
    assert.ok(node('jobs').innerHTML.includes('Übermittlung'));
    assert.equal(node('container-operation-dialog').open, false);
    assert.equal(actionRequests[0].url, '/api/actions');
    assert.equal(JSON.parse(actionRequests[0].options.body).action, 'ExecuteContainerScript');
  });
  acceptAction({ ok: true, json: async () => ({ id: 'synthetic-job' }) });
  await waitForActualBoundary(() => node('jobs').innerHTML.includes('SYNTHETIC_RESULT'), 'Actual server result must reach the renderer');
  check('Completed normal action keeps its actual result visible after feedback disappears', () => {
    assert.equal(actionRequests[1].url, '/api/jobs');
    assert.ok(node('jobs').innerHTML.includes('Erfolgreich'));
    assert.ok(node('jobs').innerHTML.includes('SYNTHETIC_RESULT'));
    assert.equal(node('action-feedback').hidden, true);
    assert.ok(!node('jobs').closest('.panel').hidden);
    assert.equal(run('workspaceArea'), 'messages');
  });
  const setupState = { ConfigurationStatus: 'READY', Complete: true, MediaRootValid: true, MediaRoot: '/synthetic/Lab_Base',
    MediaRootCandidates: [{ Path: '<invalid>', Source: 'ProcessEnvironment', Status: 'ROOT_NOT_FOUND', Selected: false }, { Path: '/synthetic/Lab_Base', Source: 'ProjectPreference', Status: 'READY', Selected: true }],
    LocationStatus: [{ LocationId: '11111111-1111-1111-1111-111111111111', LabDataRoot: '/synthetic/Lab_Data', Source: 'StorageConfiguration', Status: 'READY', IsDefault: true }, { LabDataRoot: '<missing>', Source: 'StorageConfiguration', Status: 'ROOT_NOT_FOUND' }],
    DefaultLocation: { LabDataRoot: '/synthetic/Lab_Data' } };
  const setupPlan = { ContractVersion: 'SqlServerLab.InitialSetupPlan/1.0', MediaAction: null, LocationActions: [{ LabDataRoot: '/synthetic/second_Data' }], DefaultDataRoot: '/synthetic/second_Data', IsNoOp: false };
  const setupRequests = [];
  const capacitySnapshot = { ContractVersion: 'SqlServerLab.InitialSetupCapacity/1.0', LocationId: '11111111-1111-1111-1111-111111111111', Status: 'AVAILABLE', Code: 'INITIAL_SETUP_CAPACITY_OBSERVED', AvailableBytes: 0, TotalBytes: 1099511627776, ObservedAt: '2026-10-01T12:00:00Z' };
  const writePlan = { PlanId: '22222222-2222-2222-2222-222222222222', LocationId: '11111111-1111-1111-1111-111111111111', ExpiresAt: '2099-01-01T00:00:00Z', MaximumSeconds: 39, Notice: 'SYNTHETIC_PREVIEW' };
  context.fetch = async (url, options) => {
    assert.equal(url, '/api/initial-setup');
    const payload = options?.body ? JSON.parse(options.body) : null;
    setupRequests.push(payload);
    return { ok: true, json: async () => ({ Result: payload?.action === 'PlanInitialSetup' ? setupPlan : payload?.action === 'PlanSetupWriteability' ? writePlan : payload?.action === 'ProbeSetupWriteability' ? { Status: 'WRITABLE', OwnLeafAbsent: true, Notice: 'SYNTHETIC_MOMENTARY' } : payload?.action === 'RefreshSetupCapacity' ? capacitySnapshot : payload?.action === 'RefreshSetupProvider' ? { Provider: 'podman', Check: { Status: 'BLOCKED', Code: 'PROVIDER_UNREACHABLE' } } : setupState }) };
  };
  const setupClick = async (id) => { for (const handler of node(id).events.get('click') || []) await handler({}); };
  const setupPreview = async () => { for (const handler of node('initial-setup-form').events.get('submit') || []) await handler({ preventDefault() {} }); };
  await setupClick('configuration-storage');
  check('Real setup open reads roots only, keeps complete configuration editable and escapes invalid paths', () => {
    assert.deepEqual(setupRequests, [null]);
    assert.equal(node('initial-setup-media').disabled, true);
    assert.equal(node('initial-setup-preview').disabled, false);
    assert.equal(node('initial-setup-apply').disabled, true);
    assert.equal(run('workflow.Defaults.DataRoot'), '/synthetic/Lab_Data');
    assert.equal(run('workflow.Defaults.MediaRoot'), '/synthetic/Lab_Base');
    assert.ok(node('initial-setup-roots').innerHTML.includes('&lt;invalid&gt;'));
    assert.ok(node('initial-setup-roots').innerHTML.includes('ROOT_NOT_FOUND'));
  });
  node('initial-setup-data').value = '/synthetic/second_Data';
  node('initial-setup-default').value = '/synthetic/second_Data';
  await setupPreview();
  check('Real setup preview sends explicit paths without Apply or queue mutation', () => {
    assert.equal(setupRequests.length, 2);
    assert.equal(setupRequests[1].action, 'PlanInitialSetup');
    assert.deepEqual(setupRequests[1].parameters.LabDataRoot, ['/synthetic/second_Data']);
    assert.equal(node('initial-setup-apply').disabled, false);
    assert.ok(!node('initial-setup-plan').hidden);
  });
  for (const handler of node('initial-setup-default').events.get('input')) handler({});
  await setupClick('initial-setup-apply');
  check('Editing a preview invalidates its Apply authority', () => { assert.equal(setupRequests.length, 2); assert.equal(node('initial-setup-apply').disabled, true); });
  await setupPreview();
  node('initial-setup-dialog').close();
  await setupClick('initial-setup-apply');
  check('Closing the real setup dialog discards its plan without Apply', () => { assert.equal(setupRequests.length, 3); });
  await setupClick('configuration-storage');
  await setupPreview();
  await setupClick('initial-setup-apply');
  check('Real Apply sends exactly the displayed plan and explicit boolean confirmation', () => {
    assert.equal(setupRequests.at(-1).action, 'ApplyInitialSetup');
    assert.deepEqual(setupRequests.at(-1).parameters.InitialSetupPlan, setupPlan);
    assert.equal(setupRequests.at(-1).parameters.ConfirmSetup, true);
    assert.equal(node('initial-setup-apply').disabled, true);
  });
  node('initial-setup-provider').value = 'podman';
  await setupClick('initial-setup-provider-refresh');
  check('Explicit provider refresh selects only one provider and displays structured failure', () => {
    assert.deepEqual(setupRequests.at(-1), { action: 'RefreshSetupProvider', parameters: { SetupProvider: 'podman' } });
    assert.ok(node('initial-setup-provider-status').textContent.includes('PROVIDER_UNREACHABLE'));
  });
  const capacityQueueCount = context.queued.length;
  const capacityBeforeSelect = setupRequests.length;
  await setupClick('initial-setup-capacity-read');
  check('Reading ordinary setup and unselected capacity dispatches no implicit volume query', () => { assert.equal(setupRequests.length, capacityBeforeSelect); assert.ok(node('initial-setup-capacity-result').textContent.includes('noch nicht gelesen')); });
  node('initial-setup-write-location').value = capacitySnapshot.LocationId;
  await setupClick('initial-setup-capacity-read');
  check('Real capacity button sends exactly one location ID and displays measured zero with time and host scope', () => {
    assert.deepEqual(setupRequests.at(-1), { action: 'RefreshSetupCapacity', parameters: { SetupLocationId: capacitySnapshot.LocationId } });
    assert.ok(node('initial-setup-capacity-result').textContent.includes('Momentaufnahme'));
    assert.match(node('initial-setup-capacity-result').textContent, /0[.,]0 GiB/);
    assert.ok(node('initial-setup-capacity-result').textContent.includes('gelesen'));
    assert.equal(context.queued.length, capacityQueueCount);
  });
  const originalCapacityFetch = context.fetch;
  for (const status of ['UNKNOWN', 'UNREADABLE', 'UNSUPPORTED']) {
    context.fetch = async () => ({ ok: true, json: async () => ({ Result: { ...capacitySnapshot, Status: status, AvailableBytes: null, TotalBytes: null } }) });
    await setupClick('initial-setup-capacity-read');
    check('Capacity ' + status + ' never renders a fabricated zero or capacity guarantee', () => assert.ok(!node('initial-setup-capacity-result').textContent.includes('GiB')));
  }
  let releaseCapacity;
  context.fetch = () => new Promise(resolve => { releaseCapacity = resolve; });
  const lateCapacity = setupClick('initial-setup-capacity-read');
  node('initial-setup-write-location').value = '22222222-2222-2222-2222-222222222222';
  for (const handler of node('initial-setup-write-location').events.get('change')) handler({});
  releaseCapacity({ ok: true, json: async () => ({ Result: capacitySnapshot }) });
  await lateCapacity;
  check('Late capacity for an old selection never attaches bytes to the new location', () => assert.ok(node('initial-setup-capacity-result').textContent.includes('noch nicht gelesen')));
  node('initial-setup-write-location').value = capacitySnapshot.LocationId;
  const closedCapacity = setupClick('initial-setup-capacity-read');
  node('initial-setup-dialog').close();
  releaseCapacity({ ok: true, json: async () => ({ Result: capacitySnapshot }) });
  await closedCapacity;
  check('Closing a readonly capacity request discards the late snapshot', () => assert.ok(node('initial-setup-capacity-result').textContent.includes('noch nicht gelesen')));
  context.fetch = originalCapacityFetch;
  await setupClick('configuration-storage');
  node('initial-setup-write-location').value = capacitySnapshot.LocationId;
  context.fetch = async () => ({ ok: false, text: async () => 'SYNTHETIC_PRIVATE_CAPACITY_DETAIL' });
  await setupClick('initial-setup-capacity-read');
  check('Capacity request failure stays unknown and never publishes raw diagnostics', () => { assert.ok(node('initial-setup-capacity-result').textContent.includes('nicht bestätigt')); assert.ok(!node('initial-setup-capacity-result').textContent.includes('PRIVATE')); });
  context.fetch = originalCapacityFetch;
  const writeQueueCount = context.queued.length;
  node('initial-setup-write-location').value = writePlan.LocationId;
  await setupClick('initial-setup-write-preview');
  const writePreviewCount = setupRequests.length;
  await setupClick('initial-setup-write-apply');
  check('Real write preview binds stable location and unchecked confirmation never dispatches', () => {
    assert.deepEqual(setupRequests.at(-1), { action: 'PlanSetupWriteability', parameters: { SetupLocationId: writePlan.LocationId } });
    assert.equal(setupRequests.length, writePreviewCount);
    assert.equal(node('initial-setup-write-apply').disabled, true);
  });
  node('initial-setup-dialog').close();
  node('initial-setup-write-confirm').checked = true;
  await setupClick('initial-setup-write-apply');
  check('Closing a write preview discards authority and makes no write request', () => assert.equal(setupRequests.length, writePreviewCount));
  await setupClick('configuration-storage');
  node('initial-setup-write-location').value = writePlan.LocationId;
  await setupClick('initial-setup-write-preview');
  node('initial-setup-write-confirm').checked = true;
  for (const handler of node('initial-setup-default').events.get('input')) handler({});
  const editedCount = setupRequests.length;
  await setupClick('initial-setup-write-apply');
  check('Editing setup invalidates write preview and its explicit confirmation', () => { assert.equal(setupRequests.length, editedCount); assert.equal(node('initial-setup-write-confirm').checked, false); });
  await setupClick('initial-setup-write-preview');
  node('initial-setup-write-confirm').checked = true;
  await setupClick('initial-setup-write-apply');
  check('Real write Apply sends only server plan ID and boolean confirmation and keeps result visible', () => {
    assert.deepEqual(setupRequests.at(-1), { action: 'ProbeSetupWriteability', parameters: { SetupWriteabilityPlanId: writePlan.PlanId, ConfirmWriteability: true } });
    assert.ok(node('initial-setup-write-result').textContent.includes('WRITABLE'));
    assert.ok(node('initial-setup-write-result').textContent.includes('true'));
    assert.equal(node('initial-setup-write-confirm').checked, false);
    assert.equal(context.queued.length, writeQueueCount);
  });
  await setupClick('initial-setup-write-preview');
  node('initial-setup-write-confirm').checked = true;
  let releaseWrite;
  const priorFetch = context.fetch;
  context.fetch = () => new Promise(resolve => { releaseWrite = resolve; });
  const runningWrite = setupClick('initial-setup-write-apply');
  check('In-flight explicit write locks close buttons and Escape until own cleanup result', () => {
    assert.equal(node('initial-setup-close').disabled, true);
    assert.equal(node('initial-setup-close-bottom').disabled, true);
    let prevented = false;
    for (const handler of node('initial-setup-dialog').events.get('cancel')) handler({ preventDefault() { prevented = true; } });
    assert.equal(prevented, true);
    assert.equal(node('initial-setup-write-location').disabled, true);
  });
  releaseWrite({ ok: false });
  await runningWrite;
  check('Lost write response displays unconfirmed own cleanup without automatic retry', () => {
    assert.ok(node('initial-setup-write-result').textContent.includes('nicht bestätigt'));
    assert.equal(node('initial-setup-close').disabled, false);
    assert.equal(node('initial-setup-write-apply').disabled, true);
  });
  context.fetch = priorFetch;
  context.fetch = async () => ({ ok: false, text: async () => 'synthetic-private-host' });
  await setupPreview();
  check('Setup request failure invalidates Apply and never displays raw server diagnostics', () => {
    assert.equal(node('initial-setup-apply').disabled, true);
    assert.ok(!node('initial-setup-status').textContent.includes('synthetic-private-host'));
  });
  let releaseSetup;
  context.fetch = () => new Promise((resolve) => { releaseSetup = resolve; });
  const pendingSetup = setupClick('initial-setup-read');
  node('initial-setup-dialog').close();
  releaseSetup({ ok: true, json: async () => ({ Result: { ...setupState, MediaRoot: 'stale' } }) });
  await pendingSetup;
  check('Late setup read after Cancel cannot update the closed dialog', () => { assert.notEqual(node('initial-setup-media').value, 'stale'); });
  let resourceMode = 'ready';
  let resourceMounts = { Status: 'MEASURED', TotalMountCount: 3, VolumeMountCount: 1, HostBindCount: 1, WritableHostBindCount: 1, OtherMountCount: 1, VolumeOwnership: 'NOT_CHECKED', Source: '/synthetic/private/host' };
  const resourceRequests = [];
  context.fetch = async (url, options = {}) => {
    resourceRequests.push({ url, options });
    if (url === '/api/actions') return { ok: true, json: async () => ({ id: 'resource-job' }) };
    if (url === '/api/jobs') return { ok: true, json: async () => [] };
    assert.ok(url.startsWith('/api/resource-change?'));
    if (resourceMode === 'error') return { ok: false };
    const query = new URLSearchParams(url.split('?')[1]);
    if (!query.has('instanceId')) return { ok: true, json: async () => ({ Targets: resourceMode === 'empty' ? [] : [{ InstanceId: 'secondary', Provider: 'podman' }] }) };
    const actual = { Cpu: resourceMode === 'unknown' ? null : 2, MemoryMB: 2048 };
    const desired = { Cpu: query.has('cpu') ? Number(query.get('cpu')) : actual.Cpu, MemoryMB: query.has('memoryMB') ? Number(query.get('memoryMB')) : 2048 };
    return { ok: true, json: async () => ({ RunId: 'resource-run', InstanceId: query.get('instanceId'), Provider: query.get('provider'), Actual: actual, Desired: desired, Preview: { Mounts: resourceMounts }, CanApply: resourceMode !== 'unknown', NoChange: desired.Cpu === actual.Cpu && desired.MemoryMB === actual.MemoryMB, PlanKey: 'a'.repeat(64), NextStep: resourceMode === 'unknown' ? 'Istlimit unbekannt; Apply nicht verfügbar.' : 'Live; kein Neustart.' }) };
  };
  context.resourceButton = { dataset: { run: 'resource-run' } };
  const resourceEvent = async (id, type = 'click') => { for (const handler of node(id).events.get(type) || []) await handler({ submitter: { value: 'default' }, preventDefault() {} }); };
  await run('openResourceDialog(resourceButton)');
  check('Resource dialog pre-fills measured values for exact instance/provider and blocks no-op', () => {
    assert.equal(Number(node('resource-processors').value), 2);
    assert.equal(node('resource-apply').disabled, true);
    assert.ok(node('resource-current').textContent.includes('secondary · podman'));
  });
  check('Resource mount display projects counts without private paths or ownership claims', () => {
    assert.ok(node('resource-mounts').textContent.includes('3 gesamt'));
    assert.ok(node('resource-mounts').textContent.includes('1 schreibbar'));
    assert.ok(node('resource-mounts').textContent.includes('Volumeeigentum nicht geprüft'));
    assert.ok(!node('resource-mounts').textContent.includes('/synthetic/private'));
  });
  for (const mounts of [null, { Status: 'UNKNOWN', TotalMountCount: null }, { ...resourceMounts, TotalMountCount: '3' }, { ...resourceMounts, WritableHostBindCount: 2 }, { ...resourceMounts, TotalMountCount: 4 }]) {
    resourceMounts = mounts; await resourceEvent('resource-preview');
    check('Invalid or unknown mount response never displays measured zero or stale counts', () => assert.ok(node('resource-mounts').textContent.startsWith('Mounts unbekannt')));
  }
  resourceMounts = { Status: 'MEASURED', TotalMountCount: 0, VolumeMountCount: 0, HostBindCount: 0, WritableHostBindCount: 0, OtherMountCount: 0, VolumeOwnership: 'NOT_CHECKED' };
  await resourceEvent('resource-preview');
  check('Explicit empty mount response displays measured zero', () => assert.ok(node('resource-mounts').textContent.includes('0 gesamt')));
  check('Hyper-V mount display does not claim container evidence', () => assert.ok(run("resourceMountSummary({Provider:'hyperv'})").includes('nicht verfügbar')));
  await resourceEvent('resource-form','submit');
  node('resource-processors').value = '2.5';
  await resourceEvent('resource-processors','input');
  check('Editing invalidates previous mount display before another response', () => assert.equal(node('resource-mounts').textContent, 'Mount-Vorschau noch nicht gelesen.'));
  await resourceEvent('resource-form','submit');
  check('Unpreviewed edits and no-op never queue mutation', () => assert.equal(resourceRequests.filter((r) => r.url === '/api/actions').length, 0));
  await resourceEvent('resource-preview');
  check('Shared preview displays old/new before Apply', () => { assert.equal(node('resource-apply').disabled, false); assert.ok(node('resource-current').textContent.includes('2 → 2.5')); });
  await resourceEvent('resource-form','submit');
  await waitForActualBoundary(() => resourceRequests.some((r) => r.url === '/api/actions'), 'Actual CPU/RAM submission must reach the POST boundary');
  check('Real resource handler/startAction sends bound CPU/RAM only and exposes results', () => {
    const request = JSON.parse(resourceRequests.find((r) => r.url === '/api/actions').options.body);
    assert.equal(request.action, 'SetLabResources'); assert.equal(request.parameters.InstanceId, 'secondary');
    assert.equal(request.parameters.ResourceCpu, 2.5); assert.equal(request.parameters.ExpectedPlanKey, 'a'.repeat(64));
    assert.equal(request.parameters.AutoStart, undefined); assert.equal(run('workspaceArea'), 'messages');
  });
  await run('openResourceDialog(resourceButton)');
  node('resource-processors').value = '3'; await resourceEvent('resource-preview');
  node('resource-dialog').close(); await resourceEvent('resource-form','submit');
  check('Resource Cancel discards plan without mutation', () => assert.equal(resourceRequests.filter((r) => r.url === '/api/actions').length, 1));
  for (const mode of ['unknown', 'empty', 'error']) {
    resourceMode = mode; await run('openResourceDialog(resourceButton)');
    check('Resource ' + mode + ' fails closed with visible next step', () => { assert.equal(node('resource-apply').disabled, true); assert.ok(node('resource-note').textContent.length > 0); });
    node('resource-dialog').close();
  }
  resourceMode = 'ready';
  const immediateResourceFetch = context.fetch;
  let releaseTargets;
  context.fetch = (url, options) => url.includes('/api/resource-change?') && !url.includes('instanceId=')
    ? new Promise((resolve) => { releaseTargets = () => resolve({ ok: true, json: async () => ({ Targets: [{ InstanceId: 'secondary', Provider: 'podman' }] }) }); })
    : immediateResourceFetch(url, options);
  const delayedResourceOpen = run('openResourceDialog(resourceButton)');
  check('Pending resource Targets GET disables editable inputs', () => {
    assert.equal(node('resource-memory').disabled, true); assert.equal(node('resource-processors').disabled, true);
  });
  await resourceEvent('resource-processors','input');
  releaseTargets(); await delayedResourceOpen;
  check('Early input cannot discard pending targets; initial plan finishes and enables editing', () => {
    assert.equal(node('resource-instance').disabled, false); assert.equal(node('resource-processors').disabled, false);
    assert.equal(Number(node('resource-processors').value), 2);
  });
  node('resource-dialog').close();
  const reserveRequests = [];
  const reservePolicy = { WindowsReserve: 0, SqlReserve: 0, MinimumDaysRemaining: 45, WarningDaysRemaining: 10 };
  const reserveView = { Configuration: { Status: 'CONFIGURED', Policy: reservePolicy }, CandidateCount: 2, Rows: [], Recommendation: 'NO_RESERVE_REQUESTED', Notice: 'Keine Claims; Verfügbarkeit unbekannt.' };
  const reservePlan = { Policy: reservePolicy, PlanKey: 'synthetic', PreviousKey: 'synthetic', IsNoOp: false, Notice: 'Nur Policy speichern.' };
  context.fetch = async (url, options = {}) => {
    assert.equal(url, '/api/slot-reserve');
    const request = options.body ? JSON.parse(options.body) : null;
    reserveRequests.push(request);
    return { ok: true, json: async () => ({ Result: request?.action === 'PlanSlotReserve' ? reservePlan : reserveView }) };
  };
  await resourceEvent('configuration-reserve');
  check('Reserve opens same central configuration without mutation and preserves explicit zero', () => {
    assert.equal(reserveRequests.length, 1); assert.equal(reserveRequests[0], null);
    assert.equal(Number(node('slot-reserve-windows').value), 0);
    assert.ok(node('slot-reserve-status').textContent.includes('unbekannt'));
  });
  await resourceEvent('slot-reserve-form', 'submit');
  check('Reserve preview keeps minimum lifetime separate from warning threshold', () => {
    assert.deepEqual(reserveRequests.at(-1), { action: 'PlanSlotReserve', parameters: { SlotReservePolicy: reservePolicy } });
    assert.equal(node('slot-reserve-apply').disabled, false);
  });
  await resourceEvent('slot-reserve-windows', 'input'); await resourceEvent('slot-reserve-apply');
  check('Reserve edit invalidates displayed plan', () => assert.equal(reserveRequests.length, 2));
  await resourceEvent('slot-reserve-form', 'submit'); await resourceEvent('slot-reserve-close'); await resourceEvent('slot-reserve-apply');
  check('Reserve cancel discards plan without Apply', () => assert.equal(reserveRequests.length, 3));
  await resourceEvent('templates-reserve'); await resourceEvent('slot-reserve-form', 'submit'); await resourceEvent('slot-reserve-apply');
  check('Templates uses same real reserve handler and applies only displayed policy with explicit confirmation', () => {
    assert.deepEqual(reserveRequests.at(-2), { action: 'ApplySlotReserve', parameters: { SlotReservePlan: reservePlan, ConfirmSlotReserve: true } });
    assert.equal(reserveRequests.at(-1), null);
  });
  context.fetch = async () => ({ ok: false, text: async () => 'synthetic-host-private' });
  await resourceEvent('slot-reserve-read');
  check('Reserve failure removes stale inventory and disables Apply without raw diagnostics', () => {
    assert.equal(node('slot-reserve-apply').disabled, true); assert.equal(node('slot-reserve-inventory').textContent, '');
    assert.ok(!node('slot-reserve-status').textContent.includes('synthetic-host-private'));
  });
  let releaseReserve;
  context.fetch = () => new Promise(resolve => { releaseReserve = resolve; });
  const pendingReserve = resourceEvent('slot-reserve-read'); await resourceEvent('slot-reserve-close');
  releaseReserve({ ok: true, json: async () => ({ Result: reserveView }) }); await pendingReserve;
  check('Reserve closed dialog ignores delayed read', () => assert.equal(node('slot-reserve-inventory').textContent, ''));
  const memberRequests = [];
  const memberPreview = { PreviewId: 'opaque-held-member-token', Action: 'Claim', RunId: 'own-member', VMName: 'own-vm', MemberState: 'FREE', Evidence: 'CURRENT', Notice: 'Revalidate before claim.' };
  context.fetch = async (url, options = {}) => {
    assert.equal(url, '/api/slot-reserve');
    const request = options.body ? JSON.parse(options.body) : null; memberRequests.push(request);
    return { ok: true, json: async () => ({ Result: request?.action === 'PlanWindowsPoolMember' ? memberPreview : request?.action === 'ApplyWindowsPoolMember' ? { Status: 'RECOVERY_REQUIRED', RunId: 'own-member', OriginalError: 'WINDOWS_POOL_OPERATION_FAILED' } : reserveView }) };
  };
  await resourceEvent('configuration-reserve');
  node('slot-member-run').value = 'own-member'; node('slot-member-action').value = 'Claim';
  await resourceEvent('slot-member-form', 'submit');
  check('Member preview shows actual bound identity before confirmation', () => {
    assert.equal(node('slot-member-apply').disabled, false); assert.ok(node('slot-member-plan').textContent.includes('own-vm'));
    assert.equal(memberRequests.at(-1).action, 'PlanWindowsPoolMember');
    assert.equal(memberRequests.filter(r => r?.action === 'ApplyWindowsPoolMember').length, 0);
  });
  await resourceEvent('slot-member-run', 'input'); await resourceEvent('slot-member-apply');
  check('Member edited preview cancels held token and cannot apply', () => {
    assert.deepEqual(memberRequests.at(-1), { action: 'CancelWindowsPoolMember', parameters: { SlotReservePreviewId: memberPreview.PreviewId } });
    assert.equal(memberRequests.filter(r => r?.action === 'ApplyWindowsPoolMember').length, 0);
  });
  await resourceEvent('slot-member-form', 'submit'); await resourceEvent('slot-member-apply');
  check('Member apply transmits only opaque token and explicit confirmation; recovery stays visible', () => {
    assert.deepEqual(memberRequests.at(-2), { action: 'ApplyWindowsPoolMember', parameters: { SlotReservePreviewId: memberPreview.PreviewId, ConfirmSlotReserveMember: true } });
    assert.ok(node('slot-reserve-status').textContent.includes('RECOVERY_REQUIRED'));
  });
  await resourceEvent('slot-member-form', 'submit'); await resourceEvent('slot-reserve-close');
  check('Member dialog close cancels preview separately', () => assert.equal(memberRequests.at(-1).action, 'CancelWindowsPoolMember'));
  await resourceEvent('configuration-reserve');
  const immediateMemberFetch = context.fetch; let releaseMemberPreview;
  context.fetch = (url, options = {}) => options.body && JSON.parse(options.body).action === 'PlanWindowsPoolMember'
    ? new Promise(resolve => { releaseMemberPreview = resolve; }) : immediateMemberFetch(url, options);
  const pendingMember = resourceEvent('slot-member-form', 'submit'); await resourceEvent('slot-reserve-close');
  releaseMemberPreview({ ok: true, json: async () => ({ Result: memberPreview }) }); await pendingMember;
  check('Delayed member preview after close cancels server token without displaying or applying', () => {
    assert.equal(memberRequests.at(-1).action, 'CancelWindowsPoolMember'); assert.equal(node('slot-member-plan').hidden, true);
  });
  const groupRequests = [];
  let groupMode = 'ready';
  const groupPlan = { Group: 'Registrierte Testgruppe', Total: 2, PowerStatus: 'MIXED', PowerAction: 'Start', CanApply: true, NoChange: false, PlanKey: 'a'.repeat(64), Notice: 'Nur Power; SQL nicht geprüft.', Members: [{ Key: 'DOCKER', Provider: 'docker', Power: 'STOPPED', Desired: 'RUNNING', Change: 'START' }, { Key: 'PODMAN', Provider: 'podman', Power: 'RUNNING', Desired: 'RUNNING', Change: 'NO_OP' }] };
  context.fetch = async (url, options = {}) => {
    groupRequests.push({ url, options });
    if (url.startsWith('/api/test-group?')) return { ok: groupMode !== 'error', json: async () => ({ ...groupPlan, PowerAction: new URLSearchParams(url.split('?')[1]).get('powerAction'), CanApply: groupMode !== 'unknown', NoChange: groupMode === 'noop', Total: groupMode === 'empty' ? 0 : 2 }) };
    if (url === '/api/actions') return { ok: true, json: async () => ({ id: 'group-job' }) };
    if (url === '/api/jobs') return { ok: true, json: async () => [] };
    throw new Error('Unexpected group request ' + url);
  };
  await resourceEvent('test-group-open');
  check('Group dialog uses read-only shared preview and explicit group selection', () => { assert.equal(groupRequests.length, 1); assert.equal(node('test-group-apply').disabled, true); assert.match(node('test-group-status').textContent, /nicht geprüft/); });
  node('test-group-selection').value = 'registered'; await resourceEvent('test-group-selection', 'change');
  await resourceEvent('test-group-apply');
  check('Group selection alone does not authorize power action', () => assert.equal(groupRequests.filter(r => r.url === '/api/actions').length, 0));
  node('test-group-confirm').checked = true; await resourceEvent('test-group-confirm', 'change'); await resourceEvent('test-group-apply');
  check('Confirmed group applies exact plan via real startAction and exposes job results', () => {
    assert.deepEqual(JSON.parse(groupRequests.find(r => r.url === '/api/actions').options.body), { action: 'StartTestGroupPower', parameters: { ExpectedPlanKey: groupPlan.PlanKey } });
    assert.equal(node('test-group-dialog').open, false);
    assert.equal(workspaceElements.find(e => e.dataset.workspaceArea === 'messages').hidden, false);
  });
  run('renderJobs([{ Id: "group-result", Action: "StartTestGroupPower", State: "Completed", Lines: [\'[TESTGROUP] {"Status":"PARTIAL","Details":[{"Key":"DOCKER","Status":"RUNNING","Action":"START"},{"Key":"PODMAN","Status":"UNCONFIRMED","Action":"START"}]}\'] }])');
  check('Group job renders partial outcome per member with retry boundary', () => { assert.match(node('jobs').innerHTML, /PARTIAL/); assert.match(node('jobs').innerHTML, /UNCONFIRMED/); assert.match(node('jobs').innerHTML, /neuer Vorschau/); });
  for (const mode of ['noop', 'unknown', 'empty', 'error']) {
    groupMode = mode; await resourceEvent('test-group-open');
    node('test-group-selection').value = 'registered'; node('test-group-confirm').checked = true; await resourceEvent('test-group-confirm','change'); await resourceEvent('test-group-apply');
    check('Group ' + mode + ' cannot invoke executor', () => assert.equal(groupRequests.filter(r => r.url === '/api/actions').length, 1));
    await resourceEvent('test-group-close');
  }
  groupMode = 'ready'; await resourceEvent('test-group-open'); await resourceEvent('test-group-close'); await resourceEvent('test-group-apply');
  check('Group cancel discards preview without mutation', () => assert.equal(groupRequests.filter(r => r.url === '/api/actions').length, 1));
  let releaseGroup;
  context.fetch = () => new Promise(resolve => { releaseGroup = resolve; });
  const pendingGroup = resourceEvent('test-group-open'); await resourceEvent('test-group-close'); releaseGroup({ ok: true, json: async () => groupPlan }); await pendingGroup;
  check('Closed group dialog rejects delayed preview', () => assert.equal(node('test-group-apply').disabled, true));
  const mediaRequests = [];
  const mediaItem = { Id: 'sql-server-2025-enterprise-developer-bootstrapper', DisplayName: '<Bootstrapper>', RepositoryUrl: 'https://download.microsoft.com/download/default/SQL2025-SSEI-EntDev.exe', EffectiveUrl: 'https://download.microsoft.com/download/default/SQL2025-SSEI-EntDev.exe', Provenance: 'REPOSITORY_DEFAULT', ExpectedBytes: 21, ExpectedSha256: 'a'.repeat(64) };
  const mediaItems = [mediaItem, ...[
    ['2025', 'standard-developer', 'Standard Developer', 'StdDev'], ['2025', 'express', 'Express', 'Expr'],
    ['2022', 'developer', 'Developer', 'Dev'], ['2022', 'evaluation', 'Evaluation', 'Eval'], ['2022', 'express', 'Express', 'Expr']
  ].map(([version, id, edition, file]) => ({ ...mediaItem, Id: 'sql-server-'+version+'-'+id+'-bootstrapper', DisplayName: 'SQL Server '+version+' '+edition+' bootstrapper', Version: version, RepositoryUrl: 'https://download.microsoft.com/download/default/SQL'+version+'-SSEI-'+file+'.exe', EffectiveUrl: 'https://download.microsoft.com/download/default/SQL'+version+'-SSEI-'+file+'.exe' }))];
  let mediaMode = 'ready';
  context.fetch = async (url, options) => {
    const body = options?.body ? JSON.parse(options.body) : null;
    mediaRequests.push({url,body});
    const selected = mediaItems.find(item => item.Id === body?.parameters?.MediaSourceId) || mediaItem;
    const result = body?.action === 'PlanMediaOverride' ? { Id: selected.Id, Operation: body.parameters.MediaSourceOperation, EffectiveUrl: body.parameters.MediaSourceUrl || selected.RepositoryUrl, IsNoOp: mediaMode === 'noop', PlanKey: 'synthetic-plan', Notice: 'Kein Download' } : { Status: mediaMode === 'invalid' ? 'INVALID' : 'READY', Items: mediaItems, Notice: 'Kein Download' };
    return { ok: mediaMode !== 'error', json: async () => ({Result: result}) };
  };
  await resourceEvent('media-override-open');
  check('Media state shows provenance and escaped source choice', () => { assert.match(node('media-override-details').textContent,/REPOSITORY_DEFAULT/); assert.match(node('media-override-selection').innerHTML,/&lt;Bootstrapper&gt;/); assert.equal(node('media-override-apply').disabled,true); });
  node('media-override-url').value = 'https://download.microsoft.com/download/alternate/SQL2025-SSEI-EntDev.exe';
  await resourceEvent('media-override-preview');
  check('Media preview sends exact ID and URL without apply', () => { assert.equal(mediaRequests.at(-1).body.parameters.MediaSourceId,mediaItem.Id); assert.equal(mediaRequests.at(-1).body.parameters.MediaSourceOperation,'Edit'); assert.equal(mediaRequests.filter(r=>r.body?.action==='ApplyMediaOverride').length,0); assert.equal(node('media-override-apply').disabled,false); });
  await resourceEvent('media-override-url','input'); await resourceEvent('media-override-apply');
  check('Media input invalidates previous plan', () => assert.equal(mediaRequests.filter(r=>r.body?.action==='ApplyMediaOverride').length,0));
  await resourceEvent('media-override-reset'); await resourceEvent('media-override-apply');
  check('Media reset uses explicit plan confirmation and refresh', () => { const apply=mediaRequests.find(r=>r.body?.action==='ApplyMediaOverride'); assert.equal(apply.body.parameters.ConfirmMediaSource,true); assert.equal(apply.body.parameters.MediaSourcePlan.Operation,'Reset'); assert.ok(mediaRequests.every(r=>r.url==='/api/media-overrides')); });
  for(const mode of ['noop','invalid','error']) {
    mediaMode=mode; await resourceEvent('media-override-read');
    if(mode==='noop') await resourceEvent('media-override-preview');
    await resourceEvent('media-override-apply');
    check('Media '+mode+' blocks apply',()=>assert.equal(mediaRequests.filter(r=>r.body?.action==='ApplyMediaOverride').length,1));
  }
  mediaMode='ready';await resourceEvent('media-override-read');await resourceEvent('media-override-preview');await resourceEvent('media-override-close');await resourceEvent('media-override-apply');
  check('Media cancel discards pending mutation',()=>assert.equal(mediaRequests.filter(r=>r.body?.action==='ApplyMediaOverride').length,1));
  let releaseMedia;context.fetch=()=>new Promise(resolve=>{releaseMedia=resolve;});
  const pendingMedia=resourceEvent('media-override-open');await resourceEvent('media-override-close');releaseMedia({ok:true,json:async()=>({Result:{Status:'READY',Items:[mediaItem]}})});await pendingMedia;
  check('Media closed dialog ignores delayed state',()=>assert.equal(node('media-override-apply').disabled,true));
  context.fetch = async (url, options) => {
    const body = options?.body ? JSON.parse(options.body) : null; mediaRequests.push({url,body});
    const selected = mediaItems.find(item => item.Id === body?.parameters?.MediaSourceId);
    return {ok:true,json:async()=>({Result:selected ? {Id:selected.Id,Operation:body.parameters.MediaSourceOperation,EffectiveUrl:body.parameters.MediaSourceUrl||selected.RepositoryUrl,IsNoOp:false,Notice:'Kein Download'} : {Status:'READY',Items:mediaItems,Notice:'Kein Download'}})};
  };
  await resourceEvent('media-override-open');
  check('Media chooser exposes six version-labelled fixed sources',()=>{assert.equal((node('media-override-selection').innerHTML.match(/<option/g)||[]).length,6);assert.match(node('media-override-selection').innerHTML,/SQL Server 2022 Evaluation bootstrapper/);assert.match(node('media-override-selection').innerHTML,/SQL Server 2025 Standard Developer bootstrapper/);});
  for (const selected of mediaItems.filter(item=>item.Version==='2022')) {
    node('media-override-selection').value=selected.Id;await resourceEvent('media-override-selection','change');
    const beforeApply=mediaRequests.filter(r=>r.body?.action==='ApplyMediaOverride').length;
    node('media-override-url').value=selected.EffectiveUrl;await resourceEvent('media-override-preview');
    check('Media 2022 exact selection '+selected.Id,()=>{assert.equal(mediaRequests.at(-1).body.parameters.MediaSourceId,selected.Id);assert.equal(mediaRequests.filter(r=>r.body?.action==='ApplyMediaOverride').length,beforeApply);});
    await resourceEvent('media-override-close');await resourceEvent('media-override-apply');
    check('Media 2022 cancelled preview cannot apply '+selected.Id,()=>assert.equal(mediaRequests.filter(r=>r.body?.action==='ApplyMediaOverride').length,beforeApply));
    await resourceEvent('media-override-open');
  }
  await resourceEvent('media-override-close');
  const watchRequests=[];
  const watchItem={Name:'SqlPackage <fixture>',CatalogVersion:'170.4.83.3',ObservedVersion:'170.5.96.0',LastSuccessfulVersion:'170.5.96.0',LastSuccessfulAtUtc:'synthetic-time',SourceUrl:'https://learn.microsoft.com/fixture',Status:'NEW',ReasonCode:'RESOURCE_WATCH_COMPLETED'};
  context.fetch=async (url,options={})=>{watchRequests.push({url,options});return{ok:true,json:async()=>({Result:{Status:'NEW',ReasonCode:'RESOURCE_WATCH_COMPLETED',CheckedAtUtc:'synthetic-time',Items:[watchItem],Notice:'Session only'}})}};
  await resourceEvent('resource-watch-open');
  check('Resource watch open reads snapshot without explicit refresh',()=>{assert.equal(watchRequests[0].options.method,undefined);assert.match(node('resource-watch-details').textContent,/Katalogversion: 170.4.83.3/);assert.match(node('resource-watch-details').textContent,/Letzte erfolgreiche Beobachtung/);});
  await resourceEvent('resource-watch-read');
  check('Resource watch reread remains GET',()=>assert.ok(watchRequests.every(r=>!r.options.method)));
  await resourceEvent('resource-watch-check');
  check('Resource watch explicit refresh reaches direct endpoint',()=>{assert.equal(watchRequests.at(-1).url,'/api/resource-watch');assert.deepEqual(JSON.parse(watchRequests.at(-1).options.body),{action:'RefreshResourceWatch',parameters:{}});});
  context.fetch=async()=>{throw new Error('SYNTHETIC_PRIVATE');};await resourceEvent('resource-watch-check');
  check('Resource watch failed attempt clears current success and raw errors',()=>{assert.match(node('resource-watch-status').textContent,/UNCLEAR/);assert.equal(node('resource-watch-details').textContent,'');assert.doesNotMatch(node('resource-watch-status').textContent,/SYNTHETIC_PRIVATE/);});
  let releaseWatch;context.fetch=()=>new Promise(resolve=>{releaseWatch=resolve;});
  const pendingWatch=resourceEvent('resource-watch-read');await resourceEvent('resource-watch-close');releaseWatch({ok:true,json:async()=>({Result:{Status:'NEW',Items:[watchItem]}})});await pendingWatch;
  check('Resource watch closed dialog ignores late response',()=>assert.match(node('resource-watch-status').textContent,/UNCLEAR/));
  const cmsRequests=[];
  const cmsBase={ContractVersion:'SqlServerLab.CmsInspection/1.0',Status:'NOT_CHECKED',Code:'CMS_INSPECTION_NOT_CHECKED',RunId:'11111111-1111-1111-1111-111111111111',InstanceId:'primary',Provider:'docker',SelectionKey:'a'.repeat(64),SqlMajor:null,ManagedGroupCount:null,ManagedServerCount:null,ObservedAt:null};
  let cmsMode='ready';
  context.fetch=async(url,options={})=>{
    const body=options.body?JSON.parse(options.body):null;cmsRequests.push({url,body});
    if(cmsMode==='error')throw new Error('SYNTHETIC_PRIVATE_SQL_OR_SECRET');
    const view={...cmsBase};
    if(body){Object.assign(view,{Status:'OBSERVED',Code:'CMS_INSPECTION_OBSERVED',SqlMajor:17,ManagedGroupCount:3,ManagedServerCount:0,ObservedAt:'2026-10-01T12:00:00Z'});}
    if(cmsMode==='empty')Object.assign(view,{Status:'NOT_CONFIGURED',RunId:null,Provider:null,SelectionKey:null});
    if(cmsMode==='hyperv')view.Provider='hyperv';
    if(cmsMode==='unknown')Object.assign(view,{Status:'UNKNOWN',ManagedServerCount:null,ManagedGroupCount:null,SqlMajor:null});
    if(cmsMode==='wrong-binding' && body)view.RunId='22222222-2222-2222-2222-222222222222';
    if(cmsMode==='unsafe' && body)view.ManagedServerCount=9007199254740992;
    return {ok:true,json:async()=>({Result:view})};
  };
  await resourceEvent('cms-inspection-open');
  check('CMS open reads registration only with no SQL action',()=>{assert.equal(cmsRequests.length,1);assert.equal(cmsRequests[0].url,'/api/cms-inspection');assert.equal(cmsRequests[0].body,null);assert.match(node('cms-inspection-status').textContent,/noch keine SQL-Verbindung/);});
  await resourceEvent('cms-inspection-check');
  check('CMS explicit inspection carries only bound selection key and shows genuine zero',()=>{assert.deepEqual(cmsRequests.at(-1).body,{action:'InspectCms',parameters:{ExpectedPlanKey:'a'.repeat(64)}});assert.match(node('cms-inspection-result').textContent,/markierte Server: 0/);assert.match(node('cms-inspection-result').textContent,/gelesen/);assert.equal(node('cms-inspection-check').disabled,true);});
  for(const mode of ['empty','hyperv','unknown']){
    cmsMode=mode;await resourceEvent('cms-inspection-read');const before=cmsRequests.length;await resourceEvent('cms-inspection-check');
    check('CMS '+mode+' disables probe without invented counts',()=>{assert.equal(cmsRequests.length,before);assert.equal(node('cms-inspection-check').disabled,true);assert.equal(node('cms-inspection-result').textContent,'');});
  }
  for(const mode of ['wrong-binding','unsafe','error']){
    cmsMode='ready';await resourceEvent('cms-inspection-read');cmsMode=mode;await resourceEvent('cms-inspection-check');
    check('CMS '+mode+' discards acceptance and private error',()=>{assert.equal(node('cms-inspection-result').textContent,'');assert.doesNotMatch(node('cms-inspection-status').textContent,/SYNTHETIC_PRIVATE/);});
  }
  cmsMode='ready';await resourceEvent('cms-inspection-read');
  let releaseCms;context.fetch=()=>new Promise(resolve=>{releaseCms=resolve;});const pendingCms=resourceEvent('cms-inspection-check');await resourceEvent('cms-inspection-close');releaseCms({ok:true,json:async()=>({Result:{...cmsBase,Status:'OBSERVED',SqlMajor:17,ManagedGroupCount:3,ManagedServerCount:5,ObservedAt:'2026-10-01T12:00:00Z'}})});await pendingCms;
  check('CMS close ignores late inspection without retry or queue mutation',()=>{assert.equal(node('cms-inspection-dialog').open,false);assert.equal(node('cms-inspection-result').textContent,'');assert.equal(node('cms-inspection-check').disabled,true);});
  const maintenanceCalls=[];
  const maintenanceRow={Id:'fixture',CandidateId:'a'.repeat(64),Label:'docker · SQL-Speicher',Fields:[{Label:'Herkunft',Value:'Unbekannt <script>marker</script>'}]};
  let maintenanceMode='ready';
  context.fetch=async(url,options)=>{
    const body=options?.body ? JSON.parse(options.body) : null; maintenanceCalls.push({url,body});
    if(maintenanceMode==='error') return {ok:false};
    return {ok:true,json:async()=>body?.action==='preview' ? {CandidateId:maintenanceRow.CandidateId,ExpectedKey:'b'.repeat(64),Status:maintenanceMode==='noop'?'NO_CHANGE':'READY',Notice:'Katalog-only'} : body?.action==='apply' ? {Status:'RECOVERED'} : {Rows:maintenanceMode==='empty'?[]:[maintenanceRow],Incomplete:maintenanceMode==='unknown',Notice:'Read-only',InventoryStatus:'synthetic',UnavailableProviders:1}};
  };
  await resourceEvent('maintenance-open');
  check('Maintenance opening performs no audit or mutation',()=>assert.equal(maintenanceCalls.length,0));
  await resourceEvent('maintenance-read');node('maintenance-selection').value='fixture';
  for(const handler of node('maintenance-selection').events.get('change')||[])handler({});
  check('Maintenance details escape evidence and keep apply disabled',()=>{assert.match(node('maintenance-details').innerHTML,/&lt;script&gt;/);assert.equal(node('maintenance-apply').disabled,true);});
  await resourceEvent('maintenance-preview');await resourceEvent('maintenance-apply');
  check('Maintenance preview alone does not authorize repair',()=>assert.equal(maintenanceCalls.filter(x=>x.body?.action==='apply').length,0));
  node('maintenance-confirm').checked=true;for(const handler of node('maintenance-confirm').events.get('change')||[])handler({});
  await resourceEvent('maintenance-apply');
  check('Maintenance repair sends only opaque binding and typed confirmation',()=>{assert.deepEqual(maintenanceCalls.at(-1).body,{action:'apply',candidateId:'a'.repeat(64),expectedKey:'b'.repeat(64),confirmed:true});assert.match(node('maintenance-status').textContent,/RECOVERED/);assert.equal(node('maintenance-apply').disabled,true);});
  for(const mode of ['empty','unknown','error']){
    maintenanceMode=mode;await resourceEvent('maintenance-read');node('maintenance-selection').value='fixture';
    for(const handler of node('maintenance-selection').events.get('change')||[])handler({});
    check('Maintenance '+mode+' cannot authorize repair',()=>{assert.equal(node('maintenance-preview').disabled,true);assert.equal(node('maintenance-apply').disabled,true);});
  }
  maintenanceMode='noop';await resourceEvent('maintenance-read');node('maintenance-selection').value='fixture';for(const handler of node('maintenance-selection').events.get('change')||[])handler({});await resourceEvent('maintenance-preview');
  check('Maintenance no-op never enables confirmation',()=>assert.equal(node('maintenance-confirm').disabled,true));
  node('maintenance-dialog').close();
  check('Maintenance cancel clears authority',()=>assert.equal(run('maintenancePlan'),null));
  await resourceEvent('maintenance-open');let releaseMaintenance;context.fetch=()=>new Promise(resolve=>{releaseMaintenance=resolve;});const pendingMaintenance=resourceEvent('maintenance-read');node('maintenance-dialog').close();releaseMaintenance({ok:true,json:async()=>({Rows:[maintenanceRow]})});await pendingMaintenance;
  check('Maintenance closed dialog ignores delayed audit',()=>assert.equal(run('maintenanceView'),null));
  const installerCalls = []; let installerMode = 'ready';
  const installerId = 'llama-b11247-win-x64-cpu', installerRoot = 'a'.repeat(64);
  context.fetch = async (url, options) => {
    const body = options?.body ? JSON.parse(options.body) : null; installerCalls.push({ url, body });
    if (installerMode === 'error') throw new Error('SYNTHETIC_PRIVATE');
    return { ok: true, json: async () => body?.action === 'preview' ? { CandidateId: installerId, RootId: installerRoot, ExpectedKey: 'b'.repeat(64), CanApply: installerMode !== 'blocked', IsNoOp: installerMode === 'noop', State: installerMode, Prerequisite: 'UNKNOWN' } : body?.action === 'apply' ? { Status: 'BINARY_PROBE_PASSED' } : body?.action === 'upstream' ? { Status: 'PIN_MATCHES_OFFICIAL_METADATA', Release: 'b11247' } : { Items: [{ Id: installerId, Release: 'b11247', Status: 'EXPERIMENTAL' }], Roots: installerMode === 'empty' ? [] : [{ Id: installerRoot, Label: '<script>synthetic</script>' }], Notice: 'No execution' } };
  };
  await resourceEvent('llama-installer-open');
  check('Installer opening reads only GET and escapes roots', () => { assert.equal(installerCalls.at(-1).body, null); assert.match(node('llama-installer-root').innerHTML, /&lt;script&gt;/); assert.equal(node('llama-installer-apply').disabled, true); });
  node('llama-installer-release').value = installerId; node('llama-installer-root').value = installerRoot;
  await resourceEvent('llama-installer-root', 'change'); await resourceEvent('llama-installer-preview'); await resourceEvent('llama-installer-apply');
  check('Installer preview cannot authorize execution', () => assert.equal(installerCalls.filter(c => c.body?.action === 'apply').length, 0));
  node('llama-installer-confirm').checked = true; await resourceEvent('llama-installer-confirm', 'change'); await resourceEvent('llama-installer-apply');
  check('Installer sends opaque binding and explicit typed confirmation only', () => { assert.deepEqual(installerCalls.at(-1).body, { action: 'apply', candidateId: installerId, rootId: installerRoot, expectedKey: 'b'.repeat(64), confirmed: true }); assert.match(node('llama-installer-status').textContent, /BINARY_PROBE_PASSED/); assert.equal(node('llama-installer-apply').disabled, true); });
  for (const mode of ['noop', 'blocked']) {
    installerMode = mode; await resourceEvent('llama-installer-preview');
    check('Installer ' + mode + ' prevents apply', () => { assert.equal(node('llama-installer-confirm').disabled, true); assert.equal(node('llama-installer-apply').disabled, true); });
  }
  installerMode = 'ready'; await resourceEvent('llama-installer-preview'); node('llama-installer-dialog').close();
  check('Installer cancel invalidates preview without apply', () => assert.equal(run('llamaInstallerPlan'), null));
  for (const mode of ['empty', 'error']) {
    installerMode = mode; await resourceEvent('llama-installer-open');
    check('Installer ' + mode + ' cannot start and hides raw errors', () => { assert.equal(node('llama-installer-preview').disabled, true); assert.equal(node('llama-installer-apply').disabled, true); assert.doesNotMatch(node('llama-installer-status').textContent, /SYNTHETIC_PRIVATE/); });
  }
  let releaseInstaller; context.fetch = () => new Promise(resolve => { releaseInstaller = resolve; });
  const pendingInstaller = resourceEvent('llama-installer-refresh');
  check('Installer disables early selection while initial roots are pending', () => { assert.equal(node('llama-installer-root').disabled, true); assert.equal(node('llama-installer-release').disabled, true); });
  releaseInstaller({ ok: true, json: async () => ({ Items: [], Roots: [], Notice: 'empty' }) }); await pendingInstaller;
  check('Installer delayed empty reply remains failclosed', () => assert.equal(node('llama-installer-preview').disabled, true));
  const sessionId = '11111111-1111-1111-1111-111111111111';
  const planId = '22222222-2222-2222-2222-222222222222';
  const sessionCalls = [];
  context.fetch = async (url, options = {}) => {
    assert.equal(url, '/api/llama-sessions');
    const payload = options.body ? JSON.parse(options.body) : null; sessionCalls.push(payload);
    return { ok: true, json: async () => !payload ? { Items: [{ OperationId: sessionId, Port: 19435, Status: 'OWNED_SESSION' }], Notice: 'Coverage UNKNOWN' } : payload.action === 'preview' ? { PlanId: planId, OperationId: sessionId, Port: 19435, Rights: 'OWNED_WORKER_CONTROL', KnownConsumerCount: 0, ConsumerCoverage: 'UNKNOWN', Notice: 'Unknown consumers may fail' } : { Status: 'CLEANUP_SUCCEEDED' } };
  };
  click(node('llama-session-open')); await new Promise(resolve => setImmediate(resolve));
  check('Real llama session open reads own sessions and never stops automatically', () => {
    assert.ok(node('llama-session-dialog').open); assert.equal(sessionCalls.length, 1); assert.equal(node('llama-session-stop').disabled, true);
  });
  node('llama-session-selection').value = sessionId;
  for (const handler of node('llama-session-selection').events.get('change')) handler({});
  await run('requestLlamaSession("preview")');
  check('Real session preview shows unknown coverage and requires conscious confirmation', () => {
    assert.ok(node('llama-session-preview').textContent.includes('Coverage UNKNOWN')); assert.equal(node('llama-session-stop').disabled, true);
  });
  await run('requestLlamaSession("stop")');
  check('Unchecked confirmation cannot dispatch stop', () => assert.equal(sessionCalls.length, 2));
  click(node('llama-session-close'));
  check('Cancel closes and invalidates session preview without stop', () => { assert.equal(sessionCalls.length, 2); assert.equal(node('llama-session-stop').disabled, true); });
  click(node('llama-session-open')); await new Promise(resolve => setImmediate(resolve));
  node('llama-session-selection').value = sessionId;
  for (const handler of node('llama-session-selection').events.get('change')) handler({});
  await run('requestLlamaSession("preview")');
  node('llama-session-confirm').checked = true;
  for (const handler of node('llama-session-confirm').events.get('change')) handler({});
  const originalSessionFetch = context.fetch; let releaseConfirmedStop;
  context.fetch = (url, options) => { sessionCalls.push(JSON.parse(options.body)); return new Promise(resolve => { releaseConfirmedStop = resolve; }); };
  const confirmedStop = run('requestLlamaSession("stop")');
  check('Confirmed in-flight stop waits for outcome and cannot be disguised as Cancel', () => {
    assert.equal(node('llama-session-close').disabled, true);
    let prevented = false; for (const handler of node('llama-session-dialog').events.get('cancel')) handler({ preventDefault() { prevented = true; } });
    assert.equal(prevented, true); click(node('llama-session-close')); assert.equal(node('llama-session-dialog').open, true);
  });
  releaseConfirmedStop({ ok: true, json: async () => ({ Status: 'CLEANUP_SUCCEEDED' }) }); await confirmedStop; context.fetch = originalSessionFetch;
  check('Actual stop sends only opaque preview and explicit confirmation, then clears selection', () => {
    assert.deepEqual(sessionCalls.at(-1), { action: 'stop', planId, confirmed: true });
    assert.ok(node('llama-session-status').textContent.includes('CLEANUP_SUCCEEDED')); assert.equal(node('llama-session-stop').disabled, true);
  });
  let releaseSession; context.fetch = () => new Promise(resolve => { releaseSession = resolve; });
  const lateSession = run('requestLlamaSession()');
  click(node('llama-session-close'));
  releaseSession({ ok: true, json: async () => ({ Items: [{ OperationId: sessionId }], Notice: 'stale' }) }); await lateSession;
  check('Late session response after close cannot restore a target or preview', () => assert.equal(node('llama-session-stop').disabled, true));
  context.fetch = async () => ({ ok: true, json: async () => ({ Items: [], Notice: 'Coverage UNKNOWN' }) });
  click(node('llama-session-open')); await new Promise(resolve => setImmediate(resolve));
  check('Empty own-session inventory explains same-modulehost start and disables mutation', () => { assert.ok(node('llama-session-status').textContent.includes('Keine Sitzung')); assert.equal(node('llama-session-plan').disabled, true); });
  console.log('WORKFLOW SQL TARGET, EVALUATION AND SETUP: ' + passed + ' PASS');
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
