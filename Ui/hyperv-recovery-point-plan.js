'use strict';
(() => {
  const element = id => document.getElementById('hyperv-recovery-points-' + id);
  const dialog = element('dialog');
  const target = element('target');
  const read = element('read');
  const status = element('status');
  const result = element('result');
  const guid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  let labs = new Map();
  let revision = 0;
  function resetResult() {
    revision++;
    result.replaceChildren();
    result.hidden = true;
    read.disabled = !labs.has(target.value);
    status.textContent = labs.size ? '' : 'Kein registriertes Hyper-V-Lab gefunden.';
  }
  element('open').addEventListener('click', () => {
    labs = new Map();
    target.replaceChildren(new Option('Lab auswählen', ''));
    for (const lab of workflow?.HyperVLabs || []) {
      if (typeof lab.RunId !== 'string' || !guid.test(lab.RunId) ||
          typeof lab.InstanceId !== 'string' || !/^[A-Za-z][A-Za-z0-9_-]{0,127}$/.test(lab.InstanceId)) continue;
      const runId = lab.RunId.toLowerCase();
      if (labs.has(runId)) continue;
      labs.set(runId, lab.InstanceId);
      target.add(new Option(lab.Name || runId, runId));
    }
    resetResult();
    dialog.showModal();
  });
  element('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', resetResult);
  target.addEventListener('change', resetResult);
  element('form').addEventListener('submit', async event => {
    event.preventDefault();
    if (read.disabled) return;
    const runId = target.value;
    const instanceId = labs.get(runId);
    if (!instanceId) return;
    resetResult();
    const current = revision;
    read.disabled = true;
    status.textContent = 'Checkpoints werden gelesen.';
    try {
      const query = new URLSearchParams({ runId, instanceId });
      const response = await sqlServerLabUiFetch('/api/hyperv-recovery-point-plan?' + query, { cache: 'no-store' });
      if (!response.ok) throw new Error('HYPERV_RECOVERY_POINT_READ_FAILED');
      const plan = await response.json();
      if (plan?.ContractVersion !== 'SqlServerLab.HyperVRecoveryPointPlan/1.0' ||
          plan.RunId !== runId || plan.InstanceId !== instanceId || plan.Provider !== 'hyperv' ||
          plan.ExecutionImplemented !== false || !['READY', 'NO_ACTION', 'BLOCKED'].includes(plan.Status) ||
          !Array.isArray(plan.RecoveryPoints) || !Array.isArray(plan.Blockers)) throw new Error('HYPERV_RECOVERY_POINT_PLAN_INVALID');
      if (revision !== current || !dialog.open) return;
      if (plan.Status === 'BLOCKED') {
        status.textContent = 'Inventar nicht verfügbar. ' + plan.Blockers.join(', ');
        return;
      }
      status.textContent = plan.Status === 'READY' ? 'Checkpoints gelesen.' : 'Für dieses Lab sind keine Checkpoints vorhanden.';
      for (const point of plan.RecoveryPoints) {
        const row = document.createElement('li');
        row.textContent = [point.CreatedAt, point.Kind, point.RecoveryPointId].join(' · ');
        result.append(row);
      }
      result.hidden = !plan.RecoveryPoints.length;
    } catch {
      if (revision === current && dialog.open) status.textContent = 'Die Wiederherstellungspunkte konnten nicht gelesen werden.';
    } finally {
      if (revision === current && dialog.open) read.disabled = false;
    }
  });
})();
