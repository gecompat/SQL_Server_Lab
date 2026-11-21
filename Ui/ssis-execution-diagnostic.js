'use strict';
(() => {
  const element = id => document.getElementById('ssis-execution-' + id);
  const dialog = element('dialog');
  const form = element('form');
  const read = element('read');
  const status = element('status');
  let revision = 0;
  element('open').addEventListener('click', () => {
    form.reset();
    status.textContent = '';
    read.disabled = false;
    ++revision;
    dialog.showModal();
  });
  element('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => { ++revision; form.reset(); status.textContent = ''; });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (read.disabled) return;
    const generation = ++revision;
    const args = Object.fromEntries(['RunId', 'InstanceId', 'ExecutionId', 'ProjectLsn', 'CatalogDatabaseGuid']
      .map(field => [field, form.elements.namedItem(field).value.trim()]));
    read.disabled = true;
    status.textContent = 'SSISDB-Ausführungsmetadaten werden gelesen …';
    try {
      const response = await sqlServerLabUiFetch('/api/ssis-execution-diagnostic', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(args),
      });
      if (!response.ok) throw new Error('DIAGNOSTIC_UNAVAILABLE');
      const view = await response.json();
      if (generation !== revision || !dialog.open) return;
      const reasons = ['NONE', 'SQL_OBSERVATION_UNAVAILABLE', 'SQL_BINDING_MISMATCH', 'CAPTURE_FAILED',
        'EVENT_LIMIT', 'SSIS_EXECUTION_DIAGNOSTIC_SQL2025_REQUIRED', 'SSIS_EXECUTION_DIAGNOSTIC_CREDENTIAL_UNAVAILABLE',
        'SSIS_EXECUTION_DIAGNOSTIC_BINDING_CHANGED', 'SSIS_EXECUTION_DIAGNOSTIC_RESULT_INVALID',
        'SSIS_EXECUTION_DIAGNOSTIC_TARGET_OR_TRANSPORT_UNAVAILABLE'];
      const workers = ['NOT_ATTEMPTED', 'NOT_REPORTED', 'NOT_INSPECTED_TERMINAL', 'NOT_RUNNING',
        'PID_IDENTITY_UNPROVEN', 'RUNNING_CANDIDATE', 'ENDED_DURING_READ', 'INSPECTION_FAILED'];
      if (!['OBSERVED', 'INCONCLUSIVE'].includes(view?.Status) || !reasons.includes(view.Reason) ||
          !(view.ExecutionStatus === null || (Number.isInteger(view.ExecutionStatus) && view.ExecutionStatus >= 1 && view.ExecutionStatus <= 9)) ||
          !(view.Worker === null || workers.includes(view.Worker)) ||
          !Array.isArray(view.ErrorCodes) || view.ErrorCodes.length > 64 || !view.ErrorCodes.every(Number.isInteger)) {
        throw new Error('DIAGNOSTIC_INVALID');
      }
      const result = [view.Status === 'OBSERVED' ? 'Metadaten gelesen' : 'Beobachtung unvollständig'];
      if (view.Reason !== 'NONE') result.push(view.Reason);
      if (view.ExecutionStatus !== null) result.push('Katalogstatus ' + view.ExecutionStatus);
      if (view.Worker !== null) result.push('Worker ' + view.Worker);
      if (view.ErrorCodes.length) result.push('Fehlercodes ' + view.ErrorCodes.join(', '));
      status.textContent = result.join(' · ');
    } catch {
      if (generation === revision && dialog.open) {
        status.textContent = 'SSISDB-Diagnose fehlgeschlagen. Prüfe die Angaben aus dem Beleg und das laufende Windows-Lab.';
      }
    } finally {
      if (generation === revision) read.disabled = false;
    }
  });
})();
