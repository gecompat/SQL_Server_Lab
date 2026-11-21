'use strict';
(() => {
  const el = id => document.getElementById('runtime-maintenance-preview-' + id);
  const dialog = el('dialog');
  const status = el('status');
  const result = el('result');
  const read = el('read');
  const stateLabels = {
    CLEAN: 'Für die beobachteten Ressourcen wurden keine Aktionen vorgeschlagen.',
    CHANGES_AVAILABLE: 'Der Plan enthält vorgeschlagene Aktionen.',
    REVIEW_REQUIRED: 'Ein Befund muss geprüft werden.',
    UNVERIFIABLE: 'Mindestens ein Provider konnte nicht geprüft werden.'
  };
  const providers = ['docker', 'podman', 'hyperv'];
  const countLabels = {
    Actions: 'Vorgeschlagene Aktionen',
    SafeAutomatic: 'State-Abgleich und abgelaufene Testressourcen',
    ScopedCleanup: 'Gebundener Cleanup',
    LegacyApproval: 'Legacy-Freigabe',
    ReviewOnly: 'Weitere Prüfung'
  };
  let revision = 0;
  let busy = false;

  el('open').addEventListener('click', () => {
    revision++;
    result.hidden = true;
    result.textContent = '';
    status.textContent = 'Lies den Plan, um die Provider und den registrierten Zustand zu vergleichen.';
    read.disabled = busy;
    dialog.showModal();
  });
  el('close').addEventListener('click', () => { revision++; dialog.close(); });
  dialog.addEventListener('cancel', () => { revision++; });
  read.addEventListener('click', async () => {
    if (busy || !dialog.open) return;
    const current = ++revision;
    result.hidden = true;
    result.textContent = '';
    busy = true;
    read.disabled = true;
    status.textContent = 'Der Wartungsplan wird gelesen.';
    try {
      const response = await sqlServerLabUiFetch('/api/runtime-maintenance-preview', { cache: 'no-store' });
      if (!response.ok) throw new Error('RUNTIME_MAINTENANCE_PREVIEW_UNAVAILABLE');
      const view = await response.json();
      if (view?.ContractVersion !== 'SqlServerLab.RuntimeMaintenancePreview/1.0' ||
          !Object.hasOwn(stateLabels, view.Status) || !Array.isArray(view.Providers) || view.Providers.length !== providers.length ||
          !providers.every(name => view.Providers.filter(entry => entry?.Provider === name &&
            ['AVAILABLE', 'NOT_INSTALLED', 'UNAVAILABLE'].includes(entry.Status)).length === 1) ||
          !Object.keys(countLabels).every(key => Number.isSafeInteger(view.Summary?.[key]) && view.Summary[key] >= 0)) {
        throw new Error('RUNTIME_MAINTENANCE_PREVIEW_INVALID');
      }
      if (revision !== current || !dialog.open) return;
      status.textContent = stateLabels[view.Status];
      result.textContent = [
        ...view.Providers.map(entry => entry.Provider + ': ' + entry.Status),
        ...Object.entries(countLabels).map(([key, label]) => label + ': ' + view.Summary[key])
      ].join('\n');
      result.hidden = false;
    } catch {
      if (revision === current && dialog.open) status.textContent = 'Der schnelle Wartungsplan konnte nicht gelesen werden.';
    } finally {
      busy = false;
      read.disabled = false;
    }
  });
})();
