'use strict';
(() => {
  const element = id => document.querySelector('#resource-plan-' + id);
  const dialog = element('dialog');
  const form = element('form');
  const kind = element('kind');
  const status = element('status');
  element('open').addEventListener('click', () => {
    kind.value = 'All';
    status.textContent = '';
    dialog.showModal();
  });
  element('close').addEventListener('click', () => dialog.close());
  form.addEventListener('submit', event => {
    event.preventDefault();
    if (!['All', 'Sample', 'Software'].includes(kind.value)) return;
    const matches = publicCommandCatalog.filter(command => command?.Name === 'Get-SqlServerLabResourcePlan');
    const command = matches.length === 1 ? matches[0] : null;
    const sets = command?.ParameterSets;
    const parameterSet = Array.isArray(sets) && sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    const parameters = { ResourceKind: kind.value, SummaryOnly: true };
    if (typeof parameterSet?.Name !== 'string' || fields.some(field => field?.Mandatory === true) ||
        Object.keys(parameters).some(name => fields.filter(field => field?.Name === name && field.Sensitive === false && field.IsCredential === false).length !== 1)) {
      status.textContent = 'Die Ressourcenprüfung ist auf diesem Host nicht verfügbar.';
      return;
    }
    const selection = kind.selectedOptions?.[0]?.text || 'Ressourcenauswahl';
    dialog.close();
    openConfirmation('Lokalen Ressourcenbedarf prüfen',
      selection + '. Die Prüfung liest die konfigurierten Speicherorte. Das Ergebnis steht unter Vorgänge.',
      '__PublicCommand', { command, parameterSet, parameters }, 'Prüfung starten');
  });
})();
