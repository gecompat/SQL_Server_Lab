'use strict';
(() => {
  const element = id => document.getElementById('diagnostic-bundle-' + id);
  const dialog = element('dialog');
  const target = element('target');
  const status = element('status');
  const read = element('read');
  const result = element('result');
  const runPattern = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  let targets = new Map();
  let revision = 0;
  function clear() {
    revision++;
    result.hidden = true;
    read.disabled = !targets.has(target.value);
    status.textContent = targets.size ? '' : 'Keine registrierte Lab-Instanz gefunden.';
  }
  function addTarget(lab, instanceId, provider) {
    if (typeof lab.RunId !== 'string' || !runPattern.test(lab.RunId) ||
        typeof instanceId !== 'string' || !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(instanceId) ||
        !['docker', 'podman', 'hyperv'].includes(provider)) return;
    const runId = lab.RunId.toLowerCase();
    const key = [runId, provider, instanceId].join('/');
    if (targets.has(key)) return;
    targets.set(key, { runId, instanceId, provider });
    target.add(new Option([lab.Name || runId, instanceId, provider].join(' · '), key));
  }
  element('open').addEventListener('click', () => {
    targets = new Map();
    target.replaceChildren(new Option('Lab-Instanz auswählen', ''));
    for (const lab of workflow?.ActiveLabs || []) for (const instance of lab.Instances || []) addTarget(lab, instance.Id, instance.Provider);
    for (const lab of workflow?.HyperVLabs || []) addTarget(lab, lab.InstanceId, 'hyperv');
    clear();
    dialog.showModal();
  });
  element('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', clear);
  target.addEventListener('change', clear);
  element('form').addEventListener('submit', async event => {
    event.preventDefault();
    if (read.disabled) return;
    const selection = targets.get(target.value);
    if (!selection) return;
    clear();
    const current = revision;
    read.disabled = true;
    status.textContent = 'Gespeicherter Befund wird gelesen.';
    try {
      const response = await sqlServerLabUiFetch('/api/diagnostic-bundle?' + new URLSearchParams(selection), { cache: 'no-store' });
      if (!response.ok) throw new Error('DIAGNOSTIC_BUNDLE_UNAVAILABLE');
      const bundle = await response.json();
      if (bundle?.ContractVersion !== 'SqlServerLab.DiagnosticBundle/1.0' || bundle.Capabilities?.MutationAllowed !== false ||
          bundle.Capabilities.SqlProbe !== 'NOT_EXECUTED' || bundle.Readiness?.EvidenceStatus !== 'NOT_EXECUTED' ||
          !['OBSERVED', 'BLOCKED', 'UNAVAILABLE'].includes(bundle.Status)) throw new Error('DIAGNOSTIC_BUNDLE_INVALID');
      if (revision !== current || !dialog.open) return;
      if (bundle.Status !== 'OBSERVED') {
        const reason = bundle.Binding?.Reason;
        status.textContent = 'Kein gebundener Diagnosebefund.' + (/^DIAGNOSTIC_[A-Z_]{1,64}$/.test(reason) ? ' ' + reason : '');
        return;
      }
      if (bundle.Binding?.Provider !== selection.provider || typeof bundle.History?.RunState !== 'string' ||
          typeof bundle.History.RecoveryStatus !== 'string' || !Number.isSafeInteger(bundle.History.ErrorCount) ||
          typeof bundle.Cleanup?.Status !== 'string') throw new Error('DIAGNOSTIC_BUNDLE_INVALID');
      element('state').textContent = bundle.History.RunState;
      element('recovery').textContent = bundle.History.RecoveryStatus;
      element('errors').textContent = String(bundle.History.ErrorCount);
      element('cleanup').textContent = bundle.Cleanup.Status;
      result.hidden = false;
      status.textContent = 'Gespeicherter Befund gelesen.';
    } catch {
      if (revision === current && dialog.open) status.textContent = 'Der Diagnosebefund konnte nicht gelesen werden.';
    } finally {
      if (revision === current && dialog.open) read.disabled = false;
    }
  });
})();
