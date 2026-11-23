'use strict';
(() => {
  const element = id => document.getElementById('run-state-upgrade-plan-' + id);
  const dialog = element('dialog');
  const target = element('target');
  const status = element('status');
  const read = element('read');
  const result = element('result');
  const uuid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  let runIds = new Set();
  let revision = 0;
  function clear() {
    revision++;
    result.hidden = true;
    read.disabled = !runIds.has(target.value);
    status.textContent = runIds.size ? '' : 'Kein registrierter Run gefunden.';
  }
  element('open').addEventListener('click', () => {
    runIds = new Set();
    target.replaceChildren(new Option('Lab auswählen', ''));
    for (const lab of [...(workflow?.ActiveLabs || []), ...(workflow?.HyperVLabs || [])]) {
      if (typeof lab.RunId !== 'string' || !uuid.test(lab.RunId)) continue;
      const id = lab.RunId.toLowerCase();
      if (runIds.has(id)) continue;
      runIds.add(id);
      target.add(new Option(lab.Name || id, id));
    }
    clear();
    dialog.showModal();
  });
  element('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', clear);
  target.addEventListener('change', clear);
  element('form').addEventListener('submit', async event => {
    event.preventDefault();
    if (read.disabled) return;
    const runId = target.value;
    if (!runIds.has(runId)) return;
    clear();
    const current = revision;
    read.disabled = true;
    status.textContent = 'State-Format wird geprüft.';
    try {
      const response = await sqlServerLabUiFetch('/api/run-state-upgrade-plan?runId=' + encodeURIComponent(runId), { cache: 'no-store' });
      if (!response.ok) throw new Error('RUN_STATE_UPGRADE_GUIDANCE_UNAVAILABLE');
      const view = await response.json();
      const messages = { BLOCKED: 'Upgrade blockiert.', READY: 'Ein synthetisches Upgrade ist möglich.', NO_ACTION: 'Kein Upgrade erforderlich.' };
      if (view?.RunId !== runId || !Object.hasOwn(messages, view.Status) ||
          !['SqlServerLab.RunState/1.0', 'UNSUPPORTED', 'UNVERSIONED_LEGACY'].includes(view.Source) ||
          view.Target !== 'SqlServerLab.RunState/1.0' || (view.Status === 'READY' && view.SyntheticFixture !== true) ||
          !Array.isArray(view.Changes) || !Array.isArray(view.Blockers)) throw new Error('RUN_STATE_UPGRADE_GUIDANCE_INVALID');
      if (revision !== current || !dialog.open) return;
      element('version').textContent = view.Source + ' → ' + view.Target;
      element('changes').textContent = view.Changes.join(', ') || 'keine';
      element('blockers').textContent = view.Blockers.join(', ') || 'keine';
      status.textContent = messages[view.Status];
      result.hidden = false;
    } catch {
      if (revision === current && dialog.open) status.textContent = 'Das State-Format konnte nicht geprüft werden.';
    } finally {
      if (revision === current && dialog.open) read.disabled = false;
    }
  });
})();
