'use strict';
(() => {
  async function readLlamaRuntimeInventory() {
    const button = $('#llama-runtime-inventory-read');
    const status = $('#llama-runtime-inventory-status');
    const items = $('#llama-runtime-inventory-items');
    if (button.disabled) return;
    button.disabled = true;
    status.textContent = 'Paketdateien werden geprüft …';
    items.hidden = true;
    items.replaceChildren();
    try {
      const response = await sqlServerLabUiFetch('/api/llama-runtime-inventory', { cache: 'no-store' });
      if (!response.ok) throw new Error('INVENTORY_UNAVAILABLE');
      const view = await response.json();
      const backends = ['Unknown', 'Ambiguous', 'LlamaCppCuda', 'LlamaCppOpenVino', 'LlamaCppRocm', 'LlamaCppVulkan', 'LlamaCppSycl'];
      if (view?.EvidenceStatus !== 'FILES_ONLY' || !['COMPLETED', 'PARTIAL'].includes(view.ScanStatus) ||
          !Array.isArray(view.Items) || !view.Items.every(item => backends.includes(item?.Backend) &&
            (item.Build === null || (typeof item.Build === 'string' && /^\d{1,19}$/.test(item.Build))))) {
        throw new Error('INVENTORY_INVALID');
      }
      for (const item of view.Items) {
        const row = document.createElement('li');
        row.textContent = 'Backend ' + item.Backend + ' · Build ' + (item.Build ?? 'unbekannt');
        items.append(row);
      }
      items.hidden = view.Items.length === 0;
      const scope = view.ScanStatus === 'PARTIAL' ? 'Suche unvollständig. ' : '';
      status.textContent = scope + (view.Items.length ? view.Items.length + ' Paketdateibefunde. ' : 'Keine Paketdateien gefunden. ') +
        'Paketursprung, Geräteverfügbarkeit und SQL-Embedding-Bereitschaft bleiben ungeprüft.';
    } catch {
      status.textContent = 'Paketübersicht nicht verfügbar. Konfigurierte Suchverzeichnisse und Suchgrenzen prüfen.';
    } finally {
      button.disabled = false;
    }
  }
  $('#llama-runtime-inventory-read').addEventListener('click', readLlamaRuntimeInventory);

  $('#ai-compute-inventory-read').addEventListener('click', async () => {
    const button = $('#ai-compute-inventory-read');
    const status = $('#ai-compute-inventory-status');
    if (button.disabled) return;
    button.disabled = true;
    status.textContent = 'Geräte werden erfasst …';
    try {
      const response = await sqlServerLabUiFetch('/api/ai-compute-inventory', { cache: 'no-store' });
      if (!response.ok) throw new Error('INVENTORY_UNAVAILABLE');
      const view = await response.json();
      const kinds = ['CPU', 'GPU', 'NPU'];
      if (!['COMPLETE', 'INCOMPLETE'].includes(view?.Status) || !['Windows', 'Linux', 'Unsupported'].includes(view.Platform) ||
          !Array.isArray(view.Items) || view.Items.length !== kinds.length || !view.Items.every((item, index) =>
            item?.Kind === kinds[index] && ((item.Count === null && view.Status === 'INCOMPLETE') ||
              (Number.isSafeInteger(item.Count) && item.Count >= 0)))) throw new Error('INVENTORY_INVALID');
      const coverage = view.Status === 'COMPLETE' ? 'vollständig' : 'unvollständig';
      status.textContent = view.Platform + ' · Erfassung ' + coverage + ' · ' +
        view.Items.map(item => item.Kind + ': ' + (item.Count ?? 'unbekannt')).join(' · ') +
        '. Runtime-Eignung und Leistung werden separat geprüft.';
    } catch {
      status.textContent = 'Die Geräteinventur ist nicht verfügbar.';
    } finally {
      button.disabled = false;
    }
  });

  $('#ai-runtime-capability-read').addEventListener('click', async () => {
    const button = $('#ai-runtime-capability-read');
    const status = $('#ai-runtime-capability-status');
    if (button.disabled) return;
    button.disabled = true;
    status.textContent = 'Paketdateien und Geräte werden geprüft …';
    try {
      const response = await sqlServerLabUiFetch('/api/ai-runtime-capability', { cache: 'no-store' });
      if (!response.ok) throw new Error('CAPABILITY_UNAVAILABLE');
      const view = await response.json();
      switch (view.Status) {
        case 'INVENTORY_INCOMPLETE':
          status.textContent = 'Die Geräteinventur ist unvollständig. Die Eignung kann nicht ermittelt werden.';
          break;
        case 'PACKAGE_SCAN_INCOMPLETE':
          status.textContent = 'Die Paketsuche ist unvollständig oder hat mehr als 16 Kandidaten.';
          break;
        case 'NO_PACKAGES':
          status.textContent = 'Keine llama.cpp-Pakete gefunden. Prüfe die Paketübersicht.';
          break;
        case 'FILES_HASHED_NOT_EXECUTED': {
          const backends = ['LlamaCppCpu', 'LlamaCppCuda', 'LlamaCppRocm', 'LlamaCppVulkan', 'LlamaCppSycl', 'LlamaCppOpenVino'];
          if (!Array.isArray(view.Items) || view.Items.length < 1 || view.Items.length > 8 ||
              !view.Items.every(row => backends.includes(row?.Backend) &&
                ['CPU', 'GPU', 'NPU'].includes(row.Kind) && typeof row.Eligible === 'boolean')) {
            throw new Error('CAPABILITY_INVALID');
          }
          status.textContent = view.Items.map(row =>
            row.Backend + ' · ' + row.Kind + ' · ' + (row.Eligible ? 'passendes Gerät gefunden' : 'kein passendes Gerät gefunden')
          ).join(' | ') + '. Es wurde keine Runtime ausgeführt.';
          break;
        }
        default:
          throw new Error('CAPABILITY_INVALID');
      }
    } catch {
      status.textContent = 'Die Runtime-Eignung kann nicht ermittelt werden.';
    } finally {
      button.disabled = false;
    }
  });
})();
