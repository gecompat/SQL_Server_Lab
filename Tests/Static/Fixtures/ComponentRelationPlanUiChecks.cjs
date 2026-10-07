'use strict';
// Execute the actual standalone dialog script with DOM/sqlServerLabUiFetch leaves only.
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../../..');
const html = fs.readFileSync(path.join(root, 'Ui/index.html'), 'utf8');
const source = fs.readFileSync(path.join(root, 'Ui/component-relations.js'), 'utf8');
class Element {
  constructor() { this.value = ''; this.textContent = ''; this.disabled = false; this.open = false; this.children = []; this.events = new Map(); }
  addEventListener(type, callback) { this.events.set(type, [...(this.events.get(type) || []), callback]); }
  replaceChildren() { this.children = []; this.value = ''; }
  appendChild(child) { this.children.push(child); }
  showModal() { this.open = true; }
  close() { this.open = false; return this.fire('close'); }
  async fire(type) { for (const callback of this.events.get(type) || []) await callback({}); }
}
const nodes = new Map([...html.matchAll(/\bid="(component-relations-[^"]+)"/g)].map(match => [match[1], new Element()]));
const node = id => { const element = nodes.get('component-relations-' + id); assert.ok(element, 'Actual HTML element ' + id); return element; };
const requests = [];
const context = vm.createContext({ document: { querySelector(selector) { return nodes.get(selector.slice(1)); }, createElement() { return new Element(); } },
  sqlServerLabUiFetch(url, options) { assert.equal(url, '/api/component-relations'); let resolve; const promise = new Promise(done => { resolve = done; }); requests.push({ url, options, resolve }); return promise; },
  queueBackgroundAction() { throw new Error('FORBIDDEN_WORKFLOW_DISPATCH'); }, startPublicCommand() { throw new Error('FORBIDDEN_GENERIC_COMMAND'); }, console });
vm.runInContext(source, context, { timeout: 5000 });
let checks = 0;
const check = (name, condition) => { assert.ok(condition, name); checks++; console.log('PASS ' + name); };
const own = '33333333-3333-4333-8333-333333333333', shared = '55555555-5555-4555-8555-555555555555', other = '99999999-9999-4999-8999-999999999999';
const run = (id, instances, state = 'RUNNING') => ({ RunId: id, ScopeId: id.replace(/3/g, '4').replace(/5/g, '6').replace(/9/g, 'a'), State: state, Digest: 'a'.repeat(64), Instances: instances });
const instance = (id, provider) => ({ Id: id, Provider: provider, Version: '2025' });
const metadata = { ContractVersion: 'SqlServerLab.ComponentRelationBrowser/1.0', Status: 'METADATA_ONLY', MutationAllowed: false, ExecutionSupported: false, SqlReadiness: 'NOT_CHECKED', SharedRemovalPolicy: 'PRESERVE', Runs: [run(own, [instance('consumer', 'docker'), instance('prerequisite', 'podman')]), run(shared, [instance('sharedSql', 'docker')]), run(other, [instance('otherSql', 'podman')])] };
const respond = (request, value, ok = true) => request.resolve({ ok, async json() { return value; } });
const flush = () => new Promise(resolve => setImmediate(resolve));
(async () => {
  await node('open').fire('click'); await node('close').fire('click');
  check('Open/back cancels without any read/preview/command', requests.length === 0);
  await node('open').fire('click'); node('root').value = 'SYNTHETIC_REGISTERED_ROOT';
  const pending = node('read').fire('click'); await node('read').fire('click');
  check('Busy metadata request is single and disables editing', requests.length === 1 && node('run').disabled && node('root').disabled);
  await node('close').fire('click'); respond(requests[0], metadata); await pending;
  check('Late metadata after close cannot restore choices', node('run').children.length === 0 && !node('dialog').open);
  await node('open').fire('click'); const read = node('read').fire('click'); respond(requests[1], metadata); await read;
  check('Metadata choices show stored SQL version and provider separately', node('source').children[0].textContent.includes('SQL 2025 · Provider: docker'));
  check('Read uses only exact root and action', Object.keys(JSON.parse(requests[1].options.body)).sort().join(',') === 'Action,DataRoot');
  node('target').value = shared + ':sharedSql'; await node('add').fire('click');
  check('Shared choice stays reference/PRESERVE', node('draft').textContent.includes('PRESERVE'));
  node('source').value = 'prerequisite'; await node('source').fire('change');
  check('One shared reference excludes other managed shared target', !node('target').children.some(option => option.value === other + ':otherSql'));
  node('target').value = other + ':otherSql'; await node('add').fire('click');
  check('Forged hidden second shared target is ignored', vm.runInContext('componentRelationsDraft.length', context) === 1);
  node('target').value = own + ':consumer'; await node('add').fire('click');
  const preview = node('preview').fire('click'); await node('preview').fire('click');
  const payload = JSON.parse(requests[2].options.body);
  check('Preview sends RAM relations and exactly own/shared bindings once', requests.length === 3 && payload.Action === 'Preview' && payload.ProposedRelations.length === 2 && payload.Bindings.length === 2 && !('StateRoot' in payload));
  respond(requests[2], { ContractVersion: 'SqlServerLab.ComponentRelationBrowser/1.0', RunId: own, Status: 'BLOCKED_SQL_READINESS_NOT_CHECKED', Mode: 'COMPONENT_RELATIONS_PLAN_ONLY', SqlReadiness: 'NOT_CHECKED', SharedRemovalPolicy: 'PRESERVE', Actions: [], MutationAllowed: false, ExecutionSupported: false, PrerequisiteOrder: [{ InstanceId: 'sharedSql', Provider: 'docker', LifecycleState: 'RUNNING', ManagementMode: 'EXTERNAL_READ_ONLY' }] }); await preview;
  check('Result states PLAN_ONLY NOT_CHECKED PRESERVE and blocked execution', node('result').textContent.includes('PLAN_ONLY · SQL: NOT_CHECKED · Shared: PRESERVE') && node('status').textContent.includes('gesperrt'));
  await node('clear').fire('click');
  check('Discard draft causes no network request', requests.length === 3 && vm.runInContext('componentRelationsDraft.length', context) === 0);
  const late = node('preview').fire('click'); await node('close').fire('click'); respond(requests[3], {}); await late;
  check('Late preview after close cannot display or adopt a result', node('result').textContent === '' && node('run').children.length === 0);
  await node('open').fire('click'); const bad = node('read').fire('click'); respond(requests[4], { ...metadata, MutationAllowed: true }); await bad;
  check('Malformed authority/result discarded and fixed error shown', node('run').children.length === 0 && node('status').textContent.includes('nicht bestätigt'));
  const fresh = node('read').fire('click'); respond(requests[5], metadata); await fresh;
  const failed = node('preview').fire('click'); respond(requests[6], { Code: 'PRIVATE_CANARY_SECRET' }, false); await failed;
  check('Server failure discards choices without raw error reflection', node('run').children.length === 0 && !node('status').textContent.includes('PRIVATE_CANARY'));
  const rootRead = node('read').fire('click'); respond(requests[7], metadata); await rootRead;
  node('root').value = 'CHANGED_ROOT'; await node('root').fire('input');
  check('Changed root invalidates prior metadata with zero preview', node('preview').disabled && node('run').children.length === 0 && requests.length === 8);
  check('Every actual request stays dedicated POST, never generic job/action', requests.every(request => request.url === '/api/component-relations' && request.options.method === 'POST'));
  console.log('COMPONENT_RELATION_UI_CHECKS: ' + checks + ' PASS; 0 FAIL');
})().catch(error => { console.error(error); process.exitCode = 1; });
