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

(() => {
  const element = id => document.getElementById('ssis-capability-' + id);
  const dialog = element('dialog');
  if (!dialog) return;
  const status = element('status');
  const read = element('read');
  let target;
  let revision = 0;
  const guid = /^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/;
  const instance = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;

  function renderAction(item, runningSql) {
    if (!runningSql || !['2019', '2022', '2025'].includes(String(item.SqlVersion)) ||
        typeof item.RunId !== 'string' || !guid.test(item.RunId) ||
        typeof item.InstanceId !== 'string' || !instance.test(item.InstanceId)) return '';
    return '<button type="button" class="button secondary" data-ssis-capability="true" data-run="' +
      item.RunId + '" data-instance="' + item.InstanceId + '" data-lab-name="' + escapeHtml(item.Name || item.RunId) +
      '">SSIS-Katalogvoraussetzungen prüfen</button>';
  }

  document.addEventListener('click', event => {
    const button = event.target.closest?.('[data-ssis-capability]');
    if (!button || !guid.test(button.dataset.run || '') || !instance.test(button.dataset.instance || '')) return;
    target = { RunId: button.dataset.run, InstanceId: button.dataset.instance };
    ++revision;
    element('target').textContent = (button.dataset.labName || target.RunId) + ' / ' + target.InstanceId;
    status.textContent = '';
    read.disabled = false;
    dialog.showModal();
  });
  element('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => { ++revision; target = undefined; status.textContent = ''; });
  element('form').addEventListener('submit', async event => {
    event.preventDefault();
    if (!target || read.disabled) return;
    const generation = ++revision;
    read.disabled = true;
    status.textContent = 'SQL- und SSIS-Katalogvoraussetzungen werden gelesen …';
    try {
      const response = await sqlServerLabUiFetch('/api/ssis-catalog-capability', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(target),
      });
      if (!response.ok) throw new Error('SSIS_CAPABILITY_UNAVAILABLE');
      const view = await response.json();
      if (generation !== revision || !dialog.open) return;
      const messages = {
        Status: { READY_FOR_FIXTURE_IMPLEMENTATION: 'Voraussetzungen beobachtet', BLOCKED: 'Voraussetzungen fehlen oder sind unbekannt' },
        Reason: { NONE: '', WINDOWS_HOST_REQUIRED: 'Windows-Host erforderlich', TARGET_UNAVAILABLE: 'Ziel nicht verfügbar',
          BINDING_CHANGED: 'Instanzbindung geändert', PROBE_UNAVAILABLE: 'Gastabfrage nicht verfügbar' },
        Sql: { SQL_2019_OBSERVED: 'SQL Server 2019', SQL_2022_OBSERVED: 'SQL Server 2022', SQL_2025_OBSERVED: 'SQL Server 2025',
          VERSION_UNSUPPORTED: 'SQL-Version nicht unterstützt', UNKNOWN: 'SQL-Version unbekannt' },
        Components: { OBSERVED: 'SSIS-Komponenten beobachtet', NOT_OBSERVED: 'SSIS-Komponenten fehlen', UNKNOWN: 'SSIS-Komponenten unbekannt' },
        Catalog: { MISSING: 'SSISDB fehlt', NOT_ONLINE: 'SSISDB ist offline', ONLINE_UNVERIFIED: 'SSISDB online, Katalog unverifiziert',
          ONLINE_CATALOG_OBSERVED: 'SSISDB-Katalog online', UNKNOWN: 'SSISDB-Katalogstatus unbekannt' },
      };
      const summary = Object.entries(messages).map(([key, labels]) => {
        if (!Object.hasOwn(labels, view?.[key])) throw new Error('SSIS_CAPABILITY_INVALID');
        return labels[view[key]];
      });
      status.textContent = summary.filter(Boolean).join(' · ');
    } catch {
      if (generation === revision && dialog.open) status.textContent = 'Katalogvoraussetzungen konnten nicht gelesen werden.';
    } finally {
      if (generation === revision) read.disabled = false;
    }
  });
  window.sqlServerLabSsisCapability = { renderAction };
})();
