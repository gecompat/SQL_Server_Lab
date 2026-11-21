'use strict';
(() => {
  const element = id => document.getElementById('persistent-fixture-' + id);
  const dialog = element('dialog');
  const form = element('form');
  const action = element('action');
  const target = element('target');
  const collection = element('collection');
  const resume = element('resume');
  const status = element('status');
  const next = element('next');
  const guid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  const actions = new Map([
    ['initial', { Action: 'Apply', FixtureRevision: 'Initial' }],
    ['delta', { Action: 'Apply', FixtureRevision: 'Delta' }],
    ['backup', { Action: 'Query', QueryId: 'backup' }],
    ['cleanup', { Action: 'Query', QueryId: 'cleanup' }],
    ['migrate', { Action: 'Migrate', FixtureRevision: 'Delta', TargetModelKey: 'ollama-nomic-embed-text-v2-moe' }],
  ]);
  let targets = new Map();
  let suggestedId = '';

  action.addEventListener('change', () => {
    const writes = actions.get(action.value)?.Action !== 'Query';
    element('resume-field').hidden = !writes;
    resume.checked = false;
    if (action.value !== 'initial' && collection.value === suggestedId) collection.value = '';
    if (action.value === 'initial' && !collection.value) collection.value = suggestedId;
  });
  element('open').addEventListener('click', () => {
    form.reset();
    suggestedId = crypto.randomUUID();
    collection.value = suggestedId;
    element('resume-field').hidden = false;
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
  form.addEventListener('submit', event => {
    event.preventDefault();
    const selected = targets.get(target.value);
    const step = actions.get(action.value);
    const collectionId = collection.value.toLowerCase();
    if (next.disabled || !selected || !step || !guid.test(collectionId) || collectionId === '00000000-0000-0000-0000-000000000000') return;
    const args = { ...step, CollectionId: collectionId, RunId: selected.RunId, InstanceId: selected.InstanceId };
    if (step.Action !== 'Query' && resume.checked) args.Resume = true;
    const commands = publicCommandCatalog.filter(command => command?.Name === 'Invoke-SqlServerLabAiPersistentRetrieval');
    const command = commands.length === 1 ? commands[0] : null;
    const sets = Array.isArray(command?.ParameterSets) ? command.ParameterSets : [];
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    if (command?.RequiresConfirmation !== true || typeof parameterSet?.Name !== 'string' ||
        fields.filter(field => field?.Mandatory === true).some(field => !Object.hasOwn(args, field.Name)) ||
        Object.keys(args).some(name => fields.filter(field => field?.Name === name && field.Sensitive === false && field.IsCredential === false).length !== 1)) {
      status.textContent = 'Die Retrieval-Demo ist auf diesem Host nicht verfügbar.';
      return;
    }
    const label = action.selectedOptions[0]?.text || step.Action;
    dialog.close();
    openConfirmation(label, 'Ziel: ' + selected.label + '\nCollection-ID: ' + collectionId + '\nVerwendet feste Beispieldaten und das lokale Ollama.',
      '__PublicCommand', { command, parameterSet, parameters: args }, 'Schritt starten');
  });
})();
