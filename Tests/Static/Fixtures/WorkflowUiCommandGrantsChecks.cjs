const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const { webcrypto } = require('node:crypto');
const source = fs.readFileSync(path.join(__dirname, '../../../Ui/app.js'), 'utf8');
let passed = 0;
function check(name, fn) { fn(); passed++; console.log('PASS ' + name); }
function actualFunction(name) {
  const match = new RegExp('^(?:async )?function ' + name + '\\(', 'm').exec(source);
  assert.ok(match); const rest = source.slice(match.index), next = /\n(?:async )?function \w+\(/.exec(rest);
  return next ? rest.slice(0, next.index) : rest;
}
function fixture() {
  const calls = [], timers = new Map(), nodes = new Map(); let sequence = 0;
  const document = { querySelector(key) { if (!nodes.has(key)) nodes.set(key, { hidden: true, textContent: '', innerHTML: '', closest: () => ({ scrollIntoView() {} }) }); return nodes.get(key); } };
  const context = vm.createContext({ document, crypto: webcrypto, TextEncoder, AbortController,
    window: { setTimeout(fn, delay) { const id = ++sequence; timers.set(id, { fn, delay }); return id; }, clearTimeout(id) { timers.delete(id); } },
    sqlServerLabUiFetch: async (url, options) => { calls.push({ url, options }); return context.responder(url, options); },
    renderJobs() {}, refreshJobs: async () => {}, showWorkspaceArea() {} });
  vm.runInContext(source.slice(0, source.indexOf('function publicCommandAllowedValues')), context);
  for (const name of ['readUiJobResponse','submitUiCommandBody','canonicalSubmission','nonSecretSubmissionIdentity','submitUiAction','startPublicCommand']) vm.runInContext(actualFunction(name), context);
  const run = code => vm.runInContext(code, context);
  return { context, calls, timers, nodes, run };
}
const token = 'a'.repeat(64), receiptId = 'b'.repeat(32);
const ok = value => ({ ok: true, json: async () => value });
const body = JSON.stringify({ commandName: 'Synthetic', parameterSetName: 'Set', parameters: { Target: 'same', Plan: 'fresh', Consent: true, Transient: 'LOCAL_SYNTHETIC_ONLY' }, confirmed: true });
(async () => {
  const f = fixture();
  f.context.responder = url => url === '/api/command-grants' ? ok({ grant: token, receiptId }) : ok({ id: 'synthetic-job', receiptId });
  f.run("let serializeCount=0; const p={toJSON(){serializeCount++;return {Target:'same',Plan:'fresh',Consent:true,Transient:'LOCAL_SYNTHETIC_ONLY'}}};");
  await f.run("startPublicCommand({Name:'Synthetic'},{Name:'Set'},p,true)");
  check('Actual command submission serializes once for two bounded POSTs', () => { assert.equal(f.run('serializeCount'), 1); assert.deepEqual(f.calls.map(c => c.url), ['/api/command-grants','/api/commands']); });
  check('Issuer and executor receive exact same UTF8 body material', () => assert.equal(f.calls[0].options.body, f.calls[1].options.body));
  check('Grant is separate from body and never sent to issuance', () => { assert.equal(f.calls[0].options.headers['X-SqlServerLab-Action-Grant'], undefined); assert.equal(f.calls[1].options.headers['X-SqlServerLab-Action-Grant'], token); assert.ok(!f.calls[1].options.body.includes(token)); });
  check('Both stages retain bounded abort signals and JSON media type', () => { for (const call of f.calls) { assert.ok(call.options.signal instanceof AbortSignal); assert.equal(call.options.headers['Content-Type'], 'application/json'); } assert.equal([...f.timers.values()].filter(t => t.delay === 15000).length, 0); });
  check('Grant and transient body remain outside rendered status', () => { const rendered = [...f.nodes.values()].map(n => n.textContent + n.innerHTML).join(''); assert.ok(!rendered.includes(token) && !rendered.includes('LOCAL_SYNTHETIC_ONLY')); });
  await f.run("startPublicCommand({Name:'Synthetic'},{Name:'Set'},p,true).then(()=>assertUnexpected(),()=>true)");
  check('Duplicate click produces neither new grant nor replay', () => assert.equal(f.calls.length, 2));

  const loss = fixture(); loss.context.responder = url => url === '/api/command-grants' ? ok({ grant: token, receiptId }) : Promise.reject(new Error('LOCAL_SYNTHETIC_ONLY_RAW_FAILURE'));
  await assert.rejects(loss.run('submitUiCommandBody(' + JSON.stringify(body) + ')'));
  check('Lost acceptance response never reissues, replays or cancels consumed grant', () => assert.deepEqual(loss.calls.map(c => c.url), ['/api/command-grants','/api/commands']));
  await assert.rejects(loss.run('submitUiCommandBody(' + JSON.stringify(body) + ')'), error => error.receiptId === receiptId && error.message === 'UI_COMMAND_UNCONFIRMED');
  check('Unconfirmed error retains only safe receipt identity', () => assert.equal(loss.calls.length, 4));
  const unknownUi = fixture(); unknownUi.context.responder = url => url === '/api/command-grants' ? ok({ grant: token, receiptId }) : Promise.reject(new Error('LOCAL_SYNTHETIC_ONLY_RAW_FAILURE'));
  await assert.rejects(unknownUi.run("startPublicCommand({Name:'Synthetic'},{Name:'Set'},{},true)"));
  check('Actual Unknown card preserves safe receipt for explicit reconciliation', () => { assert.equal(unknownUi.run('optimisticJobs[0].ReceiptId'), receiptId); assert.ok(unknownUi.run('optimisticJobs[0].Lines.join()').includes(receiptId)); assert.ok(!unknownUi.run('optimisticJobs[0].Lines.join()').includes(token)); });

  const issueLoss = fixture(); issueLoss.context.responder = () => Promise.reject(new Error('issue-lost'));
  await assert.rejects(issueLoss.run('submitUiCommandBody(' + JSON.stringify(body) + ')'));
  check('Unknown issue response makes no command request or retry', () => assert.deepEqual(issueLoss.calls.map(c => c.url), ['/api/command-grants']));

  const malformed = fixture(); malformed.context.responder = url => url.endsWith('/cancel') ? ok({ receiptId, state: 'CANCELLED', jobId: null }) : ok({ grant: 'invalid', receiptId });
  await assert.rejects(malformed.run('submitUiCommandBody(' + JSON.stringify(body) + ')'));
  check('Known receipt with malformed grant is revoked before any command POST', () => assert.deepEqual(malformed.calls.map(c => c.url), ['/api/command-grants','/api/command-grants/' + receiptId + '/cancel']));
  check('Revocation sends only its empty schema body', () => assert.equal(malformed.calls[1].options.body, '{}'));

  const invalidGrants = [
    ['null DTO', null], ['array DTO', [{ grant: token, receiptId }]], ['string DTO', token],
    ['array grant', { grant: [token], receiptId }], ['null grant', { grant: null, receiptId }], ['object grant', { grant: {}, receiptId }],
    ['array receipt', { grant: token, receiptId: [receiptId] }], ['null receipt', { grant: token, receiptId: null }], ['object receipt', { grant: token, receiptId: {} }]
  ];
  for (const [name, dto] of invalidGrants) {
    const rejected = fixture(); rejected.context.responder = url => url.endsWith('/cancel') ? ok({ receiptId, state: 'CANCELLED', jobId: null }) : ok(dto);
    await assert.rejects(rejected.run('submitUiCommandBody(' + JSON.stringify(body) + ')'), error => error.message === 'UI_COMMAND_UNCONFIRMED' && (error.receiptId === undefined || (typeof error.receiptId === 'string' && error.receiptId === receiptId)));
    check('Actual helper rejects ' + name + ' before command POST', () => {
      assert.equal(rejected.calls.filter(call => call.url === '/api/commands').length, 0);
      assert.ok(rejected.calls.every(call => call.url === '/api/command-grants' || call.url === '/api/command-grants/' + receiptId + '/cancel'));
      if (typeof dto?.receiptId !== 'string') assert.equal(rejected.calls.length, 1);
    });
  }
  const invalidAccepted = [
    ['null DTO', null], ['array DTO', [{ id: 'synthetic-job', receiptId }]], ['object id', { id: {}, receiptId }],
    ['array id', { id: ['synthetic-job'], receiptId }], ['array receipt', { id: 'synthetic-job', receiptId: [receiptId] }],
    ['object receipt', { id: 'synthetic-job', receiptId: {} }], ['mismatched receipt', { id: 'synthetic-job', receiptId: 'c'.repeat(32) }]
  ];
  for (const [name, dto] of invalidAccepted) {
    const rejected = fixture(); rejected.context.responder = url => url === '/api/command-grants' ? ok({ grant: token, receiptId }) : ok(dto);
    await assert.rejects(rejected.run("startPublicCommand({Name:'Synthetic'},{Name:'Set'},{},true)"));
    check('Actual submission keeps malformed acceptance ' + name + ' unconfirmed without replay', () => {
      assert.deepEqual(rejected.calls.map(call => call.url), ['/api/command-grants','/api/commands']);
      assert.equal(rejected.run('optimisticJobs[0].State'), 'Unknown');
      assert.equal(rejected.run('optimisticJobs[0].ReceiptId'), receiptId);
    });
  }

  const quota = fixture(); quota.context.responder = () => ({ ok: false, status: 429 });
  await assert.rejects(quota.run("startPublicCommand({Name:'Synthetic'},{Name:'Set'},{},true)"), /Commandfreigaben.*ausgeschöpft/);
  check('Session quota has clear user status and no retry or restart action', () => { assert.deepEqual(quota.calls.map(c => c.url), ['/api/command-grants']); assert.equal(quota.run('optimisticJobs[0].State'), 'Rejected'); assert.ok(!quota.run('optimisticJobs[0].Lines.join()').includes('Neustart')); });

  const timeout = fixture(); timeout.context.responder = () => new Promise(() => {});
  const pending = timeout.run('submitUiCommandBody(' + JSON.stringify(body) + ')');
  await new Promise(resolve => setImmediate(resolve));
  const timer = [...timeout.timers.values()].find(t => t.delay === 15000); assert.ok(timer); timer.fn();
  await assert.rejects(pending, /UI_REQUEST_TIMEOUT/);
  check('Issuer timeout aborts transport before command acceptance', () => { assert.equal(timeout.calls.length, 1); assert.equal(timeout.calls[0].options.signal.aborted, true); });
  console.log('RESULT: ' + passed + ' PASS; actual JS, synthetic transport/DOM; provider/state/sql=0');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
