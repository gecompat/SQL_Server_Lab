const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.join(__dirname, '../../..');
const source = fs.readFileSync(path.join(root, 'Ui/app.js'), 'utf8');
const html = fs.readFileSync(path.join(root, 'Ui/index.html'), 'utf8');
const server = fs.readFileSync(path.join(root, 'Tools/Start-SqlServerLabUi.ps1'), 'utf8');
let passed = 0;
function check(value, name) { if (!value) throw Error(name); passed++; }
function slice(start, end) {
  const first = source.indexOf(start), last = source.indexOf(end, first);
  if (first < 0 || last < 0) throw Error('UI source boundary missing');
  return source.slice(first, last);
}

const elements = new Map(), listeners = new Map();
function element(selector) {
  if (!elements.has(selector)) elements.set(selector, { value: '', checked: false, hidden: true, close() {}, addEventListener(type, handler) { listeners.set(`${selector}:${type}`, handler); } });
  return elements.get(selector);
}
const jobs = [], errors = [];
const context = vm.createContext({
  $: element,
  queueBackgroundAction(action, parameters, dialog, onQueued) {
    jobs.push({ action, parameters: { ...parameters } });
    if (onQueued) onQueued();
  },
  showError(error) { errors.push(error.message); }
});
vm.runInContext(slice('function resetContainerPasswordAdjustment()', "$('#new-manifest').addEventListener"), context);
const handlers = new Map();
for (const selector of ['#container-form', '#manifest-run-form']) {
  element(selector).addEventListener = (_, handler) => handlers.set(selector, handler);
}
// Re-register the actual handlers against the synthetic form listeners.
vm.runInContext(slice("$('#container-form').addEventListener", "$('#manifest-form').addEventListener"), context);
vm.runInContext(slice("$('#manifest-run-form').addEventListener", "$('#container-operation-form').addEventListener"), context);
function submit(selector, cancelled = false) {
  let prevented = false;
  return Promise.resolve(handlers.get(selector)({ submitter: { value: cancelled ? 'cancel' : 'default' }, preventDefault() { prevented = true; } })).then(() => prevented);
}
async function run() {
  element('#container-provider').value = 'docker';
  element('#container-version').value = '2025-CU9';
  element('#container-profile').value = 'standard';
  element('#container-instance').value = 'primary';
  element('#container-lab-name').value = 'synthetic';
  element('#container-storage-action').value = 'NEW';
  element('#container-autostart').checked = false;
  element('#container-password-minimum').value = '8';
  element('#container-password').value = 'Ab3';
  element('#container-password-repeat').value = 'Ab3';
  check(await submit('#container-form') && jobs.length === 0, 'Short default password creates no job');
  check(element('#container-password-adjustment').hidden === false, 'Eligible short password exposes explicit adjustment');
  element('#container-password-minimum').value = '3';
  element('#container-password-adjust-confirm').checked = true;
  element('#container-password').value = element('#container-password-repeat').value = 'Ab3xxxxx';
  check(await submit('#container-form') && jobs.length === 1 && !('SaPasswordMinimumLength' in jobs[0].parameters), 'Corrected password cannot retain a stale custom minimum');
  element('#container-password').value = element('#container-password-repeat').value = 'Ab3';
  check(await submit('#container-form') && jobs.length === 1, 'Another short password still requires explicit adjustment');
  element('#container-password-minimum').value = '3';
  element('#container-password-adjust-confirm').checked = true;
  element('#container-password').value = element('#container-password-repeat').value = 'Ab3xxxxx';
  listeners.get('#container-password:input')();
  check(element('#container-password-adjust-confirm').checked === false && element('#container-password-adjustment').hidden === true && element('#container-password-minimum').value === '8', 'Password edit revokes the adjustment choice');
  check(await submit('#container-form') && jobs.length === 2 && !('SaPasswordMinimumLength' in jobs[1].parameters), 'Edited password uses default policy');
  element('#container-password').value = element('#container-password-repeat').value = 'Ab3';
  check(await submit('#container-form') && jobs.length === 2, 'Short password needs a fresh adjustment choice');
  element('#container-password-minimum').value = '3';
  element('#container-password-adjust-confirm').checked = true;
  listeners.get('#container-password:change')();
  check(element('#container-password-adjust-confirm').checked === false && element('#container-password-minimum').value === '8', 'Password change revokes the adjustment choice');
  element('#container-password-minimum').value = '3';
  element('#container-password-adjust-confirm').checked = true;
  element('#container-storage-action').value = 'ATTACH'; // Hidden after persistent storage was disabled.
  check(await submit('#container-form') && jobs.length === 3 && jobs[2].parameters.SaPasswordMinimumLength === 3, 'Confirmed eligible minimum reaches exactly one creation job despite stale hidden storage action');
  element('#container-storage-action').value = 'NEW';
  check(element('#container-password').value === '' && element('#container-password-adjust-confirm').checked === false, 'Queued secret and adjustment are cleared');
  element('#container-version').value = '2025';
  element('#container-password').value = element('#container-password-repeat').value = 'Ab3';
  check(await submit('#container-form') && jobs.length === 3 && element('#container-password-adjustment').hidden === true, 'Floating version cannot offer adjustment or create job');
  element('#container-version').value = '2025-CU9';
  element('#container-persistent-data').checked = true;
  check(await submit('#container-form') && jobs.length === 3, 'Persistent target cannot create short-password job');
  element('#container-persistent-data').checked = false;
  element('#container-password').value = element('#container-password-repeat').value = 'Ab3xxxxx';
  check(await submit('#container-form') && jobs.length === 4 && !('SaPasswordMinimumLength' in jobs[3].parameters), 'Corrected password uses default policy');
  element('#manifest-run-password').value = 'Ab3';
  check(await submit('#manifest-run-form') && jobs.length === 4, 'Manifest short password creates no job');
  element('#manifest-run-password').value = 'Ab3xxxxx';
  element('#manifest-run-path').value = 'synthetic.json';
  check(await submit('#manifest-run-form') && jobs.length === 5 && jobs[4].action === 'NewContainerLabFromManifest', 'Manifest valid password uses existing action');
  check(!(await submit('#container-form', true)) && jobs.length === 5, 'Cancel does not submit');
  check(errors.length > 0 && errors.every(message => !message.includes('Ab3')), 'Validation errors contain no password');
  check(html.includes('id="container-password-adjustment" hidden') && html.includes('id="container-password-adjust-confirm"'), 'Visible choice is explicit and initially hidden');
  const routeStart = server.indexOf("if ($path -eq '/api/actions'");
  const route = server.slice(routeStart, server.indexOf("if ($path -eq '/api/commands'", routeStart));
  check(route.indexOf('Assert-LabSaPasswordWorkflowPreflight') >= 0 && route.indexOf('Assert-LabSaPasswordWorkflowPreflight') < route.indexOf('Start-UiWorkflowJob'), 'Server preflight precedes creation job');
  console.log('SA PASSWORD UI CHECKS: ' + passed + ' PASS; runtime and HTTP listener NOT_EXECUTED');
}
run().catch(error => { console.error(error.message); process.exitCode = 1; });
