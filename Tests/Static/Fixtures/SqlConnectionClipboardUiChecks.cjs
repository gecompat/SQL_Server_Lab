'use strict';
// Actual component with synthetic DOM/Clipboard leaves; no browser or OS proof.
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm');
const assert = require('node:assert/strict');
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/sql-connection-clipboard.js'), 'utf8');
class Element {
  constructor(tag) { this.tag = tag; this.children = []; this.textContent = ''; this.className = ''; this.dataset = {}; this.disabled = false; this.events = {}; }
  get isConnected() { return this.parent ? this.parent.isConnected : this.tag === 'root'; }
  append(...nodes) { for (const node of nodes) { node.parent = this; this.children.push(node); } }
  remove() { if (this.parent) { this.parent.children = this.parent.children.filter((node) => node !== this); this.parent = null; } }
  contains(node) { return node === this || this.children.some((child) => child.contains(node)); }
  querySelectorAll(selector) {
    const found = [];
    for (const child of this.children) {
      if ((selector === 'code' && child.tag === 'code') || (selector === '.connection-string' && child.className === 'connection-string')) found.push(child);
      found.push(...child.querySelectorAll(selector));
    }
    return found;
  }
  setAttribute(name, value) { this[name] = value; }
  addEventListener(name, callback) { this.events[name] = callback; }
  click() { return this.events.click(); }
}
function setup() {
  const writes = [];
  const clipboard = { writeText: async (value) => { writes.push(value); } };
  const window = { isSecureContext: true };
  const navigator = { clipboard };
  vm.runInNewContext(source, { window, navigator, document: { createElement: (tag) => new Element(tag) } });
  const root = new Element('root');
  return { root, writes, window, navigator, api: window.sqlServerLabConnectionClipboard };
}
function row(root, text) {
  const node = new Element('div'); node.className = 'connection-string';
  const code = new Element('code'); code.textContent = text; node.append(code); root.append(node);
  return { node, code, button: () => node.children.find((child) => child.tag === 'button'), status: () => node.children.find((child) => child.tag === 'span') };
}
function deferred() { let resolve, reject; const promise = new Promise((a, b) => { resolve = a; reject = b; }); return { promise, resolve, reject }; }
let passed = 0;
async function check(name, body) { await body(); passed++; console.log('PASS ' + name); }
(async () => {
  await check('Mount never copies automatically or duplicates connection text in attributes', () => {
    const s = setup(), r = row(s.root, 'Server=one;Password=***;Encrypt=True;TrustServerCertificate=False;');
    s.api.mount(s.root); assert.equal(s.writes.length, 0);
    assert.equal(r.button().type, 'button'); assert.equal(r.status().role, 'status');
    assert.deepEqual(r.button().dataset, { sqlConnectionCopy: 'true' });
    assert.equal(r.code.textContent, 'Server=one;Password=***;Encrypt=True;TrustServerCertificate=False;');
  });
  for (const trust of ['True', 'False']) await check('Copy preserves exact displayed TLS text and password placeholder: ' + trust, async () => {
    const s = setup(), text = ' Server=one;Database="a;b";User Id=sa;Password=***;Encrypt=True;TrustServerCertificate=' + trust + '; ';
    const r = row(s.root, text); s.api.mount(s.root); await r.button().click();
    assert.deepEqual(s.writes, [text]); assert.equal(r.status().textContent, 'Connection String kopiert.');
    assert.equal(r.button().disabled, false);
  });
  await check('Selected instance never borrows a neighbouring connection string', async () => {
    const s = setup(), a = row(s.root, 'Server=one;Encrypt=True;TrustServerCertificate=True;');
    const b = row(s.root, 'Server=two;Encrypt=True;TrustServerCertificate=False;');
    s.api.mount(s.root); await b.button().click();
    assert.deepEqual(s.writes, [b.code.textContent]); assert.equal(a.status().textContent, '');
  });
  await check('Literal characters are copied as text without parsing or re-encoding', async () => {
    const s = setup(), text = 'Server=one;Password="<script>&\"\\;ß";Encrypt=True;TrustServerCertificate=False;';
    const r = row(s.root, text); s.api.mount(s.root); await r.button().click(); assert.deepEqual(s.writes, [text]);
  });
  await check('Missing, empty, nonstring, oversized and ambiguous code has no copy action', () => {
    const s = setup();
    for (const value of ['', ' ', 42, null, 'x'.repeat(65537)]) row(s.root, value);
    const ambiguous = row(s.root, 'one'); ambiguous.node.append(new Element('code'));
    s.api.mount(s.root); assert.equal(s.root.querySelectorAll('.connection-string').flatMap((r) => r.children).filter((n) => n.tag === 'button').length, 0);
  });
  await check('The documented 65536 character bound remains usable', async () => {
    const s = setup(), r = row(s.root, 'x'.repeat(65536)); s.api.mount(s.root); await r.button().click(); assert.deepEqual(s.writes, [r.code.textContent]);
  });
  await check('Repeated mount creates exactly one control per existing row', () => {
    const s = setup(), r = row(s.root, 'Server=one;'); s.api.mount(s.root); s.api.mount(s.root);
    assert.equal(r.node.children.filter((node) => node.tag === 'button').length, 1);
    assert.equal(r.node.children.filter((node) => node.tag === 'span').length, 1);
  });
  for (const kind of ['missing', 'insecure']) await check('Unavailable Clipboard fails closed: ' + kind, async () => {
    const s = setup(), r = row(s.root, 'PRIVATE_CONNECTION_CANARY');
    if (kind === 'missing') s.navigator.clipboard = undefined; else s.window.isSecureContext = false;
    s.api.mount(s.root); await r.button().click(); assert.equal(s.writes.length, 0);
    assert.match(r.status().textContent, /^Zwischenablage nicht verfügbar\./); assert.doesNotMatch(r.status().textContent, /PRIVATE/);
  });
  await check('Permission rejection is a fixed message without raw exception or connection value', async () => {
    const s = setup(), r = row(s.root, 'PRIVATE_CONNECTION_CANARY');
    s.navigator.clipboard.writeText = async () => { throw new Error('PRIVATE_EXCEPTION_CANARY'); };
    s.api.mount(s.root); await r.button().click(); assert.match(r.status().textContent, /^Kopieren nicht möglich\./);
    assert.doesNotMatch(r.status().textContent, /PRIVATE/); assert.equal(r.button().disabled, false);
  });
  await check('A throwing Clipboard property is contained without raw diagnostics', async () => {
    const s = setup(), r = row(s.root, 'PRIVATE_CONNECTION_CANARY');
    Object.defineProperty(s.navigator, 'clipboard', { get() { throw new Error('PRIVATE_GETTER_CANARY'); } });
    s.api.mount(s.root); await r.button().click(); assert.match(r.status().textContent, /^Kopieren nicht möglich\./); assert.doesNotMatch(r.status().textContent, /PRIVATE/);
  });
  await check('One pending write spans targets and refresh; stale success cannot label the new target', async () => {
    const s = setup(), d = deferred(), a = row(s.root, 'Server=one;');
    s.navigator.clipboard.writeText = (text) => { s.writes.push(text); return d.promise; };
    s.api.mount(s.root); const pending = a.button().click(); await a.button().click();
    a.node.remove(); const b = row(s.root, 'Server=two;'); s.api.mount(s.root);
    assert.equal(b.button().disabled, true); await b.button().click(); assert.deepEqual(s.writes, ['Server=one;']);
    d.resolve(); await pending; assert.equal(b.button().disabled, false); assert.equal(b.status().textContent, '');
    assert.notEqual(a.status().textContent, 'Connection String kopiert.');
  });
  await check('Another mounted provider cannot reset the pending latch', async () => {
    const s = setup(), d = deferred(), a = row(s.root, 'Server=container;');
    s.navigator.clipboard.writeText = (text) => { s.writes.push(text); return d.promise; }; s.api.mount(s.root);
    const pending = a.button().click(), other = new Element('root'), b = row(other, 'Server=vm;'); s.api.mount(other);
    await b.button().click(); assert.deepEqual(s.writes, ['Server=container;']);
    d.resolve(); await pending; assert.equal(b.status().textContent, ''); assert.equal(b.button().disabled, false);
  });
  await check('Changed text during a write cannot receive an obsolete success', async () => {
    const s = setup(), d = deferred(), r = row(s.root, 'Server=old;');
    s.navigator.clipboard.writeText = () => d.promise; s.api.mount(s.root); const pending = r.button().click();
    r.code.textContent = 'Server=new;'; d.resolve(); await pending; assert.equal(r.status().textContent, '');
  });
  await check('Detached origin and late rejection cannot alter a refreshed target', async () => {
    const s = setup(), d = deferred(), a = row(s.root, 'Server=old;'); s.navigator.clipboard.writeText = () => d.promise;
    s.api.mount(s.root); const pending = a.button().click(); a.node.remove(); const b = row(s.root, 'Server=new;'); s.api.mount(s.root);
    d.reject(new Error('PRIVATE_LATE_CANARY')); await pending;
    assert.equal(b.status().textContent, ''); assert.equal(b.button().disabled, false);
  });
  console.log('SQL connection Clipboard UI: ' + passed + ' PASS / 0 FAIL');
})().catch((error) => { console.error(error); process.exitCode = 1; });
