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

(function () {
  'use strict';
  if (!document.getElementById?.('hyperv-library-restore-dialog')) return;
  const $ = selector => document.querySelector(selector);
  let hypervLibraryRestoreTarget = null;
  const operations = {
    restore: { title:'Bibliotheksbackup in Hyper-V wiederherstellen', database:'Neue Zieldatenbank',
      confirm:'In diese neue Datenbank wiederherstellen', submit:'Wiederherstellung starten',
      action:'RestoreHyperVLibraryBackup', path:'/api/hyperv/library-restore' },
    backup: { title:'Verifiziertes Hyper-V-Backup erstellen', database:'Quelldatenbank',
      confirm:'Geprüftes Backup in Lab_Data speichern', submit:'Backup erstellen',
      action:'BackupHyperVLibraryDatabase', path:'/api/hyperv/library-backup' },
    create: { title:'Hyper-V-Datenbank anlegen', database:'Name der neuen Datenbank',
      confirm:'Datenbank auf der angezeigten Instanz mit verifiziertem Speicher anlegen', submit:'Datenbank anlegen',
      action:'CreateHyperVLabDatabase', path:'/api/hyperv/database-create' }
  };

  function getHyperVWindowsScriptTarget(runId, instanceId) {
    const matches = (workflow?.HyperVLabs || []).filter(item => item.RunId === runId && item.InstanceId === instanceId);
    const target = matches.length === 1 ? matches[0] : null;
    return target?.State === 'RUNNING' && target.VMState === 'Running' && target.Workload === 'sql' &&
      target.SqlCompletionState === 'COMPLETE' && ['2019','2022','2025'].includes(String(target.SqlVersion)) ? target : null;
  }

  function confirmHyperVWindowsScript() {
    const runId = $('#container-operation-run').value;
    const instanceId = $('#container-operation-instance').value;
    const scriptPath = $('#container-script-path').value.trim();
    const database = $('#container-script-database').value.trim() || 'master';
    if (!getHyperVWindowsScriptTarget(runId, instanceId)) {
      showError(new Error('Die ausgewählte Hyper-V-SQL-Instanz ist nicht bereit. Öffne die Auswahl erneut.'));
      return;
    }
    if (!/^[A-Za-z]:[\\/][^\r\n]+\.sql$/i.test(scriptPath) || !/^[A-Za-z][A-Za-z0-9_]{0,127}$/.test(database)) {
      showError(new Error('Gib einen absoluten lokalen SQL-Dateipfad und einen gültigen Datenbanknamen ein.'));
      return;
    }
    const commands = publicCommandCatalog.filter(command => command.Name === 'Invoke-SqlServerLabScript');
    const command = commands.length === 1 ? commands[0] : null;
    const sets = (command?.ParameterSets || []).filter(set => set.Name === 'RunWindows');
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const descriptors = parameterSet?.Parameters || [];
    const fields = [['RunId','System.String',true],['InstanceId','System.String',false],['ScriptPath','System.String',true],
      ['Database','System.String',false],['WindowsAuthentication','System.Management.Automation.SwitchParameter',true]];
    const bound = fields.every(([name,type,required]) => {
      const matches = descriptors.filter(field => field.Name === name);
      return matches.length === 1 && matches[0].TypeName === type && matches[0].Mandatory === required &&
        matches[0].Sensitive === false && matches[0].IsCredential === false;
    });
    if (command?.RequiresConfirmation !== true || command.SupportsShouldProcess !== true || !bound ||
        descriptors.filter(field => field.Mandatory === true).length !== 3) {
      showError(new Error('Die gebundene Windows-Skriptausführung ist auf diesem Host nicht verfügbar.'));
      return;
    }
    $('#container-operation-dialog').close();
    openConfirmation('SQL-Skript im Hyper-V-Gast ausführen',
      sqlOperationTargetSummary(runId, instanceId, 'hyperv') + ' · Datenbank: ' + database + ' · Datei: ' + scriptPath,
      '__PublicCommand', { command, parameterSet, parameters: { RunId:runId, InstanceId:instanceId,
        ScriptPath:scriptPath, Database:database, WindowsAuthentication:true } }, 'Skript ausführen');
  }

  function getHyperVLibraryRestoreMajor(sqlVersion) {
    const year = String(sqlVersion || '').match(/^\d{4}(?=-|$)/)?.[0];
    return ({2016:13,2017:14,2019:15,2022:16,2025:17})[year] || 0;
  }

  function getHyperVLibraryRestoreTarget(runId, instanceId) {
    const matches = (workflow?.HyperVLabs || []).filter(item => item.RunId === runId);
    const target = matches.length === 1 ? matches[0] : null;
    if (!target || target.InstanceId !== instanceId || target.State !== 'RUNNING' || target.VMState !== 'Running' ||
        target.Workload !== 'sql' || target.SqlCompletionState !== 'COMPLETE' ||
        !getHyperVLibraryRestoreMajor(target.SqlVersion)) return null;
    return target;
  }

  function openHyperVLibraryOperation(runId, instanceId, mode) {
    const target = getHyperVLibraryRestoreTarget(runId, instanceId);
    const dialog = $('#hyperv-library-restore-dialog');
    if (dialog.open || !target) return;
    $('#hyperv-library-restore-form').reset();
    const restore = mode === 'restore';
    const operation = operations[mode];
    hypervLibraryRestoreTarget = { RunId:runId, InstanceId:instanceId, VmName:target.VMName, SqlVersion:target.SqlVersion, mode };
    $('#hyperv-library-restore-title').textContent = operation.title;
    $('#hyperv-library-restore-backup-row').hidden = !restore;
    $('#hyperv-library-restore-backup').required = restore;
    $('#hyperv-library-restore-backup').disabled = !restore;
    $('#hyperv-library-restore-database-label').textContent = operation.database;
    $('#hyperv-library-restore-confirm-label').textContent = operation.confirm;
    $('#hyperv-library-restore-submit').textContent = operation.submit;
    const major = getHyperVLibraryRestoreMajor(target.SqlVersion);
    const choices = (restore ? workflow?.BackupLibrary || [] : []).filter(backup => backup.Availability === 'SELECTABLE' && backup.IsEncrypted !== true &&
      Number(backup.SourceSqlMajorVersion) >= 13 && Number(backup.SourceSqlMajorVersion) <= major);
    const select = $('#hyperv-library-restore-backup');
    select.replaceChildren(new Option('Backup auswählen',''));
    for (const backup of choices) select.add(new Option(
      backup.DatabaseName + ' · ' + backup.SourceProvider + ' · SQL ' + backup.SourceSqlMajorVersion, backup.BackupSetId));
    $('#hyperv-library-restore-target').textContent = sqlOperationTargetSummary(runId, instanceId, 'hyperv');
    $('#hyperv-library-restore-status').textContent = restore && !choices.length ? 'Kein auswählbares Backup für diese SQL-Version.' : '';
    dialog.showModal();
  }

  $('#hyperv-library-restore-close').addEventListener('click', () => $('#hyperv-library-restore-dialog').close());
  $('#hyperv-library-restore-dialog').addEventListener('close', () => {
    $('#hyperv-library-restore-form').reset();
    hypervLibraryRestoreTarget = null;
  });
  $('#hyperv-library-restore-form').addEventListener('input', event => {
    if (event.target !== $('#hyperv-library-restore-confirm')) $('#hyperv-library-restore-confirm').checked = false;
    if (event.target === $('#hyperv-library-restore-backup')) {
      const backup = (workflow?.BackupLibrary || []).find(item => item.BackupSetId === event.target.value);
      $('#hyperv-library-restore-database').value = backup?.DatabaseName || '';
    }
  });
  $('#hyperv-library-restore-form').addEventListener('submit', event => {
    event.preventDefault();
    const form = event.currentTarget || $('#hyperv-library-restore-form');
    const dialog = $('#hyperv-library-restore-dialog');
    if (!dialog.open || !hypervLibraryRestoreTarget || !form.reportValidity() || !$('#hyperv-library-restore-confirm').checked) return;
    const { RunId, InstanceId, VmName, SqlVersion, mode } = hypervLibraryRestoreTarget;
    const restore = mode === 'restore';
    const target = getHyperVLibraryRestoreTarget(RunId, InstanceId);
    const BackupSetId = $('#hyperv-library-restore-backup').value;
    const major = getHyperVLibraryRestoreMajor(SqlVersion);
    const backups = (workflow?.BackupLibrary || []).filter(backup =>
      backup.BackupSetId === BackupSetId && backup.Availability === 'SELECTABLE' && backup.IsEncrypted !== true &&
      Number(backup.SourceSqlMajorVersion) >= 13 && Number(backup.SourceSqlMajorVersion) <= major);
    if (!target || target.VMName !== VmName || target.SqlVersion !== SqlVersion || (restore && backups.length !== 1)) {
      $('#hyperv-library-restore-status').textContent = 'Ziel oder Backup hat sich geändert. Öffne die Auswahl erneut.';
      return;
    }
    const parameters = { RunId, InstanceId, DatabaseName:$('#hyperv-library-restore-database').value.trim(),
      GuestUserName:$('#hyperv-library-restore-user').value.trim(),
      GuestPassword:$('#hyperv-library-restore-guest-password').value, SaPassword:$('#hyperv-library-restore-sa-password').value };
    dialog.close();
    $('#hyperv-library-restore-guest-password').value = '';
    $('#hyperv-library-restore-sa-password').value = '';
    if (restore) parameters.BackupSetId = BackupSetId;
    const { action, path } = operations[mode];
    submitUiAction(action, path, { parameters, confirmed:true }).catch(showError);
  });

  function renderActions(item, runningSql) {
    if (!runningSql || item.SqlCompletionState !== 'COMPLETE' || !item.InstanceId) return '';
    const target = ' data-run="' + escapeHtml(item.RunId) + '" data-instance="' + escapeHtml(item.InstanceId) + '"';
    return '<button class="button secondary" data-hyperv-database-create="true"' + target + '>Datenbank anlegen</button>' +
      '<button class="button secondary" data-hyperv-library-backup="true"' + target + '>Verifiziertes Backup erstellen</button>' +
      '<button class="button secondary" data-hyperv-library-restore="true"' + target + '>Bibliotheksbackup wiederherstellen</button>';
  }

  function handleClick(element) {
    const button = element.closest('[data-hyperv-database-create], [data-hyperv-library-backup], [data-hyperv-library-restore]');
    if (!button) return false;
    const mode = button.dataset.hypervDatabaseCreate === 'true' ? 'create' :
      (button.dataset.hypervLibraryBackup === 'true' ? 'backup' : 'restore');
    openHyperVLibraryOperation(button.dataset.run, button.dataset.instance, mode);
    return true;
  }

  window.sqlServerLabHyperVLibraryRestore = Object.freeze({
    getWindowsScriptTarget: getHyperVWindowsScriptTarget,
    confirmWindowsScript: confirmHyperVWindowsScript,
    renderActions,
    handleClick,
    open: (runId, instanceId) => openHyperVLibraryOperation(runId, instanceId, 'restore'),
    openBackup: (runId, instanceId) => openHyperVLibraryOperation(runId, instanceId, 'backup')
  });
})();
