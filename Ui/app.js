let workflow = null;
let activeJobCount = 0;
let optimisticJobs = [];
const jobLineCache = {};
let uiConfig = { jobLogBurstLimit: 300 };
let workflowRefreshTimer = null;
let pendingPersistentStorageRemoval = null;
let pendingDatabasePackageAttach = null;
let pendingHyperVPersistentData = null;

const $ = (selector) => document.querySelector(selector);
const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
const shortId = (value) => value ? String(value).slice(0, 12) + '…' : '–';
const safeExternalUrl = (value) => /^https:\/\//i.test(String(value || '')) ? String(value) : '';

function formatOperatingSystem(value) {
  const operatingSystem = String(value || 'Windows');
  if (/^windows-server-\d+$/i.test(operatingSystem)) return 'Windows Server ' + operatingSystem.replace(/^windows-server-/i, '');
  if (/^windows-\d+$/i.test(operatingSystem)) return 'Windows ' + operatingSystem.replace(/^windows-/i, '');
  return operatingSystem;
}

function statusClass(state) {
  if (['OS_SEALED', 'SQL_PREPARED_SEALED', 'TESTS_PASSED'].includes(state)) return 'done';
  if (state === 'FAILED') return 'failed';
  return 'pending';
}

function empty(message) {
  return '<p class="empty">' + escapeHtml(message) + '</p>';
}

function resourceForInstance(resources, instanceId) {
  return (resources?.Instances || []).find((item) => String(item.InstanceId) === String(instanceId)) || null;
}

function resourceSummary(resource, provider) {
  if (!resource || resource.Available === false) return 'Ressourcen: Runtime derzeit nicht erreichbar';
  const memory = provider === 'hyperv' ? resource.MemoryStartupMB : resource.MemoryLimitMB;
  const cpu = resource.ProcessorCount;
  return 'Ressourcen: ' + (memory ? memory + ' MB' : 'unbegrenzt') + ' · ' + (cpu || 'unbegrenzt') + ' CPU';
}

function renderSummary(summary) {
  const values = [
    [summary.WindowsBaselines, 'OS-Baselines'],
    [summary.SqlPreparedImages, 'SQL-Prepared-Images'],
    [String(summary.TemplatePoolUsed ?? 0) + '/' + String(summary.TemplatePoolCapacity ?? 20), 'Vorlagenpool'],
    [summary.PendingWindowsBuilds, 'offene Windows-Builds'],
    [summary.PendingSqlBuilds, 'offene SQL-Builds'],
    [summary.ActiveContainerLabs, 'aktive Container-Labs'],
    [summary.RunningWorkers, 'laufende Worker'],
    [summary.WaitingUserGates, 'wartende User-Gates'],
    [summary.QueueLength, 'Queue-Positionen']
  ];
  $('#summary').innerHTML = values.map(([value, label]) =>
    '<article class="summary-card"><span class="summary-value">' + escapeHtml(value) + '</span><span class="summary-label">' + escapeHtml(label) + '</span></article>'
  ).join('');
}

function actionsFor(kind, item) {
  const state = item.State;
  if (kind === 'windows') {
    if (['BUILDER_READY', 'MANUAL_ACTION_REQUIRED'].includes(state)) {
      const result = [{ label: 'VMConnect öffnen', action: 'OpenWindowsConsole' }];
      result.push(item.InstallationVerified
        ? { label: 'Windows generalisieren · Gastpasswort erforderlich', action: 'GeneralizeWindowsBuild', credential: true }
        : { label: 'Windows bestätigen', action: 'ConfirmWindowsInstall', credential: true });
      return result.concat(cleanupActionFor(kind, item));
    }
    if (state === 'REBOOT_REQUIRED') return [{ label: 'Generalisierung fortsetzen', action: 'GeneralizeWindowsBuild', credential: false }].concat(cleanupActionFor(kind, item));
    if (state === 'RESUME_PENDING') return [{ label: 'Image veröffentlichen', action: 'PublishWindowsBuild', publish: true }].concat(cleanupActionFor(kind, item));
    return cleanupActionFor(kind, item);
  }
  if (kind === 'sql') {
    if (['MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED'].includes(state)) {
      const result = [{ label: 'VMConnect öffnen', action: 'OpenSqlConsole' }];
      if (state === 'MANUAL_ACTION_REQUIRED' && item.ProvisioningMode === 'fresh-windows-media' && !item.InstallationVerified) {
        result.push({
          label: 'Windows prüfen und Image automatisch fertigstellen · Gastpasswort erforderlich',
          action: 'ConfirmSqlWindowsInstall',
          credential: true
        });
        return result.concat(cleanupActionFor(kind, item));
      }
      result.push({
        label: 'Automatischen Image-Abschluss fortsetzen',
        action: 'PrepareSqlImage',
        credential: true
      });
      return result.concat(cleanupActionFor(kind, item));
    }
    if (state === 'RESUME_PENDING') return [{ label: 'Prepared-Image manuell veröffentlichen (Diagnose)', action: 'PublishSqlImage', publish: true }].concat(cleanupActionFor(kind, item));
    if (state === 'FAILED') return [{ label: 'Offline-Recovery versuchen', action: 'ResumeSqlImage' }].concat(cleanupActionFor(kind, item));
    return cleanupActionFor(kind, item);
  }
  return [];
}

function cleanupActionFor(kind, item) {
  if (item.State === 'CLEANED_UP') return [];
  const published = kind === 'windows' ? item.State === 'OS_SEALED' : item.State === 'SQL_PREPARED_SEALED';
  if (published) return [{ label: 'Build-Verlauf entfernen', action: kind === 'windows' ? 'CleanupWindowsBuild' : 'CleanupSqlBuild', cleanup: true, published: true }];
  return [{ label: 'Builder aufräumen', action: kind === 'windows' ? 'CleanupWindowsBuild' : 'CleanupSqlBuild', cleanup: true }];
}

function acceptanceActions(item) {
  if (item.State === 'SQL_PREPARED_SEALED') return [{ label: 'Build-Verlauf entfernen', action: 'CleanupSqlBuild', cleanup: true, published: true }];
  if (item.ProvisioningMode === 'fresh-windows-media') return [];
  if (['MANUAL_ACTION_REQUIRED', 'OOBE_AUTOMATION_RUNNING', 'OOBE_COMPLETED', 'SQL_INSTALL_REBOOT_REQUIRED'].includes(item.State)) {
    return [
      { label: 'VMConnect öffnen', action: 'OpenSqlConsole' },
      { label: item.State === 'SQL_INSTALL_REBOOT_REQUIRED' ? 'SQL-Setup fortsetzen' : 'OOBE + SQL-Setup ausführen', action: 'RunSqlAcceptanceSetup' }
    ];
  }
  if (item.State === 'SQL_READY_RUN') return [{ label: 'SQL-Abnahme ausführen', action: 'RunSqlAcceptanceTests' }];
  return [];
}

function renderBuilds(target, kind, items) {
  $(target).innerHTML = items.length ? items.map((item) => {
    const generatedTitle = kind === 'sql'
      ? escapeHtml(formatOperatingSystem(item.OperatingSystem)) + ' · SQL Server ' + escapeHtml(item.SqlVersion)
      : escapeHtml(formatOperatingSystem(item.OperatingSystem));
    const title = item.DisplayName ? escapeHtml(item.DisplayName) : generatedTitle;
    const metadata = kind === 'sql'
      ? escapeHtml(item.WindowsEdition + ' · ' + item.InstallationType + ' · ' + item.SqlEdition)
      : escapeHtml(item.Edition + ' · ' + item.InstallationType);
    const buttons = actionsFor(kind, item).map((button) => button.cleanup
      ? '<button class="button danger" data-build-cleanup="' + button.action + '" data-build="' + escapeHtml(item.BuildId) + '" data-build-kind="' + kind + '" data-build-published="' + Boolean(button.published) + '">' + escapeHtml(button.label) + '</button>'
      : '<button class="button ' + (button.publish ? 'primary' : 'secondary') + '" data-action="' + button.action + '" data-build="' + escapeHtml(item.BuildId) + '" data-credential="' + Boolean(button.credential) + '" data-publish="' + Boolean(button.publish) + '">' + escapeHtml(button.label) + '</button>'
    ).join('');
    return '<article class="build-card"><div class="build-card-top"><div><div class="build-title">' + title + '</div><div class="build-meta">' + metadata + ' · VM: ' + escapeHtml(item.VMName || 'noch nicht erstellt') + '</div></div><span class="status ' + statusClass(item.State) + '">' + escapeHtml(item.State) + '</span></div><p class="build-next"><strong>Nächster Schritt:</strong> ' + escapeHtml(item.NextStep) + '</p><div class="build-actions">' + buttons + '</div><div class="build-meta">Build: ' + escapeHtml(shortId(item.BuildId)) + '</div></article>';
  }).join('') : empty('Keine offenen Builds vorhanden.');
}

function renderList(target, items, format) {
  $(target).innerHTML = items.length ? items.map(format).join('') : empty('Noch keine Einträge vorhanden.');
}

function listItem(title, detail) {
  return '<div class="list-item"><strong>' + escapeHtml(title) + '</strong><span>' + escapeHtml(detail) + '</span></div>';
}

function renderArtifactList(target, items, kind, title, detail) {
  $(target).innerHTML = items.length ? items.map((item) =>
    '<div class="list-item"><div><strong>' + escapeHtml(title(item)) + '</strong><span>' + escapeHtml(detail(item)) + '</span></div><div class="build-actions"><button class="button secondary" data-artifact-rename="true" data-artifact="' + escapeHtml(item.ArtifactId) + '" data-artifact-name="' + escapeHtml(item.DisplayName || title(item)) + '" data-artifact-kind="' + escapeHtml(kind) + '">Name ändern</button><button class="button danger" data-artifact-remove="true" data-artifact="' + escapeHtml(item.ArtifactId) + '" data-artifact-kind="' + escapeHtml(kind) + '">Löschen</button></div></div>'
  ).join('') : empty('Noch keine Einträge vorhanden.');
}

function artifactRefreshDetail(item) {
  const action = item.RefreshAction || 'UNKNOWN';
  if (action === 'MANUAL_REBUILD_REQUIRED') return 'Evaluation abgelaufen · manueller Parallel-Rebuild erforderlich';
  if (action === 'MANUAL_REBUILD_RECOMMENDED') return 'Evaluation läuft ab · manueller Parallel-Rebuild empfohlen';
  if (action === 'EVALUATION_REVIEW_REQUIRED') return 'Evaluation prüfen · Ablaufdatum fehlt';
  return action === 'NO_ACTION' ? '' : 'Refresh-Status: ' + action;
}

function artifactFallbackDetail(item) {
  if (item.AutomaticFallbackEligible) return 'Automatischer SQL-Fallback geeignet';
  const reasons = Array.isArray(item.AutomaticFallbackReasons) ? item.AutomaticFallbackReasons.filter(Boolean) : [];
  return reasons.length ? 'Kein automatischer SQL-Fallback: ' + reasons.join(', ') : 'Automatischer SQL-Fallback nicht verifizierbar';
}

function getHyperVArtifactCandidates(sqlItems = workflow?.SqlPreparedImages || [], windowsItems = workflow?.WindowsBaselines || []) {
  return [
    ...(sqlItems || []).map((item) => ({ ...item, Workload: 'sql' })),
    ...(windowsItems || []).map((item) => ({ ...item, Workload: 'windows' }))
  ];
}

function renderHyperVArtifactOptions(sqlItems, windowsItems) {
  const select = $('#hyperv-artifact');
  const previous = select.value;
  const items = getHyperVArtifactCandidates(sqlItems, windowsItems);
  select.innerHTML = '<option value="">Windows- oder SQL-Vorlage auswählen …</option>' + items.map((item) =>
    '<option value="' + escapeHtml(item.ArtifactId) + '">' + escapeHtml(item.Workload === 'sql'
      ? ('SQL: ' + (item.DisplayName || ('SQL Server ' + item.SqlVersion + ' · ' + item.SqlEdition)))
      : ('Windows: ' + (item.DisplayName || (formatOperatingSystem(item.OperatingSystem) + ' · ' + item.Edition + ' · ' + item.InstallationType)))) + '</option>'
  ).join('');
  if (items.some((item) => item.ArtifactId === previous)) select.value = previous;
  renderHyperVArtifactDetails(items);
}

function renderSqlParentOptions(items) {
  const select = $('#sql-parent-artifact');
  const previous = select.value;
  const compatible = (items || []).filter((item) => /^windows-(server-)?\d+$/i.test(String(item.OperatingSystem || '')));
  select.innerHTML = '<option value="">OS-Baseline auswählen …</option>' + compatible.map((item) =>
    '<option value="' + escapeHtml(item.ArtifactId) + '">' + escapeHtml(item.DisplayName || (formatOperatingSystem(item.OperatingSystem) + ' · ' + item.Edition + ' · ' + item.InstallationType)) + ' · ' + escapeHtml(shortId(item.ArtifactId)) + '</option>'
  ).join('');
  if (compatible.some((item) => item.ArtifactId === previous)) select.value = previous;
  renderSqlParentDetails(compatible);
}

function renderSqlParentDetails(items) {
  const selected = (items || []).find((item) => item.ArtifactId === $('#sql-parent-artifact').value);
  const target = $('#sql-parent-details');
  target.textContent = selected
    ? formatOperatingSystem(selected.OperatingSystem) + ' · ' + selected.Edition + ' · ' + selected.InstallationType + ' · Parent bleibt unverändert · Artifact: ' + selected.ArtifactId
    : 'Die OS-Baseline bleibt unverändert; der SQL-Builder erhält eine eigene differenzierende VHDX.';
}

function renderHyperVArtifactDetails(items) {
  const selected = (items || []).find((item) => item.ArtifactId === $('#hyperv-artifact').value);
  const target = $('#hyperv-artifact-details');
  if (!selected) {
    target.textContent = 'Wählen Sie eine Windows- oder SQL-Vorlage; alle technischen Details werden hier angezeigt.';
    updateHyperVLabWorkload(null);
    return;
  }
  const isSql = selected.Workload === 'sql';
  const title = selected.DisplayName || (isSql ? ('SQL Server ' + selected.SqlVersion + ' · ' + selected.SqlEdition) : (formatOperatingSystem(selected.OperatingSystem) + ' · ' + selected.Edition));
  const windowsEdition = selected.WindowsEdition || selected.Edition;
  const workload = isSql
    ? '<span>SQL Server ' + escapeHtml(selected.SqlVersion) + ' · ' + escapeHtml(selected.SqlEdition) + (selected.SqlBuild ? ' · Build ' + escapeHtml(selected.SqlBuild) : '') + '</span>'
    : '<span>Reine Windows-VM: OOBE wird automatisch eingerichtet; SQL, WMI und SQL-TCP bleiben unangetastet.</span>';
  target.innerHTML = '<strong>' + escapeHtml(title) + '</strong><span>Windows: ' + escapeHtml(selected.OperatingSystem) + ' · ' + escapeHtml(windowsEdition) + ' · ' + escapeHtml(selected.InstallationType) + '</span>' + workload + '<span>' + escapeHtml(artifactFallbackDetail(selected)) + '</span><code>ArtifactId: ' + escapeHtml(selected.ArtifactId) + '</code>';
  updateHyperVLabWorkload(selected);
}

function updateHyperVLabWorkload(selected) {
  const windowsOnly = selected?.Workload === 'windows';
  $('#hyperv-sa-field').hidden = windowsOnly;
  $('#hyperv-sa-password-repeat-label').hidden = windowsOnly || !$('#hyperv-sa-password').value;
  $('#hyperv-persistent-field').hidden = windowsOnly;
  if (windowsOnly) $('#hyperv-persistent-data').checked = false;
  $('#hyperv-lab-note').textContent = windowsOnly
    ? 'Die Antwortdatei wird nur in die differenzierende Klon-VHDX geschrieben und nach OOBE im Gast entfernt. Das Gastpasswort wird ausschließlich für diesen Run DPAPI-geschützt abgelegt. Diese Vorlage erstellt eine reine Windows-VM; SQL, WMI und SQL-TCP werden bewusst nicht konfiguriert.'
    : 'Die Antwortdatei wird nur in die differenzierende Klon-VHDX geschrieben und nach OOBE im Gast entfernt. Das Gastpasswort wird ausschließlich für diesen Run DPAPI-geschützt abgelegt. Bei einer SQL-Vorlage richtet die Bereitstellung zusätzlich SQL CompleteImage, WMI und TCP/IP für den Hostzugriff ein.';
  $('#hyperv-lab-submit').textContent = windowsOnly ? 'Windows-VM bereitstellen' : 'SQL-Umgebung bereitstellen';
}

function renderHyperVSwitchOptions(items) {
  const select = $('#hyperv-switch');
  const previous = select.value;
  select.innerHTML = '<option value="">SQL_Server_Lab-Standard (Host-SSMS möglich)</option>' + (items || []).map((item) =>
    '<option value="' + escapeHtml(item.Name) + '">' + escapeHtml(item.Name) + (item.Type ? ' · ' + escapeHtml(item.Type) : '') + '</option>'
  ).join('');
  if ((items || []).some((item) => item.Name === previous)) select.value = previous;
  const existingVmSelect = $('#hyperv-existing-vm-switch');
  if (existingVmSelect) {
    const existingPrevious = existingVmSelect.value;
    existingVmSelect.innerHTML = '<option value="">SQL_Server_Lab-Standard (Host-SSMS möglich)</option>' + (items || []).map((item) =>
      '<option value="' + escapeHtml(item.Name) + '">' + escapeHtml(item.Name) + (item.Type ? ' · ' + escapeHtml(item.Type) : '') + '</option>'
    ).join('');
    if ((items || []).some((item) => item.Name === existingPrevious)) existingVmSelect.value = existingPrevious;
  }
}

function renderHyperVExistingVmSourceOptions(items) {
  const select = $('#hyperv-existing-vm-source');
  const previous = select.value;
  select.innerHTML = '<option value="">Ausgeschaltete vorhandene Windows-VM auswählen …</option>' + (items || []).map((item) =>
    '<option value="' + escapeHtml(item.VMName) + '">' + escapeHtml(item.VMName) + (item.IsDeveloperEnvironment ? ' · Entwicklungsumgebung erkannt' : '') + '</option>'
  ).join('');
  if ((items || []).some((item) => item.VMName === previous)) select.value = previous;
  renderHyperVExistingVmSourceDetails(items || []);
}

function renderHyperVExistingVmSourceDetails(items) {
  const selected = (items || []).find((item) => item.VMName === $('#hyperv-existing-vm-source').value);
  const target = $('#hyperv-existing-vm-details');
  if (!selected) {
    target.textContent = 'Nur ausgeschaltete Generation-2-VMs mit genau einer System-VHDX werden angeboten. Die Quell-VM bleibt unverändert.';
    return;
  }
  target.innerHTML = '<strong>' + escapeHtml(selected.VMName) + '</strong><span>Generation ' + escapeHtml(selected.Generation) + ' · Quelle: ' + escapeHtml(selected.SourceDiskType || 'VHDX') + '</span><span>' + escapeHtml(selected.LicenseNotice || 'Lizenz- und Ablaufstatus in Windows prüfen.') + '</span><code>Quell-VHDX: ' + escapeHtml(selected.SourceVhdxPath) + '</code>';
  if (selected.MemoryStartupMB) $('#hyperv-existing-vm-memory').value = selected.MemoryStartupMB;
  if (selected.ProcessorCount) $('#hyperv-existing-vm-processors').value = selected.ProcessorCount;
}

function renderMediaSources(items) {
  $('#media-source-list').innerHTML = (items || []).map((item) => {
    const url = safeExternalUrl(item.Url);
    const link = url ? '<a href="' + escapeHtml(url) + '" target="_blank" rel="noopener noreferrer">Offizielle Quelle öffnen</a>' : '';
    return '<article class="source-item"><strong>' + escapeHtml(item.Category) + ' · ' + escapeHtml(item.DisplayName) + '</strong><span>' + escapeHtml(item.Acquisition) + ' · Ziel: ' + escapeHtml(item.TargetRelativePath) + '</span><span>' + escapeHtml(item.Note) + '</span>' + link + '</article>';
  }).join('') || empty('Keine Quelleninformationen verfügbar.');
}

function renderDatabasePackageOptions(items) {
  const select = $('#database-package-source');
  const previous = select.value;
  const packages = Array.isArray(items) ? items : [];
  select.innerHTML = '<option value="">Datenbankpaket auswählen …</option>' + packages.map((item) => {
    const size = item.Bytes ? ' · ' + Math.ceil(Number(item.Bytes) / 1048576) + ' MB' : '';
    return '<option value="' + escapeHtml(item.DatabasePackageId) + '">' + escapeHtml(item.DatabaseName) + ' · ' + escapeHtml(item.SourceProvider) + ' · SQL ' + escapeHtml(item.SourceSqlMajorVersion) + size + ' · ' + escapeHtml(item.Availability) + '</option>';
  }).join('');
  if (packages.some((item) => item.DatabasePackageId === previous)) select.value = previous;
  $('#database-package-count').textContent = packages.length + ' Paket(e)';
  updateDatabasePackageDetails(packages);
}

function databasePackageAttachTargets(items = workflow?.HyperVLabs || []) {
  return (Array.isArray(items) ? items : []).filter((item) =>
    item.State === 'RUNNING' && item.VMState === 'Running' && item.Workload !== 'windows');
}

function renderDatabasePackageTargetOptions(items) {
  const select = $('#database-package-target');
  const previous = select.value;
  const targets = databasePackageAttachTargets(items);
  select.innerHTML = '<option value="">Hyper-V-SQL-Ziel auswählen …</option>' + targets.map((item) =>
    '<option value="' + escapeHtml(item.RunId) + '" data-instance="' + escapeHtml(item.InstanceId || 'primary') + '">' +
    escapeHtml((item.Name || shortId(item.RunId)) + ' · SQL ' + (item.SqlVersion || '–')) + '</option>'
  ).join('');
  if (targets.some((item) => item.RunId === previous)) select.value = previous;
  updateDatabasePackageDetails();
}

function renderHyperVPersistentDataOptions(items) {
  const select = $('#hyperv-persistent-data-source');
  const previous = select.value;
  const candidates = Array.isArray(items) ? items : [];
  select.innerHTML = '<option value="">Keine Daten-VHDX katalogisiert</option>' + candidates.map((item) =>
    '<option value="' + escapeHtml(item.PersistentStorageId) + '">' + escapeHtml(item.DisplayName || shortId(item.PersistentStorageId)) + ' · ' + escapeHtml(item.State || 'UNKNOWN') + '</option>'
  ).join('');
  if (candidates.some((item) => item.PersistentStorageId === previous)) select.value = previous;
  $('#hyperv-persistent-data-count').textContent = candidates.length + ' VHDX';
  renderHyperVPersistentDataTargetOptions(workflow?.HyperVLabs || []);
  updateHyperVPersistentDataDetails(candidates);
}

function hyperVPersistentDataTargets(items = workflow?.HyperVLabs || []) {
  const selected = (workflow?.HyperVPersistentDataCandidates || []).find((item) =>
    item.PersistentStorageId === $('#hyperv-persistent-data-source').value);
  return (Array.isArray(items) ? items : []).filter((item) =>
    item.State === 'STOPPED' && item.VMState === 'Off' && item.Workload !== 'windows' &&
    (!selected?.SqlMajorVersion || String(item.SqlVersion) === String(selected.SqlMajorVersion)));
}

function renderHyperVPersistentDataTargetOptions(items) {
  const select = $('#hyperv-persistent-data-target');
  const previous = select.value;
  const targets = hyperVPersistentDataTargets(items);
  select.innerHTML = '<option value="">Ziel für Reattach oder Clone auswählen …</option>' + targets.map((item) =>
    '<option value="' + escapeHtml(item.RunId) + '">' +
    escapeHtml((item.Name || shortId(item.RunId)) + ' · SQL ' + (item.SqlVersion || '–')) + '</option>'
  ).join('');
  if (targets.some((item) => item.RunId === previous)) select.value = previous;
}

function updateHyperVPersistentDataDetails(items = workflow?.HyperVPersistentDataCandidates || []) {
  const selected = (items || []).find((item) => item.PersistentStorageId === $('#hyperv-persistent-data-source').value);
  const selectedTarget = hyperVPersistentDataTargets().find((item) => item.RunId === $('#hyperv-persistent-data-target').value);
  const target = $('#hyperv-persistent-data-details');
  const reattach = $('#hyperv-persistent-data-reattach');
  const release = $('#hyperv-persistent-data-release');
  const clone = $('#hyperv-persistent-data-clone');
  reattach.disabled = true;
  release.disabled = true;
  clone.disabled = true;
  if (!selected) {
    target.textContent = 'Die Auswahl erfolgt ausschließlich über die stabile PersistentStorageId; Hostpfad und DiskIdentifier werden nicht an den Browser übertragen.';
    return;
  }
  const lifecycle = Array.isArray(selected.LifecycleActions) && selected.LifecycleActions.length ? selected.LifecycleActions.join(', ') : 'keine';
  const blockers = Array.isArray(selected.Issues) && selected.Issues.length ? selected.Issues.join(', ') : 'keine';
  const available = Array.isArray(selected.AvailableActions) ? selected.AvailableActions : [];
  release.disabled = !available.includes('RELEASE') || !selected.BoundRunId;
  reattach.disabled = !available.includes('REATTACH') || !selectedTarget;
  clone.disabled = !available.includes('CLONE') || !selectedTarget;
  const attachment = selected.AttachmentState === 'ATTACHED' && selected.AttachedVMName
    ? selected.AttachmentState + ' · VM ' + selected.AttachedVMName
    : (selected.AttachmentState || 'UNKNOWN');
  target.innerHTML = '<strong>' + escapeHtml(selected.DisplayName || shortId(selected.PersistentStorageId)) + '</strong>' +
    '<span>Katalog: ' + escapeHtml(selected.State || 'UNKNOWN') + ' · Runtime: ' + escapeHtml(attachment) + '</span>' +
    '<span>Lifecycle: ' + escapeHtml(lifecycle) + ' · Blocker: ' + escapeHtml(blockers) + '</span>' +
    '<span>Detach-Evidenz: ' + escapeHtml(selected.DetachEvidenceStatus || 'MISSING') +
    (selectedTarget ? ' · Ziel: ' + escapeHtml(selectedTarget.Name || shortId(selectedTarget.RunId)) : '') + '</span>' +
    '<span>Datenbanken online: nein · Folgeaktion: explizites Restore oder Attach</span>' +
    '<code>PersistentStorageId: ' + escapeHtml(selected.PersistentStorageId) + '</code>';
}

function updateDatabasePackageDetails(items = workflow?.DatabasePackageLibrary || []) {
  const selected = (items || []).find((item) => item.DatabasePackageId === $('#database-package-source').value);
  const targetRun = databasePackageAttachTargets().find((item) => item.RunId === $('#database-package-target').value);
  const target = $('#database-package-details');
  const attach = $('#database-package-attach');
  attach.disabled = true;
  if (!selected) {
    target.textContent = 'Die Auswahl erfolgt ausschließlich über die stabile DatabasePackageId; Hostpfade und Hashes werden nicht an den Browser übertragen.';
    return;
  }
  const capabilities = [selected.HasFileStream ? 'FILESTREAM' : 'ohne FILESTREAM', selected.IsEncrypted ? 'TDE' : 'nicht verschlüsselt'];
  const dependencyCategories = Array.isArray(selected.DependencyCategories) ? selected.DependencyCategories : [];
  const migrationWarnings = Array.isArray(selected.MigrationWarnings) ? selected.MigrationWarnings : [];
  const dependencySummary = dependencyCategories.length ? dependencyCategories.join(', ') : 'keine erkannten oder veröffentlichten Kategorien';
  const warningSummary = migrationWarnings.length ? migrationWarnings.join(', ') : 'keine';
  const targetSummary = targetRun
    ? 'Ziel: ' + (targetRun.Name || shortId(targetRun.RunId)) + ' · SQL ' + (targetRun.SqlVersion || '–') + ' · Zielpfad wird live aus SQL Default Data gebunden'
    : 'Attach gesperrt: laufenden Hyper-V-SQL-Run auswählen';
  const packageReady = selected.Availability === 'SELECTABLE' && !selected.IsEncrypted;
  attach.disabled = !(packageReady && targetRun);
  const packageBlocker = selected.IsEncrypted ? '<span>Attach gesperrt: TDE-Ziel-Key-Vertrag fehlt</span>' : '';
  target.innerHTML = '<strong>' + escapeHtml(selected.DatabaseName) + '</strong><span>' + escapeHtml(selected.SourceProvider + ' · SQL ' + selected.SourceSqlMajorVersion + ' · ' + capabilities.join(' · ')) + '</span><span>' + escapeHtml(selected.DatabaseFileCount + ' Datenbankdatei(en) · ' + selected.ObjectCount + ' gehashte(s) Objekt(e) · ' + selected.MigrationBoundary) + '</span><span>Migrationsinventar: ' + escapeHtml(selected.DependencyInventoryStatus) + '</span><span>Getrennt zu behandeln: ' + escapeHtml(dependencySummary) + '</span><span>Hinweise: ' + escapeHtml(warningSummary) + '</span><code>DatabasePackageId: ' + escapeHtml(selected.DatabasePackageId) + '</code><span>' + escapeHtml(targetSummary) + '</span>' + packageBlocker;
}

function renderSqlInstallationMedia(items) {
  const select = $('#sql-media');
  const previous = select.value;
  const ready = (items || []).filter((item) => item.State === 'READY');
  select.innerHTML = '<option value="">SQL-Installationsmedium auswählen …</option>' + ready.map((item) => {
    const edition = item.MediaEdition || 'Edition bitte wählen';
    const hashLabel = item.HashStatus === 'SIDECAR_READY' ? ' · Hash gesetzt' : ' · Hash fehlt';
    return '<option value="' + escapeHtml(item.MediaId) + '" data-version="' + escapeHtml(item.SqlVersion) + '" data-edition="' + escapeHtml(item.MediaEdition || '') + '" data-hash-status="' + escapeHtml(item.HashStatus || 'MISSING') + '" data-hash="' + escapeHtml(item.ExpectedSha256 || '') + '">SQL Server ' + escapeHtml(item.SqlVersion) + ' · ' + escapeHtml(edition) + hashLabel + ' · ' + escapeHtml(item.MediaId) + '</option>';
  }).join('');
  if (ready.some((item) => item.MediaId === previous)) select.value = previous;
  updateSqlMediaSelection();
}

function isSqlPreparedCompatibleWindowsMedia(item) {
  return /^windows-(server-)?\d+$/i.test(String(item?.OperatingSystemId || ''));
}

function windowsMediaGroup(item) {
  const osId = String(item?.OperatingSystemId || 'unbekannt');
  const serverMatch = /^windows-server-(\d+)$/i.exec(osId);
  const clientMatch = /^windows-(\d+)$/i.exec(osId);
  const osLabel = serverMatch ? ('Windows Server ' + serverMatch[1]) : (clientMatch ? ('Windows ' + clientMatch[1]) : osId);
  const evaluation = /-evaluation$/i.test(String(item?.WindowsEdition || ''));
  const versionSort = String(9999 - Number((serverMatch || clientMatch || [])[1] || 0)).padStart(4, '0');
  return {
    key: osId + '::' + (evaluation ? 'evaluation' : 'regular'),
    label: osLabel + ' · ' + (evaluation ? 'Evaluation' : 'Reguläre Medien'),
    sortKey: (serverMatch ? '0' : (clientMatch ? '1' : '9')) + '-' + versionSort + '::' + (evaluation ? '1' : '0')
  };
}

function renderGroupedWindowsOptions(items, prefix, optionHtml) {
  const groups = new Map();
  (items || []).forEach((item) => {
    const group = windowsMediaGroup(item);
    if (!groups.has(group.key)) groups.set(group.key, { ...group, items: [] });
    groups.get(group.key).items.push(item);
  });
  return [...groups.values()].sort((left, right) => left.sortKey.localeCompare(right.sortKey)).map((group) =>
    '<optgroup label="' + escapeHtml(prefix ? (prefix + ' · ' + group.label) : group.label) + '">'
      + group.items.map(optionHtml).join('') + '</optgroup>'
  ).join('');
}

function renderWindowsInstallationMedia(items, sqlCompatibleOnly = false) {
  const select = $('#windows-media');
  const previous = select.value;
  const allReady = (items || []).filter((item) => item.State === 'READY');
  const ready = sqlCompatibleOnly ? allReady.filter(isSqlPreparedCompatibleWindowsMedia) : allReady;
  const optionHtml = (item, disabled = false) => '<option' + (disabled ? ' disabled' : '') + ' value="' + escapeHtml(windowsMediaSelectionKey(item)) + '" data-media-id="' + escapeHtml(item.MediaId) + '" data-os="' + escapeHtml(item.OperatingSystemId) + '" data-edition="' + escapeHtml(item.WindowsEdition) + '" data-installation="' + escapeHtml(item.InstallationType) + '" data-hash-status="' + escapeHtml(item.HashStatus || 'MISSING') + '" data-hash="' + escapeHtml(item.ExpectedSha256 || '') + '">'
    + escapeHtml(item.ImageName || (item.OperatingSystemId + ' · ' + item.WindowsEdition + ' · ' + item.InstallationType)) + (item.HashStatus === 'SIDECAR_READY' ? ' · Hash gesetzt' : ' · Hash fehlt') + ' · ' + escapeHtml(item.MediaId) + (disabled ? ' · nur OS-Baseline' : '') + '</option>';
  const unsupported = sqlCompatibleOnly ? allReady.filter((item) => !isSqlPreparedCompatibleWindowsMedia(item)) : [];
  const unrecognized = (items || []).filter((item) => item.State !== 'READY');
  const unrecognizedHtml = unrecognized.map((item) => '<option disabled value="">' + escapeHtml(item.MediaId) + ' · nicht auswertbar: ' + escapeHtml(item.Message || 'Unbekannter Fehler') + '</option>').join('');
  select.innerHTML = '<option value="">Windows-Installationsmedium auswählen …</option>'
    + (ready.length ? renderGroupedWindowsOptions(ready, sqlCompatibleOnly ? 'Für diesen Build verfügbar' : '', (item) => optionHtml(item)) : '')
    + (unsupported.length ? renderGroupedWindowsOptions(unsupported, 'Erkannt – für SQL-Prepared derzeit nicht unterstützt', (item) => optionHtml(item, true)) : '')
    + (unrecognizedHtml ? '<optgroup label="Nicht auswertbar – nicht verwendbar">' + unrecognizedHtml + '</optgroup>' : '');
  if (ready.some((item) => windowsMediaSelectionKey(item) === previous)) select.value = previous;
  updateWindowsMediaSelection();
}

function windowsMediaSelectionKey(item) {
  // Eine ISO kann Standard, Datacenter sowie Core/Desktop als getrennte
  // install.wim-Images enthalten. Der ISO-Pfad allein ist daher kein
  // eindeutiger Auswahlwert und würde beim Refresh die erste Edition wählen.
  return [item.MediaId, item.ImageIndex || '', item.WindowsEdition || '', item.InstallationType || ''].join('::');
}

function selectedWindowsMediaPath() {
  return $('#windows-media').selectedOptions[0]?.dataset?.mediaId || '';
}

function updateWindowsMediaSelection() {
  const option = $('#windows-media').selectedOptions[0];
  $('#os-id').value = option?.dataset?.os || '';
  $('#windows-edition').value = option?.dataset?.edition || '';
  $('#installation-type').value = option?.dataset?.installation || '';
  $('#windows-media-sha256').value = option?.dataset?.hash || '';
  $('#windows-media-hash-status').textContent = option?.value ? ('Windows-Hash: ' + (option.dataset?.hashStatus === 'SIDECAR_READY' ? 'gesetzt und verifiziert' : 'fehlt – offiziellen SHA-256 eintragen')) : 'Windows-Hash: Medium auswählen';
}

function updateSqlMediaSelection() {
  const option = $('#sql-media').selectedOptions[0];
  $('#sql-version').value = option?.dataset?.version || '';
  $('#sql-edition').value = option?.dataset?.edition || '';
  $('#sql-media-sha256').value = option?.dataset?.hash || '';
  $('#sql-media-hash-status').textContent = option?.value ? ('SQL-Hash: ' + (option.dataset?.hashStatus === 'SIDECAR_READY' ? 'gesetzt und verifiziert' : 'fehlt – offiziellen SHA-256 eintragen')) : 'SQL-Hash: Medium auswählen';
}

function renderWorkflow(data) {
  workflow = data;
  renderOperationQueue(data.Queue);
  // Der Quellen-Dialog kann vor dem ersten API-Refresh geöffnet werden. In
  // diesem Fall das anfangs leere Feld nachträglich füllen, aber eine bereits
  // vom Benutzer eingegebene Pfadänderung niemals überschreiben.
  const sourceMediaRoot = $('#sources-media-root');
  if (sourceMediaRoot && !sourceMediaRoot.value && data.Defaults?.MediaRoot) {
    sourceMediaRoot.value = data.Defaults.MediaRoot;
  }
  const sourceDataRoot = $('#sources-data-root');
  if (sourceDataRoot && !sourceDataRoot.value && data.Defaults?.DataRoot) {
    sourceDataRoot.value = data.Defaults.DataRoot;
  }
  const sourceTestDataRoot = $('#sources-test-data-root');
  if (sourceTestDataRoot && !sourceTestDataRoot.value && data.Defaults?.TestDataRoot) {
    sourceTestDataRoot.value = data.Defaults.TestDataRoot;
  }
  const host = data.Host;
  const hostChip = $('#host-status');
  if (!host.HyperV.Supported) {
    hostChip.textContent = 'Hyper-V: nur Windows-Host';
    hostChip.className = 'chip warn';
    $('#notice').hidden = false;
    $('#notice').textContent = 'Diese Oberfläche funktioniert unter Linux für Docker und Podman. Hyper-V-Aktionen benötigen einen lokalen Windows-Host.';
  } else if (host.HyperV.Available) {
    hostChip.textContent = host.IsElevated ? 'Hyper-V bereit · Administrator' : 'Hyper-V bereit · Capability geprüft';
    hostChip.className = 'chip ok';
    $('#notice').hidden = true;
  } else {
    hostChip.textContent = 'Hyper-V nicht verfügbar';
    hostChip.className = 'chip warn';
    $('#notice').hidden = false;
    $('#notice').textContent = host.HyperV.Message || 'Hyper-V ist auf diesem Host nicht verfügbar.';
  }
  renderSummary(data.Summary);
  renderBuilds('#windows-builds', 'windows', data.WindowsBuilds);
  renderBuilds('#sql-builds', 'sql', data.SqlBuilds);
  $('#windows-count').textContent = data.WindowsBuilds.length + ' Build(s)';
  $('#sql-count').textContent = data.SqlBuilds.length + ' Build(s)';
  renderArtifactList('#windows-baselines', data.WindowsBaselines, 'OS-Baseline', (item) => item.DisplayName || (item.OperatingSystem + ' · ' + item.Edition), (item) => [item.InstallationType, shortId(item.ArtifactId), artifactRefreshDetail(item), artifactFallbackDetail(item)].filter(Boolean).join(' · '));
  renderArtifactList('#sql-images', data.SqlPreparedImages, 'SQL-Prepared-Image', (item) => item.DisplayName || (item.OperatingSystem + ' · SQL Server ' + item.SqlVersion), (item) => [item.WindowsEdition, item.SqlEdition, shortId(item.ArtifactId), artifactRefreshDetail(item), artifactFallbackDetail(item)].filter(Boolean).join(' · '));
  renderAcceptance(data.AcceptanceEnvironments);
  renderActiveLabs(data.ActiveLabs);
  renderHyperVLabs(data.HyperVLabs || []);
  renderDatabasePackageTargetOptions(data.HyperVLabs || []);
  renderHyperVArtifactOptions(data.SqlPreparedImages || [], data.WindowsBaselines || []);
  renderSqlParentOptions(data.WindowsBaselines || []);
  renderHyperVSwitchOptions(data.HyperVSwitches || []);
  renderHyperVExistingVmSourceOptions(data.HyperVExistingVmSources || []);
  renderMediaSources(data.MediaSources || []);
  renderDatabasePackageOptions(data.DatabasePackageLibrary || []);
  renderHyperVPersistentDataOptions(data.HyperVPersistentDataCandidates || []);
  renderSqlInstallationMedia(data.SqlInstallationMedia);
  const sqlFreshBuildDialogOpen = $('#build-dialog')?.open && $('#build-type')?.value === 'sql-fresh';
  renderWindowsInstallationMedia(data.WindowsInstallationMedia, sqlFreshBuildDialogOpen);
  const hyperVDisabled = !host.HyperV.Supported || !host.HyperV.Available;
  // Der Provider-Capability-Probe ist die Autoritaet. Mitglieder der lokalen
  // Hyper-V-Administratoren duerfen VMs auch ohne Administrator-Rollenbit
  // verwalten; speziellere Volume-Rechte prueft erst die jeweilige Aktion.
  document.querySelectorAll('[data-open-build], [data-action], [data-build-cleanup], [data-artifact-rename], [data-artifact-remove], [data-hyperv-action], #new-hyperv-lab, #new-hyperv-existing-vm-lab').forEach((button) => { button.disabled = hyperVDisabled; });
  document.querySelectorAll('[data-lab-resources][data-provider="hyperv"]').forEach((button) => { button.disabled = hyperVDisabled; });
}

function renderOperationQueue(queue) {
  const items = queue?.items || [];
  $('#queue-count').textContent = (queue?.runningWorkers || 0) + '/' + (queue?.maxWorkers || 2) + ' Worker · ' + items.length + ' offen';
  $('#operation-queue').innerHTML = items.length ? items.map((item) => {
    const gate = item.userGate;
    const gateDetails = gate ? '<div class="operation-gate"><strong>' + escapeHtml(gate.reason) + '</strong><ol>' + (gate.instructions || []).map((step) => '<li>' + escapeHtml(step) + '</li>').join('') + '</ol><span>Erwartet: ' + escapeHtml(gate.expectedResult) + '</span></div>' : '';
    const confirmation = ['WaitingForUser', 'CandidateSatisfied'].includes(item.status)
      ? '<button class="button primary" data-operation-command="Confirm" data-operation="' + escapeHtml(item.operationId) + '" data-verification="' + escapeHtml(gate?.verification?.type || '') + '">Erledigt - prüfen und fortsetzen</button>'
      : '';
    const pause = item.status === 'Paused'
      ? '<button class="button secondary" data-operation-command="Resume" data-operation="' + escapeHtml(item.operationId) + '">Freigeben</button>'
      : (item.status === 'Queued' || item.status === 'WaitingForDependency' ? '<button class="button secondary" data-operation-command="Suspend" data-operation="' + escapeHtml(item.operationId) + '">Pausieren</button>' : '');
    return '<article class="build-card operation-card"><div class="build-card-top"><div><div class="build-title">' + escapeHtml(item.title) + '</div><div class="build-meta">' + escapeHtml(item.priority + ' · ' + item.resourceClass + ' · ' + item.provider) + '</div></div><span class="status ' + statusClass(item.status) + '">' + escapeHtml(item.status) + '</span></div><progress max="100" value="' + escapeHtml(item.progress || 0) + '"></progress>' + gateDetails + '<div class="build-actions">' + confirmation + pause + '<button class="button secondary" data-operation-command="MoveUp" data-operation="' + escapeHtml(item.operationId) + '">Nach oben</button><button class="button danger" data-operation-command="StopCleanup" data-operation="' + escapeHtml(item.operationId) + '">Stoppen + Cleanup</button></div><div class="build-meta">' + escapeHtml(item.blockedReason || item.operationId) + '</div></article>';
  }).join('') : empty('Keine offenen persistenten Vorgänge.');
}

async function runOperationCommand(operationId, command, verificationType) {
  const payload = { operationId, command };
  if (command === 'Confirm' && verificationType === 'HyperVWindowsSetup') {
    $('#credential-action').value = '__ConfirmOperation';
    $('#credential-build').value = operationId;
    $('#credential-title').textContent = 'Windows-Aktion prüfen und fortsetzen';
    $('#credential-note').textContent = 'Das eingerichtete Windows-Konto wird nur für diese PowerShell-Direct-Prüfung verwendet und nicht gespeichert oder protokolliert.';
    $('#credential-sa-password-label').hidden = true;
    $('#credential-dialog').showModal();
    return;
  }
  if (command === 'StopCleanup') {
    openConfirmation('Vorgang stoppen und aufräumen', 'Diesen Vorgang wirklich aufräumen? Nur sein persistierter Scope wird entfernt; veröffentlichte Images bleiben unverändert.', '__OperationStopCleanup', { operationId }, 'Stoppen + Cleanup');
    return;
  }
  const response = await fetch('/api/operations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
  if (!response.ok) throw new Error(await response.text());
  await refresh();
}

document.addEventListener('click', async (event) => {
  const button = event.target.closest('[data-operation-command]');
  if (!button) return;
  button.disabled = true;
  try { await runOperationCommand(button.dataset.operation, button.dataset.operationCommand, button.dataset.verification); }
  catch (error) { window.alert(error.message); }
  finally { button.disabled = false; }
});

function renderActiveLabs(items) {
  $('#active-labs').innerHTML = items.length ? items.map((item) => {
    const running = item.State === 'RUNNING';
    const resources = item.Resources?.Instances || [];
    const primaryResource = resources[0] || null;
    const lifecycleActions = [
      '<button class="button secondary" data-container-action="' + (running ? 'StopLabReconcile' : 'StartLabReconcile') + '" data-run="' + escapeHtml(item.RunId) + '">' + (running ? 'Stoppen' : 'Starten') + '</button>',
      running ? '<button class="button secondary" data-container-action="RestartContainerLab" data-run="' + escapeHtml(item.RunId) + '">Neustarten</button>' : '',
      '<button class="button secondary" data-lab-resources="true" data-run="' + escapeHtml(item.RunId) + '" data-provider="container" data-memory="' + escapeHtml(primaryResource?.MemoryLimitMB || primaryResource?.memoryLimitMB || '') + '" data-cpu="' + escapeHtml(primaryResource?.ProcessorCount || primaryResource?.processorCount || '') + '" data-instances="' + escapeHtml(resources.length) + '">CPU / Speicher ändern</button>',
      '<button class="button secondary" data-lab-rename="true" data-run="' + escapeHtml(item.RunId) + '" data-name="' + escapeHtml(item.Name || item.RunId) + '">Name ändern</button>',
      persistentStorageCandidatesForRun(item.RunId).length ? '<button class="button secondary" data-persistent-storage-removal-preview="true" data-run="' + escapeHtml(item.RunId) + '" data-name="' + escapeHtml(item.Name || item.RunId) + '">Retention prüfen</button>' : '',
      '<button class="button secondary" data-container-remove="true" data-run="' + escapeHtml(item.RunId) + '" data-name="' + escapeHtml(item.Name || item.RunId) + '">Entfernen</button>'
    ].join('');
    const instances = (item.Instances || []).map((instance) => {
      const provider = instance.Provider || 'unbekannter Provider';
      const connection = instance.Port ? (instance.Host || '127.0.0.1') + ':' + instance.Port : 'kein Host-Port';
      const connectionString = instance.ConnectionString
        ? '<div class="build-meta connection-string"><strong>Connection String:</strong> <code>' + escapeHtml(instance.ConnectionString) + '</code></div>'
        : '';
      const persistentStorage = instance.PersistentStorage?.hostPath
        ? '<div class="build-meta"><strong>Persistente Daten:</strong> Host ' + escapeHtml(instance.PersistentStorage.hostPath) + (instance.PersistentStorage.guestPath ? ' → Gast ' + escapeHtml(instance.PersistentStorage.guestPath) : '') + ' [' + escapeHtml(instance.PersistentStorage.state || '–') + ']</div>'
        : '';
      const backupStorage = instance.PersistentStorage?.backupHostPath
        ? '<div class="build-meta"><strong>Backup-Arbeitsbereich:</strong> Host ' + escapeHtml(instance.PersistentStorage.backupHostPath) + ' → SQL ' + escapeHtml(instance.PersistentStorage.backupGuestPath || '/var/opt/mssql/backup') + '</div>'
        : '';
      const operations = running && instance.Port ? [
        '<button class="button secondary" data-container-operation="CreateContainerDatabase" data-container-operation-kind="container" data-run="' + escapeHtml(item.RunId) + '" data-instance="' + escapeHtml(instance.Id) + '" data-container-operation-host="' + escapeHtml(instance.Host || '127.0.0.1') + '" data-sql-version="' + escapeHtml(instance.SqlVersion) + '" data-port="' + escapeHtml(instance.Port) + '">Datenbank anlegen</button>',
        '<button class="button secondary" data-container-operation="ExportContainerDatabasePackage" data-container-operation-kind="container" data-run="' + escapeHtml(item.RunId) + '" data-instance="' + escapeHtml(instance.Id) + '">Datenbank paketieren</button>',
        '<button class="button secondary" data-container-operation="ExecuteContainerScript" data-container-operation-kind="container" data-run="' + escapeHtml(item.RunId) + '" data-instance="' + escapeHtml(instance.Id) + '" data-container-operation-host="' + escapeHtml(instance.Host || '127.0.0.1') + '" data-port="' + escapeHtml(instance.Port) + '">SQL-Skript ausführen</button>'
      ].join('') : '';
      const resource = resourceForInstance(item.Resources, instance.Id);
      return '<div class="container-instance"><div class="build-meta">' + escapeHtml(provider) + ' · SQL Server ' + escapeHtml(instance.SqlVersion || '–') + ' · ' + escapeHtml(connection) + ' · Autostart: ' + escapeHtml(instance.AutoStart === 'on' ? 'ein' : 'aus') + '</div><div class="build-meta">' + escapeHtml(resourceSummary(resource, provider)) + '</div>' + connectionString + persistentStorage + backupStorage + '<div class="build-actions">' + operations + '</div></div>';
    }).join('') || '<p class="empty">Keine Instanzen im Run gespeichert.</p>';
    return '<article class="build-card"><div class="build-card-top"><div><div class="build-title">' + escapeHtml(item.Name || shortId(item.RunId)) + '</div><div class="build-meta">' + escapeHtml(item.State) + '</div></div><span class="status ' + statusClass(item.State === 'RUNNING' ? 'TESTS_PASSED' : item.State) + '">' + escapeHtml(item.State) + '</span></div><div class="build-actions">' + lifecycleActions + '</div>' + instances + '<div class="build-meta">Run: ' + escapeHtml(shortId(item.RunId)) + '</div></article>';
  }).join('') : empty('Noch keine Container-Labs vorhanden.');
}

function parseSqlConnectionHost(connectionString) {
  const match = String(connectionString || '').match(/Data Source\s*=\s*([^;]+)/i);
  if (!match) return '127.0.0.1';
  const endpoint = String(match[1] || '').trim();
  if (!endpoint) return '127.0.0.1';
  return endpoint.split(',')[0].replace(/^\[(.+)\]$/, '$1');
}

function renderHyperVLabs(items) {
  $('#hyperv-labs').innerHTML = items.length ? items.map((item) => {
    const running = item.State === 'RUNNING' && item.VMState === 'Running';
    const isSqlLab = item.Workload !== 'windows';
    const sqlInstances = Array.isArray(item.SqlInstances) ? item.SqlInstances : (item.SqlInstances ? [item.SqlInstances] : []);
    const primarySqlInstance = sqlInstances.find((instance) => instance.IsDefault) || sqlInstances[0] || null;
    const sqlOperationInstanceId = primarySqlInstance && primarySqlInstance.InstanceId ? primarySqlInstance.InstanceId : item.InstanceId || 'primary';
    const sqlOperationPort = primarySqlInstance && primarySqlInstance.TcpPort ? Number(primarySqlInstance.TcpPort) : 1433;
    const sqlOperationHost = primarySqlInstance && primarySqlInstance.ConnectionString
      ? parseSqlConnectionHost(primarySqlInstance.ConnectionString)
      : parseSqlConnectionHost(item.ConnectionString);
    const sqlNeedsCompletion = isSqlLab && Boolean(item.ArtifactId) && item.SqlCompletionState === 'PENDING_COMPLETE_IMAGE';
    const persistent = item.PersistentStorage;
    const instanceDetails = sqlInstances.length
      ? '<div class="container-instance"><div class="build-meta"><strong>SQL-Instanzen in der VM</strong> · geprüft ' + escapeHtml(item.SqlInstancesInspectedAt || '–') + '</div>' + sqlInstances.map((instance) => {
        const endpoint = instance.ConnectionString ? '<div class="build-meta connection-string"><strong>Connection String:</strong> <code>' + escapeHtml(instance.ConnectionString) + '</code></div>' : '';
        const port = instance.TcpPort ? ' · TCP ' + escapeHtml(instance.TcpPort) : '';
        return '<div class="build-meta">' + escapeHtml(instance.Name || instance.ServiceName || '–') + ' · Dienst ' + escapeHtml(instance.ServiceStatus || '–') + port + '</div>' + endpoint;
      }).join('') + '</div>'
      : '';
    const primaryConnection = item.ConnectionString && !sqlInstances.length
      ? '<div class="build-meta connection-string"><strong>Connection String (Host-SSMS):</strong> <code>' + escapeHtml(item.ConnectionString) + '</code></div>'
      : '';
    const resource = resourceForInstance(item.Resources, item.InstanceId);
    const actions = [
      '<button class="button secondary" data-hyperv-action="' + (running ? 'StopLabReconcile' : 'StartLabReconcile') + '" data-run="' + escapeHtml(item.RunId) + '">' + (running ? 'Stoppen' : 'Starten') + '</button>',
      '<button class="button secondary" data-lab-resources="true" data-run="' + escapeHtml(item.RunId) + '" data-provider="hyperv" data-memory="' + escapeHtml(resource?.MemoryStartupMB || resource?.memoryStartupMB || '') + '" data-cpu="' + escapeHtml(resource?.ProcessorCount || resource?.processorCount || '') + '" data-requires-stopped="true">CPU / Speicher ändern</button>',
      (!running && !persistent) ? '<button class="button secondary" data-hyperv-action="EnableHyperVLabPersistentData" data-run="' + escapeHtml(item.RunId) + '">Daten-VHDX anhängen</button>' : '',
      (running && persistent?.state === 'ATTACHED_PENDING_INITIALIZATION') ? '<button class="button primary" data-hyperv-action="InitializeHyperVLabPersistentData" data-run="' + escapeHtml(item.RunId) + '">Daten-VHDX initialisieren</button>' : '',
      sqlNeedsCompletion ? '<button class="button primary" data-hyperv-action="CompleteHyperVLabSql" data-run="' + escapeHtml(item.RunId) + '">SQL, WMI und TCP/IP automatisch einrichten</button>' : '',
      (running && isSqlLab && !sqlNeedsCompletion) ? '<button class="button primary" data-hyperv-action="EnableHyperVLabHostSqlAccess" data-run="' + escapeHtml(item.RunId) + '">Hostzugriff reparieren</button>' : '',
      (running && isSqlLab) ? '<button class="button secondary" data-hyperv-action="InspectHyperVLabSqlInstances" data-run="' + escapeHtml(item.RunId) + '">SQL-Instanzen prüfen</button>' : '',
      (running && isSqlLab) ? '<button class="button secondary" data-container-operation="CreateHyperVLabDatabase" data-container-operation-kind="hyperv" data-run="' + escapeHtml(item.RunId) + '" data-container-operation-host="' + escapeHtml(sqlOperationHost) + '" data-instance="' + escapeHtml(sqlOperationInstanceId) + '" data-port="' + escapeHtml(String(sqlOperationPort)) + '">Datenbank anlegen</button>' : '',
      (running && isSqlLab) ? '<button class="button secondary" data-container-operation="ExecuteHyperVLabScript" data-container-operation-kind="hyperv" data-run="' + escapeHtml(item.RunId) + '" data-container-operation-host="' + escapeHtml(sqlOperationHost) + '" data-instance="' + escapeHtml(sqlOperationInstanceId) + '" data-port="' + escapeHtml(String(sqlOperationPort)) + '">SQL-Skript ausführen</button>' : '',
      '<button class="button secondary" data-hyperv-action="OpenHyperVConsole" data-run="' + escapeHtml(item.RunId) + '">VMConnect öffnen</button>',
      '<button class="button secondary" data-lab-rename="true" data-run="' + escapeHtml(item.RunId) + '" data-name="' + escapeHtml(item.Name || item.RunId) + '">Name ändern</button>',
      persistentStorageCandidatesForRun(item.RunId).length ? '<button class="button secondary" data-persistent-storage-removal-preview="true" data-run="' + escapeHtml(item.RunId) + '" data-name="' + escapeHtml(item.Name || item.RunId) + '">Retention prüfen</button>' : '',
      '<button class="button danger" data-hyperv-remove="true" data-run="' + escapeHtml(item.RunId) + '" data-name="' + escapeHtml(item.Name || item.RunId) + '">Entfernen</button>'
    ].join('');
    const sourceBased = item.BaseKind === 'existing-vm';
    const detail = ['VM: ' + (item.VMName || '–'), 'VM-Status: ' + (item.VMState || '–'), 'Autostart: ' + (item.AutoStart === 'on' ? 'ein' : 'aus'), sourceBased ? 'Basis: ' + (item.SourceVMName || 'bestehende VM') : (isSqlLab ? 'SQL Server ' + (item.SqlVersion || '–') : 'Reine Windows-VM')].join(' · ');
    const baseDetail = sourceBased ? 'Quelle: ' + (item.SourceVMName || '–') + ' · Original unverändert' : 'Vorlage: ' + shortId(item.ArtifactId);
    const persistentDetail = persistent ? '<div class="build-meta"><strong>Persistente Daten:</strong> Host ' + escapeHtml(persistent.hostPath || persistent.root || '–') + (persistent.guestPath ? ' → Gast ' + escapeHtml(persistent.guestPath) : '') + ' · ' + escapeHtml(persistent.state || 'eingebunden') + '</div>' : '';
    const backupDetail = persistent?.backupGuestPath ? '<div class="build-meta"><strong>Backup-Arbeitsbereich:</strong> Gast ' + escapeHtml(persistent.backupGuestPath) + ' auf eigener Daten-VHDX' + (persistent.backupMode === 'guest-data-vhdx' ? ' · nicht als Host-Ordner eingebunden' : '') + '</div>' : '';
    const nextStep = !isSqlLab
      ? (running ? 'Die reine Windows-VM läuft. VMConnect öffnen und Windows verwenden.' : 'VM starten und anschließend VMConnect öffnen.')
      : sqlNeedsCompletion ? (running ? 'SQL, WMI und TCP/IP automatisch einrichten; danach ist die VM vom Host aus erreichbar.' : 'VM starten; danach SQL, WMI und TCP/IP automatisch einrichten.') : (item.SqlCompletionState === 'REBOOT_REQUIRED' ? 'SQL Setup startet automatisch neu; der laufende Job wartet auf die anschließende WMI- und TCP/IP-Konfiguration.' : (running ? 'VM läuft und ist bei erfolgreicher Bereitstellung über ihren Connection String vom Host erreichbar.' : 'VM starten und anschließend VMConnect öffnen.'));
    return '<article class="build-card"><div class="build-card-top"><div><div class="build-title">' + escapeHtml(item.Name || shortId(item.RunId)) + '</div><div class="build-meta">' + escapeHtml(detail) + '</div></div><span class="status ' + statusClass(running ? 'TESTS_PASSED' : item.State) + '">' + escapeHtml(item.State) + '</span></div><p class="build-next"><strong>Nächster Schritt:</strong> ' + escapeHtml(nextStep) + '</p><div class="build-actions">' + actions + '</div><div class="build-meta">' + escapeHtml(resourceSummary(resource, 'hyperv')) + '</div>' + persistentDetail + backupDetail + instanceDetails + primaryConnection + '<div class="build-meta">Run: ' + escapeHtml(shortId(item.RunId)) + ' · ' + escapeHtml(baseDetail) + '</div></article>';
  }).join('') : empty('Noch keine regulären Hyper-V-Umgebungen vorhanden.');
}

function generateHyperVGuestPassword() {
  const groups = ['ABCDEFGHJKLMNPQRSTUVWXYZ', 'abcdefghijkmnopqrstuvwxyz', '23456789', '!#%+-_@'];
  const all = groups.join('');
  const randomIndex = (max) => crypto.getRandomValues(new Uint32Array(1))[0] % max;
  const characters = groups.map((group) => group[randomIndex(group.length)]);
  while (characters.length < 32) characters.push(all[randomIndex(all.length)]);
  for (let index = characters.length - 1; index > 0; index -= 1) {
    const swapIndex = randomIndex(index + 1);
    [characters[index], characters[swapIndex]] = [characters[swapIndex], characters[index]];
  }
  return characters.join('');
}

function updateHyperVGuestPasswordMode() {
  const generated = $('#hyperv-password-mode').value === 'generated';
  $('#hyperv-guest-password').type = generated ? 'text' : 'password';
  $('#hyperv-guest-password-repeat-label').hidden = generated;
  $('#hyperv-guest-password-repeat').required = !generated;
  $('#hyperv-generate-password').hidden = !generated;
  $('#hyperv-copy-password').hidden = !generated;
  if (generated && !$('#hyperv-guest-password').value) $('#hyperv-guest-password').value = generateHyperVGuestPassword();
}

function updateHyperVSaPasswordMode() {
  const hasSeparateSaPassword = Boolean($('#hyperv-sa-password').value);
  $('#hyperv-sa-password-repeat-label').hidden = !hasSeparateSaPassword;
  $('#hyperv-sa-password-repeat').required = hasSeparateSaPassword;
  if (!hasSeparateSaPassword) $('#hyperv-sa-password-repeat').value = '';
}

function renderAcceptance(items) {
  $('#acceptance').innerHTML = items.length ? items.map((item) => {
    const actions = acceptanceActions(item).map((button) => button.cleanup
      ? '<button class="button danger" data-build-cleanup="' + button.action + '" data-build="' + escapeHtml(item.BuildId) + '" data-build-kind="sql" data-build-published="' + Boolean(button.published) + '">' + escapeHtml(button.label) + '</button>'
      : '<button class="button ' + (button.action === 'RunSqlAcceptanceTests' ? 'primary' : 'secondary') + '" data-action="' + button.action + '" data-build="' + escapeHtml(item.BuildId) + '" data-credential="false" data-publish="false">' + escapeHtml(button.label) + '</button>'
    ).join('');
    const detail = [item.VMName || '–', item.Edition || '', item.ProductVersion || ''].filter(Boolean).join(' · ');
    return '<article class="build-card"><div class="build-card-top"><div><div class="build-title">SQL Server ' + escapeHtml(item.SqlVersion) + '</div><div class="build-meta">' + escapeHtml(detail) + '</div></div><span class="status ' + statusClass(item.State) + '">' + escapeHtml(item.State) + '</span></div><p class="build-next"><strong>Nächster Schritt:</strong> ' + escapeHtml(item.NextStep || 'Status prüfen.') + '</p><div class="build-actions">' + actions + '</div></article>';
  }).join('') : empty('Noch keine Abnahmeumgebungen vorhanden.');
}

async function refresh(mediaRoot) {
  const suffix = mediaRoot ? '?mediaRoot=' + encodeURIComponent(mediaRoot) : '';
  const response = await fetch('/api/workflow' + suffix);
  if (!response.ok) throw new Error(await response.text());
  const payload = await response.json();
  if (Object.prototype.hasOwnProperty.call(payload, 'Refreshing')) {
    if (payload.Snapshot) renderWorkflow(payload.Snapshot);
    else {
      $('#host-status').textContent = 'Inventar wird geladen …';
      $('#host-status').className = 'chip neutral';
      $('#notice').hidden = false;
      $('#notice').textContent = 'Windows-, SQL- und Hyper-V-Inventar wird im Hintergrund ermittelt. Live-Aktionen bleiben bedienbar.';
    }
    if (payload.Refreshing && !workflowRefreshTimer) {
      workflowRefreshTimer = window.setTimeout(() => {
        workflowRefreshTimer = null;
        refresh(mediaRoot).catch(showError);
      }, 750);
    }
    return;
  }
  renderWorkflow(payload);
}

async function refreshUiConfig() {
  const response = await fetch('/api/config');
  if (!response.ok) return;
  const config = await response.json();
  const requestedLimit = Number(config?.jobLogBurstLimit);
  uiConfig.jobLogBurstLimit = Number.isFinite(requestedLimit) ? Math.max(1, Math.floor(requestedLimit)) : uiConfig.jobLogBurstLimit;
}

function renderJobs(serverJobs) {
  const jobsByServer = serverJobs || [];
  const known = new Set(jobsByServer.map((job) => String(job.Id)));
  const optimisticJobIds = new Set(optimisticJobs.map((job) => String(job.Id)));
  optimisticJobs = optimisticJobs.filter((job) => !known.has(String(job.Id)));
  const jobs = [...optimisticJobs, ...jobsByServer];
  activeJobCount = jobs.filter((job) => ['Running', 'NotStarted', 'Submitting'].includes(job.State)).length;
  const anyRunning = activeJobCount > 0;
  $('#job-count').textContent = jobs.length + ' Aktion(en)';
  $('#jobs').innerHTML = jobs.length ? jobs.map((job) => {
    const running = ['Running', 'NotStarted', 'Submitting'].includes(job.State);
    const configuredLimit = Number(uiConfig.jobLogBurstLimit);
    const burstLimit = Number.isFinite(configuredLimit) ? Math.max(1, Math.floor(configuredLimit)) : 300;
    const elapsed = Number(job.ElapsedSeconds || Math.max(0, Math.floor((Date.now() - Date.parse(job.StartedAt || new Date().toISOString())) / 1000)) || 0);
    const runtime = running ? ' · läuft seit ' + elapsed + ' s' : '';
    const activityAge = job.LastActivityAt ? Math.max(0, Math.floor((Date.now() - Date.parse(job.LastActivityAt)) / 1000)) : null;
    const heartbeat = running ? '[HEARTBEAT] Job aktiv · Laufzeit ' + elapsed + ' s' + (activityAge === null ? ' · Auftrag wird an den lokalen Server übergeben.' : ' · letzte Servermeldung vor ' + activityAge + ' s.') : '';
    const jobId = String(job.Id);
    const previousLines = Array.isArray(jobLineCache[jobId]) ? jobLineCache[jobId] : [];
    const incomingLines = Array.isArray(job.Lines) ? job.Lines : [];
    const isOptimisticOnly = optimisticJobIds.has(jobId) && !known.has(jobId);
    const mergedLines = (isOptimisticOnly ? incomingLines : [...previousLines, ...incomingLines]).slice(-burstLimit);
    jobLineCache[jobId] = mergedLines;
    const lines = [...mergedLines, ...(heartbeat ? [heartbeat] : [])].join('\n') || 'Aktion läuft …';
    return '<article class="job"><div class="job-header"><strong>' + escapeHtml(job.Action + runtime) + '</strong><span class="status ' + (job.State === 'Failed' ? 'failed' : job.State === 'Completed' ? 'done' : 'pending') + '">' + escapeHtml(job.State) + '</span></div>' + (running ? '<div class="job-progress" aria-label="Aktion läuft"></div>' : '') + '<pre class="log">' + escapeHtml(lines) + '</pre></article>';
  }).join('') : empty('Noch keine Aktion wurde aus der Oberfläche gestartet.');
  const feedback = $('#action-feedback');
  const presentJobIds = new Set(jobs.map((job) => String(job.Id)));
  Object.keys(jobLineCache).forEach((jobId) => {
    if (!presentJobIds.has(jobId)) { delete jobLineCache[jobId]; }
  });
  if (!anyRunning) feedback.hidden = true;
}

async function refreshJobs() {
  const response = await fetch('/api/jobs');
  if (!response.ok) return;
  const payload = await response.json();
  renderJobs(Array.isArray(payload) ? payload : (payload ? [payload] : []));
}

async function startAction(action, parameters) {
  const optimistic = { Id: 'pending-' + Date.now(), Action: action, State: 'Submitting', StartedAt: new Date().toISOString(), Lines: ['[ANFORDERUNG] ' + action + ' wurde im Browser ausgelöst.', '[WARTEN] Auftrag wird an den lokalen Workflow-Server übergeben.'] };
  jobLineCache[String(optimistic.Id)] = Array.isArray(optimistic.Lines) ? optimistic.Lines : [];
  optimisticJobs.push(optimistic);
  renderJobs([]);
  const feedback = $('#action-feedback');
  $('#action-feedback-text').textContent = 'Auftrag wird angenommen: ' + action + ' – Live-Log und Herzschlag sind sofort sichtbar.';
  feedback.hidden = false;
  let response;
  try {
    response = await fetch('/api/actions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, parameters })
    });
    if (!response.ok) throw new Error(await response.text());
    const accepted = await response.json();
    const acceptedId = accepted.id || optimistic.Id;
    if (acceptedId && acceptedId !== optimistic.Id) {
      const previousId = String(optimistic.Id);
      const nextId = String(acceptedId);
      if (jobLineCache[previousId]) {
        jobLineCache[nextId] = jobLineCache[previousId];
        delete jobLineCache[previousId];
      }
      optimistic.Id = acceptedId;
    }
    else {
      optimistic.Id = acceptedId;
    }
    optimistic.State = 'Running';
    optimistic.Lines.push('[AKZEPTIERT] Hintergrundjob ' + optimistic.Id + ' wurde gestartet.');
    renderJobs([]);
    refreshJobs().catch(() => {});
    // Die komplette Workflow-Inventur kann ISO-Metadaten prüfen und ist
    // bewusst nicht Teil des unmittelbaren Klickpfads. Der Job bleibt jede
    // Sekunde sichtbar; nach kurzer Zeit wird die fachliche Ansicht erneuert.
    window.setTimeout(() => refresh().catch(showError), 3500);
  } catch (error) {
    optimisticJobs = optimisticJobs.filter((job) => job !== optimistic);
    renderJobs([]);
    throw error;
  }
}

function showError(error) {
  const notice = $('#notice');
  notice.hidden = false;
  notice.textContent = error.message || String(error);
}

function openBuild(kind) {
  const sqlBuild = kind === 'sql' || kind === 'sql-fresh';
  const freshSqlBuild = kind === 'sql-fresh';
  $('#build-type').value = kind;
  $('#build-kind').textContent = sqlBuild ? 'SQL-PREPARED-IMAGE' : 'WINDOWS-OS-BASELINE';
  $('#build-title').textContent = kind === 'sql' ? 'Erweitert: SQL-Prepared-Image aus OS-Baseline' : freshSqlBuild ? 'Neues SQL-Prepared-Image' : 'Erweitert: Windows-OS-Baseline';
  $('#sql-fields').hidden = !sqlBuild;
  $('#sql-hash-fields').hidden = !sqlBuild;
  $('#sql-image-name-field').hidden = !sqlBuild;
  $('#sql-parent-field').hidden = kind !== 'sql';
  $('#sql-parent-details').hidden = kind !== 'sql';
  $('#windows-fields').hidden = kind === 'sql';
  $('#windows-hash-fields').hidden = kind === 'sql';
  $('#windows-media').disabled = kind === 'sql';
  $('#sql-media').disabled = !sqlBuild;
  $('#build-note').textContent = kind === 'sql'
    ? 'Expertenpfad: Aus der gewählten unveränderlichen OS-Baseline wird eine eigene differenzierende VHDX erstellt. Windows muss nicht erneut installiert werden; nur OOBE und SQL PrepareImage erfolgen in der neuen Build-VM.'
    : freshSqlBuild
      ? 'Standardpfad: Windows und SQL werden gemeinsam aus den Original-ISOs installiert und anschließend genau einmal final generalisiert. Vor dem Build müssen die SHA-256-Werte der ausgewählten ISOs geprüft und gespeichert sein.'
      : 'Expertenpfad: Windows-ISOs können in beliebigen Unterordnern des Media Root liegen. Vor dem Build muss der SHA-256 der ausgewählten ISO geprüft und gespeichert sein.';
  $('#sql-image-name').value = '';
  $('#media-root').value = workflow?.Defaults?.MediaRoot || '';
  renderWindowsInstallationMedia(workflow?.WindowsInstallationMedia || [], freshSqlBuild);
  if (sqlBuild) renderSqlInstallationMedia(workflow?.SqlInstallationMedia || []);
  if (kind === 'sql') renderSqlParentOptions(workflow?.WindowsBaselines || []);
  $('#build-dialog').showModal();
}

function dateToGerman(value) {
  const day = String(value.getDate()).padStart(2, '0');
  const month = String(value.getMonth() + 1).padStart(2, '0');
  return day + '.' + month + '.' + value.getFullYear();
}

function parseGermanDate(value) {
  const match = String(value || '').trim().match(/^(\d{2})\.(\d{2})\.(\d{4})$/);
  if (!match) throw new Error('Bitte das Ablaufdatum im Format TT.MM.JJJJ eingeben.');
  const iso = match[3] + '-' + match[2] + '-' + match[1];
  const parsed = new Date(iso + 'T00:00:00');
  if (Number.isNaN(parsed.getTime()) || parsed.getFullYear() !== Number(match[3]) || parsed.getMonth() + 1 !== Number(match[2]) || parsed.getDate() !== Number(match[1])) {
    throw new Error('Das eingegebene Ablaufdatum ist ungültig.');
  }
  return iso;
}

function renderContainerSampleOptions(sqlVersion) {
  const select = $('#container-sample');
  const version = Number(String(sqlVersion || '').match(/^\d{4}/)?.[0] || 0);
  const catalog = workflow?.SampleDatabases;
  if (!Array.isArray(catalog)) {
    select.innerHTML = '<option value="">Testdatenbank-Katalog wird erst nach einem Neustart des UI-Servers geladen …</option>';
    updateContainerSampleSelection();
    return;
  }
  const samples = catalog.filter((sample) => !sample.MinSqlVersion || Number(sample.MinSqlVersion) <= version);
  select.innerHTML = samples.map((sample) => {
    const trustRequired = sample.TrustStatus === 'TRUST_REQUIRED';
    const size = sample.DownloadSizeMB ? ' · ' + sample.DownloadSizeMB + ' MB' : '';
    const type = sample.ArtifactType ? ' · ' + sample.ArtifactType : '';
    return '<option value="' + escapeHtml(sample.SampleId + ':' + sample.Variant) + '" data-database="' + escapeHtml(sample.ExpectedDatabase) + '" data-artifact-type="' + escapeHtml(sample.ArtifactType || '') + '" data-trust-required="' + trustRequired + '" data-sha256="' + escapeHtml(sample.ExpectedSha256 || '') + '">' + escapeHtml(sample.DisplayName) + ' · ' + escapeHtml(sample.Variant) + ' → ' + escapeHtml(sample.ExpectedDatabase) + type + size + '</option>';
  }).join('');
  updateContainerSampleSelection();
}

function renderContainerLibraryBackups(sqlVersion) {
  const select = $('#container-library-backup');
  const targetMajor = ({ 2017: 14, 2019: 15, 2022: 16, 2025: 17 })[Number(String(sqlVersion || '').match(/^\d{4}/)?.[0] || 0)] || 0;
  const catalog = workflow?.BackupLibrary;
  if (!Array.isArray(catalog)) {
    select.innerHTML = '<option value="">Backup-Bibliothek wird erst nach einem Neustart des UI-Servers geladen …</option>';
    updateContainerLibraryBackupSelection();
    return;
  }
  const backups = catalog.filter((backup) => backup.Availability === 'SELECTABLE' && (!targetMajor || Number(backup.SourceSqlMajorVersion) <= targetMajor));
  select.innerHTML = '<option value="">Kein Bibliotheksbackup ausgewählt</option>' + backups.map((backup) => {
    const size = backup.Bytes ? ' · ' + Math.ceil(Number(backup.Bytes) / 1048576) + ' MB' : '';
    return '<option value="' + escapeHtml(backup.BackupSetId) + '" data-database="' + escapeHtml(backup.DatabaseName) + '">' + escapeHtml(backup.DatabaseName) + ' · ' + escapeHtml(backup.SourceProvider) + ' · SQL ' + escapeHtml(backup.SourceSqlMajorVersion) + size + '</option>';
  }).join('');
  updateContainerLibraryBackupSelection();
}

function updateContainerLibraryBackupSelection() {
  const option = $('#container-library-backup').selectedOptions[0];
  const selected = Boolean(option?.value);
  if (selected) {
    [...$('#container-sample').options].forEach((sample) => { sample.selected = false; });
    $('#container-database-name').disabled = false;
    $('#container-database-name').value = option.dataset?.database || '';
    $('#container-sample-note').textContent = 'Für diesen Restore ist keine Katalog-Testdatenbank ausgewählt.';
    $('#container-sample-hash-field').hidden = true;
    $('#container-sample-trust-field').hidden = true;
    $('#container-sample-trust').checked = false;
  }
  else if ([...$('#container-sample').selectedOptions].filter((sample) => sample.value).length === 0) {
    $('#container-database-name').disabled = false;
    $('#container-database-name').value = '';
  }
  $('#container-library-backup-note').textContent = selected
    ? 'Das Backup wird beim Start anhand seiner BackupSetId erneut status-, evidence- und SHA-256-geprüft.'
    : 'Die Auswahl erfolgt ausschließlich über die stabile BackupSetId; lokale Hostpfade werden nicht an den Browser übertragen.';
}

function updateContainerSampleSelection() {
  const options = [...$('#container-sample').selectedOptions].filter((option) => option.value);
  const option = options[0];
  const selectedSample = options.length > 0;
  if (selectedSample) {
    $('#container-library-backup').value = '';
    updateContainerLibraryBackupSelection();
  }
  const trustRequired = options.some((item) => item.dataset?.trustRequired === 'true');
  const multipleSamples = options.length > 1;
  $('#container-database-name').disabled = selectedSample;
  if (selectedSample) $('#container-database-name').value = multipleSamples ? options.length + ' Testdatenbanken ausgewählt' : (option?.dataset?.database || '');
  else $('#container-database-name').value = '';
  const artifactType = option?.dataset?.artifactType || 'backup';
  $('#container-sample-note').textContent = selectedSample
    ? (multipleSamples ? options.length + ' Testdatenbanken werden nacheinander installiert und verifiziert.' : 'Die Zieldatenbank wird vom Katalog festgelegt. Handler: ' + artifactType + '.')
    : 'Ohne Auswahl wird die oben angegebene leere Datenbank angelegt.';
  const expectedSha = option?.dataset?.sha256 || '';
  $('#container-sample-hash-field').hidden = !selectedSample || multipleSamples;
  $('#container-sample-sha256').value = multipleSamples ? '' : expectedSha;
  $('#container-sample-sha256').disabled = multipleSamples || Boolean(expectedSha);
  $('#container-sample-trust-field').hidden = !trustRequired || (!multipleSamples && Boolean(expectedSha));
  // Eine Freigabe ist nur für die aktuell ausgewählte Variante gültig und
  // darf niemals aus einer vorherigen Dialognutzung übernommen werden.
  $('#container-sample-trust').checked = false;
}

function openContainerOperation(action, runId, port, instanceId, sqlVersion, kind, host) {
  const operationKind = kind === 'hyperv' ? 'hyperv' : 'container';
  const isCreateAction = action === 'CreateContainerDatabase' || action === 'CreateHyperVLabDatabase';
  const isExportAction = action === 'ExportContainerDatabasePackage';
  const databaseAction = isCreateAction || isExportAction;
  $('#container-operation-action').value = action;
  $('#container-operation-run').value = runId;
  $('#container-operation-port').value = port;
  $('#container-operation-host').value = host || '127.0.0.1';
  $('#container-operation-kind').value = operationKind;
  $('#container-operation-badge').textContent = 'LAB-AKTION';
  $('#container-operation-password-label').hidden = isExportAction;
  $('#container-operation-password').required = !isExportAction;
  $('#container-operation-password-text').textContent = operationKind === 'hyperv' ? 'Gastpasswort' : 'SA-Passwort';
  $('#container-operation-password-note').hidden = isExportAction;
  $('#container-operation-password-note').textContent = operationKind === 'hyperv'
    ? 'Das Passwort dient für PowerShell Direct und den SQL-Zugriff auf die laufende Hyper-V-VM.'
    : 'Das Passwort wird nicht gespeichert oder im Log angezeigt.';
  $('#container-operation-instance').value = instanceId || 'primary';
  $('#container-operation-title').textContent = isExportAction ? 'Datenbank als Paket veröffentlichen' : (databaseAction ? 'Datenbank anlegen oder wiederherstellen' : 'SQL-Skript ausführen');
  $('#container-database-field').hidden = !databaseAction;
  const showContainerSamples = isCreateAction && operationKind === 'container';
  $('#container-library-backup-field').hidden = !showContainerSamples;
  $('#container-library-backup-note').hidden = !showContainerSamples;
  $('#container-sample-field').hidden = !showContainerSamples;
  $('#container-sample-note').hidden = !showContainerSamples;
  $('#container-sample-hash-field').hidden = true;
  $('#container-sample-trust-field').hidden = true;
  $('#container-sample-sha256').value = '';
  $('#container-sample-trust').checked = false;
  $('#container-script-field').hidden = databaseAction;
  $('#container-script-database-field').hidden = databaseAction;
  if (isExportAction) {
    $('#container-sample-note').hidden = false;
    $('#container-sample-note').textContent = 'Der Export übergibt ausschließlich Run, Instanz und Datenbankname. Die Quelle wird serverseitig neu gebunden, exklusiv offline genommen und automatisch per SHA-256 verifiziert.';
  }
  if (isCreateAction && operationKind === 'container') {
    renderContainerLibraryBackups(sqlVersion);
    renderContainerSampleOptions(sqlVersion);
  }
  $('#container-operation-dialog').showModal();
}

function openResourceDialog(button) {
  const provider = button.dataset.provider;
  const memory = Number(button.dataset.memory || (provider === 'hyperv' ? 4096 : 4096));
  const cpu = Number(button.dataset.cpu || 4);
  const instanceCount = Number(button.dataset.instances || 1);
  $('#resource-run').value = button.dataset.run;
  $('#resource-memory').value = memory;
  $('#resource-processors').value = cpu;
  $('#resource-memory-label').firstChild.textContent = provider === 'hyperv' ? 'Startspeicher (MB)' : 'Speicher-Limit (MB)';
  $('#resource-current').textContent = 'Aktuell aus der Runtime erkannt: ' + memory + ' MB · ' + cpu + ' CPU' + (instanceCount > 1 ? ' · wird auf ' + instanceCount + ' Container angewendet.' : '.');
  $('#resource-note').textContent = provider === 'hyperv'
    ? 'Hyper-V muss zum Ändern ausgeschaltet sein. Der dynamische Speicherbereich wird sinnvoll auf mindestens 1 GB bzw. die Hälfte des Startwerts und maximal das Doppelte gesetzt – nicht auf 512 MB oder 1 TB.'
    : 'Docker/Podman übernehmen die Werte sofort über ihre Runtime-Limits. Für mehrere Instanzen dieses Labs gelten die Werte einheitlich.';
  $('#resource-dialog').showModal();
}

function queueBackgroundAction(action, parameters, dialog, onQueued) {
  // Das unmittelbare Signal und der optimistische Live-Log-Eintrag entstehen
  // synchron vor dem ersten await. Der Dialog darf deshalb nicht einen langen
  // HTTP-/Inventarzugriff überdecken.
  dialog?.close();
  if (onQueued) onQueued();
  startAction(action, parameters).catch(showError);
}

let pendingConfirmation = null;
function openConfirmation(title, message, action, parameters, submitLabel = 'Entfernen') {
  pendingConfirmation = { action, parameters };
  $('#confirmation-title').textContent = title;
  $('#confirmation-message').textContent = message;
  $('#confirmation-submit').textContent = submitLabel;
  $('#confirmation-dialog').showModal();
}

const persistentStoragePolicyLabels = {
  DELETE_WITH_RUN: 'Mit dem Run löschen',
  RETAIN_INSTANCE_STORE: 'Instanzstore katalogisiert behalten',
  BACKUP_ON_REMOVE: 'Backups erzeugen und Store behalten',
  PACKAGE_ON_REMOVE: 'Datenbankpakete erzeugen und Store behalten',
  BACKUP_AND_PACKAGE: 'Backups und Pakete erzeugen, Store behalten',
  EXTERNAL_UNMANAGED: 'Nur externe Bindung lösen'
};

function updateContainerStorageSelection() {
  const enabled = $('#container-persistent-data').checked;
  const selection = $('#container-storage-selection');
  selection.hidden = !enabled;
  const action = $('#container-storage-action').value;
  const sourceLabel = $('#container-storage-source-label');
  sourceLabel.hidden = !enabled || action === 'NEW';
  if (!enabled || action === 'NEW') return;

  const provider = $('#container-provider').value;
  const sqlMajorVersion = $('#container-version').value.substring(0, 4);
  const current = $('#container-storage-source').value;
  const candidates = (Array.isArray(workflow?.ContainerInstanceStoreCandidates) ? workflow.ContainerInstanceStoreCandidates : [])
    .filter((item) => item.Provider === provider && item.SqlMajorVersion === sqlMajorVersion &&
      Array.isArray(item.AvailableActions) && item.AvailableActions.includes(action));
  $('#container-storage-source').innerHTML = candidates.length
    ? candidates.map((item) => '<option value="' + escapeHtml(item.PersistentStorageId) + '">' + escapeHtml((item.DisplayName || 'Instanzstore') + ' · ' + shortId(item.PersistentStorageId)) + '</option>').join('')
    : '<option value="">Kein kompatibler detached Instanzstore verfügbar</option>';
  if (candidates.some((item) => item.PersistentStorageId === current)) $('#container-storage-source').value = current;
  $('#container-storage-note').textContent = candidates.length
    ? 'Die Quelle wird direkt vor jeder Mutation anhand ihrer stabilen PersistentStorageId, SQL-Major-Version, Runtime-Labels, Attachments und Lease erneut geprüft.'
    : 'Für Provider und SQL-Major-Version ist kein sicher verwendbarer detached Instanzstore verfügbar.';
}

function persistentStorageCandidatesForRun(runId) {
  const candidates = Array.isArray(workflow?.PersistentStorageRemovalCandidates) ? workflow.PersistentStorageRemovalCandidates : [];
  return candidates.filter((item) => item.RunId === runId && Array.isArray(item.AllowedPolicies) && item.AllowedPolicies.length > 0);
}

function openPersistentStorageRemovalPreview(runId, labName) {
  const candidates = persistentStorageCandidatesForRun(runId);
  if (!candidates.length) {
    showError(new Error('Für diese Umgebung sind keine katalogisierten Retention-Auswahlen verfügbar.'));
    return;
  }
  $('#persistent-storage-removal-run').value = runId;
  $('#persistent-storage-removal-note').textContent = 'Umgebung „' + labName + '“ · Auswahl ausschließlich über stabile PersistentStorageIds.';
  $('#persistent-storage-removal-result').hidden = true;
  $('#persistent-storage-removal-result').innerHTML = '';
  pendingPersistentStorageRemoval = null;
  $('#persistent-storage-removal-execute').disabled = true;
  $('#persistent-storage-removal-selections').innerHTML = candidates.map((candidate) => {
    const policies = candidate.AllowedPolicies.map((policy) => '<option value="' + escapeHtml(policy) + '">' + escapeHtml(persistentStoragePolicyLabels[policy] || policy) + '</option>').join('');
    const references = Array.isArray(candidate.DatabaseReferences) ? candidate.DatabaseReferences : [];
    const databaseSelection = references.length
      ? '<label>Datenbankreferenzen (für Backup/Package)<select class="persistent-storage-database-references" multiple size="' + Math.min(6, Math.max(2, references.length)) + '">' + references.map((reference) => '<option value="' + escapeHtml(reference.ReferenceId) + '">' + escapeHtml(reference.DisplayName || shortId(reference.ReferenceId)) + '</option>').join('') + '</select></label>'
      : '<p class="form-note">Keine aktiven Datenbankreferenzen katalogisiert; Export-Policies werden dadurch fail-closed blockiert.</p>';
    return '<div class="list-item persistent-storage-removal-selection" data-storage-id="' + escapeHtml(candidate.PersistentStorageId) + '"><div><strong>' + escapeHtml(candidate.DisplayName || candidate.StorageClass) + '</strong><span>' + escapeHtml(candidate.Provider + ' · ' + candidate.StorageClass + ' · ' + candidate.State + ' · ' + shortId(candidate.PersistentStorageId)) + '</span></div><label>Policy<select class="persistent-storage-policy" required>' + policies + '</select></label>' + databaseSelection + '</div>';
  }).join('');
  $('#persistent-storage-removal-dialog').showModal();
}

function renderPersistentStorageRemovalPlan(plan, selections) {
  const summary = plan?.Summary || {};
  const execution = plan?.Execution || {};
  const stores = Array.isArray(plan?.Stores) ? plan.Stores : [];
  const issues = Array.isArray(plan?.Issues) ? plan.Issues : [];
  const statusClassName = statusClass(plan?.Status || 'BLOCKED');
  const storeHtml = stores.map((store) => {
    const blockers = Array.isArray(store.Blockers) && store.Blockers.length ? '<div class="build-meta"><strong>Blocker:</strong> ' + escapeHtml(store.Blockers.join(', ')) + '</div>' : '';
    const steps = Array.isArray(store.Steps) ? store.Steps.map((step) => escapeHtml(step.Order + '. ' + step.Action + (step.Mutation !== 'NONE' ? ' [' + step.Mutation + ']' : ''))).join('<br>') : '';
    return '<div class="list-item"><div><strong>' + escapeHtml(store.Outcome) + '</strong><span>' + escapeHtml(shortId(store.PersistentStorageId) + ' · ' + (store.Policy || 'automatisch behalten')) + '</span><div class="build-meta">' + steps + '</div>' + blockers + '</div></div>';
  }).join('');
  const executionStatus = execution.Status || 'BLOCKED';
  const executionReason = execution.Reason || 'PLAN_EXECUTION_STATUS_UNAVAILABLE';
  $('#persistent-storage-removal-result').innerHTML = '<div class="build-card-top"><strong>Planstatus</strong><span class="status ' + statusClassName + '">' + escapeHtml(plan?.Status || 'BLOCKED') + '</span></div><div class="build-meta"><strong>Ausführung:</strong> ' + escapeHtml(executionStatus + ' · ' + executionReason) + '</div><div class="build-meta">' + escapeHtml((summary.StoreCount || 0) + ' Store(s) · ' + (summary.RecoveryGuardedSteps || 0) + ' recovery-geschützte Schritte · ' + (summary.Blockers || 0) + ' Blocker') + '</div>' + (issues.length ? '<div class="build-meta"><strong>Issues:</strong> ' + escapeHtml(issues.join(', ')) + '</div>' : '') + storeHtml;
  $('#persistent-storage-removal-result').hidden = false;
  const executable = executionStatus === 'EXECUTABLE' && plan?.Status === 'READY' && selections.length > 0;
  pendingPersistentStorageRemoval = executable ? { runId: $('#persistent-storage-removal-run').value, selections, plan } : null;
  $('#persistent-storage-removal-execute').disabled = !executable;
}

document.addEventListener('click', async (event) => {
  const opener = event.target.closest('[data-open-build]');
  if (opener) { openBuild(opener.dataset.openBuild); return; }
  const containerAction = event.target.closest('[data-container-action]');
  if (containerAction) {
    try { await startAction(containerAction.dataset.containerAction, { BuildId: containerAction.dataset.run }); } catch (error) { showError(error); }
    return;
  }
  const hypervAction = event.target.closest('[data-hyperv-action]');
  if (hypervAction) {
    if (['CompleteHyperVLabSql', 'EnableHyperVLabHostSqlAccess', 'InspectHyperVLabSqlInstances', 'InitializeHyperVLabPersistentData'].includes(hypervAction.dataset.hypervAction)) {
      const inspect = hypervAction.dataset.hypervAction === 'InspectHyperVLabSqlInstances';
      const initializePersistentData = hypervAction.dataset.hypervAction === 'InitializeHyperVLabPersistentData';
      const hostSql = hypervAction.dataset.hypervAction === 'EnableHyperVLabHostSqlAccess';
      const sqlCompletion = hypervAction.dataset.hypervAction === 'CompleteHyperVLabSql';
      $('#credential-action').value = hypervAction.dataset.hypervAction;
      $('#credential-build').value = hypervAction.dataset.run;
      $('#credential-sa-password-label').hidden = !(hostSql || sqlCompletion);
      $('#credential-sa-password').value = '';
      $('#credential-title').textContent = initializePersistentData ? 'Daten-VHDX initialisieren' : (inspect ? 'SQL-Instanzen prüfen' : (hostSql ? 'Host-SSMS einrichten' : 'SQL CompleteImage'));
      $('#credential-note').textContent = initializePersistentData
        ? 'Das lokale Administratorpasswort wird einmalig benötigt, um ausschließlich den neu angehängten Lab-Datenträger zu formatieren und unter einem freien Gastbuchstaben einzubinden (bevorzugt S:\\SQLData).'
        : inspect
        ? 'Das lokale Administratorpasswort wird einmalig für eine ausschließlich lesende Prüfung von SQL-Instanzen, Diensten und TCP-Ports in dieser laufenden Lab-VM benötigt.'
        : hostSql
        ? 'Der laufenden VM wird ein verbindlicher Lab-Switch, eine feste Gast-IP, SQL-TCP und eine auf diesen Host beschränkte Firewallregel eingerichtet. Optional kann ein eigenständiges SA-Passwort gesetzt werden; leer übernimmt das Gastpasswort. Fehlt der SQL-Dienst, zuerst „SQL CompleteImage ausführen“ wählen. Kein Passwort wird protokolliert.'
        : 'Das lokale Administratorpasswort wird einmalig benötigt, um SQL Server in dieser laufenden Lab-VM zu vervollständigen. Danach werden ein möglicher SQL-Setup-Neustart abgewartet, der SQL-WMI-Provider geprüft beziehungsweise repariert sowie feste Lab-IP, SQL-TCP und die auf den Host beschränkte Firewallregel eingerichtet. Optional kann ein eigenständiges SA-Passwort gesetzt werden; leer übernimmt das Gastpasswort.';
      $('#credential-dialog').showModal();
      return;
    }
    try { await startAction(hypervAction.dataset.hypervAction, { BuildId: hypervAction.dataset.run }); } catch (error) { showError(error); }
    return;
  }
  const databasePackageAttach = event.target.closest('#database-package-attach');
  if (databasePackageAttach) {
    const packageId = $('#database-package-source').value;
    const targetSelect = $('#database-package-target');
    const targetRunId = targetSelect.value;
    const targetOption = targetSelect.selectedOptions[0];
    if (!packageId || !targetRunId) { showError(new Error('Bitte Paket und laufendes Hyper-V-SQL-Ziel auswählen.')); return; }
    pendingDatabasePackageAttach = {
      DatabasePackageId: packageId,
      InstanceId: targetOption?.dataset.instance || 'primary',
      DataRoot: workflow?.Defaults?.DataRoot || ''
    };
    $('#credential-action').value = 'AttachHyperVDatabasePackage';
    $('#credential-build').value = targetRunId;
    $('#credential-sa-password-label').hidden = true;
    $('#credential-sa-password').value = '';
    $('#credential-title').textContent = 'Datenbankpaket sicher attachen';
    $('#credential-note').textContent = 'Das Gast-Administratorpasswort wird einmalig für PowerShell Direct benötigt. Das Paket wird vollständig verifiziert, in das live gebundene SQL-Default-Data-Ziel kopiert, dort erneut gehasht und erst danach attached. Kein freier Pfad und kein Passwort werden gespeichert.';
    $('#credential-dialog').showModal();
    return;
  }
  const persistentDataRelease = event.target.closest('#hyperv-persistent-data-release');
  if (persistentDataRelease) {
    const selected = (workflow?.HyperVPersistentDataCandidates || []).find((item) =>
      item.PersistentStorageId === $('#hyperv-persistent-data-source').value);
    if (!selected?.PersistentStorageId || !selected?.BoundRunId) { showError(new Error('Bitte eine freigabefähige Daten-VHDX auswählen.')); return; }
    pendingHyperVPersistentData = { PersistentStorageId: selected.PersistentStorageId, DataRoot: workflow?.Defaults?.DataRoot || '' };
    $('#credential-action').value = 'ReleaseHyperVPersistentData';
    $('#credential-build').value = selected.BoundRunId;
    $('#credential-sa-password-label').hidden = false;
    $('#credential-sa-password').value = '';
    $('#credential-title').textContent = 'Daten-VHDX sauber freigeben';
    $('#credential-note').textContent = 'Gast- und optional abweichendes SA-Passwort werden nur für die Live-Prüfung verwendet. Aktive SQL-Dateien blockieren die Freigabe. Bei Erfolg wird der Gast sauber heruntergefahren, die VHDX detached und der Katalog atomar freigegeben.';
    $('#credential-dialog').showModal();
    return;
  }
  const persistentDataReattach = event.target.closest('#hyperv-persistent-data-reattach');
  const persistentDataClone = event.target.closest('#hyperv-persistent-data-clone');
  if (persistentDataReattach || persistentDataClone) {
    const storageId = $('#hyperv-persistent-data-source').value;
    const targetRunId = $('#hyperv-persistent-data-target').value;
    if (!storageId || !targetRunId) { showError(new Error('Bitte Daten-VHDX und kompatible ausgeschaltete Ziel-VM auswählen.')); return; }
    const action = persistentDataReattach ? 'ReattachHyperVPersistentData' : 'CloneHyperVPersistentData';
    const label = persistentDataReattach ? 'Daten-VHDX reattachen' : 'Daten-VHDX klonen';
    const message = persistentDataReattach
      ? 'Die freigegebene Daten-VHDX an die gewählte VM binden? Datenbankdateien bleiben offline und benötigen danach ein explizites Restore oder Attach.'
      : 'Eine eigenständige, katalogisierte Kopie der freigegebenen Daten-VHDX für die gewählte VM erzeugen? Die Quelle bleibt unverändert.';
    openConfirmation(label, message, action, { BuildId: targetRunId, PersistentStorageId: storageId, DataRoot: workflow?.Defaults?.DataRoot || '' }, persistentDataReattach ? 'Reattach' : 'Klonen');
    return;
  }
  const operation = event.target.closest('[data-container-operation]');
  if (operation) {
    openContainerOperation(operation.dataset.containerOperation, operation.dataset.run, operation.dataset.port, operation.dataset.instance, operation.dataset.sqlVersion, operation.dataset.containerOperationKind, operation.dataset.containerOperationHost);
    return;
  }
  const labRename = event.target.closest('[data-lab-rename]');
  if (labRename) {
    const currentName = labRename.dataset.name || '–';
    $('#lab-name-run').value = labRename.dataset.run;
    $('#lab-current-name').textContent = currentName;
    $('#lab-display-name').value = currentName === '–' ? '' : currentName;
    $('#lab-name-dialog').showModal();
    return;
  }
  const resourceButton = event.target.closest('[data-lab-resources]');
  if (resourceButton) { openResourceDialog(resourceButton); return; }
  const retentionPreview = event.target.closest('[data-persistent-storage-removal-preview]');
  if (retentionPreview) {
    openPersistentStorageRemovalPreview(retentionPreview.dataset.run, retentionPreview.dataset.name || retentionPreview.dataset.run);
    return;
  }
  const remove = event.target.closest('[data-container-remove]');
  if (remove) {
    openConfirmation('Container-Lab entfernen', 'Container-Lab „' + remove.dataset.name + '“ wirklich entfernen? Der Container und sein Workflow-Run werden bereinigt.', 'RemoveContainerLab', { BuildId: remove.dataset.run });
    return;
  }
  const hypervRemove = event.target.closest('[data-hyperv-remove]');
  if (hypervRemove) {
    openConfirmation('Hyper-V-Umgebung entfernen', 'Hyper-V-Umgebung „' + hypervRemove.dataset.name + '“ wirklich entfernen? Die VM und ihre differenzierenden run-lokalen VHDX werden gelöscht. Das Prepared-Image bleibt unverändert.', 'RemoveHyperVLab', { BuildId: hypervRemove.dataset.run });
    return;
  }
  const buildCleanup = event.target.closest('[data-build-cleanup]');
  if (buildCleanup) {
    const kind = buildCleanup.dataset.buildKind === 'windows' ? 'Windows-Builder' : 'SQL-Builder';
    const published = buildCleanup.dataset.buildPublished === 'true';
    const message = published
      ? kind + ' „' + buildCleanup.dataset.build + '“ aus der Workflow-Ansicht entfernen? Das veröffentlichte Image bleibt erhalten und kann anschließend separat gelöscht werden.'
      : kind + ' „' + buildCleanup.dataset.build + '“ wirklich aufräumen? Die zugehörige VM und buildlokale VHDX werden entfernt. Veröffentlichte Images bleiben unverändert.';
    openConfirmation(published ? 'Versiegelten Build entfernen' : kind + ' aufräumen', message, buildCleanup.dataset.buildCleanup, { BuildId: buildCleanup.dataset.build }, published ? 'Build entfernen' : 'Aufräumen');
    return;
  }
  const artifactRemove = event.target.closest('[data-artifact-remove]');
  if (artifactRemove) {
    const kind = artifactRemove.dataset.artifactKind;
    openConfirmation(kind + ' löschen', kind + ' „' + artifactRemove.dataset.artifact + '“ wirklich löschen? Die registrierte immutable VHDX und ihre Metadaten werden entfernt. Falls ein aktiver Build oder Lab-Klon das Image noch verwendet, wird das Löschen sicher blockiert.', 'RemoveHyperVImageArtifact', { ArtifactId: artifactRemove.dataset.artifact }, 'Image löschen');
    return;
  }
  const artifactRename = event.target.closest('[data-artifact-rename]');
  if (artifactRename) {
    $('#artifact-name-id').value = artifactRename.dataset.artifact;
    const currentName = artifactRename.dataset.artifactName || '–';
    $('#artifact-current-name').textContent = currentName;
    $('#artifact-display-name').value = currentName === '–' ? '' : currentName;
    $('#artifact-name-dialog').showModal();
    return;
  }
  const button = event.target.closest('[data-action]');
  if (!button) return;
  const action = button.dataset.action;
  const buildId = button.dataset.build;
  if (button.dataset.credential === 'true') {
    $('#credential-action').value = action;
    $('#credential-build').value = buildId;
    const credentialText = action === 'PrepareSqlImage'
      ? { title: 'Automatischen Image-Abschluss fortsetzen', note: 'Das lokale Administratorpasswort wird benötigt. Der Ablauf führt SQL PrepareImage, notwendige Neustarts, Sysprep sowie die immutable Veröffentlichung automatisch aus.' }
      : action === 'ConfirmSqlWindowsInstall'
        ? { title: 'Windows prüfen und Image automatisch fertigstellen', note: 'Das lokale Administratorpasswort wird zuerst zum Abgleich von Windows, Edition und Installationsart verwendet. Anschließend laufen SQL PrepareImage, notwendige Neustarts, Sysprep und die Veröffentlichung ohne weitere Klicks.' }
      : action === 'GeneralizeWindowsBuild'
        ? { title: 'Windows generalisieren', note: 'Das lokale Administratorpasswort wird benötigt, um Sysprep in dieser VM auszuführen. Die VM fährt danach automatisch herunter.' }
        : { title: 'Windows-Installation bestätigen', note: 'Das lokale Administratorpasswort wird nur für die Prüfung der installierten Windows-Edition verwendet.' };
    $('#credential-title').textContent = credentialText.title;
    $('#credential-note').textContent = credentialText.note;
    $('#credential-dialog').showModal();
    return;
  }
  if (button.dataset.publish === 'true') {
    $('#publish-action').value = action;
    $('#publish-build').value = buildId;
    const build = [...(workflow?.WindowsBuilds || []), ...(workflow?.SqlBuilds || [])].find((item) => item.BuildId === buildId);
    const suggested = build?.SuggestedEvaluationExpiresAt;
    $('#evaluation-expiry').value = suggested ? dateToGerman(new Date(suggested + 'T00:00:00')) : dateToGerman(new Date(Date.now() + 180 * 24 * 60 * 60 * 1000));
    $('#publish-dialog').showModal();
    return;
  }
  try { await startAction(action, { BuildId: buildId }); } catch (error) { showError(error); }
});

$('#build-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  const kind = $('#build-type').value;
  const parameters = {
    MediaRoot: $('#media-root').value,
    WindowsMediaPath: selectedWindowsMediaPath(),
    OperatingSystemId: $('#os-id').value,
    WindowsEdition: $('#windows-edition').value,
    InstallationType: $('#installation-type').value,
    MemoryStartupMB: Number($('#memory-mb').value),
    ProcessorCount: Number($('#processor-count').value),
    OsDiskSizeGB: Number($('#disk-gb').value),
    SqlVersion: $('#sql-version').value,
    SqlEdition: $('#sql-edition').value,
    SqlMediaPath: $('#sql-media').value,
    WindowsMediaSha256: $('#windows-media-sha256').value.trim(),
    SqlMediaSha256: $('#sql-media-sha256').value.trim(),
    ImageName: $('#sql-image-name').value.trim()
  };
  if (!parameters.ImageName) delete parameters.ImageName;
  if (!parameters.WindowsMediaSha256) delete parameters.WindowsMediaSha256;
  if (!parameters.SqlMediaSha256) delete parameters.SqlMediaSha256;
  if (kind !== 'sql' && kind !== 'sql-fresh') {
    // Ein reiner Windows-Build hat keine SQL-Medien. Ein leeres, aber an die
    // API übergebenes SqlEdition-Feld würde deren ValidateSet noch vor der
    // eigentlichen Windows-Aktion ablehnen.
    delete parameters.SqlVersion;
    delete parameters.SqlEdition;
    delete parameters.SqlMediaPath;
    delete parameters.SqlMediaSha256;
  }
  if (kind !== 'sql' && (!parameters.WindowsMediaPath || !parameters.OperatingSystemId || !parameters.WindowsEdition || !parameters.InstallationType)) { showError(new Error('Bitte ein erkanntes Windows-Installationsmedium auswählen.')); return; }
  if ((kind === 'sql' || kind === 'sql-fresh') && (!parameters.SqlMediaPath || !parameters.SqlVersion || !parameters.SqlEdition)) { showError(new Error('Bitte ein SQL-Installationsmedium mit erkannter Edition auswählen.')); return; }
  if (kind === 'sql' && !$('#sql-parent-artifact').value) { showError(new Error('Bitte eine veröffentlichte OS-Baseline auswählen.')); return; }
  if (kind === 'sql') parameters.ArtifactId = $('#sql-parent-artifact').value;
  queueBackgroundAction(kind === 'sql' ? 'NewSqlBuildFromBaseline' : kind === 'sql-fresh' ? 'NewSqlBuild' : 'NewWindowsBuild', parameters, $('#build-dialog'));
});

$('#sql-media').addEventListener('change', updateSqlMediaSelection);
$('#windows-media').addEventListener('change', updateWindowsMediaSelection);
$('#sql-parent-artifact').addEventListener('change', () => renderSqlParentDetails(workflow?.WindowsBaselines || []));
$('#set-windows-media-hash').addEventListener('click', async () => {
  const sha = $('#windows-media-sha256').value.trim();
  if (!$('#windows-media').value || (sha && !/^[a-fA-F0-9]{64}$/.test(sha))) { showError(new Error('Windows-ISO auswählen; ein optionaler SHA-256 muss 64 Hex-Zeichen enthalten.')); return; }
  try {
    const parameters = { MediaRoot: $('#media-root').value.trim(), WindowsMediaPath: selectedWindowsMediaPath(), OperatingSystemId: $('#os-id').value, WindowsEdition: $('#windows-edition').value, InstallationType: $('#installation-type').value };
    if (sha) parameters.WindowsMediaSha256 = sha;
    await startAction('SetWindowsMediaHash', parameters);
    await refresh($('#media-root').value.trim());
  } catch (error) { showError(error); }
});
$('#set-sql-media-hash').addEventListener('click', async () => {
  const sha = $('#sql-media-sha256').value.trim();
  if (!$('#sql-media').value || (sha && !/^[a-fA-F0-9]{64}$/.test(sha))) { showError(new Error('SQL-ISO auswählen; ein optionaler SHA-256 muss 64 Hex-Zeichen enthalten.')); return; }
  try {
    const parameters = { MediaRoot: $('#media-root').value.trim(), SqlMediaPath: $('#sql-media').value, SqlVersion: $('#sql-version').value, SqlEdition: $('#sql-edition').value };
    if (sha) parameters.SqlMediaSha256 = sha;
    await startAction('SetSqlMediaHash', parameters);
    await refresh($('#media-root').value.trim());
  } catch (error) { showError(error); }
});
$('#scan-media').addEventListener('click', async () => {
  const mediaRoot = $('#media-root').value.trim();
  if (!mediaRoot) { showError(new Error('Bitte zuerst den Media Root angeben.')); return; }
  try { await refresh(mediaRoot); } catch (error) { showError(error); }
});

$('#credential-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  const password = $('#guest-password').value;
  const saPassword = $('#credential-sa-password').value;
  if ($('#credential-action').value === '__ConfirmOperation') {
    const operationId = $('#credential-build').value;
    try {
      const response = await fetch('/api/operations', {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ operationId, command: 'Confirm', userName: $('#guest-user').value, password })
      });
      if (!response.ok) throw new Error(await response.text());
      $('#credential-dialog').close();
      $('#guest-password').value = '';
      await refresh();
    }
    catch (error) { showError(error); }
    return;
  }
  const parameters = { BuildId: $('#credential-build').value, GuestUserName: $('#guest-user').value, GuestPassword: password };
  if ($('#credential-action').value === 'AttachHyperVDatabasePackage' && pendingDatabasePackageAttach) {
    parameters.DatabasePackageId = pendingDatabasePackageAttach.DatabasePackageId;
    parameters.InstanceId = pendingDatabasePackageAttach.InstanceId;
    if (pendingDatabasePackageAttach.DataRoot) parameters.DataRoot = pendingDatabasePackageAttach.DataRoot;
  }
  if ($('#credential-action').value === 'ReleaseHyperVPersistentData' && pendingHyperVPersistentData) {
    parameters.PersistentStorageId = pendingHyperVPersistentData.PersistentStorageId;
    if (pendingHyperVPersistentData.DataRoot) parameters.DataRoot = pendingHyperVPersistentData.DataRoot;
  }
  if (saPassword) parameters.SaPassword = saPassword;
  queueBackgroundAction($('#credential-action').value, parameters, $('#credential-dialog'), () => {
    $('#guest-password').value = '';
    $('#credential-sa-password').value = '';
    pendingDatabasePackageAttach = null;
    pendingHyperVPersistentData = null;
  });
});

$('#publish-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  let evaluationExpiresAt;
  try { evaluationExpiresAt = parseGermanDate($('#evaluation-expiry').value); } catch (error) { showError(error); return; }
  queueBackgroundAction($('#publish-action').value, { BuildId: $('#publish-build').value, EvaluationExpiresAt: evaluationExpiresAt }, $('#publish-dialog'));
});

$('#new-container').addEventListener('click', () => { updateContainerStorageSelection(); $('#container-dialog').showModal(); });

$('#container-persistent-data').addEventListener('change', updateContainerStorageSelection);
$('#container-storage-action').addEventListener('change', updateContainerStorageSelection);
$('#container-provider').addEventListener('change', updateContainerStorageSelection);
$('#container-version').addEventListener('change', updateContainerStorageSelection);

$('#new-manifest').addEventListener('click', () => $('#manifest-dialog').showModal());

$('#run-manifest').addEventListener('click', () => $('#manifest-run-dialog').showModal());

$('#clear-all-labs').addEventListener('click', () => {
  openConfirmation('Alles aufräumen', 'Alle bekannten SQL Server Lab-Runs sowie nachweislich verwaiste SQL_Server_Lab-Container werden nach ihren Cleanup-Plänen bereinigt. Persistente Data-Root-Inhalte und veröffentlichte Hyper-V-Images bleiben erhalten.', 'ClearAllLabs', {}, 'Alles aufräumen');
});

$('#new-hyperv-lab').addEventListener('click', () => {
  renderHyperVArtifactOptions(workflow?.SqlPreparedImages || [], workflow?.WindowsBaselines || []);
  renderHyperVSwitchOptions(workflow?.HyperVSwitches || []);
  updateHyperVGuestPasswordMode();
  updateHyperVSaPasswordMode();
  $('#hyperv-lab-dialog').showModal();
});

$('#new-hyperv-existing-vm-lab').addEventListener('click', () => {
  renderHyperVExistingVmSourceOptions(workflow?.HyperVExistingVmSources || []);
  renderHyperVSwitchOptions(workflow?.HyperVSwitches || []);
  $('#hyperv-existing-vm-lab-dialog').showModal();
});

$('#hyperv-artifact').addEventListener('change', () => renderHyperVArtifactDetails(getHyperVArtifactCandidates()));
$('#hyperv-existing-vm-source').addEventListener('change', () => renderHyperVExistingVmSourceDetails(workflow?.HyperVExistingVmSources || []));
$('#hyperv-password-mode').addEventListener('change', updateHyperVGuestPasswordMode);
$('#hyperv-sa-password').addEventListener('input', updateHyperVSaPasswordMode);
$('#hyperv-generate-password').addEventListener('click', () => { $('#hyperv-guest-password').value = generateHyperVGuestPassword(); });
$('#hyperv-copy-password').addEventListener('click', async () => {
  try { await navigator.clipboard.writeText($('#hyperv-guest-password').value); }
  catch (error) { showError(new Error('Passwort konnte nicht in die Zwischenablage kopiert werden.')); }
});

$('#hyperv-lab-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  const selectedArtifact = getHyperVArtifactCandidates().find((item) => item.ArtifactId === $('#hyperv-artifact').value);
  if (!selectedArtifact) { showError(new Error('Bitte eine veröffentlichte Windows- oder SQL-Vorlage auswählen.')); return; }
  const passwordMode = $('#hyperv-password-mode').value;
  const guestPassword = $('#hyperv-guest-password').value;
  const saPassword = selectedArtifact.Workload === 'sql' ? $('#hyperv-sa-password').value : '';
  const region = $('#hyperv-region').value.trim();
  const systemLocale = $('#hyperv-system-locale').value.trim();
  const uiLanguage = $('#hyperv-ui-language').value.trim();
  const inputLocale = $('#hyperv-input-locale').value.trim();
  const timeZone = $('#hyperv-time-zone').value.trim();
  if (!guestPassword) { showError(new Error('Bitte ein lokales Administratorpasswort erzeugen oder eingeben.')); return; }
  if (passwordMode === 'user' && guestPassword !== $('#hyperv-guest-password-repeat').value) { showError(new Error('Die eingegebenen Passwörter stimmen nicht überein.')); return; }
  if (saPassword && saPassword !== $('#hyperv-sa-password-repeat').value) { showError(new Error('Die beiden SQL-SA-Passwörter stimmen nicht überein.')); return; }
  if (!region || !/^[A-Za-z]{2}(-[A-Za-z]{2})?$/.test(region)) { showError(new Error('Bitte eine gültige Region im Format DE oder DE-DE eingeben.')); return; }
  if (!systemLocale || !/^[A-Za-z]{2}-[A-Za-z]{2}$/i.test(systemLocale)) { showError(new Error('Bitte eine gültige System-Locale im Format de-DE eingeben.')); return; }
  if (!uiLanguage || !/^[A-Za-z]{2}-[A-Za-z]{2}$/i.test(uiLanguage)) { showError(new Error('Bitte eine gültige UI-Language im Format en-US eingeben.')); return; }
  if (!inputLocale || !/^[0-9A-Fa-f]{4}:[0-9A-Fa-f]{8}$/.test(inputLocale)) { showError(new Error('Bitte eine gültige Input-Locale im Format 0407:00000407 eingeben.')); return; }
  if (!timeZone) { showError(new Error('Bitte eine Zeitzone angeben.')); return; }
  const parameters = {
    ArtifactId: $('#hyperv-artifact').value,
    LabName: $('#hyperv-lab-name').value.trim(),
    InstanceId: $('#hyperv-instance').value.trim(),
    MemoryStartupMB: Number($('#hyperv-memory').value),
    ProcessorCount: Number($('#hyperv-processors').value),
    AutoStart: $('#hyperv-autostart').checked ? 'on' : 'off',
    SwitchName: $('#hyperv-switch').value.trim(),
    Region: region,
    SystemLocale: systemLocale,
    UiLanguage: uiLanguage,
    InputLocale: inputLocale,
    TimeZone: timeZone,
    PersistentData: selectedArtifact.Workload === 'sql' && $('#hyperv-persistent-data').checked,
    DataRoot: selectedArtifact.Workload === 'sql' && $('#hyperv-persistent-data').checked ? (workflow?.Defaults?.DataRoot || '') : '',
    ProvisionUnattended: true,
    GuestPasswordSource: passwordMode,
    GuestPassword: guestPassword
  };
  if (saPassword) parameters.SaPassword = saPassword;
  queueBackgroundAction('NewHyperVLab', parameters, $('#hyperv-lab-dialog'), () => {
    $('#hyperv-guest-password').value = '';
    $('#hyperv-guest-password-repeat').value = '';
    $('#hyperv-sa-password').value = '';
    $('#hyperv-sa-password-repeat').value = '';
    updateHyperVSaPasswordMode();
  });
});

$('#hyperv-existing-vm-lab-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  if (!$('#hyperv-existing-vm-source').value) { showError(new Error('Bitte eine ausgeschaltete vorhandene Windows-VM auswählen.')); return; }
  if (!$('#hyperv-existing-vm-license-confirm').checked) { showError(new Error('Bitte Lizenz- und Ablaufhinweis für die Quell-VM bestätigen.')); return; }
  queueBackgroundAction('NewHyperVLabFromExistingVm', {
    SourceVMName: $('#hyperv-existing-vm-source').value,
    LabName: $('#hyperv-existing-vm-lab-name').value.trim(),
    InstanceId: $('#hyperv-existing-vm-instance').value.trim(),
    MemoryStartupMB: Number($('#hyperv-existing-vm-memory').value),
    ProcessorCount: Number($('#hyperv-existing-vm-processors').value),
    AutoStart: $('#hyperv-existing-vm-autostart').checked ? 'on' : 'off',
    SwitchName: $('#hyperv-existing-vm-switch').value.trim(),
    ConfirmSourceLicense: true,
    PersistentData: $('#hyperv-existing-vm-persistent-data').checked,
    DataRoot: $('#hyperv-existing-vm-persistent-data').checked ? (workflow?.Defaults?.DataRoot || '') : ''
  }, $('#hyperv-existing-vm-lab-dialog'), () => {
    $('#hyperv-existing-vm-license-confirm').checked = false;
  });
});

$('#media-sources').addEventListener('click', () => {
  $('#sources-media-root').value = workflow?.Defaults?.MediaRoot || '';
  $('#sources-data-root').value = workflow?.Defaults?.DataRoot || '';
  $('#sources-test-data-root').value = workflow?.Defaults?.TestDataRoot || '';
  renderMediaSources(workflow?.MediaSources || []);
  $('#media-sources-dialog').showModal();
});

$('#media-sources-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  const mediaRoot = $('#sources-media-root').value.trim();
  if (!mediaRoot) { showError(new Error('Bitte einen vorhandenen Media Root angeben.')); return; }
  try {
    await startAction('SetMediaRoot', { MediaRoot: mediaRoot });
    const dataRoot = $('#sources-data-root').value.trim();
    if (dataRoot) await startAction('SetDataRoot', { DataRoot: dataRoot });
    const testDataRoot = $('#sources-test-data-root').value.trim();
    if (testDataRoot) await startAction('SetTestDataRoot', { TestDataRoot: testDataRoot });
    await refresh(mediaRoot);
    $('#media-sources-dialog').close();
  } catch (error) { showError(error); }
});

$('#container-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  if ($('#container-password').value !== $('#container-password-repeat').value) { showError(new Error('Die beiden SA-Passwörter stimmen nicht überein.')); return; }
  const persistentData = $('#container-persistent-data').checked;
  const storageAction = persistentData ? $('#container-storage-action').value : 'NEW';
  const persistentStorageId = storageAction === 'NEW' ? '' : $('#container-storage-source').value;
  if (storageAction !== 'NEW' && !persistentStorageId) { showError(new Error('Kein kompatibler Instanzstore ausgewählt.')); return; }
  const parameters = { Provider: $('#container-provider').value, SqlVersion: $('#container-version').value, Profile: $('#container-profile').value, InstanceId: $('#container-instance').value, LabName: $('#container-lab-name').value, PersistentData: persistentData, AutoStart: $('#container-autostart').checked ? 'on' : 'off', SaPassword: $('#container-password').value };
  if (persistentData) parameters.DataRoot = workflow?.Defaults?.DataRoot || '';
  if (persistentStorageId) { parameters.PersistentStorageId = persistentStorageId; parameters.PersistentStorageAction = storageAction; }
  queueBackgroundAction('NewContainerLab', parameters, $('#container-dialog'), () => {
    $('#container-password').value = ''; $('#container-password-repeat').value = ''; $('#container-dialog').close();
  });
});

$('#manifest-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  queueBackgroundAction('CreateContainerManifest', {
    ManifestPath: $('#manifest-path').value.trim(),
    LabName: $('#manifest-name').value.trim(),
    ManifestDescription: $('#manifest-description').value.trim(),
    Provider: $('#manifest-provider').value,
    SqlVersion: $('#manifest-version').value,
    Profile: $('#manifest-profile').value,
    InstanceId: $('#manifest-instance').value.trim()
  }, $('#manifest-dialog'));
});

$('#manifest-run-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  queueBackgroundAction('NewContainerLabFromManifest', { ManifestPath: $('#manifest-run-path').value.trim(), SaPassword: $('#manifest-run-password').value }, $('#manifest-run-dialog'), () => {
    $('#manifest-run-password').value = '';
  });
});

$('#container-operation-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  let action = $('#container-operation-action').value;
  const operationKind = $('#container-operation-kind').value || 'container';
  if (action === 'ExportContainerDatabasePackage') {
    const databaseName = $('#container-database-name').value.trim();
    if (!/^[A-Za-z][A-Za-z0-9_]{0,127}$/.test(databaseName)) {
      showError(new Error('Der Datenbankname ist ungültig. Erlaubt sind Buchstaben, Zahlen und Unterstrich; das erste Zeichen muss ein Buchstabe sein.'));
      return;
    }
    const exportParameters = {
      BuildId: $('#container-operation-run').value,
      InstanceId: $('#container-operation-instance').value,
      DatabaseName: databaseName
    };
    if (workflow?.Defaults?.DataRoot) exportParameters.DataRoot = workflow.Defaults.DataRoot;
    queueBackgroundAction(action, exportParameters, $('#container-operation-dialog'));
    return;
  }
  const targetPort = Number($('#container-operation-port').value);
  const password = $('#container-operation-password').value;
  const operationPort = Number.isFinite(targetPort) ? Number(targetPort) : 0;
  const parameters = {
    BuildId: $('#container-operation-run').value,
    InstanceId: $('#container-operation-instance').value,
    HostName: $('#container-operation-host').value || '127.0.0.1',
    Port: operationPort
  };

  if (!operationPort || operationPort < 1 || operationPort > 65535) {
    showError(new Error('Bitte einen gültigen SQL-Port zwischen 1 und 65535 angeben.'));
    return;
  }

  if (operationKind === 'hyperv') {
    parameters.GuestPassword = password;
  }
  else {
    parameters.SaPassword = password;
  }
  if (!password) {
    showError(new Error(operationKind === 'hyperv' ? 'Bitte das Gastpasswort angeben.' : 'Bitte das SA-Passwort angeben.'));
    return;
  }
  if (action === 'CreateContainerDatabase' || action === 'CreateHyperVLabDatabase') {
    if (action === 'CreateContainerDatabase' && operationKind === 'container') {
      const backupSetId = $('#container-library-backup').value;
      const samples = [...$('#container-sample').selectedOptions].map((option) => option.value).filter(Boolean);
      if (backupSetId) {
        const databaseName = $('#container-database-name').value.trim();
        if (!databaseName || !/^[A-Za-z][A-Za-z0-9_]{0,127}$/.test(databaseName)) {
          showError(new Error('Bitte einen gültigen Datenbanknamen für den Restore eingeben.'));
          return;
        }
        action = 'RestoreContainerLibraryBackup';
        parameters.BackupSetId = backupSetId;
        parameters.DatabaseName = databaseName;
        if (workflow?.Defaults?.DataRoot) parameters.DataRoot = workflow.Defaults.DataRoot;
      }
      else if (samples.length) {
        const sampleSha256 = $('#container-sample-sha256').value.trim();
        if (sampleSha256 && !/^[a-fA-F0-9]{64}$/.test(sampleSha256)) { showError(new Error('Der SHA-256 der Testdatenbank muss 64 Hex-Zeichen enthalten.')); return; }
        if ($('#container-sample-trust-field').hidden === false && !sampleSha256 && !$('#container-sample-trust').checked) { showError(new Error('Bitte einen offiziellen SHA-256 eintragen oder die einmalige Vertrauensfreigabe bestätigen.')); return; }
        action = samples.length === 1 ? 'InstallContainerSampleDatabase' : 'InstallContainerSampleDatabases';
        if (samples.length === 1) {
          const [SampleId, SampleVariant] = samples[0].split(':', 2);
          parameters.SampleId = SampleId;
          parameters.SampleVariant = SampleVariant;
          if (sampleSha256) parameters.SampleSha256 = sampleSha256;
        }
        else {
          parameters.SampleSelections = samples;
        }
        parameters.TrustUnknownSample = $('#container-sample-trust').checked;
      }
      else {
        const databaseName = $('#container-database-name').value.trim();
        if (!databaseName) {
          showError(new Error('Bitte einen Datenbanknamen eingeben.'));
          return;
        }
        if (!/^[A-Za-z][A-Za-z0-9_]{0,127}$/.test(databaseName)) {
          showError(new Error('Der Datenbankname ist ungültig. Erlaubt sind Buchstaben, Zahlen und Unterstrich; das erste Zeichen muss ein Buchstabe sein.'));
          return;
        }
        parameters.DatabaseName = databaseName;
      }
    }
    else {
      const databaseName = $('#container-database-name').value.trim();
      if (!databaseName) {
        showError(new Error('Bitte einen Datenbanknamen für den Hyper-V-Vorgang eingeben.'));
        return;
      }
      if (!/^[A-Za-z][A-Za-z0-9_]{0,127}$/.test(databaseName)) {
        showError(new Error('Der Datenbankname ist ungültig. Erlaubt sind Buchstaben, Zahlen und Unterstrich; das erste Zeichen muss ein Buchstabe sein.'));
        return;
      }
      parameters.DatabaseName = databaseName;
    }
  }
  else {
    const scriptPath = $('#container-script-path').value.trim();
    const targetDatabase = $('#container-script-database').value.trim() || 'master';
    if (!scriptPath) {
      showError(new Error(operationKind === 'hyperv' ? 'Bitte den absoluten Skriptpfad für die Hyper-V-VM angeben.' : 'Bitte den absoluten Skriptpfad angeben.'));
      return;
    }
    if (!/^[A-Za-z][A-Za-z0-9_]{0,127}$/.test(targetDatabase)) {
      showError(new Error('Der Skript-Zieldatenbankname ist ungültig. Erlaubt sind Buchstaben, Zahlen und Unterstrich; das erste Zeichen muss ein Buchstabe sein.'));
      return;
    }
    parameters.ScriptPath = scriptPath;
    parameters.Database = targetDatabase;
  }
  queueBackgroundAction(action, parameters, $('#container-operation-dialog'), () => {
    $('#container-operation-password').value = ''; $('#container-operation-dialog').close();
  });
});

$('#container-sample').addEventListener('change', updateContainerSampleSelection);
$('#container-library-backup').addEventListener('change', updateContainerLibraryBackupSelection);
$('#database-package-source').addEventListener('change', () => updateDatabasePackageDetails());
$('#database-package-target').addEventListener('change', () => updateDatabasePackageDetails());
$('#hyperv-persistent-data-source').addEventListener('change', () => {
  renderHyperVPersistentDataTargetOptions(workflow?.HyperVLabs || []);
  updateHyperVPersistentDataDetails();
});
$('#hyperv-persistent-data-target').addEventListener('change', () => updateHyperVPersistentDataDetails());

$('#persistent-storage-removal-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  const selections = [...document.querySelectorAll('.persistent-storage-removal-selection')].map((row) => ({
    PersistentStorageId: row.dataset.storageId,
    Policy: row.querySelector('.persistent-storage-policy')?.value || '',
    DatabaseReferenceIds: [...(row.querySelector('.persistent-storage-database-references')?.selectedOptions || [])].map((option) => option.value)
  }));
  if (!selections.length || selections.some((selection) => !selection.PersistentStorageId || !selection.Policy)) {
    showError(new Error('Für jeden katalogisierten Store muss eine Retention-Policy gewählt werden.'));
    return;
  }

  const submit = $('#persistent-storage-removal-submit');
  pendingPersistentStorageRemoval = null;
  $('#persistent-storage-removal-execute').disabled = true;
  submit.disabled = true;
  try {
    const response = await fetch('/api/persistent-storage/removal-plan', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ runId: $('#persistent-storage-removal-run').value, selections })
    });
    if (!response.ok) throw new Error(await response.text());
    renderPersistentStorageRemovalPlan(await response.json(), selections);
  }
  catch (error) { showError(error); }
  finally { submit.disabled = false; }
});

$('#persistent-storage-removal-selections').addEventListener('change', () => {
  pendingPersistentStorageRemoval = null;
  $('#persistent-storage-removal-execute').disabled = true;
});

$('#persistent-storage-removal-execute').addEventListener('click', () => {
  const pending = pendingPersistentStorageRemoval;
  if (!pending) {
    showError(new Error('Zuerst einen ausführbaren, blockerfreien Retention-Plan erzeugen.'));
    return;
  }
  $('#persistent-storage-removal-dialog').close();
  openConfirmation(
    'Backup/Retention ausführen',
    'Die Auswahl wird unmittelbar vor jeder Mutation erneut geprüft. Verlangte Datenbanken werden mit CHECKSUM gesichert und per RESTORE VERIFYONLY bestätigt; anschließend wird der Run entfernt, der persistente Instanzstore aber nicht gelöscht.',
    'ExecutePersistentStorageRemoval',
    { BuildId: pending.runId, PersistentStorageSelection: pending.selections, DataRoot: workflow?.Defaults?.DataRoot || '' },
    'Backup + entfernen'
  );
});

function cancelDialog(dialog) {
  if (!dialog?.open) return;
  if (dialog.id === 'confirmation-dialog') pendingConfirmation = null;
  dialog.querySelectorAll('input[type="password"]').forEach((input) => { input.value = ''; });
  dialog.close('cancel');
}

document.addEventListener('click', (event) => {
  const cancel = event.target.closest('[value="cancel"], [data-confirmation-cancel]');
  if (!cancel) return;
  cancelDialog(cancel.closest('dialog'));
});

document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape') return;
  const openDialogs = Array.from(document.querySelectorAll('dialog[open]'));
  const dialog = openDialogs.at(-1);
  if (!dialog) return;
  event.preventDefault();
  cancelDialog(dialog);
});

$('#confirmation-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const confirmation = pendingConfirmation;
  if (!confirmation) { $('#confirmation-dialog').close(); return; }
  pendingConfirmation = null;
  if (confirmation.action === '__OperationStopCleanup') {
    $('#confirmation-dialog').close();
    try {
      const response = await fetch('/api/operations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ operationId: confirmation.parameters.operationId, command: 'StopCleanup' }) });
      if (!response.ok) throw new Error(await response.text());
      await refresh();
    }
    catch (error) { showError(error); }
    return;
  }
  queueBackgroundAction(confirmation.action, confirmation.parameters, $('#confirmation-dialog'));
});

$('#artifact-name-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  const displayName = $('#artifact-display-name').value.trim();
  if (!displayName) { showError(new Error('Bitte einen Namen eingeben.')); return; }
  queueBackgroundAction('RenameHyperVImageArtifact', { ArtifactId: $('#artifact-name-id').value, DisplayName: displayName }, $('#artifact-name-dialog'));
});

$('#lab-name-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  const labName = $('#lab-display-name').value.trim();
  if (!labName) { showError(new Error('Bitte einen Namen angeben.')); return; }
  queueBackgroundAction('RenameLab', { BuildId: $('#lab-name-run').value, LabName: labName }, $('#lab-name-dialog'));
});

$('#resource-form').addEventListener('submit', (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  const memory = Number($('#resource-memory').value);
  const processors = Number($('#resource-processors').value);
  if (!Number.isInteger(memory) || memory < 512 || !Number.isInteger(processors) || processors < 1) {
    showError(new Error('Bitte mindestens 512 MB Speicher und mindestens eine CPU angeben.'));
    return;
  }
  queueBackgroundAction('SetLabResources', { BuildId: $('#resource-run').value, MemoryMB: memory, ProcessorCount: processors }, $('#resource-dialog'));
});

$('#action-feedback-log').addEventListener('click', () => $('#jobs').closest('.panel')?.scrollIntoView({ behavior: 'smooth', block: 'start' }));

$('#refresh').addEventListener('click', () => refresh().catch(showError));

refreshUiConfig().catch(() => {});
refresh().catch(showError);
refreshJobs();
// Der Sekunden-Takt ist ausschließlich für sichtbares Fortschritts-Feedback.
// Eine Workflow-Aktualisierung kann ISO- und VHDX-Metadaten untersuchen und
// darf daher keinen Klickpfad oder den lokalen HTTP-Server blockieren.
window.setInterval(() => { refreshJobs(); }, 1000);
window.setInterval(() => { refresh().catch(() => {}); }, 15000);
