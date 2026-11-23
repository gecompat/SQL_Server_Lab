'use strict';
(() => {
  const element = id => document.getElementById('hyperv-storage-preview-' + id);
  const dialog = element('dialog');
  const result = element('result');
  const status = element('status');
  const classes = ['Run', 'Build', 'Image', 'Staging', 'Recovery'];
  let revision = 0;

  async function readPreview() {
    const current = ++revision;
    result.textContent = '';
    result.hidden = true;
    status.textContent = 'Registriertes Speicherziel wird gelesen.';
    try {
      const response = await sqlServerLabUiFetch('/api/hyperv-storage-preview', { cache: 'no-store' });
      if (!response.ok) throw new Error('HYPERV_STORAGE_PREVIEW_UNAVAILABLE');
      const view = await response.json();
      if (typeof view?.LabDataRoot !== 'string' || !view.LabDataRoot || typeof view.FreeBytes !== 'string' ||
          !/^\d{1,19}$/.test(view.FreeBytes) || typeof view.SystemVolume !== 'boolean' ||
          !Array.isArray(view.Targets) || view.Targets.length !== classes.length ||
          !classes.every(name => view.Targets.filter(target => target?.ResourceClass === name &&
              typeof target.ClassRoot === 'string' && target.ClassRoot).length === 1)) {
        throw new Error('HYPERV_STORAGE_PREVIEW_INVALID');
      }
      if (revision !== current || !dialog.open) return;
      const freeGiB = new Intl.NumberFormat('de-DE', { maximumFractionDigits: 1 }).format(Number(view.FreeBytes) / 1073741824);
      result.textContent = [
        'Lab_Data: ' + view.LabDataRoot,
        'Freier Speicher bei Prüfung: ' + freeGiB + ' GiB',
        ...view.Targets.map(target => target.ResourceClass + ': ' + target.ClassRoot)
      ].join('\n');
      result.hidden = false;
      status.textContent = view.SystemVolume ?
        'Das Standardziel liegt auf dem Systemvolume. Prüfe die Kapazität vor größeren Builds.' :
        'Speicherziel gelesen.';
    } catch {
      if (revision === current && dialog.open) {
        status.textContent = 'Hyper-V-Zielpfade sind nicht lesbar. Prüfe die Lab_Data-Registrierung unter Grundkonfiguration.';
      }
    }
  }

  element('open').addEventListener('click', () => { dialog.showModal(); return readPreview(); });
  element('refresh').addEventListener('click', readPreview);
  element('close').addEventListener('click', () => { revision++; dialog.close(); });
  dialog.addEventListener('cancel', () => { revision++; });
})();
