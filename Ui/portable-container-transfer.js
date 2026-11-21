'use strict';
(() => {
  const element = id => document.getElementById('portable-transfer-' + id);
  const dialog = element('dialog');
  const form = element('form');
  const backup = element('backup');
  const target = element('target');
  const database = element('database');
  const intent = element('intent');
  const status = element('status');
  const next = element('next');
  const guid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  const instanceId = /^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$/;
  const isDatabaseName = name => /^[A-Za-z][A-Za-z0-9_]{0,127}$/.test(name) && !['master', 'model', 'msdb', 'tempdb'].includes(name.toLowerCase());
  const targetKey = (runId, id) => runId.toLowerCase() + '/' + id.toLowerCase();
  let preflight = false;
  let dataRoot = '';
  let instances = new Map();
  let backups = new Map();

  function open(asPreflight) {
    preflight = asPreflight;
    dataRoot = typeof workflow?.Defaults?.DataRoot === 'string' ? workflow.Defaults.DataRoot : '';
    instances = new Map();
    backups = new Map();
    const duplicates = new Set();
    for (const lab of workflow?.ActiveLabs || []) {
      if (lab.State !== 'RUNNING' || !guid.test(lab.RunId)) continue;
      for (const sql of lab.Instances || []) {
        if (!['docker', 'podman'].includes(sql.Provider) || typeof sql.Id !== 'string' || !instanceId.test(sql.Id)) continue;
        const key = targetKey(lab.RunId, sql.Id);
        if (instances.has(key)) duplicates.add(key);
        instances.set(key, { runId: lab.RunId, id: sql.Id, provider: sql.Provider, label: [lab.Name || lab.RunId, sql.Id, sql.Provider].join(' · ') });
      }
    }
    for (const key of duplicates) instances.delete(key);
    form.reset();
    backup.replaceChildren(new Option('Backup auswählen', ''));
    target.replaceChildren(new Option('Zielinstanz auswählen', ''));
    for (const item of workflow?.BackupLibrary || []) {
      if (item.Availability !== 'SELECTABLE' || item.SourceSqlMajorVersion !== '17' || item.HasFileStream || item.IsEncrypted ||
          typeof item.DatabaseName !== 'string' || !isDatabaseName(item.DatabaseName) || !guid.test(item.SourceRunId) ||
          typeof item.SourceInstanceId !== 'string' || !instanceId.test(item.SourceInstanceId) || !guid.test(item.BackupSetId) ||
          (!preflight && (typeof item.Bytes !== 'number' || item.Bytes > 256 * 1024 * 1024))) continue;
      const source = instances.get(targetKey(item.SourceRunId, item.SourceInstanceId));
      if (!source || source.provider !== item.SourceProvider || backups.has(item.BackupSetId)) continue;
      backups.set(item.BackupSetId, item);
      backup.add(new Option([item.DatabaseName, source.label, item.CreatedAt || item.BackupSetId].join(' · '), item.BackupSetId));
    }
    element('title').textContent = preflight ? 'Backupmedium am Zielcontainer vorprüfen' : 'SQL-2025-Datenbank in neuen Container übertragen';
    element('notice').textContent = preflight
      ? 'Das Backup wird vorübergehend am gebundenen Backup-Mount des bestehenden Ziels geprüft.'
      : 'Erstellt einen eigenen Ziel-Run beim selben Provider. Die Quelle muss ONLINE und READ_ONLY sein. Verwende bei einer Wiederaufnahme dieselbe Vorgangs-ID und dieselbe Auswahl.';
    element('target-field').hidden = !preflight;
    target.required = preflight;
    element('intent-field').hidden = preflight;
    intent.required = !preflight;
    intent.value = preflight ? '' : crypto.randomUUID();
    status.textContent = !dataRoot ? 'Richte zuerst den Lab_Data-Speicher ein.' :
      !backups.size ? 'Kein passendes registriertes SQL-2025-Backup eines laufenden Container-Runs gefunden.' : '';
    next.disabled = !dataRoot || !backups.size;
    dialog.showModal();
  }

  document.getElementById('portable-media-open').addEventListener('click', () => open(true));
  element('open').addEventListener('click', () => open(false));
  element('close').addEventListener('click', () => dialog.close());
  backup.addEventListener('change', () => {
    const item = backups.get(backup.value);
    database.value = item?.DatabaseName || '';
    target.replaceChildren(new Option('Zielinstanz auswählen', ''));
    if (!preflight || !item || !dataRoot) return;
    const source = targetKey(item.SourceRunId, item.SourceInstanceId);
    for (const [key, instance] of instances) if (key !== source) target.add(new Option(instance.label, key));
    status.textContent = target.options.length < 2 ? 'Die Vorprüfung benötigt einen weiteren laufenden Container.' : '';
  });

  form.addEventListener('submit', event => {
    event.preventDefault();
    const selected = backups.get(backup.value);
    if (next.disabled || !selected || !isDatabaseName(database.value)) return;
    const args = { DataRoot: dataRoot, SourceRunId: selected.SourceRunId, SourceInstanceId: selected.SourceInstanceId };
    const source = instances.get(targetKey(selected.SourceRunId, selected.SourceInstanceId));
    let message = 'Backup: ' + selected.DatabaseName + ' · ' + source.label + ' · ' + selected.BackupSetId + '\n';
    if (preflight) {
      const destination = instances.get(target.value);
      if (!destination || destination === source) return;
      args.TargetRunId = destination.runId;
      args.TargetInstanceId = destination.id;
      args.DatabaseTransfers = [{ SourceDatabaseName: selected.DatabaseName, TargetDatabaseName: database.value, BackupSetId: selected.BackupSetId }];
      message += 'Ziel: ' + destination.label + '\nBackup vorübergehend bereitstellen und prüfen?';
    } else {
      if (!guid.test(intent.value) || intent.value === '00000000-0000-0000-0000-000000000000') return;
      args.OperationId = intent.value;
      args.SourceDatabaseName = selected.DatabaseName;
      args.TargetDatabaseName = database.value;
      args.BackupSetId = selected.BackupSetId;
      message += 'Vorgangs-ID: ' + intent.value + '\nNeuen eigenen Run erstellen und das Backup als ' + database.value + ' übertragen?';
    }
    const name = preflight ? 'Invoke-SqlServerLabPortableContainerTransferPreflight' : 'Invoke-SqlServerLabPortableContainerTransfer';
    const candidates = publicCommandCatalog.filter(command => command?.Name === name);
    const command = candidates.length === 1 ? candidates[0] : null;
    const sets = Array.isArray(command?.ParameterSets) ? command.ParameterSets : [];
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const fields = (parameterSet?.Parameters || []).filter(field => field?.Mandatory === true);
    if (command?.RequiresConfirmation !== true || typeof parameterSet?.Name !== 'string' ||
        fields.length !== Object.keys(args).length || Object.keys(args).some(key =>
          fields.filter(field => field.Name === key && field.Sensitive === false && field.IsCredential === false).length !== 1)) {
      status.textContent = 'Der Auftrag ist auf diesem Host nicht verfügbar.';
      return;
    }
    dialog.close();
    openConfirmation(element('title').textContent, message, '__PublicCommand', { command, parameterSet, parameters: args },
      preflight ? 'Vorprüfung starten' : 'Transfer starten');
  });
})();
