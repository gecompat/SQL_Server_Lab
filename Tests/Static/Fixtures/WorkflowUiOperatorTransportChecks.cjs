'use strict';
const fs = require('fs'), path = require('path'), vm = require('vm'), assert = require('assert/strict');
const root = path.resolve(__dirname, '../../..');
const source = fs.readFileSync(path.join(root, 'Ui/operator-transport.js'), 'utf8');
let count = 0;
const check = (value, label) => { assert.ok(value, label); count++; console.log('PASS ' + label); };
function setup(fragment = '#sql-lab-operator=' + 'a'.repeat(64), origin = 'http://127.0.0.1:18484', failScrub = false) {
  const calls = [], history = [];
  const context = { URL, Headers, Error, location: { origin, hash: fragment, href: origin + '/' + fragment, pathname: '/', search: '' },
    history: { replaceState(...args) { if (failScrub) throw Error('synthetic'); history.push(args); context.location.hash = ''; } },
    fetch(url, options) { calls.push({ url, options }); return Promise.resolve({ ok: true, synthetic: true }); } };
  for (const name of ['localStorage', 'sessionStorage', 'document', 'console']) Object.defineProperty(context, name, { get() { throw Error('FORBIDDEN_SECRET_DESTINATION'); } });
  const nativeFetch = context.fetch;
  vm.runInNewContext(source, context);
  return { context, calls, history, nativeFetch };
}
(async () => {
  let f = setup();
  check(f.history.length === 1 && f.history[0][2] === '/' && f.context.location.hash === '', 'Fragment entfernt vor jedem Komponentenfetch');
  check(f.context.fetch === f.nativeFetch && typeof f.context.sqlServerLabUiFetch === 'function', 'Benannter Transport ohne globales Fetch-Monkeypatch');
  const signal = new AbortController().signal, body = JSON.stringify({ action: 'synthetic', parameters: { secret: 'SYNTHETIC_ONLY' } });
  const headers = new Headers({ 'Content-Type': 'application/json', 'X-Synthetic': 'retained' });
  const options = { method: 'POST', headers, signal, body, cache: 'no-store', redirect: 'follow' };
  await f.context.sqlServerLabUiFetch('/api/actions', options);
  const call = f.calls[0];
  check(call.url === 'http://127.0.0.1:18484/api/actions' && call.options.headers.get('X-SqlServerLab-Operator') === 'a'.repeat(64), 'Capability nur am eigenen APIrequest');
  check(call.options.body === body && call.options.signal === signal && call.options.method === 'POST' && call.options.cache === 'no-store' && call.options.redirect === 'error', 'Body Signal Methode Cache erhalten; Redirect wird blockiert');
  check(call.options.headers.get('Content-Type') === 'application/json' && call.options.headers.get('X-Synthetic') === 'retained' && !headers.has('X-SqlServerLab-Operator') && options.redirect === 'follow', 'Header werden ohne Mutation des Callers ergänzt');
  await f.context.sqlServerLabUiFetch('api/jobs');
  await f.context.sqlServerLabUiFetch('http://127.0.0.1:18484/api/config?synthetic=1');
  check(f.calls.length === 3 && f.calls[1].options.redirect === 'error', 'Relative und absolute eigene GETs authentifiziert');
  for (const target of ['https://synthetic.invalid/api/actions', '//synthetic.invalid/api/actions', 'http://localhost:18484/api/actions', 'http://127.0.0.1:18485/api/actions', 'https://127.0.0.1:18484/api/actions', '/index.html', '/api/../index.html', '/api/actions#synthetic', 'http://user@127.0.0.1:18484/api/actions']) {
    await assert.rejects(f.context.sqlServerLabUiFetch(target), /UI_OPERATOR_TARGET_INVALID/);
    check(f.calls.length === 3, 'Fremdes oder ungeeignetes Ziel erzeugt keinen Transport');
  }
  await assert.rejects(f.context.sqlServerLabUiFetch('/api/jobs', { headers: { 'x-sqlserverlab-operator': 'synthetic' } }), /UI_OPERATOR_HEADER_INVALID/);
  check(f.calls.length === 3, 'Caller kann Credentialheader nicht überschreiben');
  await assert.rejects(f.context.sqlServerLabUiFetch(new URL('http://127.0.0.1:18484/api/jobs')), /UI_OPERATOR_REQUIRED/);
  check(f.calls.length === 3, 'Nicht unterstützte Requestobjekte bleiben geschlossen');
  for (const fragment of ['', '#sql-lab-operator=' + 'a'.repeat(63), '#sql-lab-operator=' + 'A'.repeat(64), '#sql-lab-operator=' + 'a'.repeat(64) + '&extra=1', '#synthetic']) {
    f = setup(fragment); await assert.rejects(f.context.sqlServerLabUiFetch('/api/jobs'), /UI_OPERATOR_REQUIRED/);
    check(f.calls.length === 0 && f.history.length === 1, 'Fehlendes oder ungültiges Fragment wird entfernt und nicht versandt');
  }
  for (const origin of ['https://synthetic.invalid', 'http://localhost:18484', 'http://127.0.0.1:80']) {
    f = setup(undefined, origin); await assert.rejects(f.context.sqlServerLabUiFetch('/api/jobs'), /UI_OPERATOR_REQUIRED/);
    check(f.calls.length === 0, 'Nicht unterstützte Bootstrap-Origin bleibt gesperrt');
  }
  f = setup(undefined, undefined, true); await assert.rejects(f.context.sqlServerLabUiFetch('/api/jobs'), /UI_OPERATOR_REQUIRED/);
  check(f.calls.length === 0, 'Fehlgeschlagener History-Scrub erteilt keine Capability');
  f = setup(''); await assert.rejects(f.context.sqlServerLabUiFetch('/api/jobs'), /UI_OPERATOR_REQUIRED/);
  check(f.calls.length === 0, 'Reload ohne erneuten privaten Startlink bleibt gesperrt');
  const html = fs.readFileSync(path.join(root, 'Ui/index.html'), 'utf8');
  const assets = Array.from(html.matchAll(/<script src="([a-z.-]+)"/g), m => m[1]);
  check(assets[0] === 'operator-transport.js', 'Capabilitybootstrap steht vor dem ersten aktiven Komponentenasset');
  for (const asset of assets.slice(1)) {
    const text = fs.readFileSync(path.join(root, 'Ui', asset), 'utf8');
    check(!/\bfetch\s*\(/.test(text) && /sqlServerLabUiFetch\s*\(/.test(text), 'Aktives Produktasset verwendet nur den benannten Transport: ' + asset);
  }
  console.log(`Ergebnis: ${count} PASS, 0 FAIL`);
})().catch(error => { console.error(error.message); process.exitCode = 1; });
