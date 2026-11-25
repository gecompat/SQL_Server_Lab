'use strict';

function confirmContainerLibraryBackup(runId, instanceId, databaseName, password) {
  const matches = (workflow?.ActiveLabs || []).filter(lab => lab.RunId === runId && lab.State === 'RUNNING');
  const instances = matches.length === 1 && Array.isArray(matches[0].Instances)
    ? matches[0].Instances.filter(instance => instance.Id === instanceId) : [];
  if (instances.length !== 1 || !['docker', 'podman'].includes(instances[0].Provider) ||
      !/^[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/.test(runId) || !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(instanceId)) {
    showError(new Error('Die laufende Container-Instanz ist nicht eindeutig gebunden. Lies die Lab-Übersicht erneut.'));
    return;
  }
  if (!/^[A-Za-z][A-Za-z0-9_]{0,127}$/.test(databaseName) || !password || password.length > 128) {
    showError(new Error('Gib einen gültigen Datenbanknamen und das SA-Passwort an.'));
    return;
  }
  const dataRoot = workflow?.Defaults?.DataRoot;
  if (typeof dataRoot !== 'string' || !dataRoot.trim() || dataRoot.length > 2048) {
    showError(new Error('Wähle zuerst ein registriertes Lab_Data unter Pfade und Medienquellen.'));
    return;
  }
  const commands = publicCommandCatalog.filter(command => command?.Name === 'Backup-SqlServerLabDatabase');
  const command = commands.length === 1 ? commands[0] : null;
  const sets = Array.isArray(command?.ParameterSets) ? command.ParameterSets.filter(set => set?.Name === 'RunBased') : [];
  const parameterSet = sets.length === 1 ? sets[0] : null;
  const descriptors = Array.isArray(parameterSet?.Parameters) ? parameterSet.Parameters : [];
  const fields = [
    ['RunId', 'System.String', true, false], ['InstanceId', 'System.String', false, false],
    ['DatabaseName', 'System.String', true, false], ['SaPassword', 'System.Security.SecureString', true, true],
    ['DataRoot', 'System.String', false, false]
  ];
  const safeParameters = fields.every(([name, type, mandatory, sensitive]) => {
    const entries = descriptors.filter(item => item?.Name === name);
    return entries.length === 1 && entries[0].TypeName === type && entries[0].Mandatory === mandatory &&
      entries[0].Sensitive === sensitive && entries[0].IsCredential === false;
  });
  if (command?.RequiresConfirmation !== true || command.SupportsShouldProcess !== true || !safeParameters ||
      descriptors.filter(item => item?.Mandatory === true).length !== 3) {
    showError(new Error('Die geführte Sicherung ist in diesem Laufzeitprofil nicht verfügbar.'));
    return;
  }
  $('#container-operation-password').value = '';
  $('#container-operation-dialog').close();
  openConfirmation('Verifiziertes Backup erstellen',
    sqlOperationTargetSummary(runId, instanceId, 'container') + ' · Datenbank: ' + databaseName +
    ' · Die geprüfte Sicherung wird im konfigurierten Lab_Data eingetragen.',
    '__PublicCommand', { command, parameterSet, parameters: { RunId: runId, InstanceId: instanceId, DatabaseName: databaseName, SaPassword: password, DataRoot: dataRoot } },
    'Backup erstellen');
}
