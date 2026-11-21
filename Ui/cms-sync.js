'use strict';
(() => {
  const button = document.getElementById('cms-sync-open');
  const dialog = document.getElementById('cms-inspection-dialog');
  const status = document.getElementById('cms-sync-status');
  function binding() {
    const view = cmsInspectionView;
    if (cmsInspectionBusy || !dialog.open || !['NOT_CHECKED', 'OBSERVED'].includes(view?.Status) ||
        !['docker', 'podman'].includes(view.Provider) || !/^[a-f0-9]{64}$/.test(view.SelectionKey || '') ||
        !/^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/.test(view.RunId || '')) return null;
    return view;
  }
  window.sqlServerLabCmsSync = { update() { button.disabled = !binding(); } };
  dialog.addEventListener('close', () => { status.textContent = ''; });
  button.addEventListener('click', () => {
    const view = binding();
    if (!view) return;
    const matches = publicCommandCatalog.filter(command => command?.Name === 'Sync-SqlServerLabCms');
    const command = matches.length === 1 ? matches[0] : null;
    const sets = (command?.ParameterSets || []).filter(set => set.Name === 'RegistrationBound');
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    if (command?.RequiresConfirmation !== true || fields.length !== 1 || fields[0].Name !== 'ExpectedRegistrationKey' ||
        fields[0].Mandatory !== true || fields[0].Sensitive !== false || fields[0].IsCredential !== false) {
      status.textContent = 'Der Synchronisationsauftrag ist auf diesem Host nicht verfügbar.';
      return;
    }
    dialog.close();
    openConfirmation('Registrierten CMS synchronisieren',
      'Ziel: ' + view.Provider + ' · ' + view.RunId + '\n'
      + 'Der lokale Endpunktkatalog wird aktualisiert. Nur die vom Lab verwalteten CMS-Einträge werden abgeglichen.',
      '__PublicCommand', { command, parameterSet, parameters: { ExpectedRegistrationKey: view.SelectionKey } }, 'Synchronisieren');
  });
})();
