'use strict';
(() => {
  const element = id => document.getElementById('sql-guest-evidence-' + id);
  const dialog = element('dialog');
  const run = element('run');
  const next = element('next');
  const status = element('status');
  const runIdPattern = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  element('open').addEventListener('click', () => {
    run.replaceChildren(new Option('Laufendes SQL-2025-Lab auswählen', ''));
    for (const lab of workflow?.HyperVLabs || []) {
      if (lab.State === 'RUNNING' && lab.VMState === 'Running' && lab.Workload === 'sql' &&
          String(lab.SqlVersion) === '2025' && runIdPattern.test(lab.RunId)) {
        run.add(new Option(lab.Name || lab.RunId, lab.RunId));
      }
    }
    status.textContent = run.options.length > 1 ? '' : 'Aktuell ist kein passendes laufendes Hyper-V-Lab in der Übersicht.';
    next.disabled = true;
    dialog.showModal();
  });
  run.addEventListener('change', () => { next.disabled = !runIdPattern.test(run.value); });
  element('close').addEventListener('click', () => dialog.close());
  next.addEventListener('click', () => {
    if (next.disabled || !runIdPattern.test(run.value)) return;
    const candidates = publicCommandCatalog.filter(item => item?.Name === 'Update-SqlServerLabSqlGuestEvaluationEvidence');
    const command = candidates.length === 1 ? candidates[0] : null;
    const sets = Array.isArray(command?.ParameterSets) ? command.ParameterSets : [];
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const required = (parameterSet?.Parameters || []).filter(item => item?.Mandatory === true);
    if (command?.RequiresConfirmation !== true || typeof parameterSet?.Name !== 'string' || required.length !== 1 ||
        required[0].Name !== 'RunId' || required[0].TypeName !== 'System.Guid' ||
        required[0].Sensitive !== false || required[0].IsCredential !== false) {
      status.textContent = 'Die geführte Aktualisierung ist auf diesem Host nicht verfügbar.';
      return;
    }
    const runId = run.value;
    const label = run.selectedOptions[0]?.text || runId;
    dialog.close();
    openConfirmation(
      'SQL-Editionsbeleg aktualisieren',
      'Die Edition von ' + label + ' wird im gebundenen Gast gelesen. Der Auftrag ersetzt den lokalen Editionsbeleg dieses Runs.',
      '__PublicCommand',
      { command, parameterSet, parameters: { RunId: runId } },
      'Beleg aktualisieren'
    );
  });
})();
