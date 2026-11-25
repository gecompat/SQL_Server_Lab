'use strict';
{
function initializeOllamaGeneration(lane) {
  const cloud = lane === 'cloud';
  const element = id => document.querySelector(`#ollama-${lane}-generation-${id}`);
  const dialog = element('dialog');
  if (!dialog) return;
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
    if (cloud) element('class').value = '';
    status.textContent = 'Modellkatalog wird gelesen …';
    dialog.showModal();
    try {
      const response = await sqlServerLabUiFetch(`/api/ollama-${lane}-generation`, { cache: 'no-store' });
      if (!response.ok) throw new Error();
      const entries = await response.json();
      if (request !== revision || !dialog.open) return;
      if (!Array.isArray(entries) || entries.length > 100) throw new Error();
      for (const model of entries) {
        if (typeof model?.Id !== 'string' || !/^[a-z][a-z0-9-]{2,95}$/.test(model.Id) ||
            typeof model.Name !== 'string' || !model.Name || models.has(model.Id) ||
            (cloud && model.TargetHost !== 'ollama.com')) throw new Error();
        models.set(model.Id, model.Name);
      }
      for (const [id, label] of models) selection.add(new Option(label, id));
      status.textContent = models.size ? '' : 'Kein unterstütztes Generationsmodell für diese Auswahl im Katalog.';
    } catch {
      if (request !== revision || !dialog.open) return;
      resetOptions();
      status.textContent = 'Der Modellkatalog ist nicht verfügbar.';
    }
  });
  selection.addEventListener('change', update);
  element('close').addEventListener('click', () => dialog.close());
  for (const event of ['close', 'cancel']) dialog.addEventListener(event, () => {
    revision++;
    prompt.value = '';
    if (cloud) element('class').value = '';
    resetOptions();
  });
  element('form').addEventListener('submit', event => {
    event.preventDefault();
    const value = cloud ? '' : element('port').value;
    const port = /^[0-9]+$/.test(value) ? Number(value) : NaN;
    const timeoutValue = element('timeout').value;
    const timeout = /^[0-9]+$/.test(timeoutValue) ? Number(timeoutValue) : NaN;
    const model = models.get(selection.value);
    if (next.disabled || !model) return;
    const dataClassification = cloud ? element('class').value : 'synthetic-only';
    if ((!cloud && (!Number.isInteger(port) || port < 1024 || port > 65535)) ||
        !['synthetic-only','public-or-redistributable'].includes(dataClassification) ||
        !Number.isInteger(timeout) || timeout < 1 || timeout > 230 ||
        !prompt.value.trim() || prompt.value.length > 8192) {
      status.textContent = cloud
        ? 'Wähle die Datenklasse und gib 1–230 Sekunden Zeitlimit sowie einen Prompt mit höchstens 8192 Zeichen ein.'
        : 'Gib einen gültigen lokalen Port, 1–230 Sekunden Zeitlimit und einen Prompt mit höchstens 8192 Zeichen ein.';
      return;
    }
    const parameters = { ModelKey: selection.value, InputText: prompt.value, DataClassification: dataClassification,
      Lane: lane, TimeoutSeconds: timeout, RetryCount: 0 };
    if (cloud) parameters.AllowCloudEgress = true;
    else parameters.LocalPort = port;
    const commands = publicCommandCatalog.filter(command => command?.Name === 'Invoke-SqlServerLabAiModel');
    const command = commands.length === 1 ? commands[0] : null;
    const sets = command?.ParameterSets;
    const parameterSet = Array.isArray(sets) && sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    if (command?.RequiresConfirmation !== true || typeof parameterSet?.Name !== 'string' ||
        fields.some(field => field?.Mandatory === true && !Object.hasOwn(parameters, field.Name)) ||
        Object.keys(parameters).some(name => fields.filter(field => field?.Name === name && field.Sensitive === false && field.IsCredential === false).length !== 1)) {
      status.textContent = 'Der Modellaufruf ist auf diesem Host nicht verfügbar.';
      return;
    }
    dialog.close();
    if (cloud) {
      const label = dataClassification === 'synthetic-only' ? 'synthetische Daten' : 'öffentliche oder weitergebbare Daten';
      openConfirmation('Cloud-Übermittlung bestätigen',
        `${model} · https://ollama.com · ${timeout} Sekunden Zeitlimit\nSende genau eine Abfrage mit ${label}. Die Antwort steht unter Vorgänge.`,
        '__PublicCommand', { command, parameterSet, parameters }, 'Einmal an Ollama senden');
      return;
    }
    openConfirmation('Lokalen Modellaufruf bestätigen',
      model + ' · 127.0.0.1:' + port + ' · ' + timeout + ' Sekunden Zeitlimit\nSende genau eine Abfrage mit synthetischen Daten. Die Antwort steht unter Vorgänge.',
      '__PublicCommand', { command, parameterSet, parameters }, 'Lokal ausführen');
  });
}

initializeOllamaGeneration('local');
initializeOllamaGeneration('cloud');
}
