const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const { webcrypto } = require('node:crypto');
const source = fs.readFileSync(path.join(__dirname, '../../../Ui/app.js'), 'utf8');
let passed = 0;
function check(value, name) { if (!value) throw Error(name); passed++; console.log('PASS: ' + name); }
function actualFunction(name) {
  const match = new RegExp('^(?:async )?function ' + name + '\\(', 'm').exec(source);
  if (!match) throw Error('Function missing: ' + name);
  const rest = source.slice(match.index), next = /\n(?:async )?function \w+\(/.exec(rest);
  return next ? rest.slice(0, next.index) : rest;
}
const elements = new Map();
const document = { querySelector(selector) { if (!elements.has(selector)) elements.set(selector, { innerHTML: '', textContent: '', hidden: true, closest: () => ({ scrollIntoView() {} }) }); return elements.get(selector); } };
let timers = new Map(), timerId = 0, calls = [], responder, hashInputs = [];
const context = vm.createContext({ document, crypto: { subtle: { async digest(algorithm, bytes) { hashInputs.push(new TextDecoder().decode(bytes)); return webcrypto.subtle.digest(algorithm, bytes); } } }, TextEncoder, AbortController, console,
  window: { setTimeout(fn, delay) { timers.set(++timerId, { fn, delay }); return timerId; }, clearTimeout(id) { timers.delete(id); } },
  sqlServerLabUiFetch: async (url, options) => { calls.push({ url, method: options?.method || 'GET' }); return responder(url, options); },
  showWorkspaceArea() {}, empty: value => value, migrationInventoryResult: () => '', testGroupResult: () => ''
});
vm.runInContext(source.slice(0, source.indexOf('function publicCommandAllowedValues')), context);
for (const name of ['renderJobs','refreshJobs','readUiJobResponse','submitUiCommandBody','canonicalSubmission','nonSecretSubmissionIdentity','submitUiAction','startAction','startPublicCommand']) vm.runInContext(actualFunction(name), context);
const run = code => vm.runInContext(code, context);
const html = () => document.querySelector('#jobs').innerHTML;
const tick = () => new Promise(resolve => setImmediate(resolve));
const response = value => ({ ok: true, json: async () => value });
const job = (state, id='batch-own') => ({ Id: id, Action: 'SetDataRoot', State: state, Source: 'PersistentBatch', Lines: ['[STATUS] ' + state] });
function fire(delay) { const entry = [...timers.entries()].find(([, item]) => item.delay === delay); if (!entry) throw Error('Timer missing'); timers.delete(entry[0]); entry[1].fn(); }
(async () => {
  let late;
  responder = (url) => url === '/api/actions' ? response({ id: 'batch-own', hostStart: 'Failed' }) : new Promise(resolve => { late = resolve; });
  const first = run("startAction('SetDataRoot', { DataRoot: 'synthetic' })");
  const duplicate = run("startAction('SetDataRoot', { DataRoot: 'synthetic' })");
  const submissions = await Promise.allSettled([first, duplicate]);
  check(submissions.filter(item => item.status === 'fulfilled').length === 1 && submissions.filter(item => item.status === 'rejected').length === 1, 'Identical concurrent click is rejected without second POST');
  check(calls.filter(call => call.method === 'POST').length === 1, 'Exactly one submission despite double click');
  check(html().includes('Start unbestätigt') && !html().includes('HEARTBEAT') && !html().includes('job-progress'), 'Accepted is not Running or animated heartbeat');
  check(html().includes('OPERATION_HOST_START_FAILED'), 'Hoststart failure is visible separately');
  late(response([job('Waiting')])); await tick();
  check(html().includes('Wartend') && !html().includes('läuft seit'), 'Persistent ID replaces optimistic card with waiting status');
  responder = () => response([job('Blocked')]); await run('refreshJobs()'); check(html().includes('Blockiert'), 'Blocked is distinct');
  responder = () => response([job('Running')]); await run('refreshJobs()'); check(html().includes('Serverstatus'), 'Only server reported Running is rendered');
  run("renderJobs([{Id:'batch-own',Action:'SetDataRoot',State:'Running',Source:'PersistentBatch',StartedAt:'2000-01-01T00:00:00Z',ElapsedSeconds:999999,Lines:[]}])");
  check(!html().includes('läuft seit') && !html().includes('999999'), 'Persistent Running never derives execution duration from old acceptance or summary elapsed');
  responder = () => new Promise(resolve => { late = resolve; });
  const pending = run('refreshJobs()'); await tick(); const count = calls.length;
  await run('refreshJobs()'); check(calls.length === count, 'Status polling is single-flight');
  fire(5000); await pending; check(html().includes('Verbindung verloren') && !html().includes('läuft seit'), 'Hung status request becomes Unknown with bounded abort');
  responder = () => response([job('Completed')]); await run('refreshJobs()');
  late(response([job('Running')])); await tick(); check(html().includes('Erfolgreich') && !html().includes('Serverstatus'), 'Late timed out response cannot regress newer terminal status');
  responder = () => { throw Error('raw host path secret'); }; await run('refreshJobs()'); check(html().includes('Erfolgreich') && !html().includes('raw host'), 'Terminal result survives outage without raw exception');
  responder = () => response([]); await run('refreshJobs()'); check(html().includes('Erfolgreich'), 'Terminal result retained when omitted by later source');
  responder = url => url === '/api/actions' ? response({ id: 'batch-next' }) : response([job('Running', 'batch-next')]);
  await run("startAction('SetDataRoot', { DataRoot: 'synthetic' })"); await tick(); check(calls.filter(call => call.method === 'POST').length === 2, 'Deliberate identical action allowed after terminal');
  responder = () => response([]); await run('refreshJobs()'); check(html().includes('STATUS_SOURCE_MISSING'), 'Missing accepted persistent source becomes Unknown');
  responder = () => { throw Error('private-secret'); };
  check(await run("startAction('RemoveContainerLab', {BuildId:'synthetic'}).then(() => false, () => true)"), 'POST response loss is reported');
  check(html().includes('Annahme unbestätigt') && !html().includes('private-secret'), 'Unknown POST retains card without raw exception');
  const before = calls.length;
  check(await run("startAction('RemoveContainerLab', {BuildId:'synthetic'}).then(() => false, () => true)"), 'Unknown acceptance prevents duplicate submission');
  check(calls.length === before, 'No automatic or second mutation after unknown POST');
  responder = url => url === '/api/command-grants' ? response({grant:'a'.repeat(64),receiptId:'b'.repeat(32)}) : url === '/api/commands' ? response({id:'command-own',receiptId:'b'.repeat(32)}) : response([]);
  await run("startPublicCommand({Name:'Synthetic'}, {Name:'SecretSet'}, {Password:'sensitive-synthetic'}, true)"); await tick();
  check(await run("startPublicCommand({Name:'Synthetic'}, {Name:'SecretSet'}, {Password:'sensitive-synthetic'}, true).then(() => false, () => true)"), 'Public command submission shares dedupe boundary');
  check(run("[...actionSubmissions.keys()].every(key => /^[0-9a-f]{64}$/.test(key))"), 'Retained dedupe keys contain hashes only, no parameters or secrets');
  const identityA = run("nonSecretSubmissionIdentity('Synthetic','/api/actions',{parameters:{BuildId:'same-target',GuestPassword:'canary-first',SaPassword:'canary-first',Nested:{Password:'canary-first'}}},[])");
  const identityB = run("nonSecretSubmissionIdentity('Synthetic','/api/actions',{parameters:{BuildId:'same-target',GuestPassword:'canary-second',SaPassword:'canary-second',Nested:{Password:'canary-second'}}},[])");
  check(JSON.stringify(identityA) === JSON.stringify(identityB), 'Action password and nested secret changes cannot change retained identity');
  check(JSON.stringify(identityA) !== JSON.stringify(run("nonSecretSubmissionIdentity('Synthetic','/api/actions',{parameters:{BuildId:'other-target'}},[])")), 'Different nonsecret target keeps distinct submission identity');
  const metadata = "[{Name:'RunId',Sensitive:false,IsCredential:false,TypeName:'System.String'},{Name:'Credential',Sensitive:true,IsCredential:true,TypeName:'System.Management.Automation.PSCredential'},{Name:'Password',Sensitive:true,IsCredential:false,TypeName:'System.String'},{Name:'DataRoot',Sensitive:true,IsCredential:false,TypeName:'System.String'}]";
  const commandIdentityA = run("nonSecretSubmissionIdentity('Command: Synthetic','/api/commands',{parameterSetName:'SecretSet',parameters:{RunId:'same-target',Password:'canary-first',Credential:{password:'canary-first'},DataRoot:'canary-first',Unknown:'canary-first'}}," + metadata + ")");
  const commandIdentityB = run("nonSecretSubmissionIdentity('Command: Synthetic','/api/commands',{parameterSetName:'SecretSet',parameters:{RunId:'same-target',Password:'canary-second',Credential:{password:'canary-second'},DataRoot:'canary-second',Unknown:'canary-second'}}," + metadata + ")");
  check(JSON.stringify(commandIdentityA) === JSON.stringify(commandIdentityB), 'Generic metadata-sensitive values and unknown inputs are omitted before digest');
  responder = url => url === '/api/command-grants' ? response({grant:'a'.repeat(64),receiptId:'b'.repeat(32)}) : url === '/api/commands' ? response({id:'secret-command-own',receiptId:'b'.repeat(32)}) : response([]);
  await run("startPublicCommand({Name:'SecretCanary'},{Name:'SecretSet',Parameters:" + metadata + "},{RunId:'same-target',Password:'canary-first',Credential:{password:'canary-first'},DataRoot:'canary-first',Unknown:'canary-first'},true)"); await tick();
  const postsBeforeSecretChange = calls.filter(call => call.method === 'POST').length;
  check(await run("startPublicCommand({Name:'SecretCanary'},{Name:'SecretSet',Parameters:" + metadata + "},{RunId:'same-target',Password:'canary-second',Credential:{password:'canary-second'},DataRoot:'canary-second',Unknown:'canary-second'},true).then(()=>false,()=>true)"), 'Secret-only change remains protected against duplicate generic submission');
  check(calls.filter(call => call.method === 'POST').length === postsBeforeSecretChange && !hashInputs.some(input => /canary-|sensitive-synthetic/.test(input)), 'No secret reaches actual digest input; no second POST');
  responder = url => url === '/api/actions' ? response({id:'secret-action-own'}) : response([]);
  await run("startAction('SyntheticSecretAction',{BuildId:'same-target',GuestPassword:'canary-first',SaPassword:'canary-first'})"); await tick();
  const actionPosts = calls.filter(call => call.method === 'POST').length;
  check(await run("startAction('SyntheticSecretAction',{BuildId:'same-target',GuestPassword:'canary-second',SaPassword:'canary-second'}).then(()=>false,()=>true)"), 'Transient action secret changes cannot bypass duplicate target protection');
  check(calls.filter(call => call.method === 'POST').length === actionPosts && !hashInputs.some(input => /canary-|sensitive-synthetic/.test(input)), 'Transient secrets never enter retained identity digest');
  run("renderJobs([{Id:'thread-own',Action:'Synthetic',State:'Running',Lines:['only-once']}]); renderJobs([])");
  check((html().match(/only-once/g) || []).length === 1, 'Rerender does not duplicate cached thread log');
  responder = () => response([{Id:'bad',State:['Running'],Action:'Synthetic'}]); await run('refreshJobs()');
  check(html().includes('Verbindung verloren'), 'Malformed status response fails closed');
  console.log('RESULT: ' + passed + ' PASS; network/provider/action execution=0');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
