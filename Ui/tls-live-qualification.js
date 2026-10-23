/* Explicit observation at one SQL target. No storage or automatic SQL checks. */
(() => {
  'use strict';
  let generation = 0;
  let pending = false;
  let available = false;
  let timer;
  let controls = [];
  const keys = ['ContractVersion', 'Status', 'RunId', 'InstanceId', 'Provider', 'SqlVersion', 'Patch', 'SqlBuild',
    'Encrypt', 'TrustServerCertificate', 'QualifiedAtUtc', 'ObservedAtUtc', 'ExpiresAtUtc', 'ClientChecks', 'Evidence', 'WireCertificateFingerprint'];
  const profile = { '2019/cu32': '15.0.4430.1', '2022/cu27': '16.0.4295.3', '2025/cu9': '17.0.5005.3' };
  const initial = 'Keine aktuelle Liveprüfung in dieser Ansicht.';
  function invalidate() {
    generation++;
    window.clearTimeout(timer);
    for (const c of controls) c.status.textContent = initial;
  }
  function eligible(target) {
    return /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(target.runId) &&
      /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(target.instanceId) && ['docker', 'podman'].includes(target.provider) &&
      target.settings?.Status === 'CONFIGURED_CONNECTION_STRING' && target.settings.Encrypt === true &&
      target.settings.TrustServerCertificate === false;
  }
  function valid(result, target, started, finished) {
    if (!result || Array.isArray(result) || Object.keys(result).length !== keys.length ||
        keys.some((key) => !Object.prototype.hasOwnProperty.call(result, key))) return false;
    const q = Date.parse(result.QualifiedAtUtc), o = Date.parse(result.ObservedAtUtc), e = Date.parse(result.ExpiresAtUtc);
    return result.ContractVersion === 'SqlServerLab.TlsLiveQualificationResult/0.1' &&
      result.Status === 'QUALIFIED_AT_OBSERVATION' && result.RunId === target.runId &&
      result.InstanceId === target.instanceId && result.Provider === target.provider &&
      typeof result.SqlVersion === 'string' && typeof result.Patch === 'string' &&
      profile[result.SqlVersion + '/' + result.Patch] === result.SqlBuild && result.Encrypt === true &&
      result.TrustServerCertificate === false && result.Evidence === 'FRESH_NATIVE_SQLCLIENT_AND_ODBC_SQLCMD' &&
      result.WireCertificateFingerprint === 'NOT_OBSERVED' && Array.isArray(result.ClientChecks) &&
      result.ClientChecks.length === 2 && result.ClientChecks[0] === 'SYSTEM_DATA_SQLCLIENT' &&
      result.ClientChecks[1] === 'ODBC_SQLCMD' && q >= started && q <= o && o <= finished && e > finished && e - q <= 900000;
  }
  function mount(container, targets) {
    invalidate();
    controls = [];
    const articles = container.querySelectorAll('article');
    targets.forEach((target, index) => {
      if (!eligible(target) || !articles[index]) return;
      // Copy only selected scalar identities; a later workflow render invalidates
      // every pending response, even when its visible endpoint appears unchanged.
      const selected = { runId: target.runId, instanceId: target.instanceId, provider: target.provider };
      const button = document.createElement('button');
      button.type = 'button'; button.className = 'button secondary';
      button.textContent = 'TLS jetzt prüfen'; button.disabled = pending || !available;
      button.dataset.tlsLiveRun = selected.runId; button.dataset.tlsLiveInstance = selected.instanceId;
      const status = document.createElement('span'); status.className = 'tls-live-observation';
      status.setAttribute('role', 'status'); status.textContent = available ? initial : 'Liveprüfung auf diesem Host nicht verfügbar.';
      controls.push({ button, status }); articles[index].append(button, status);
      button.addEventListener('click', async () => {
        if (pending || button.disabled) return;
        invalidate();
        const callGeneration = generation, started = Date.now();
        pending = true; controls.forEach((c) => { c.button.disabled = true; });
        status.textContent = 'TLS wird mit beiden Clients geprüft …';
        try {
          const response = await sqlServerLabUiFetch('/api/tls-live-qualification', { method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({ RunId: selected.runId, InstanceId: selected.instanceId, Provider: selected.provider }) });
          if (!response.ok) throw new Error('TLS_LIVE_HTTP_REJECTED');
          const accepted = await response.json();
          if (accepted.Status !== 'ACCEPTED' || !/^[a-f0-9]{32}$/.test(accepted.Id)) throw new Error('TLS_LIVE_HTTP_REJECTED');
          // GET observes this accepted job only. It never starts a new probe.
          let terminal, polls = 0;
          do {
            if (++polls > 300) throw new Error('TLS_LIVE_HTTP_REJECTED');
            await new Promise((resolve) => window.setTimeout(resolve, 1000));
            const poll = await sqlServerLabUiFetch('/api/tls-live-qualification/' + accepted.Id);
            if (!poll.ok) throw new Error('TLS_LIVE_HTTP_REJECTED');
            terminal = await poll.json();
            if (terminal.Id !== accepted.Id || !['PENDING', 'COMPLETE'].includes(terminal.Status)) throw new Error('TLS_LIVE_HTTP_REJECTED');
          } while (terminal.Status === 'PENDING');
          const result = terminal.Result, finished = Date.now();
          if (callGeneration !== generation) return;
          if (!valid(result, selected, started, finished)) throw new Error('TLS_LIVE_HTTP_REJECTED');
          status.textContent = 'Beide Clients erfolgreich geprüft am ' + new Date(result.ObservedAtUtc).toLocaleString('de-DE') +
            '. Dies ist eine Beobachtung; Änderungen erfordern eine neue Prüfung.';
          timer = window.setTimeout(invalidate, Math.min(Date.parse(result.ExpiresAtUtc) - finished, 900000));
        } catch {
          if (callGeneration === generation) status.textContent = 'TLS-Prüfung nicht bestätigt. Ziel und Voraussetzungen prüfen.';
        } finally {
          pending = false; controls.forEach((c) => { c.button.disabled = !available; });
        }
      });
    });
  }
  document.addEventListener('visibilitychange', () => { if (document.hidden) invalidate(); });
  document.addEventListener('submit', invalidate, true);
  document.addEventListener('click', (event) => { if (event.target?.closest('button')) invalidate(); }, true);
  window.addEventListener('pagehide', invalidate);
  function setAvailable(value) {
    invalidate();
    available = value === true;
    controls.forEach((c) => { c.button.disabled = pending || !available; c.status.textContent = available ? initial : 'Liveprüfung auf diesem Host nicht verfügbar.'; });
  }
  window.sqlServerLabTlsLiveQualification = Object.freeze({ mount, invalidate, setAvailable,
    isPending: () => pending, getGeneration: () => generation });
})();
