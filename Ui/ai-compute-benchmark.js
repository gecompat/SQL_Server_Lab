'use strict';
(() => {
  const element = id => document.getElementById('compute-benchmark-' + id);
  const dialog = element('dialog');
  const form = element('form');
  const candidate = element('candidate');
  const status = element('status');
  const next = element('next');
  const modelInput = element('model');
  const hash = /^[a-f0-9]{64}$/;
  const candidateId = /^[a-z0-9][a-z0-9._-]{0,127}$/;
  let generation = 0;
  let options = null;

  function invalidate() {
    generation++;
    options = null;
    candidate.replaceChildren(new Option('Zuerst Modell und Messkandidaten prüfen', ''));
    next.disabled = true;
    status.textContent = '';
  }

  element('open').addEventListener('click', () => {
    form.reset();
    invalidate();
    dialog.showModal();
  });
  modelInput.addEventListener('input', invalidate);
  element('read').addEventListener('click', async () => {
    const requestedModel = modelInput.value.trim();
    const localModelPath = /^(?:[A-Za-z]:[\\/]|\/(?!\/)).+\.gguf$/i;
    invalidate();
    const current = generation;
    if (!localModelPath.test(requestedModel) || requestedModel.length > 4096 || /[\u0000-\u001f\u007f]/.test(requestedModel)) {
      status.textContent = 'Gib den absoluten lokalen Pfad zur GGUF-Datei an.';
      return;
    }
    status.textContent = 'Lokales Inventar und Paketdateien werden geprüft.';
    try {
      const response = await sqlServerLabUiFetch('/api/ai-compute-benchmark-options', {
        method: 'POST', cache: 'no-store', headers: {'Content-Type': 'application/json'},
        body: JSON.stringify({ ModelPath: requestedModel }),
      });
      if (!response.ok) throw new Error('BENCHMARK_OPTIONS_UNAVAILABLE');
      const payload = await response.json();
      const candidates = payload?.CandidateSet?.Candidates;
      const packages = payload?.Packages;
      const inventory = payload?.Inventory;
      if (typeof payload?.ModelPath !== 'string' || !localModelPath.test(payload.ModelPath) ||
          inventory?.Contract !== 'SqlServerLab.AiComputeInventory/1.0' || inventory.Status !== 'COMPLETE' ||
          !hash.test(inventory.InventorySha256) || payload?.CandidateSet?.Contract !== 'SqlServerLab.AiComputeCandidateSet/1.0' ||
          payload.CandidateSet.InventorySha256 !== inventory.InventorySha256 || !Array.isArray(candidates) ||
          !candidates.length || candidates.length > 64 || !Array.isArray(packages) || !packages.length || packages.length > 16 ||
          !packages.every(item => hash.test(item?.RuntimeSha256) && typeof item.Directory === 'string' && item.Directory.length > 0 && item.Directory.length <= 4096)) {
        throw new Error('BENCHMARK_OPTIONS_INVALID');
      }
      const eligible = candidates.filter(item => item?.Eligible === true);
      const byHash = new Map(packages.map(item => [item.RuntimeSha256, item.Directory]));
      if (!eligible.length || byHash.size !== packages.length ||
          !eligible.every(item => candidateId.test(item.CandidateId) && typeof item.Backend === 'string' &&
            Array.isArray(item.Devices) && item.Devices.length && byHash.has(item.RuntimeSha256)) ||
          new Set(eligible.map(item => item.CandidateId)).size !== eligible.length) throw new Error('BENCHMARK_OPTIONS_INVALID');
      if (generation !== current || !dialog.open || modelInput.value.trim() !== requestedModel) return;
      options = { candidates, inventory, eligible, byHash, requestedModel, model: payload.ModelPath };
      candidate.replaceChildren(new Option('Kandidaten wählen', ''));
      candidate.add(new Option('Alle geeigneten Kandidaten (' + eligible.length + ')', 'all'));
      for (const item of eligible) candidate.add(new Option(item.Backend + ' · ' + item.Devices.map(device => device.DeviceId).join(', '), 'candidate:' + item.CandidateId));
      status.textContent = 'Lokale Pakete gefunden. Der genaue Gerätenachweis entsteht bei der Messung.';
      next.disabled = false;
    } catch {
      if (generation === current && dialog.open) status.textContent = 'Keine vollständige Geräte- und Paketgrundlage verfügbar. Prüfe die lokale llama.cpp-Installation.';
    }
  });
  element('close').addEventListener('click', () => { generation++; dialog.close(); });
  form.addEventListener('submit', event => {
    event.preventDefault();
    if (next.disabled || !options) return;
    const all = candidate.value === 'all';
    const selected = options.eligible.find(item => 'candidate:' + item.CandidateId === candidate.value);
    const mode = element('mode').value;
    const model = options.model;
    if ((!all && !selected) || !['Generation', 'Embedding'].includes(mode) ||
        modelInput.value.trim() !== options.requestedModel) return;
    const packages = all ? [...options.byHash.values()] : [options.byHash.get(selected.RuntimeSha256)];
    const args = {
      Inventory: options.inventory, ModelPath: model, BenchmarkMode: mode, WorkloadKey: mode === 'Embedding' ? 'sql-ai-embedding' : 'sql-ai-generation',
      Candidate: all ? options.candidates : selected, RuntimeDirectory: all ? packages : packages[0],
    };
    const commandName = all ? 'Measure-SqlServerLabAiComputeCandidateSet' : 'Measure-SqlServerLabAiComputeCandidate';
    const commands = publicCommandCatalog.filter(command => command?.Name === commandName);
    const command = commands.length === 1 ? commands[0] : null;
    const sets = Array.isArray(command?.ParameterSets) ? command.ParameterSets : [];
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    if (command?.RequiresConfirmation !== true || command?.SupportsShouldProcess !== true || typeof parameterSet?.Name !== 'string' ||
        fields.filter(field => field?.Mandatory === true).some(field => !Object.hasOwn(args, field.Name)) ||
        Object.keys(args).some(name => fields.filter(field => field?.Name === name && field.Sensitive === false && field.IsCredential === false).length !== 1)) {
      status.textContent = 'Die Messung ist auf diesem Host nicht verfügbar.';
      return;
    }
    const packageNames = packages.map(directory => directory.split(/[\\/]/).filter(Boolean).at(-1)).join(', ');
    const modelName = model.split(/[\\/]/).at(-1);
    const count = all ? options.eligible.length : 1;
    dialog.close();
    openConfirmation('llama.cpp-Benchmark starten',
      modelName + ' · Pakete: ' + packageNames + '. Vertraust du diesen Paketen? ' + count + ' Benchmark(s) mit je bis zu 900 Sekunden starten?',
      '__PublicCommand', { command, parameterSet, parameters: args }, 'Messung starten');
  });
})();
