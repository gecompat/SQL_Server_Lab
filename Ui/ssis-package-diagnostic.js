'use strict';
(() => {
  const element = id => document.getElementById('ssis-package-' + id);
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
    const value = name => form.elements.namedItem(name);
    if (!value('TrustConfirmed').checked) return;
    const generation = ++revision;
    const args = Object.fromEntries(['RunId', 'InstanceId', 'PackagePath', 'PackageName', 'ExpectedSha256']
      .map(field => [field, value(field).value.trim()]));
    args.TrustConfirmed = true;
    form.reset();
    read.disabled = true;
    status.textContent = 'Die Paketladediagnose läuft …';
    try {
      const response = await sqlServerLabUiFetch('/api/ssis-package-diagnostic', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(args),
      });
      if (!response.ok) throw new Error('DIAGNOSTIC_UNAVAILABLE');
      const view = await response.json();
      if (generation !== revision || !dialog.open) return;
      const statuses = {
        OBSERVED: 'Paketladung beobachtet',
        LOAD_FAILED: 'Paketladung fehlgeschlagen',
        INCONCLUSIVE: 'Paketladung konnte nicht bestätigt werden',
      };
      if (!Object.hasOwn(statuses, view?.Status) ||
          !(view.LoadStatus === null || ['NOT_ATTEMPTED', 'RETURNED', 'FAILED'].includes(view.LoadStatus)) ||
          !Array.isArray(view.EventCodes) || view.EventCodes.length > 256 || !view.EventCodes.every(Number.isInteger)) {
        throw new Error('DIAGNOSTIC_INVALID');
      }
      status.textContent = statuses[view.Status] + (view.EventCodes.length ? ' · Ereigniscodes ' + view.EventCodes.join(', ') : '');
    } catch {
      if (generation === revision && dialog.open) {
        status.textContent = 'Paketladediagnose fehlgeschlagen. Prüfe den Paketbeleg und das laufende Windows-Lab.';
      }
    } finally {
      if (generation === revision) read.disabled = false;
    }
  });
})();
