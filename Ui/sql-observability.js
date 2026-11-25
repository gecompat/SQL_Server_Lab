'use strict';

function confirmContainerSqlObservability(runId, instanceId, password) {
  const matches = (workflow?.ActiveLabs || []).filter(lab => lab.RunId === runId && lab.State === 'RUNNING');
  const instances = matches.length === 1 && Array.isArray(matches[0].Instances)
    ? matches[0].Instances.filter(instance => instance.Id === instanceId) : [];
  if (instances.length !== 1 || !['docker', 'podman'].includes(instances[0].Provider) ||
      !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(runId) || !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(instanceId)) {
    showError(new Error('Die laufende Container-Instanz ist nicht eindeutig gebunden. Lies die Lab-Übersicht erneut.'));
    return;
  }
  if (!password || password.length > 128) {
    showError(new Error('Gib das SA-Passwort für diese Instanz ein.'));
    return;
  }
  const commands = publicCommandCatalog.filter(command => command?.Name === 'Get-SqlServerLabSqlObservabilityEvidence');
  const command = commands.length === 1 ? commands[0] : null;
  const sets = Array.isArray(command?.ParameterSets) ? command.ParameterSets.filter(set => set?.Name === 'RunBased') : [];
  const parameterSet = sets.length === 1 ? sets[0] : null;
  const descriptors = Array.isArray(parameterSet?.Parameters) ? parameterSet.Parameters : [];
  const fields = [
    ['RunId', 'System.String', true, false],
    ['InstanceId', 'System.String', false, false],
    ['SaPassword', 'System.Security.SecureString', true, true]
  ];
  const bound = fields.every(([name, type, mandatory, sensitive]) => {
    const items = descriptors.filter(item => item?.Name === name);
    return items.length === 1 && items[0].TypeName === type && items[0].Mandatory === mandatory &&
      items[0].Sensitive === sensitive && items[0].IsCredential === false;
  });
  if (!bound || descriptors.filter(item => item?.Mandatory === true).length !== 2) {
    showError(new Error('Die geführte Metrikabfrage ist in diesem Laufzeitprofil nicht verfügbar.'));
    return;
  }
  $('#container-operation-password').value = '';
  $('#container-operation-dialog').close();
  openConfirmation('SQL-Betriebsmetriken lesen',
    sqlOperationTargetSummary(runId, instanceId, 'container') + ' · Die Abfrage liest aggregierte SQL-Werte.',
    '__PublicCommand', { command, parameterSet, parameters: { RunId: runId, InstanceId: instanceId, SaPassword: password } }, 'Metriken lesen');
}
