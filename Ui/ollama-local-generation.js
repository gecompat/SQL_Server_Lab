'use strict';
(() => {
  const element = id => document.querySelector('#ollama-local-generation-' + id);
  const dialog = element('dialog');
  const selection = element('model');
  const prompt = element('prompt');
  const status = element('status');
  const next = element('next');
  const models = new Map();
  let revision = 0;
  const resetOptions = () => {
    models.clear();
    selection.options.length = 0;
    selection.add(new Option('Modell auswählen', ''));
    next.disabled = true;
  };
  const update = () => { next.disabled = !models.has(selection.value); };
  element('open').addEventListener('click', async () => {
    const request = ++revision;
    resetOptions();
    prompt.value = '';
    status.textContent = 'Lokaler Modellkatalog wird gelesen …';
    dialog.showModal();
    try {
      const response = await sqlServerLabUiFetch('/api/ollama-local-generation', { cache: 'no-store' });
      if (!response.ok) throw new Error();
      const entries = await response.json();
      if (request !== revision || !dialog.open) return;
      if (!Array.isArray(entries) || entries.length > 100) throw new Error();
      for (const model of entries) {
        if (typeof model?.Id !== 'string' || !/^[a-z][a-z0-9-]{2,95}$/.test(model.Id) ||
            typeof model.Name !== 'string' || !model.Name || models.has(model.Id)) throw new Error();
        models.set(model.Id, model.Name);
      }
      for (const [id, label] of models) selection.add(new Option(label, id));
      status.textContent = models.size ? '' : 'Kein unterstütztes lokales Generationsmodell im Katalog.';
    } catch {
      if (request !== revision || !dialog.open) return;
      resetOptions();
      status.textContent = 'Der lokale Modellkatalog ist nicht verfügbar.';
    }
  });
  selection.addEventListener('change', update);
  element('close').addEventListener('click', () => dialog.close());
  for (const event of ['close', 'cancel']) dialog.addEventListener(event, () => {
    revision++;
    prompt.value = '';
    resetOptions();
  });
  element('form').addEventListener('submit', event => {
    event.preventDefault();
    const value = element('port').value;
    const port = /^[0-9]+$/.test(value) ? Number(value) : NaN;
    const timeoutValue = element('timeout').value;
    const timeout = /^[0-9]+$/.test(timeoutValue) ? Number(timeoutValue) : NaN;
    const model = models.get(selection.value);
    if (next.disabled || !model) return;
    if (!Number.isInteger(port) || port < 1024 || port > 65535 || !Number.isInteger(timeout) || timeout < 1 || timeout > 230 ||
        !prompt.value.trim() || prompt.value.length > 8192) {
      status.textContent = 'Gib einen gültigen lokalen Port, 1–230 Sekunden Zeitlimit und einen Prompt mit höchstens 8192 Zeichen ein.';
      return;
    }
    const parameters = { ModelKey: selection.value, InputText: prompt.value, DataClassification: 'synthetic-only',
      Lane: 'local', LocalPort: port, TimeoutSeconds: timeout, RetryCount: 0 };
    const commands = publicCommandCatalog.filter(command => command?.Name === 'Invoke-SqlServerLabAiModel');
    const command = commands.length === 1 ? commands[0] : null;
    const sets = command?.ParameterSets;
    const parameterSet = Array.isArray(sets) && sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    if (command?.RequiresConfirmation !== true || typeof parameterSet?.Name !== 'string' ||
        fields.some(field => field?.Mandatory === true && !Object.hasOwn(parameters, field.Name)) ||
        Object.keys(parameters).some(name => fields.filter(field => field?.Name === name && field.Sensitive === false && field.IsCredential === false).length !== 1)) {
      status.textContent = 'Der lokale Modellaufruf ist auf diesem Host nicht verfügbar.';
      return;
    }
    dialog.close();
    openConfirmation('Lokalen Modellaufruf bestätigen',
      model + ' · 127.0.0.1:' + port + ' · ' + timeout + ' Sekunden Zeitlimit\nSende genau eine Abfrage mit synthetischen Daten. Die Antwort steht unter Vorgänge.',
      '__PublicCommand', { command, parameterSet, parameters }, 'Lokal ausführen');
  });
})();
