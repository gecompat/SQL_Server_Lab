'use strict';
(() => {
  const element = id => document.getElementById('persistent-fixture-' + id);
  const dialog = element('dialog');
  const form = element('form');
  const action = element('action');
  const target = element('target');
  const collection = element('collection');
  const resume = element('resume');
  const retention = element('retention');
  const documentFile = element('document');
  const status = element('status');
  const next = element('next');
  const guid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  const actions = new Map([
    ['initial', { Action: 'Apply', FixtureRevision: 'Initial' }],
    ['delta', { Action: 'Apply', FixtureRevision: 'Delta' }],
    ['backup', { Action: 'Query', QueryId: 'backup' }],
    ['cleanup', { Action: 'Query', QueryId: 'cleanup' }],
    ['migrate', { Action: 'Migrate', FixtureRevision: 'Delta', TargetModelKey: 'ollama-nomic-embed-text-v2-moe' }],
    ['own-apply', { Action: 'Apply' }],
    ['own-query', { Action: 'Query' }],
    ['own-sync', { Action: 'Sync' }],
    ['own-migrate', { Action: 'Migrate', TargetModelKey: 'ollama-nomic-embed-text-v2-moe' }],
    ['prune', { Action: 'Prune' }],
    ['remove', { Action: 'Remove' }],
  ]);
  let targets = new Map();
  let suggestedId = '';
  const canResume = name => ['Apply', 'Migrate', 'Sync'].includes(name);
  const createsCollection = name => ['initial', 'own-apply'].includes(name);
  const readDocuments = async (file, name) => {
    if (!file || !/\.json$/i.test(file.name) || file.size < 1 || file.size > 512 * 1024) throw new Error();
    const bytes = await file.arrayBuffer();
    if (bytes.byteLength !== file.size) throw new Error();
    const payload = JSON.parse(new TextDecoder('utf-8', { fatal: true }).decode(bytes));
    const required = ['Documents'];
    if (name === 'Sync') required.push('ExpectedDocuments');
    if (name === 'Query') required.push('Question');
    const allowed = name === 'Migrate' ? required : [...required, 'EmbeddingModelKey'];
    if (!payload || Array.isArray(payload) || typeof payload !== 'object' ||
        required.some(key => !Object.hasOwn(payload, key)) || Object.keys(payload).some(key => !allowed.includes(key))) throw new Error();
    for (const key of required.filter(key => key !== 'Question')) {
      const documents = payload[key];
      if (!Array.isArray(documents) || documents.length < 1 || documents.length > 16) throw new Error();
      const ids = new Set();
      for (const document of documents) {
        if (!document || typeof document !== 'object' || Object.keys(document).length !== 2 ||
            !Object.hasOwn(document, 'Id') || !Object.hasOwn(document, 'Content') ||
            typeof document.Id !== 'string' || !/^[a-z][a-z0-9-]{2,95}$/i.test(document.Id) || ids.has(document.Id) ||
            typeof document.Content !== 'string' || !document.Content.trim() || document.Content.length > 4000) throw new Error();
        ids.add(document.Id);
      }
    }
    if (name === 'Query' && (typeof payload.Question !== 'string' || !payload.Question.trim() || payload.Question.length > 1000)) throw new Error();
    if (Object.hasOwn(payload, 'EmbeddingModelKey') && (typeof payload.EmbeddingModelKey !== 'string' || !/^ollama-[a-z0-9-]{1,64}$/.test(payload.EmbeddingModelKey))) throw new Error();
    return payload;
  };

  const updateAction = () => {
    const selectedAction = actions.get(action.value)?.Action;
    const own = action.value?.startsWith('own-') === true;
    element('resume-field').hidden = !canResume(selectedAction);
    element('retention-field').hidden = selectedAction !== 'Prune';
    retention.disabled = selectedAction !== 'Prune';
    element('document-field').hidden = !own;
    documentFile.disabled = !own;
    documentFile.value = '';
    element('document-help').textContent = 'Documents' +
      (selectedAction === 'Sync' ? ' und ExpectedDocuments' : selectedAction === 'Query' ? ' und Question' : '') +
      (selectedAction === 'Migrate' ? '.' : ', optional EmbeddingModelKey.');
    status.textContent = '';
    resume.checked = false;
    if (!createsCollection(action.value) && collection.value === suggestedId) collection.value = '';
    if (createsCollection(action.value) && !collection.value) collection.value = suggestedId;
  };
  action.addEventListener('change', updateAction);
  element('open').addEventListener('click', () => {
    form.reset();
    suggestedId = crypto.randomUUID();
    collection.value = suggestedId;
    updateAction();
    targets = new Map();
    const duplicates = new Set();
    for (const lab of workflow?.ActiveLabs || []) {
      if (lab.State !== 'RUNNING' || !guid.test(lab.RunId)) continue;
      for (const sql of lab.Instances || []) {
        if (!['docker', 'podman'].includes(sql.Provider) || !/^2025(?:[-_]|$)/.test(sql.SqlVersion) ||
            typeof sql.Id !== 'string' || !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(sql.Id)) continue;
        const key = lab.RunId.toLowerCase() + '/' + sql.Id.toLowerCase();
        if (targets.has(key)) duplicates.add(key);
        targets.set(key, { RunId: lab.RunId.toLowerCase(), InstanceId: sql.Id, label: [lab.Name || lab.RunId, sql.Id, sql.Provider].join(' · ') });
      }
    }
    for (const key of duplicates) targets.delete(key);
    target.replaceChildren(new Option('SQL-2025-Instanz wählen', ''));
    for (const [key, choice] of targets) target.add(new Option(choice.label, key));
    status.textContent = targets.size ? '' : 'Es ist kein laufender SQL-2025-Container registriert.';
    next.disabled = !targets.size;
    dialog.showModal();
  });
  element('close').addEventListener('click', () => dialog.close());
  form.addEventListener('submit', async event => {
    event.preventDefault();
    const selected = targets.get(target.value);
    const step = actions.get(action.value);
    const actionKey = action.value;
    const targetKey = target.value;
    const requestedResume = resume.checked;
    const collectionId = collection.value.toLowerCase();
    if (next.disabled || !selected || !step || !guid.test(collectionId) || collectionId === '00000000-0000-0000-0000-000000000000') return;
    const args = { ...step, CollectionId: collectionId, RunId: selected.RunId, InstanceId: selected.InstanceId };
    if (canResume(step.Action) && requestedResume) args.Resume = true;
    if (step.Action === 'Prune') {
      if (!/^(?:[1-9]|[12][0-9]|3[01])$/.test(retention.value)) return;
      args.KeepGenerations = Number(retention.value);
    }
    if (actionKey.startsWith('own-')) {
      const file = documentFile.files?.[0];
      next.disabled = true;
      try {
        const payload = await readDocuments(file, step.Action);
        if (!dialog.open || action.value !== actionKey || target.value !== targetKey || resume.checked !== requestedResume ||
            collection.value.toLowerCase() !== collectionId || documentFile.files?.[0] !== file) return;
        Object.assign(args, payload);
      } catch {
        if (dialog.open && action.value === actionKey) status.textContent = 'Die JSON-Datei ist ungültig. Prüfe die erforderlichen Felder, Werte und die Größe.';
        return;
      } finally {
        next.disabled = !targets.size;
      }
    }
    const commands = publicCommandCatalog.filter(command => command?.Name === 'Invoke-SqlServerLabAiPersistentRetrieval');
    const command = commands.length === 1 ? commands[0] : null;
    const sets = Array.isArray(command?.ParameterSets) ? command.ParameterSets : [];
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    if (command?.RequiresConfirmation !== true || typeof parameterSet?.Name !== 'string' ||
        fields.filter(field => field?.Mandatory === true).some(field => !Object.hasOwn(args, field.Name)) ||
        Object.keys(args).some(name => fields.filter(field => field?.Name === name && field.Sensitive === false && field.IsCredential === false).length !== 1)) {
      status.textContent = 'Der Retrieval-Schritt ist auf diesem Host nicht verfügbar.';
      return;
    }
    const label = action.selectedOptions[0]?.text || step.Action;
    const effect = args.Documents ? {
      Apply: args.Documents.length + ' eigene Dokumente als neue Collection schreiben.',
      Query: 'Freie Frage für die gebundene Collection mit ' + args.Documents.length + ' Dokumenten stellen.',
      Sync: 'Erwarteten Bestand von ' + args.ExpectedDocuments?.length + ' Dokumenten prüfen und durch ' + args.Documents.length + ' Dokumente ersetzen.',
      Migrate: args.Documents.length + ' eigene Dokumente neu einbetten und auf Nomic Embed v2 umstellen.',
    }[step.Action] : ({
      Prune: 'Die jüngsten ' + args.KeepGenerations + ' Generationen bleiben erhalten. Ältere Generationen werden dauerhaft gelöscht. Die aktive Generation bleibt erhalten.',
      Remove: 'Die gesamte Collection-Datenbank mit allen Dokumenten und Generationen wird dauerhaft gelöscht.',
    }[step.Action] || 'Verwendet feste Beispieldaten und das lokale Ollama.');
    dialog.close();
    openConfirmation(label, 'Ziel: ' + selected.label + '\nRun-ID: ' + selected.RunId + '\nCollection-ID: ' + collectionId + '\n' + effect +
      (args.Resume ? '\nBereits begonnener Auftrag wird mit derselben Collection-ID fortgesetzt.' : ''),
      '__PublicCommand', { command, parameterSet, parameters: args }, ['Prune', 'Remove'].includes(step.Action) ? 'Dauerhaft löschen' : 'Schritt starten');
  });
})();
