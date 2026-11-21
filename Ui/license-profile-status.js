'use strict';
(() => {
  const el = id => document.getElementById('license-profile-status-' + id);
  const dialog = el('dialog');
  const selection = el('selection');
  const result = el('result');
  const read = el('read');
  const idPattern = /^[a-z][a-z0-9.-]{2,63}$/;
  const states = {
    READY: 'Das Profil ist lokal strukturell verwendbar.',
    NOT_FOUND: 'Das gewählte Profil ist nicht mehr vorhanden.',
    KEY_UNAVAILABLE: 'Die geschützte Schlüsseldatei fehlt oder ist nicht verfügbar.',
    KEY_FORMAT_INVALID: 'Das gespeicherte Schlüsselformat ist ungültig.',
    UNVERIFIABLE: 'Das Profil ist lokal nicht eindeutig prüfbar.'
  };
  let revision = 0;
  let profiles = new Set();

  async function readInventory(profileId) {
    const query = profileId ? '?' + new URLSearchParams({ profileId }) : '';
    const response = await sqlServerLabUiFetch('/api/license-profile-status' + query, { cache: 'no-store' });
    if (!response.ok) throw new Error('LICENSE_STATUS_UNAVAILABLE');
    const data = await response.json();
    if (data?.ContractVersion !== 'SqlServerLab.LicenseProfileStatusGuidance/1.0') throw new Error('LICENSE_STATUS_INVALID');
    return data;
  }

  el('open').addEventListener('click', async () => {
    const current = ++revision;
    profiles = new Set();
    selection.replaceChildren();
    read.disabled = true;
    result.textContent = 'Lokale Lizenzprofile werden gelesen.';
    dialog.showModal();
    try {
      const inventory = await readInventory();
      if (!dialog.open || current !== revision) return;
      if (inventory.Status === 'UNSUPPORTED') {
        result.textContent = 'Lokale Lizenzprofile benötigen Windows und DPAPI.';
        return;
      }
      if (inventory.Status !== 'LISTED' || !Array.isArray(inventory.Profiles) ||
          !inventory.Profiles.every(p => idPattern.test(p?.Id) && ['SqlServer', 'Windows'].includes(p.Product) &&
            [p.Version, p.Edition, p.Channel].every(value => typeof value === 'string') && typeof p.KeyAvailable === 'boolean')) {
        throw new Error('LICENSE_STATUS_INVALID');
      }
      for (const profile of inventory.Profiles) {
        if (profiles.has(profile.Id)) continue;
        profiles.add(profile.Id);
        const option = document.createElement('option');
        option.value = profile.Id;
        option.textContent = [profile.Product, profile.Version, profile.Edition, profile.Channel, profile.Id,
          profile.KeyAvailable ? 'Schlüsseldatei vorhanden' : 'Schlüsseldatei fehlt'].join(' · ');
        selection.append(option);
      }
      read.disabled = !profiles.size;
      result.textContent = profiles.size ? 'Wähle ein Profil für die lokale Formatprüfung.' : 'Keine lokalen Lizenzprofile vorhanden.';
    } catch {
      if (dialog.open && current === revision) result.textContent = 'Die Lizenzprofile konnten nicht gelesen werden.';
    }
  });
  selection.addEventListener('change', () => {
    revision++;
    read.disabled = !profiles.has(selection.value);
    result.textContent = 'Wähle ein Profil für die lokale Formatprüfung.';
  });
  el('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => { revision++; });
  el('form').addEventListener('submit', async event => {
    event.preventDefault();
    const id = selection.value;
    if (!dialog.open || read.disabled || !profiles.has(id)) return;
    const current = ++revision;
    read.disabled = true;
    result.textContent = 'Das gewählte Profil wird lokal geprüft.';
    try {
      const receipt = await readInventory(id);
      if (!dialog.open || current !== revision || selection.value !== id) return;
      if (receipt.Id !== id || receipt.OnlineActivationTested !== false || !Object.hasOwn(states, receipt.Status)) {
        throw new Error('LICENSE_STATUS_INVALID');
      }
      result.textContent = states[receipt.Status];
    } catch {
      if (dialog.open && current === revision) result.textContent = 'Die lokale Profilprüfung konnte nicht abgeschlossen werden.';
    } finally {
      if (dialog.open && current === revision) read.disabled = false;
    }
  });
})();
