/* Explicit False creation; opaque references are scoped to this server start. */
(() => {
  'use strict';
  const $ = (id) => document.getElementById(id);
  const dialog = $('tls-auth-create-dialog'), form = $('tls-auth-create-form');
  const status = $('tls-auth-create-status'), list = $('tls-created-targets');
  let available = false, initialized = false, busy = false, uncertain = false, generation = 0;
  let expiry;
  const targets = new Map();
  const viewKeys = ['Ref', 'Status', 'Provider', 'Version', 'LabName', 'RunId', 'RunState', 'Port', 'Encrypt', 'TrustServerCertificate', 'ActionStatus', 'LiveResult'];
  const liveKeys = ['ContractVersion', 'Status', 'RunId', 'InstanceId', 'Provider', 'SqlVersion', 'Patch', 'SqlBuild', 'Encrypt', 'TrustServerCertificate',
    'QualifiedAtUtc', 'ObservedAtUtc', 'ExpiresAtUtc', 'ClientChecks', 'Evidence', 'WireCertificateFingerprint'];
  const ref = (v) => typeof v === 'string' && /^[a-f0-9]{32}$/.test(v);
  const requestId = () => crypto.randomUUID().replaceAll('-', '');
  function valid(v) {
    return v && !Array.isArray(v) && Object.keys(v).length === viewKeys.length && viewKeys.every((key) => Object.hasOwn(v, key)) && ref(v.Ref) &&
      ['ACCEPTED', 'PENDING', 'COMPLETE', 'UNCONFIRMED', 'REJECTED'].includes(v.Status) &&
      ['docker', 'podman'].includes(v.Provider) && v.Version === '2025-CU9' && typeof v.LabName === 'string' &&
      typeof v.RunId === 'string' && ['UNKNOWN', 'RUNNING', 'STOPPED', 'REMOVED'].includes(v.RunState) &&
      Number.isInteger(v.Port) && v.Port >= 0 && v.Port <= 65535 && v.Encrypt === true && v.TrustServerCertificate === false &&
      ['NONE', 'PENDING', 'COMPLETE', 'UNCONFIRMED'].includes(v.ActionStatus);
  }
  function validLive(r, view, started) {
    if (!r || Array.isArray(r) || Object.keys(r).length !== liveKeys.length || !liveKeys.every((key) => Object.hasOwn(r, key))) return false;
    const q = Date.parse(r.QualifiedAtUtc), o = Date.parse(r.ObservedAtUtc), e = Date.parse(r.ExpiresAtUtc);
    return r.ContractVersion === 'SqlServerLab.TlsLiveQualificationResult/0.1' && r.Status === 'QUALIFIED_AT_OBSERVATION' &&
      r.RunId === view.RunId && r.InstanceId === 'primary' && r.Provider === view.Provider && r.SqlVersion === '2025' && r.Patch === 'cu9' &&
      r.SqlBuild === '17.0.5005.3' && r.Encrypt === true && r.TrustServerCertificate === false &&
      r.Evidence === 'FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD' && r.WireCertificateFingerprint === 'NOT_OBSERVED' &&
      Array.isArray(r.ClientChecks) && r.ClientChecks.length === 2 && r.ClientChecks[0] === 'SYSTEM_DATA_SQLCLIENT' && r.ClientChecks[1] === 'ODBC_SQLCMD' &&
      Number.isFinite(q) && Number.isFinite(o) && Number.isFinite(e) && q >= started && q <= o && o <= Date.now() && e > Date.now() && e - q <= 900000;
  }
  function invalidate() {
    generation++; window.clearTimeout(expiry);
    for (const value of targets.values()) value.LiveResult = null;
    render();
  }
  function render() {
    $('tls-created-section').hidden = initialized && !uncertain && targets.size === 0;
    list.replaceChildren();
    for (const target of targets.values()) {
      const card = document.createElement('article'); card.dataset.tlsCreatedRef = target.Ref;
      const title = document.createElement('h3'); title.textContent = target.LabName + ' · ' + target.Provider;
      const text = document.createElement('p');
      text.textContent = 'Referenz: ' + target.Ref + ' · ' + target.Status + ' · ' + target.RunState + ' · Encrypt=True;TrustServerCertificate=False' +
        (target.Port ? ' · 127.0.0.1:' + target.Port : '') + ' · Aktion: ' + target.ActionStatus;
      const live = document.createElement('p'); live.setAttribute('role', 'status');
      const result = target.LiveResult;
      live.textContent = result && Date.parse(result.ExpiresAtUtc) > Date.now() ?
        'Beide Clients erfolgreich geprüft am ' + new Date(result.ObservedAtUtc).toLocaleString('de-DE') + '. Beobachtung, kein dauerhafter Status.' :
        'Keine aktuelle Liveprüfung in dieser Ansicht.';
      card.append(title, text, live);
      for (const [action, label] of [['Live', 'TLS jetzt prüfen'], ['Stop', 'Stoppen'], ['Start', 'Starten'], ['Rebind', 'Nach Neustart wiederbinden'], ['Remove', 'Dieses Lab entfernen']]) {
        const button = document.createElement('button'); button.type = 'button'; button.className = 'button secondary';
        button.textContent = label; button.dataset.tlsCreatedAction = action;
        button.disabled = busy || !available || target.Status !== 'COMPLETE' || target.RunState === 'REMOVED';
        button.addEventListener('click', () => act(target.Ref, action)); card.append(button);
      }
      list.append(card);
    }
    $('tls-auth-create-open').disabled = !available || !initialized || busy || uncertain;
    $('tls-auth-create-submit').disabled = !available || !initialized || busy || uncertain;
    $('tls-created-refresh').disabled = busy;
  }
  async function json(path, body) {
    const controller = new AbortController(), timeout = window.setTimeout(() => controller.abort(), 30000);
    try {
      const options = body === undefined ? {} : { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body) };
      options.signal = controller.signal;
      const response = await sqlServerLabUiFetch(path, options);
      if (!response.ok) throw new Error('TLS_CREATION_UNCONFIRMED');
      return await response.json();
    } finally { window.clearTimeout(timeout); }
  }
  async function poll(id) {
    for (let i = 0; i < 900; i++) {
      await new Promise((resolve) => window.setTimeout(resolve, 2000));
      const view = await json('/api/tls-created-targets/' + id);
      if (!valid(view) || view.Ref !== id) throw new Error('TLS_CREATION_UNCONFIRMED');
      targets.set(id, { ...view, LiveResult: null }); render();
      if (view.Status !== 'PENDING' && view.ActionStatus !== 'PENDING') return view;
    }
    throw new Error('TLS_CREATION_UNCONFIRMED');
  }
  async function act(id, action) {
    if (busy || !available) return;
    if (action === 'Remove' && !window.confirm('Genau dieses authentifizierte Lab entfernen? CA und Trust bleiben erhalten.')) return;
    invalidate(); const current = generation, started = Date.now(); busy = true; render();
    try {
      const accepted = await json('/api/tls-created-targets/action', { Ref: id, Action: action, RequestId: requestId() });
      if (accepted.Status !== 'ACCEPTED' || accepted.Ref !== id) throw new Error('TLS_CREATION_UNCONFIRMED');
      const view = await poll(id);
      if (current !== generation) { view.LiveResult = null; return; }
      if (action === 'Live' && view.ActionStatus === 'COMPLETE') {
        const r = view.LiveResult;
        if (!validLive(r, view, started)) throw new Error('TLS_CREATION_UNCONFIRMED');
        targets.get(id).LiveResult = r;
        expiry = window.setTimeout(invalidate, Math.min(900000, Date.parse(r.ExpiresAtUtc) - Date.now()));
      }
    } catch { targets.get(id).LiveResult = null; targets.get(id).ActionStatus = 'UNCONFIRMED'; }
    finally { busy = false; render(); }
  }
  $('tls-auth-create-open').addEventListener('click', () => {
    if (busy || !available || !initialized || uncertain) return;
    $('container-dialog').close(); dialog.showModal();
  });
  form.addEventListener('submit', async (event) => {
    if (event.submitter?.value === 'cancel') return;
    event.preventDefault();
    if (busy || !available || !initialized || uncertain) return;
    const password = $('tls-auth-password').value;
    if (password !== $('tls-auth-password-repeat').value) { status.textContent = 'Die beiden SA-Passwörter stimmen nicht überein.'; return; }
    const body = { RequestId: requestId(), Provider: $('tls-auth-provider').value, Version: $('tls-auth-version').value,
      Profile: $('tls-auth-profile').value, LabName: $('tls-auth-name').value,
      TlsCandidateId: $('tls-auth-candidate').value, TlsControllerId: $('tls-auth-controller').value,
      TlsLocationId: $('tls-auth-location').value, SaPassword: password };
    busy = true; invalidate(); status.textContent = 'Erstellung angefordert. Nicht erneut senden.';
    try {
      const accepted = await json('/api/tls-creation', body);
      if (accepted.Status !== 'ACCEPTED' || !ref(accepted.Ref)) throw new Error('TLS_CREATION_UNCONFIRMED');
      status.textContent = 'Erstellung angenommen. Der eigene Auftrag wird beobachtet.';
      const view = await poll(accepted.Ref);
      uncertain = view.Status === 'UNCONFIRMED';
      status.textContent = view.Status === 'COMPLETE' ? 'Eigenes authentifiziertes Lab erstellt. Zielaktionen stehen in der Sitzungsansicht bereit.' :
        'Erstellung nicht bestätigt. Privaten Allokationsbeleg prüfen; keine automatische Wiederholung.';
      if (view.Status === 'COMPLETE') dialog.close();
    } catch { uncertain = true; status.textContent = 'Annahme oder Ergebnis unbestätigt. Sitzungsziele erneut lesen; nicht erneut erstellen.'; }
    finally { body.SaPassword = ''; $('tls-auth-password').value = ''; $('tls-auth-password-repeat').value = ''; busy = false; render(); }
  });
  async function readTargets() {
    if (busy) return; invalidate();
    try {
      const view = await json('/api/tls-created-targets');
      if (!view || typeof view.CreationBlocked !== 'boolean' || !Array.isArray(view.Targets) || view.Targets.length > 64 || view.Targets.some((v) => !valid(v))) throw new Error('INVALID');
      uncertain = uncertain || view.CreationBlocked; initialized = true;
      targets.clear(); for (const value of view.Targets) { value.LiveResult = null; targets.set(value.Ref, value); }
      $('tls-created-status').textContent = uncertain ? 'Frühere Erstellung unbestätigt. Privaten Allokationsbeleg prüfen; keine weitere Erstellung.' : 'Sitzungsziele gelesen. Keine Verbindung ausgeführt.';
      render();
    } catch { initialized = false; $('tls-created-status').textContent = 'Sitzungsziele nicht bestätigt. Erstellung bleibt gesperrt.'; render(); }
  }
  $('tls-created-refresh').addEventListener('click', readTargets);
  document.addEventListener('visibilitychange', () => { if (document.hidden) invalidate(); });
  window.addEventListener('pagehide', invalidate);
  window.sqlServerLabTlsCreation = Object.freeze({ setAvailable: (value) => { available = value === true; render(); }, invalidate });
  render();
  readTargets();
})();
