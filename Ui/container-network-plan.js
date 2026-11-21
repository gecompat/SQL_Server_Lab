'use strict';
(() => {
  const element = id => document.getElementById('container-network-plan-' + id);
  const dialog = element('dialog');
  const form = element('form');
  const status = element('status');
  element('open').addEventListener('click', () => {
    form.reset();
    status.textContent = '';
    dialog.showModal();
  });
  element('close').addEventListener('click', () => dialog.close());
  form.addEventListener('submit', event => {
    event.preventDefault();
    const provider = element('provider').value;
    if (!['docker', 'podman'].includes(provider)) return;
    const commands = publicCommandCatalog.filter(command => command?.Name === 'Move-SqlServerLabContainerNetwork');
    const command = commands.length === 1 ? commands[0] : null;
    const sets = Array.isArray(command?.ParameterSets) ? command.ParameterSets : [];
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    const providerFields = fields.filter(field => field?.Name === 'Provider');
    const previewFields = fields.filter(field => field?.Name === 'WhatIf');
    if (command?.SupportsShouldProcess !== true || command?.RequiresConfirmation !== true ||
        typeof parameterSet?.Name !== 'string' || fields.filter(field => field?.Mandatory === true).length !== 1 ||
        providerFields.length !== 1 || providerFields[0].Mandatory !== true || providerFields[0].TypeName !== 'System.String' ||
        previewFields.length !== 1 || previewFields[0].Mandatory !== false ||
        previewFields[0].TypeName !== 'System.Management.Automation.SwitchParameter' ||
        [...providerFields, ...previewFields].some(field => field.Sensitive !== false || field.IsCredential !== false)) {
      status.textContent = 'Die Netzvorschau ist auf diesem Host nicht verfügbar.';
      return;
    }
    dialog.close();
    openConfirmation('Lab-Netz prüfen', 'Vorhandenes ' + provider + '-Lab-Netz lesend prüfen? Der Befund erscheint im Live-Log.',
      '__PublicCommand', { command, parameterSet, parameters: { Provider: provider, WhatIf: true } }, 'Vorschau starten');
  });
})();
