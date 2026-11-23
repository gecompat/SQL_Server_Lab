'use strict';
(() => {
  const element = id => document.querySelector('#llama-model-catalog-' + id);
  const dialog = element('dialog');
  const selection = element('selection');
  const details = element('details');
  const status = element('status');
  const submit = element('download');
  let catalog = new Map();
  let revision = 0;
  const sizeLabel = bytes => (bytes / 1e9).toLocaleString('de-AT', { maximumFractionDigits: 2 }) + ' GB';
  const mediaRoot = () => typeof workflow?.Defaults?.MediaRoot === 'string' ? workflow.Defaults.MediaRoot : '';
  function updateSelection() {
    const model = catalog.get(selection.value);
    details.textContent = model ? [sizeLabel(model.SizeBytes), model.Quantization, model.License, model.Publisher].join(' · ') : '';
    submit.disabled = !model || !mediaRoot();
    status.textContent = model && !mediaRoot() ? 'Konfiguriere zuerst den Medienordner in der Grundkonfiguration.' : '';
  }
  element('open').addEventListener('click', async () => {
    const request = ++revision;
    catalog.clear();
    selection.replaceChildren(new Option('Modell auswählen', ''));
    updateSelection();
    status.textContent = 'Modellkatalog wird gelesen …';
    dialog.showModal();
    try {
      const response = await sqlServerLabUiFetch('/api/llama-model-catalog', { cache: 'no-store' });
      if (!response.ok) throw new Error();
      const rows = await response.json();
      if (request !== revision || !dialog.open) return;
      if (!Array.isArray(rows) || rows.length > 100) throw new Error();
      for (const model of rows) {
        if (model?.Contract !== 'SqlServerLab.LlamaCppModel/1.0' || model.DirectDownload !== true || model.Purpose !== 'generation' ||
            typeof model.Id !== 'string' || !/^[a-z0-9][a-z0-9._-]{0,127}$/.test(model.Id) || catalog.has(model.Id) ||
            typeof model.DisplayName !== 'string' || typeof model.License !== 'string' ||
            typeof model.Quantization !== 'string' || typeof model.Publisher !== 'string' ||
            typeof model.Sha256 !== 'string' || !/^[a-f0-9]{64}$/.test(model.Sha256) ||
            typeof model.Revision !== 'string' || !/^[a-f0-9]{40}$/.test(model.Revision) ||
            !Number.isSafeInteger(model.SizeBytes) || model.SizeBytes < 1) throw new Error();
        catalog.set(model.Id, model);
      }
      for (const model of catalog.values()) selection.add(new Option(model.DisplayName, model.Id));
      status.textContent = catalog.size ? '' : 'Der Katalog enthält keine herunterladbaren Modelle.';
    } catch {
      if (request !== revision || !dialog.open) return;
      catalog.clear();
      updateSelection();
      status.textContent = 'Der lokale Modellkatalog ist nicht verfügbar.';
    }
  });
  selection.addEventListener('change', updateSelection);
  element('close').addEventListener('click', () => dialog.close());
  for (const event of ['close', 'cancel']) dialog.addEventListener(event, () => { revision++; catalog.clear(); });
  element('form').addEventListener('submit', event => {
    event.preventDefault();
    const model = catalog.get(selection.value);
    const root = mediaRoot();
    if (submit.disabled || !model || !root) return;
    const commands = publicCommandCatalog.filter(command => command?.Name === 'Save-SqlServerLabLlamaCppModel');
    const command = commands.length === 1 ? commands[0] : null;
    const sets = command?.ParameterSets;
    const parameterSet = Array.isArray(sets) && sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    const parameters = { Id: model.Id, MediaRoot: root, ExpectedModelSha256: model.Sha256, ExpectedModelRevision: model.Revision };
    if (command?.RequiresConfirmation !== true || typeof parameterSet?.Name !== 'string' ||
        fields.some(field => field?.Mandatory === true && !Object.hasOwn(parameters, field.Name)) ||
        Object.keys(parameters).some(name => fields.filter(field => field?.Name === name && field.Sensitive === false && field.IsCredential === false).length !== 1)) {
      status.textContent = 'Der Download ist auf diesem Host nicht verfügbar.';
      return;
    }
    dialog.close();
    openConfirmation('llama.cpp-Modell herunterladen',
      [model.DisplayName, sizeLabel(model.SizeBytes) + ' · Lizenz ' + model.License,
        'Ziel: ' + root + ' / AI/Models', 'Die bestätigte Revision wird geladen und geprüft.'].join('\n'),
      '__PublicCommand', { command, parameterSet, parameters }, 'Download starten');
  });
})();
