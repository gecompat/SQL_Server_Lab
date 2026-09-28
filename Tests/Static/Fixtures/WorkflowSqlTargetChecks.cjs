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
  close() { this.open = false; }
  querySelectorAll(selector) {
    return this.id === 'container-operation-dialog' && selector === 'input[type="password"]'
      ? [nodes.get('container-operation-password')] : [];
  }
}
for (const match of html.matchAll(/\bid="([^"]+)"/g)) nodes.set(match[1], new Element(match[1]));
const documentEvents = new Map();
const document = {
  querySelector(selector) {
    if (!selector.startsWith('#')) return null;
    const element = nodes.get(selector.slice(1));
    assert.ok(element, 'Real HTML must contain ' + selector);
    return element;
  },
  querySelectorAll(selector) { return selector === 'dialog[open]' ? [...nodes.values()].filter((item) => item.open) : []; },
  addEventListener(type, callback) { documentEvents.set(type, [...(documentEvents.get(type) || []), callback]); }
};
const context = vm.createContext({ document, console, URLSearchParams,
  window: { setInterval() {}, setTimeout() {}, clearTimeout() {}, alert() {} },
  fetch: () => new Promise(() => {}), setTimeout() {}, clearTimeout() {}, queued: [] });
const run = (code) => vm.runInContext(code, context, { timeout: 5000 });
run(source);
run('queueBackgroundAction = (action, parameters) => queued.push({action, parameters});');
let passed = 0;
function check(name, body) { body(); passed++; console.log('PASS ' + name); }
const node = (id) => nodes.get(id);
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
  console.log('WORKFLOW SQL TARGET: ' + passed + ' PASS');
}
main().catch((error) => { console.error(error); process.exitCode = 1; });
