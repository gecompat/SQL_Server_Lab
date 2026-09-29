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
  window: { setInterval() {}, setTimeout() {}, clearTimeout() {}, alert() {} },
  fetch: (...args) => { fetchRequests.push(args); return new Promise(() => {}); }, setTimeout() {}, clearTimeout() {}, queued: [] });
const fetchRequests = [];
const run = (code) => vm.runInContext(code, context, { timeout: 5000 });
run(source);
run('const actualQueueBackgroundAction = queueBackgroundAction; queueBackgroundAction = (action, parameters) => queued.push({action, parameters});');
let passed = 0;
function check(name, body) { body(); passed++; console.log('PASS ' + name); }
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
  check('Real form/queue/startAction chain exposes live log before server acceptance', () => {
    assert.equal(run('workspaceArea'), 'messages');
    assert.ok(!node('jobs').closest('.panel').hidden);
    assert.ok(node('jobs').closest('.panel').scrolled);
    assert.ok(node('jobs').innerHTML.includes('Submitting'));
    assert.equal(node('container-operation-dialog').open, false);
    assert.equal(actionRequests[0].url, '/api/actions');
    assert.equal(JSON.parse(actionRequests[0].options.body).action, 'ExecuteContainerScript');
  });
  acceptAction({ ok: true, json: async () => ({ id: 'synthetic-job' }) });
  await new Promise((resolve) => setImmediate(resolve));
  check('Completed normal action keeps its actual result visible after feedback disappears', () => {
    assert.equal(actionRequests[1].url, '/api/jobs');
    assert.ok(node('jobs').innerHTML.includes('Completed'));
    assert.ok(node('jobs').innerHTML.includes('SYNTHETIC_RESULT'));
    assert.equal(node('action-feedback').hidden, true);
    assert.ok(!node('jobs').closest('.panel').hidden);
    assert.equal(run('workspaceArea'), 'messages');
  });
  const setupState = { ConfigurationStatus: 'READY', Complete: true, MediaRootValid: true, MediaRoot: '/synthetic/Lab_Base',
    MediaRootCandidates: [{ Path: '<invalid>', Source: 'ProcessEnvironment', Status: 'ROOT_NOT_FOUND', Selected: false }, { Path: '/synthetic/Lab_Base', Source: 'ProjectPreference', Status: 'READY', Selected: true }],
    LocationStatus: [{ LabDataRoot: '/synthetic/Lab_Data', Source: 'StorageConfiguration', Status: 'READY', IsDefault: true }, { LabDataRoot: '<missing>', Source: 'StorageConfiguration', Status: 'ROOT_NOT_FOUND' }],
    DefaultLocation: { LabDataRoot: '/synthetic/Lab_Data' } };
  const setupPlan = { ContractVersion: 'SqlServerLab.InitialSetupPlan/1.0', MediaAction: null, LocationActions: [{ LabDataRoot: '/synthetic/second_Data' }], DefaultDataRoot: '/synthetic/second_Data', IsNoOp: false };
  const setupRequests = [];
  context.fetch = async (url, options) => {
    assert.equal(url, '/api/initial-setup');
    const payload = options?.body ? JSON.parse(options.body) : null;
    setupRequests.push(payload);
    return { ok: true, json: async () => ({ Result: payload?.action === 'PlanInitialSetup' ? setupPlan : payload?.action === 'RefreshSetupProvider' ? { Provider: 'podman', Check: { Status: 'BLOCKED', Code: 'PROVIDER_UNREACHABLE' } } : setupState }) };
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
    return { ok: true, json: async () => ({ RunId: 'resource-run', InstanceId: query.get('instanceId'), Provider: query.get('provider'), Actual: actual, Desired: desired, CanApply: resourceMode !== 'unknown', NoChange: desired.Cpu === actual.Cpu && desired.MemoryMB === actual.MemoryMB, PlanKey: 'a'.repeat(64), NextStep: resourceMode === 'unknown' ? 'Istlimit unbekannt; Apply nicht verfügbar.' : 'Live; kein Neustart.' }) };
  };
  context.resourceButton = { dataset: { run: 'resource-run' } };
  const resourceEvent = async (id, type = 'click') => { for (const handler of node(id).events.get(type) || []) await handler({ submitter: { value: 'default' }, preventDefault() {} }); };
  await run('openResourceDialog(resourceButton)');
  check('Resource dialog pre-fills measured values for exact instance/provider and blocks no-op', () => {
    assert.equal(Number(node('resource-processors').value), 2);
    assert.equal(node('resource-apply').disabled, true);
    assert.ok(node('resource-current').textContent.includes('secondary · podman'));
  });
  await resourceEvent('resource-form','submit');
  node('resource-processors').value = '2.5';
  await resourceEvent('resource-processors','input');
  await resourceEvent('resource-form','submit');
  check('Unpreviewed edits and no-op never queue mutation', () => assert.equal(resourceRequests.filter((r) => r.url === '/api/actions').length, 0));
  await resourceEvent('resource-preview');
  check('Shared preview displays old/new before Apply', () => { assert.equal(node('resource-apply').disabled, false); assert.ok(node('resource-current').textContent.includes('2 → 2.5')); });
  await resourceEvent('resource-form','submit');
  await new Promise((resolve) => setImmediate(resolve));
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
  let mediaMode = 'ready';
  context.fetch = async (url, options) => {
    const body = options?.body ? JSON.parse(options.body) : null;
    mediaRequests.push({url,body});
    const result = body?.action === 'PlanMediaOverride' ? { Id: mediaItem.Id, Operation: body.parameters.MediaSourceOperation, EffectiveUrl: body.parameters.MediaSourceUrl || mediaItem.RepositoryUrl, IsNoOp: mediaMode === 'noop', PlanKey: 'synthetic-plan', Notice: 'Kein Download' } : { Status: mediaMode === 'invalid' ? 'INVALID' : 'READY', Items: [mediaItem], Notice: 'Kein Download' };
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
  console.log('WORKFLOW SQL TARGET, EVALUATION AND SETUP: ' + passed + ' PASS');
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
