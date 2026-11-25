'use strict';
(() => {
  $('#ssms-registration-download').addEventListener('click', async () => {
    const button = $('#ssms-registration-download');
    const status = $('#ssms-registration-status');
    if (button.disabled) return;
    button.disabled = true;
    status.textContent = 'Registrierungen werden aus dem gespeicherten Zustand gelesen.';
    try {
      const response = await sqlServerLabUiFetch('/api/ssms-registration', { cache: 'no-store' });
      if (!response.ok || !/^application\/xml(?:;|$)/i.test(response.headers.get('Content-Type') || '')) {
        throw new Error('SSMS_REGISTRATION_UNAVAILABLE');
      }
      const registration = await response.blob();
      if (!registration.size || registration.size > 2097152) throw new Error('SSMS_REGISTRATION_INVALID');
      const url = URL.createObjectURL(registration);
      try {
        const link = document.createElement('a');
        link.href = url;
        link.download = 'sql-server-lab.regsrvr';
        link.click();
      } finally {
        window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      }
      status.textContent = 'Download gestartet. Die Datei kann in SSMS importiert werden.';
    } catch {
      status.textContent = 'Die gespeicherten Registrierungen konnten nicht exportiert werden.';
    } finally {
      button.disabled = false;
    }
  });
})();

(() => {
  const element = name => document.querySelector('#connection-center-' + name);
  const dialog = element('dialog');
  if (!dialog) return;
  const entries = element('entries');
  const status = element('status');
  const read = element('read');
  const columns = ['DisplayName','Provider','Server','StoredState'];
  const providers = {docker:'Docker',podman:'Podman',hyperv:'Hyper-V',unknown:'Unbekannt'};
  const states = {RUNNING:'Läuft laut gespeichertem Zustand',STOPPED:'Gestoppt laut gespeichertem Zustand',UNKNOWN:'Unbekannt'};
  let revision = 0;

  async function loadConnections() {
    if (!dialog.open || read.disabled) return;
    const requested = ++revision;
    entries.replaceChildren();
    read.disabled = true;
    status.textContent = 'Gespeicherte Endpunkte werden gelesen …';
    try {
      const response = await sqlServerLabUiFetch('/api/connection-center', {cache:'no-store'});
      if (!response.ok) throw new Error('STORED_CONNECTION_CENTER_UNAVAILABLE');
      const view = await response.json();
      if (requested !== revision || !dialog.open) return;
      if (view?.ContractVersion !== 'SqlServerLab.StoredConnectionCenter/1.0' || typeof view.MoreAvailable !== 'boolean' ||
          !Number.isSafeInteger(view.SkippedCount) || view.SkippedCount < 0 || !Array.isArray(view.Entries) ||
          view.Entries.length > 200 || !view.Entries.every(entry => entry && Object.keys(entry).length === columns.length &&
            columns.every(name => typeof entry[name] === 'string') && Object.hasOwn(providers,entry.Provider) &&
            Object.hasOwn(states,entry.StoredState) && entry.DisplayName.length > 0 && entry.DisplayName.length <= 256 &&
            entry.Server.length > 0 && entry.Server.length <= 300)) throw new Error('STORED_CONNECTION_CENTER_INVALID');

      const rows = view.Entries.map(entry => {
        const row = document.createElement('tr');
        for (const value of [entry.DisplayName,providers[entry.Provider],entry.Server,states[entry.StoredState]]) {
          const cell = document.createElement('td');
          cell.textContent = value;
          row.append(cell);
        }
        return row;
      });
      entries.replaceChildren(...rows);
      const counts = [rows.length ? `${rows.length} gespeicherte SQL-Endpunkte angezeigt.` : 'Keine gespeicherten SQL-Endpunkte gefunden.'];
      if (view.SkippedCount) {
        const noun = view.SkippedCount === 1 ? 'Eintrag' : 'Einträge';
        counts.push(`${view.SkippedCount} ${noun} mit unvollständigen oder ungültigen Angaben ausgelassen.`);
      }
      if (view.MoreAvailable) counts.push('Die Anzeige ist auf die ersten 200 gültigen Einträge begrenzt.');
      status.textContent = counts.join(' ');
    } catch {
      if (requested === revision && dialog.open) status.textContent = 'Gespeicherte Endpunkte konnten nicht gelesen werden.';
    } finally {
      if (requested === revision) read.disabled = false;
    }
  }

  element('open').addEventListener('click', () => { dialog.showModal(); return loadConnections(); });
  read.addEventListener('click', loadConnections);
  element('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => {
    revision++;
    entries.replaceChildren();
    status.textContent = '';
    read.disabled = false;
  });
})();
