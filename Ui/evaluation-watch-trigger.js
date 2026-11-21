'use strict';
(() => {
  const element = id => document.getElementById('evaluation-trigger-' + id);
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
    const interval = element('interval').valueAsNumber;
    const count = element('count').valueAsNumber;
    if (!Number.isInteger(interval) || interval < 1 || interval > 86400 ||
        !Number.isInteger(count) || count < 1 || count > 1440) return;

    const candidates = publicCommandCatalog.filter(command => command?.Name === 'Invoke-SqlServerLabEvaluationWatchTrigger');
    const command = candidates.length === 1 ? candidates[0] : null;
    const sets = Array.isArray(command?.ParameterSets) ? command.ParameterSets : [];
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const descriptors = parameterSet?.Parameters || [];
    const expectedTypes = { IntervalSeconds: 'System.Int32', MaximumChecks: 'System.Int32', RecordEvents: 'System.Management.Automation.SwitchParameter' };
    const schemaMatches = Object.entries(expectedTypes).every(([name, type]) => {
      const fields = descriptors.filter(field => field?.Name === name);
      return fields.length === 1 && fields[0].TypeName === type && fields[0].Sensitive === false && fields[0].IsCredential === false;
    });
    if (command?.RequiresConfirmation !== true || typeof parameterSet?.Name !== 'string' ||
        descriptors.some(field => field?.Mandatory === true) || !schemaMatches) {
      status.textContent = 'Die zeitgesteuerte Prüfung ist auf diesem Host nicht verfügbar.';
      return;
    }

    const record = element('record').checked;
    const parameters = { IntervalSeconds: String(interval), MaximumChecks: String(count) };
    if (record) parameters.RecordEvents = true;
    const wait = ((count - 1) * interval).toLocaleString('de-AT');
    const effect = record ? 'Neue Warnereignisse werden lokal gespeichert.' : 'Die Prüfungen lesen nur gespeicherte Fristen.';
    dialog.close();
    openConfirmation('Fristen zeitgesteuert prüfen', `${count} Prüfungen mit insgesamt ${wait} Sekunden Wartezeit. ${effect}`,
      '__PublicCommand', { command, parameterSet, parameters }, 'Prüfungen starten');
  });
})();
