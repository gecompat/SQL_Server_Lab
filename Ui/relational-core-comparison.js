'use strict';
(() => {
  const element = id => document.getElementById('relational-compare-' + id);
  const dialog = element('dialog');
  const form = element('form');
  const source = element('source');
  const target = element('target');
  const status = element('status');
  const next = element('next');
  const runIdPattern = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  const databasePattern = /^[A-Za-z][A-Za-z0-9_]{0,127}$/;
  let targets = new Map();

  function fillSelect(select, excluded = '') {
    select.replaceChildren(new Option('Instanz auswählen', ''));
    for (const [key, item] of targets) {
      if (key !== excluded) select.add(new Option(item.label, key));
    }
  }

  element('open').addEventListener('click', () => {
    form.reset();
    targets = new Map();
    const duplicates = new Set();
    for (const lab of workflow?.ActiveLabs || []) {
      if (lab.State !== 'RUNNING' || !runIdPattern.test(lab.RunId)) continue;
      for (const instance of lab.Instances || []) {
        if (!['docker', 'podman'].includes(instance.Provider) || typeof instance.Id !== 'string' || !instance.Id.trim()) continue;
        const key = lab.RunId.toLowerCase() + '/' + instance.Id.toLowerCase();
        if (targets.has(key)) duplicates.add(key);
        targets.set(key, { runId: lab.RunId, instanceId: instance.Id, label: [lab.Name || lab.RunId, instance.Id, instance.Provider].join(' · ') });
      }
    }
    for (const key of duplicates) targets.delete(key);
    fillSelect(source);
    fillSelect(target);
    next.disabled = targets.size < 2;
    status.textContent = next.disabled ? 'Die Übersicht enthält weniger als zwei laufende SQL-Containerinstanzen.' : '';
    dialog.showModal();
  });
  source.addEventListener('change', () => fillSelect(target, source.value));
  element('close').addEventListener('click', () => dialog.close());
  form.addEventListener('submit', event => {
    event.preventDefault();
    const sourceItem = targets.get(source.value);
    const targetItem = targets.get(target.value);
    const sourceName = element('source-name').value;
    const targetName = element('target-name').value;
    if (next.disabled || !sourceItem || !targetItem || sourceItem === targetItem ||
        !databasePattern.test(sourceName) || !databasePattern.test(targetName)) return;
    const candidates = publicCommandCatalog.filter(command => command?.Name === 'Test-SqlServerLabRelationalCoreComparison');
    const command = candidates.length === 1 ? candidates[0] : null;
    const sets = Array.isArray(command?.ParameterSets) ? command.ParameterSets : [];
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const required = (parameterSet?.Parameters || []).filter(field => field?.Mandatory === true);
    if (!command || typeof parameterSet?.Name !== 'string' || required.length !== 1 ||
        required[0].Name !== 'ComparisonPair' || required[0].TypeName !== 'System.Object[]' ||
        required[0].Sensitive !== false || required[0].IsCredential !== false) {
      status.textContent = 'Der Datenbankvergleich ist auf diesem Host nicht verfügbar.';
      return;
    }
    const pair = {
      PairId: 'GuidedComparison',
      SourceRunId: sourceItem.runId, SourceInstanceId: sourceItem.instanceId, SourceDatabaseName: sourceName,
      TargetRunId: targetItem.runId, TargetInstanceId: targetItem.instanceId, TargetDatabaseName: targetName,
    };
    dialog.close();
    openConfirmation('Containerdatenbanken vergleichen',
      'Quelle: ' + sourceItem.label + ' / ' + sourceName + '\nZiel: ' + targetItem.label + ' / ' + targetName + '\nDer Vergleich läuft lesend im Hintergrund.',
      '__PublicCommand', { command, parameterSet, parameters: { ComparisonPair: [pair] } }, 'Vergleich starten');
  });
})();
