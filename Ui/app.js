let workflow = null;
let activeJobCount = 0;
let optimisticJobs = [];
const jobLineCache = {};
let uiConfig = { jobLogBurstLimit: 300, aiSharedGatewayServiceSecret: { available: false, reason: 'Capability wurde noch nicht geprüft.' } };
let workflowRefreshTimer = null;
let pendingPersistentStorageRemoval = null;
let pendingDatabasePackageAttach = null;
let pendingHyperVPersistentData = null;
let publicCommandCatalog = [];

const $ = (selector) => document.querySelector(selector);
const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
const shortId = (value) => value ? String(value).slice(0, 12) + '…' : '–';
const safeExternalUrl = (value) => /^https:\/\//i.test(String(value || '')) ? String(value) : '';

function publicCommandAllowedValues(descriptor) {
  const match = String(descriptor?.AllowedValues || '').match(/(?:^|;\s*)Werte:\s*([^;]+)/i);
  return match ? match[1].split(',').map((value) => value.trim()).filter(Boolean) : [];
}

function selectedPublicCommand() {
  return publicCommandCatalog.find((item) => item.Name === $('#command-name').value) || null;
}

function selectedPublicCommandParameterSet() {
  const command = selectedPublicCommand();
  return command?.ParameterSets?.find((item) => item.Name === $('#command-parameter-set').value) || null;
}

function renderPublicCommandParameter(descriptor) {
  const id = 'command-parameter-' + descriptor.Name.replace(/[^a-z0-9_-]/gi, '-').toLowerCase();
  const required = descriptor.Mandatory ? ' required' : '';
  const sensitive = descriptor.Sensitive ? ' autocomplete="off"' : '';
  const typeName = String(descriptor.TypeName || 'System.String');
  const allowedValues = publicCommandAllowedValues(descriptor);
  let editor;
  if (descriptor.IsCredential) {
    editor = '<div class="credential-fields"><input id="' + id + '-username" data-command-credential-username="' + escapeHtml(descriptor.Name) + '" type="text" placeholder="Benutzername"' + required + ' autocomplete="username"><input id="' + id + '-password" data-command-credential-password="' + escapeHtml(descriptor.Name) + '" type="password" placeholder="Kennwort"' + required + ' autocomplete="new-password"></div>';
  } else if (/System\.(Management\.Automation\.)?(SwitchParameter|Boolean)$/i.test(typeName)) {
    editor = '<input id="' + id + '" data-command-parameter="' + escapeHtml(descriptor.Name) + '" data-command-kind="boolean" type="checkbox">';
  } else if (allowedValues.length > 0) {
    editor = '<select id="' + id + '" data-command-parameter="' + escapeHtml(descriptor.Name) + '" data-command-kind="value"' + required + '><option value="">' + (descriptor.Mandatory ? 'Bitte auswählen' : 'Befehlsstandard verwenden') + '</option>' + allowedValues.map((value) => '<option value="' + escapeHtml(value) + '">' + escapeHtml(value) + '</option>').join('') + '</select>';
  } else if (/\[\]$/.test(typeName) || /Hashtable|PSCustomObject|System\.Object$/i.test(typeName)) {
    editor = '<textarea id="' + id + '" data-command-parameter="' + escapeHtml(descriptor.Name) + '" data-command-kind="json" rows="4" spellcheck="false" placeholder="JSON-Wert, z. B. [\u0022a\u0022, \u0022b\u0022] oder {\u0022key\u0022:\u0022value\u0022}"' + required + '></textarea>';
  } else {
    const inputType = descriptor.Sensitive ? 'password' : (/Int|Decimal|Double|Single|Byte/i.test(typeName) ? 'number' : 'text');
    editor = '<input id="' + id + '" data-command-parameter="' + escapeHtml(descriptor.Name) + '" data-command-kind="value" type="' + inputType + '"' + required + sensitive + '>';
  }
  return '<label class="command-parameter"><span>' + escapeHtml(descriptor.Name) + (descriptor.Mandatory ? ' *' : '') + '</span>' + editor + '<small>' + escapeHtml(descriptor.AllowedValues || ('Typ: ' + typeName)) + ' · Standard: ' + escapeHtml(descriptor.DefaultExpression || '<Befehlsstandard>') + '</small></label>';
}

function renderPublicCommandForm() {
  const command = selectedPublicCommand();
  const setSelect = $('#command-parameter-set');
  if (!command) {
    setSelect.disabled = true;
    setSelect.innerHTML = '<option value="">Parametersatz auswählen</option>';
    $('#command-parameters').innerHTML = '';
    $('#command-submit').disabled = true;
    $('#command-description').textContent = 'Wählen Sie eine Funktion. Danach erscheinen nur die Eingaben des gewählten Parametersatzes.';
    return;
  }
  if (![...setSelect.options].some((option) => option.dataset.command === command.Name)) {
    setSelect.innerHTML = command.ParameterSets.map((set) => '<option data-command="' + escapeHtml(command.Name) + '" value="' + escapeHtml(set.Name) + '"' + (set.IsDefault ? ' selected' : '') + '>' + escapeHtml(set.Name) + (set.IsDefault ? ' (Standard)' : '') + '</option>').join('');
  }
  setSelect.disabled = false;
  const parameterSet = selectedPublicCommandParameterSet() || command.ParameterSets[0];
  if (parameterSet && setSelect.value !== parameterSet.Name) setSelect.value = parameterSet.Name;
  $('#command-parameters').innerHTML = (parameterSet?.Parameters || []).map(renderPublicCommandParameter).join('') || empty('Diese Ausführungsvariante benötigt keine Eingaben.');
  $('#command-submit').disabled = false;
  $('#command-description').innerHTML = '<strong>' + escapeHtml(command.Name) + '</strong><span>' + escapeHtml(command.Synopsis || 'Keine Kurzbeschreibung hinterlegt.') + '</span><span>Arbeitsbereich: ' + escapeHtml(command.Area) + (command.RequiresConfirmation ? ' · Änderungen werden vor dem Start bestätigt.' : ' · Nur lesender Aufruf.') + '</span>';
}

function renderPublicCommandCatalog() {
  const search = $('#command-search').value.trim().toLocaleLowerCase('de');
  const area = $('#command-area').value;
  const filtered = publicCommandCatalog.filter((item) => (!area || item.Area === area) && (!search || [item.Name, item.Synopsis, item.Area].join(' ').toLocaleLowerCase('de').includes(search)));
  const previous = $('#command-name').value;
  $('#command-name').innerHTML = '<option value="">Funktion auswählen</option>' + filtered.map((item) => '<option value="' + escapeHtml(item.Name) + '">' + escapeHtml(item.Name) + '</option>').join('');
  $('#command-name').disabled = false;
  if (filtered.some((item) => item.Name === previous)) $('#command-name').value = previous;
  $('#command-count').textContent = filtered.length + ' von ' + publicCommandCatalog.length + ' Funktionen';
  renderPublicCommandForm();
}

async function refreshPublicCommandCatalog() {
  const response = await fetch('/api/commands');
  if (!response.ok) throw new Error(await response.text());
  const payload = await response.json();
  publicCommandCatalog = Array.isArray(payload) ? payload : (payload ? [payload] : []);
  const areas = [...new Set(publicCommandCatalog.map((item) => item.Area))].sort((left, right) => left.localeCompare(right, 'de'));
  $('#command-area').innerHTML = '<option value="">Alle Arbeitsbereiche</option>' + areas.map((area) => '<option value="' + escapeHtml(area) + '">' + escapeHtml(area) + '</option>').join('');
  renderPublicCommandCatalog();
}

let workspaceArea = 'labs';
const workspaceHistory = [];
function showWorkspaceArea(area, remember = true) {
  const targets = [...document.querySelectorAll('[data-workspace-target]')];
  if (!targets.some((button) => button.dataset.workspaceTarget === area)) return false;
  if (remember && area !== workspaceArea) workspaceHistory.push(workspaceArea);
  workspaceArea = area;
  document.querySelectorAll('[data-workspace-area]').forEach((section) => { section.hidden = section.dataset.workspaceArea !== area; });
  targets.forEach((button) => button.setAttribute('aria-pressed', String(button.dataset.workspaceTarget === area)));
  $('#workspace-back').disabled = workspaceHistory.length === 0;
  return true;
}

function collectPublicCommandParameters() {
  const parameterSet = selectedPublicCommandParameterSet();
  const parameters = {};
  for (const descriptor of parameterSet?.Parameters || []) {
    if (descriptor.IsCredential) {
      const userName = document.querySelector('[data-command-credential-username="' + CSS.escape(descriptor.Name) + '"]')?.value || '';
      const password = document.querySelector('[data-command-credential-password="' + CSS.escape(descriptor.Name) + '"]')?.value || '';
      if (userName || password || descriptor.Mandatory) parameters[descriptor.Name] = { userName, password };
      continue;
    }
    const element = document.querySelector('[data-command-parameter="' + CSS.escape(descriptor.Name) + '"]');
    if (!element) continue;
    if (element.dataset.commandKind === 'boolean') {
      if (element.checked || descriptor.Mandatory) parameters[descriptor.Name] = element.checked;
      continue;
    }
    const text = element.value.trim();
    if (!text) continue;
    if (element.dataset.commandKind === 'json') {
      try { parameters[descriptor.Name] = JSON.parse(text); }
      catch { throw new Error(descriptor.Name + ' muss gültiges JSON enthalten.'); }
    } else {
      parameters[descriptor.Name] = text;
    }
  }
  return parameters;
}

async function startPublicCommand(command, parameterSet, parameters, confirmed) {
  const response = await fetch('/api/commands', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ commandName: command.Name, parameterSetName: parameterSet.Name, parameters, confirmed })
  });
  if (!response.ok) throw new Error(await response.text());
  const accepted = await response.json();
  const optimistic = { Id: accepted.id, Action: accepted.action || ('Command: ' + command.Name), State: 'Running', StartedAt: new Date().toISOString(), Lines: ['[AKZEPTIERT] ' + command.Name + ' wurde gestartet.'] };
  jobLineCache[String(optimistic.Id)] = optimistic.Lines;
  optimisticJobs.push(optimistic);
  renderJobs([]);
  $('#action-feedback-text').textContent = command.Name + ' läuft. Fortschritt und Ergebnis erscheinen im Live-Log.';
  $('#action-feedback').hidden = false;
  showWorkspaceArea('messages');
  $('#jobs').closest('.panel')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
  refreshJobs().catch(() => {});
}

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
    const link = url ? '<a href="' + escapeHtml(url) + '" target="_blank" rel="noopener noreferrer">Quelle öffnen</a>' : '';
    return '<article class="source-item"><strong>' + escapeHtml(item.Category) + ' · ' + escapeHtml(item.DisplayName) + '</strong><span>' + escapeHtml(item.Acquisition) + ' · ' + escapeHtml(item.SourceProvenance || 'REPOSITORY_DEFAULT') + ' · Ziel: ' + escapeHtml(item.TargetRelativePath) + '</span><span>' + escapeHtml(item.Note) + '</span>' + link + '</article>';
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
  const migrationPlanBlockers = Array.isArray(selected.MigrationPlanBlockers) ? selected.MigrationPlanBlockers : [];
  const dependencySummary = dependencyCategories.length ? dependencyCategories.join(', ') : 'keine erkannten oder veröffentlichten Kategorien';
  const warningSummary = migrationWarnings.length ? migrationWarnings.join(', ') : 'keine';
  const targetSummary = targetRun
    ? 'Ziel: ' + (targetRun.Name || shortId(targetRun.RunId)) + ' · SQL ' + (targetRun.SqlVersion || '–') + ' · Zielpfad wird live aus SQL Default Data gebunden'
    : 'Attach gesperrt: laufenden Hyper-V-SQL-Run auswählen';
  const packageReady = selected.Availability === 'SELECTABLE' && !selected.IsEncrypted;
  attach.disabled = !(packageReady && targetRun);
  const packageBlocker = selected.IsEncrypted ? '<span>Attach gesperrt: TDE-Ziel-Key-Vertrag fehlt</span>' : '';
  target.innerHTML = '<strong>' + escapeHtml(selected.DatabaseName) + '</strong><span>' + escapeHtml(selected.SourceProvider + ' · SQL ' + selected.SourceSqlMajorVersion + ' · ' + capabilities.join(' · ')) + '</span><span>' + escapeHtml(selected.DatabaseFileCount + ' Datenbankdatei(en) · ' + selected.ObjectCount + ' gehashte(s) Objekt(e) · ' + selected.MigrationBoundary) + '</span><span>Migrationsinventar: ' + escapeHtml(selected.DependencyInventoryStatus) + '</span><span>Getrennt zu behandeln: ' + escapeHtml(dependencySummary) + '</span><span>Hinweise: ' + escapeHtml(warningSummary) + '</span><span>Nicht ausführbarer Migrationsplan: ' + escapeHtml(selected.MigrationExecutionStatus || 'NOT_CAPTURED') + ' · ' + escapeHtml(String(selected.MigrationPlanStepCount || 0)) + ' Schritt(e) · Blocker: ' + escapeHtml(migrationPlanBlockers.join(', ') || 'keine') + '</span><code>DatabasePackageId: ' + escapeHtml(selected.DatabasePackageId) + '</code><span>' + escapeHtml(targetSummary) + '</span>' + packageBlocker;
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

function sqlConnectionEndpoint(connectionString, tcpPort) {
  // The workflow DTO emits Server first. Fail closed for other formats rather
  // than searching inside a possibly quoted credential for a server-like token.
  const server = String(connectionString || '').match(/^\s*(?:Server|Data Source|Address|Addr|Network Address)\s*=\s*(?:tcp:)?(\[[a-f0-9:]+\]|[a-z0-9_.-]+)(?:\\[a-z0-9_$-]+)?(?:,(\d+))?\s*(?:;|$)/i);
  const port = Number(tcpPort || server?.[2]);
  return server && Number.isInteger(port) && port > 0 && port <= 65535 ? server[1] + ',' + port : 'Host oder Port unbekannt';
}

function renderConnectionEndpoints(data) {
  const endpoints = [];
  for (const lab of data.ActiveLabs || []) {
    for (const instance of lab.Instances || []) {
      endpoints.push({ lab: lab.Name || lab.RunId, instance: instance.Id, provider: instance.Provider,
        endpoint: instance.Host && instance.Port ? instance.Host + ',' + instance.Port : 'Host oder Port unbekannt' });
    }
  }
  for (const lab of data.HyperVLabs || []) {
    const instances = lab.SqlInstances?.length ? lab.SqlInstances : (lab.Workload === 'sql' ? [{ InstanceId: lab.InstanceId, ConnectionString: lab.ConnectionString }] : []);
    for (const instance of instances) {
      endpoints.push({ lab: lab.Name || lab.RunId, instance: instance.Name || instance.InstanceId, provider: 'hyperv',
        endpoint: sqlConnectionEndpoint(instance.ConnectionString, instance.TcpPort) });
    }
  }
  $('#connection-endpoints').innerHTML = endpoints.length ? endpoints.map((item) => '<article class="list-item"><strong>' + escapeHtml(item.lab) + ' · ' + escapeHtml(item.instance) + '</strong><span>' + escapeHtml(item.provider) + ' · ' + escapeHtml(item.endpoint) + '</span></article>').join('') : empty('Keine registrierten SQL-Endpunkte in der aktuellen Ansicht.');
}

function renderWorkflow(data) {
  workflow = data;
  renderConnectionEndpoints(data);
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
  renderRetainedStoreRemovalOptions(data.RetainedStoreRemovalCandidates || []);
  renderSqlInstallationMedia(data.SqlInstallationMedia);
  const sqlFreshBuildDialogOpen = $('#build-dialog')?.open && $('#build-type')?.value === 'sql-fresh';
  renderWindowsInstallationMedia(data.WindowsInstallationMedia, sqlFreshBuildDialogOpen);
  const hyperVDisabled = !host.HyperV.Supported || !host.HyperV.Available;
  const hyperVDisabledReason = hyperVDisabled ? (host.HyperV.Message || (host.HyperV.Supported ? 'Hyper-V ist auf diesem Host nicht verfügbar.' : 'Hyper-V benötigt einen lokalen Windows-Host.')) : '';
  // Der Provider-Capability-Probe ist die Autoritaet. Mitglieder der lokalen
  // Hyper-V-Administratoren duerfen VMs auch ohne Administrator-Rollenbit
  // verwalten; speziellere Volume-Rechte prueft erst die jeweilige Aktion.
  document.querySelectorAll('[data-open-build], [data-action], [data-build-cleanup], [data-artifact-rename], [data-artifact-remove], [data-hyperv-action], [data-provider-capability="hyperv"], #new-hyperv-lab, #new-hyperv-existing-vm-lab').forEach((button) => {
    button.disabled = hyperVDisabled;
  });
  document.querySelectorAll('[data-provider-capability="hyperv"]').forEach((button) => {
    if (hyperVDisabledReason) button.title = hyperVDisabledReason;
    else button.removeAttribute('title');
  });
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
        '<button class="button secondary" data-container-operation="InspectContainerDatabaseMigrationDependencies" data-container-operation-kind="container" data-run="' + escapeHtml(item.RunId) + '" data-instance="' + escapeHtml(instance.Id) + '">Migrationsabhängigkeiten prüfen</button>',
        '<button class="button secondary" data-container-operation="ExportContainerDatabasePackage" data-container-operation-kind="container" data-run="' + escapeHtml(item.RunId) + '" data-instance="' + escapeHtml(instance.Id) + '">Datenbank paketieren</button>',
        '<button class="button secondary" data-container-operation="ExecuteContainerScript" data-container-operation-kind="container" data-run="' + escapeHtml(item.RunId) + '" data-instance="' + escapeHtml(instance.Id) + '" data-container-operation-host="' + escapeHtml(instance.Host || '127.0.0.1') + '" data-port="' + escapeHtml(instance.Port) + '">SQL-Skript ausführen</button>'
      ].join('') : '';
      const resource = resourceForInstance(item.Resources, instance.Id);
      return '<div class="container-instance"><div class="build-meta"><strong>Instanz: ' + escapeHtml(instance.Id || 'unbekannt') + '</strong></div><div class="build-meta">' + escapeHtml(provider) + ' · SQL Server ' + escapeHtml(instance.SqlVersion || '–') + ' · ' + escapeHtml(connection) + ' · Autostart: ' + escapeHtml(instance.AutoStart === 'on' ? 'ein' : 'aus') + '</div><div class="build-meta">' + escapeHtml(resourceSummary(resource, provider)) + '</div>' + connectionString + persistentStorage + backupStorage + '<div class="build-actions">' + operations + '</div></div>';
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
  const capability = config?.aiSharedGatewayServiceSecret || { available: false, reason: 'Capability-Antwort fehlt.' };
  uiConfig.aiSharedGatewayServiceSecret = capability;
  const available = capability.available === true;
  const submit = $('#ai-shared-gateway-service-secret-submit');
  const status = $('#ai-shared-gateway-service-secret-status');
  const reason = $('#ai-shared-gateway-service-secret-reason');
  submit.disabled = !available;
  submit.title = available ? '' : String(capability.reason || 'Dienst-Secret-Prüfung ist auf diesem Host nicht verfügbar.');
  status.textContent = available ? 'SecretManagement bereit' : 'Nicht verfügbar';
  status.className = available ? 'chip ready' : 'chip blocked';
  reason.textContent = String(capability.reason || 'Dienst-Secret-Prüfung ist auf diesem Host nicht verfügbar.');
}

function migrationInventoryResult(lines) {
  const inventoryLine = [...(lines || [])].reverse().find((line) => String(line).startsWith('[INVENTAR] '));
  if (!inventoryLine) return '';
  try {
    const inventory = JSON.parse(String(inventoryLine).substring('[INVENTAR] '.length));
    if (inventory?.ContractVersion !== 'SqlServerLab.DatabaseMigrationDependencyInventory/1.0' ||
      !/^[A-Za-z][A-Za-z0-9_]{0,127}$/.test(String(inventory.DatabaseName || ''))) return '';
    const dependencies = Array.isArray(inventory.Dependencies) ? inventory.Dependencies : [];
    const rows = dependencies.map((dependency) => {
      const count = dependency.Count === null || dependency.Count === undefined ? 'nicht beobachtbar' : String(dependency.Count);
      return '<li><strong>' + escapeHtml(String(dependency.Category || 'UNKNOWN')) + '</strong>: ' +
        escapeHtml(String(dependency.Status || 'UNKNOWN')) + ' · ' + escapeHtml(count) +
        ' · ' + escapeHtml(String(dependency.Scope || 'UNKNOWN')) + ' · ' + escapeHtml(String(dependency.RequiredAction || 'MANUAL_REVIEW')) + '</li>';
    }).join('') || '<li>Keine Dependency-Einträge geliefert.</li>';
    const warnings = Array.isArray(inventory.Warnings) ? inventory.Warnings : [];
    const blockers = Array.isArray(inventory.Blockers) ? inventory.Blockers : [];
    const executionPlan = inventory.ExecutionPlan;
    const hasSafeExecutionPlan = executionPlan?.ContractVersion === 'SqlServerLab.DatabaseMigrationExecutionPlan/1.0' &&
      executionPlan.MutationAllowed === false && executionPlan.TransferAuthority === 'NONE' &&
      executionPlan.ArtifactScope === 'DATABASE_FILES_ONLY';
    const planSteps = hasSafeExecutionPlan && Array.isArray(executionPlan.Steps) ? executionPlan.Steps : [];
    const planRows = planSteps.map((step) => '<li><strong>' + escapeHtml(String(step.Category || 'UNKNOWN')) + '</strong>: ' +
      escapeHtml(String(step.Status || 'UNKNOWN')) + ' · ' + escapeHtml(String(step.Scope || 'UNKNOWN')) +
      ' · ' + escapeHtml(String(step.RequiredAction || 'MANUAL_REVIEW')) +
      ' · Transfer: ' + escapeHtml(step.IncludedInTransfer === false ? 'nein' : 'ungültig') + '</li>').join('');
    const plan = hasSafeExecutionPlan
      ? '<section class="job-execution-plan" aria-label="Nicht ausführbarer Migrationsplan"><strong>Nicht ausführbarer Migrationsplan</strong>' +
        '<span>' + escapeHtml(String(executionPlan.ExecutionStatus || 'UNKNOWN')) + ' · Mutation: nein · Transferautorität: NONE</span>' +
        '<ul>' + (planRows || '<li>Keine Plan-Schritte geliefert.</li>') + '</ul><span>Plan-Blocker: ' +
        escapeHtml((Array.isArray(executionPlan.Blockers) ? executionPlan.Blockers : []).join(', ') || 'keine') + '</span></section>'
      : '';
    return '<section class="job-inventory" aria-label="Migrationsinventar"><strong>Migrationsinventar: ' + escapeHtml(String(inventory.DatabaseName)) + '</strong>' +
      '<span>' + escapeHtml(String(inventory.ObservationStatus || 'UNKNOWN')) + ' · Grenze: ' + escapeHtml(String(inventory.MigrationBoundary || 'DATABASE_ONLY')) +
      ' · Vollmigration: ' + escapeHtml(inventory.FullInstanceMigration ? 'ja' : 'nein') + '</span>' +
      '<ul>' + rows + '</ul><span>Hinweise: ' + escapeHtml(warnings.join(', ') || 'keine') + '</span><span>Blocker: ' + escapeHtml(blockers.join(', ') || 'keine') + '</span>' + plan + '</section>';
  }
  catch { return ''; }
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
    const inventory = job.Action === 'InspectContainerDatabaseMigrationDependencies' ? migrationInventoryResult(mergedLines) : ['StartTestGroupPower', 'StopTestGroupPower'].includes(job.Action) ? testGroupResult(mergedLines) : '';
    return '<article class="job"><div class="job-header"><strong>' + escapeHtml(job.Action + runtime) + '</strong><span class="status ' + (job.State === 'Failed' ? 'failed' : job.State === 'Completed' ? 'done' : 'pending') + '">' + escapeHtml(job.State) + '</span></div>' + (running ? '<div class="job-progress" aria-label="Aktion läuft"></div>' : '') + inventory + '<pre class="log">' + escapeHtml(lines) + '</pre></article>';
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
  showWorkspaceArea('messages');
  $('#jobs').closest('.panel')?.scrollIntoView({ behavior: 'smooth', block: 'start' });
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
    if (!['StartTestGroupPower', 'StopTestGroupPower'].includes(action)) window.setTimeout(() => refresh().catch(showError), 3500);
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
    const trust = trustRequired
      ? ' · SHA-256-Freigabe erforderlich'
      : (sample.TrustStatus === 'catalog-verified' ? ' · Katalog-SHA-256' : ' · lokale SHA-256');
    const cache = sample.CacheStatus === 'HIT' ? ' · Cache bereit' : '';
    return '<option value="' + escapeHtml(sample.SampleId + ':' + sample.Variant) + '" data-database="' + escapeHtml(sample.ExpectedDatabase) + '" data-artifact-type="' + escapeHtml(sample.ArtifactType || '') + '" data-trust-required="' + trustRequired + '" data-sha256="' + escapeHtml(sample.ExpectedSha256 || '') + '">' + escapeHtml(sample.DisplayName) + ' · ' + escapeHtml(sample.Variant) + ' → ' + escapeHtml(sample.ExpectedDatabase) + type + size + trust + cache + '</option>';
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
    const planStatus = backup.MigrationExecutionStatus || 'NOT_CAPTURED';
    const planSteps = Number(backup.MigrationPlanStepCount || 0);
    const planBlockers = Array.isArray(backup.MigrationPlanBlockers) ? backup.MigrationPlanBlockers.join(', ') : '';
    const plan = planStatus === 'NOT_CAPTURED' ? '' : ' · Migrationsplan ' + planStatus + ' (' + planSteps + ' Schritte)';
    return '<option value="' + escapeHtml(backup.BackupSetId) + '" data-database="' + escapeHtml(backup.DatabaseName) + '" data-migration-plan-status="' + escapeHtml(planStatus) + '" data-migration-plan-steps="' + escapeHtml(String(planSteps)) + '" data-migration-plan-blockers="' + escapeHtml(planBlockers) + '">' + escapeHtml(backup.DatabaseName) + ' · ' + escapeHtml(backup.SourceProvider) + ' · SQL ' + escapeHtml(backup.SourceSqlMajorVersion) + size + plan + '</option>';
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
  const migrationPlanStatus = option?.dataset?.migrationPlanStatus || 'NOT_CAPTURED';
  const migrationPlanSteps = option?.dataset?.migrationPlanSteps || '0';
  const migrationPlanBlockers = option?.dataset?.migrationPlanBlockers || '';
  const migrationPlanNote = migrationPlanStatus === 'NOT_CAPTURED'
    ? ''
    : ' Nicht ausführbarer Migrationsplan: ' + migrationPlanStatus + ' (' + migrationPlanSteps + ' Schritte)' + (migrationPlanBlockers ? '; Blocker: ' + migrationPlanBlockers : '') + '.';
  $('#container-library-backup-note').textContent = selected
    ? 'Das Backup wird beim Start anhand seiner BackupSetId erneut status-, evidence- und SHA-256-geprüft.' + migrationPlanNote
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

function sqlOperationTargetSummary(runId, instanceId, operationKind) {
  const labs = operationKind === 'hyperv' ? workflow?.HyperVLabs : workflow?.ActiveLabs;
  const matches = (labs || []).filter((item) => item.RunId === runId);
  const lab = matches.length === 1 ? matches[0] : null;
  const instances = operationKind === 'hyperv' ? lab?.SqlInstances : lab?.Instances;
  const instanceMatches = (Array.isArray(instances) ? instances : (instances ? [instances] : []))
    .filter((item) => (operationKind === 'hyperv' ? item.InstanceId : item.Id) === instanceId);
  const instance = instanceMatches.length === 1 ? instanceMatches[0] : null;
  const provider = operationKind === 'hyperv' && lab ? 'hyperv' : instance?.Provider;
  // Benannte Hyper-V-Instanzen tragen bisher keine eigene Versionsmetadaten.
  const version = instance?.SqlVersion || (operationKind === 'hyperv' && lab &&
    (instance?.IsDefault || instanceId === lab.InstanceId) ? lab.SqlVersion : '');
  return 'Umgebung: ' + (lab?.Name || 'unbekannt') + ' · Instanz: ' +
    (instance?.Name || instanceId || 'unbekannt') + ' · Provider: ' + (provider || 'unbekannt') +
    ' · SQL-Version: ' + (version || 'unbekannt');
}

function openContainerOperation(action, runId, port, instanceId, sqlVersion, kind, host) {
  const operationKind = kind === 'hyperv' ? 'hyperv' : 'container';
  const isCreateAction = action === 'CreateContainerDatabase' || action === 'CreateHyperVLabDatabase';
  const isDependencyInventoryAction = action === 'InspectContainerDatabaseMigrationDependencies';
  const isExportAction = action === 'ExportContainerDatabasePackage';
  const databaseAction = isCreateAction || isDependencyInventoryAction || isExportAction;
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
  $('#container-operation-target').textContent = sqlOperationTargetSummary(runId, instanceId || 'primary', operationKind);
  $('#container-operation-title').textContent = isDependencyInventoryAction ? 'Migrationsabhängigkeiten prüfen' : (isExportAction ? 'Datenbank als Paket veröffentlichen' : (databaseAction ? 'Datenbank anlegen oder wiederherstellen' : 'SQL-Skript ausführen'));
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
  if (isDependencyInventoryAction) {
    $('#container-sample-note').hidden = false;
    $('#container-sample-note').textContent = 'Die Prüfung übergibt ausschließlich Run, Instanz, Datenbankname und das flüchtige SA-Passwort. Sie ist read-only und zeigt nur sanitisierte Kategorien, Counts und notwendige Review-Schritte im Live-Log.';
  }
  if (isCreateAction && operationKind === 'container') {
    renderContainerLibraryBackups(sqlVersion);
    renderContainerSampleOptions(sqlVersion);
  }
  $('#container-operation-dialog').showModal();
}

let resourcePlan = null;
let resourceTargets = [];
let resourceRequest = 0;
function invalidateResourcePlan() {
  resourcePlan = null;
  resourceRequest += 1;
  $('#resource-apply').disabled = true;
}
async function fetchResourceView(parameters) {
  const response = await fetch('/api/resource-change?' + new URLSearchParams(parameters), { cache: 'no-store' });
  if (!response.ok) throw new Error('Ressourcen nicht verfügbar: Ziel, Schutzstatus, Runtime und offene Recovery prüfen; anschließend erneut lesen.');
  return response.json();
}
async function readResourcePlan(prefill = false) {
  invalidateResourcePlan();
  const request = resourceRequest;
  const target = resourceTargets[Number($('#resource-instance').value)];
  if (!target) { $('#resource-note').textContent = 'Keine Instanz ausgewählt.'; return; }
  const parameters = { runId: $('#resource-run').value, instanceId: target.InstanceId, provider: target.Provider };
  if (!prefill) {
    const cpu = Number($('#resource-processors').value);
    const memory = Number($('#resource-memory').value);
    if (!Number.isFinite(cpu) || cpu < 1 || cpu > 64 || Math.abs(cpu * 100 - Math.round(cpu * 100)) > 0.000001 || !Number.isInteger(memory) || memory < 512 || memory > 1048576) {
      $('#resource-note').textContent = 'CPU 1–64 mit höchstens zwei Nachkommastellen; RAM 512–1048576 ganze MB.';
      return;
    }
    parameters.cpu = cpu; parameters.memoryMB = memory;
  }
  if (prefill) {
    $('#resource-processors').disabled = true; $('#resource-memory').disabled = true;
    $('#resource-processors').value = ''; $('#resource-memory').value = '';
    $('#resource-current').textContent = target.InstanceId + ' · ' + target.Provider + ': Istwerte noch unbekannt.';
  }
  $('#resource-note').textContent = 'Vorschau wird gelesen …';
  try {
    const plan = await fetchResourceView(parameters);
    if (request !== resourceRequest || !$('#resource-dialog').open) return;
    if (plan.RunId !== parameters.runId || plan.InstanceId !== target.InstanceId || plan.Provider !== target.Provider) throw new Error('Zielbindung der Vorschau stimmt nicht. Erneut lesen.');
    if (prefill) {
      $('#resource-processors').disabled = false; $('#resource-memory').disabled = false;
      $('#resource-processors').value = plan.Desired.Cpu ?? '';
      $('#resource-memory').value = plan.Desired.MemoryMB ?? '';
    }
    $('#resource-current').textContent = target.InstanceId + ' · ' + target.Provider + ': CPU ' + (plan.Actual.Cpu ?? 'unbekannt/unbegrenzt') + ' → ' + (plan.Desired.Cpu ?? 'unbekannt') + '; RAM ' + (plan.Actual.MemoryMB ?? 'unbekannt/unbegrenzt') + ' → ' + (plan.Desired.MemoryMB ?? 'unbekannt') + ' MB';
    $('#resource-note').textContent = plan.NextStep;
    resourcePlan = plan;
    $('#resource-apply').disabled = !plan.CanApply || plan.NoChange || !plan.PlanKey;
  } catch (error) {
    if (request === resourceRequest) $('#resource-note').textContent = error.message;
  }
}
async function openResourceDialog(button) {
  invalidateResourcePlan();
  const request = resourceRequest;
  resourceTargets = [];
  $('#resource-processors').disabled = true; $('#resource-memory').disabled = true;
  $('#resource-run').value = button.dataset.run;
  $('#resource-instance').innerHTML = '';
  $('#resource-instance').disabled = true;
  $('#resource-processors').value = '';
  $('#resource-memory').value = '';
  $('#resource-current').textContent = 'Istwerte werden ausdrücklich aus der Runtime gelesen.';
  $('#resource-note').textContent = 'Instanzen werden gelesen …';
  if (!$('#resource-dialog').open) $('#resource-dialog').showModal();
  try {
    const view = await fetchResourceView({ runId: button.dataset.run });
    if (request !== resourceRequest || !$('#resource-dialog').open) return;
    resourceTargets = view.Targets || [];
    $('#resource-instance').innerHTML = resourceTargets.map((target, index) => '<option value="' + index + '">' + escapeHtml(target.InstanceId + ' · ' + target.Provider) + '</option>').join('');
    $('#resource-instance').disabled = !resourceTargets.length;
    $('#resource-instance').value = resourceTargets.length ? '0' : '';
    if (!resourceTargets.length) { $('#resource-note').textContent = 'Keine Instanzen vorhanden.'; return; }
    await readResourcePlan(true);
  } catch (error) {
    if (request === resourceRequest) $('#resource-note').textContent = error.message;
  }
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
    WindowsActivation: {
      ContractVersion: 'SqlServerLab.WindowsActivationIntent/1.0',
      Strategy: $('#hyperv-activation-strategy').value,
      EgressPolicy: $('#hyperv-activation-egress').value
    },
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

function openMediaSourcesDialog() {
  $('#sources-media-root').value = workflow?.Defaults?.MediaRoot || '';
  $('#sources-data-root').value = workflow?.Defaults?.DataRoot || '';
  $('#sources-test-data-root').value = workflow?.Defaults?.TestDataRoot || '';
  renderMediaSources(workflow?.MediaSources || []);
  $('#media-sources-dialog').showModal();
}
$('#media-sources').addEventListener('click', openMediaSourcesDialog);
let initialSetupState = null;
let initialSetupPlan = null;
let initialSetupRevision = 0;
let initialSetupBusy = false;
function updateInitialSetupControls() {
  const ready = initialSetupState?.ConfigurationStatus === 'READY' && !initialSetupBusy;
  $('#initial-setup-media').disabled = !ready || initialSetupState.MediaRootValid;
  for (const id of ['initial-setup-data', 'initial-setup-default', 'initial-setup-preview']) $('#' + id).disabled = !ready;
  $('#initial-setup-apply').disabled = !ready || !initialSetupPlan || initialSetupPlan.IsNoOp;
  for (const id of ['initial-setup-read', 'initial-setup-provider', 'initial-setup-provider-refresh']) $('#' + id).disabled = initialSetupBusy;
}
function invalidateInitialSetupPlan() {
  initialSetupPlan = null;
  $('#initial-setup-plan').hidden = true;
  updateInitialSetupControls();
}
async function requestInitialSetup(action, parameters) {
  const response = await fetch('/api/initial-setup', action ? {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action, parameters })
  } : { cache: 'no-store' });
  if (!response.ok) throw new Error('Grundkonfiguration konnte nicht geprüft oder angewendet werden. Eingaben und aktuellen Zustand erneut prüfen.');
  return (await response.json()).Result;
}
function renderInitialSetupState(state) {
  initialSetupState = state;
  if (workflow && state.ConfigurationStatus === 'READY') {
    workflow.Defaults = { ...(workflow.Defaults || {}), MediaRoot: state.MediaRoot || '', DataRoot: state.DefaultLocation?.LabDataRoot || '' };
  }
  const rows = (state.MediaRootCandidates || []).map((item) => '<div>Lab_Base: ' + escapeHtml(item.Path) + ' · ' + escapeHtml(item.Source) + ' · ' + escapeHtml(item.Status) + (item.Selected ? ' · aktiv' : '') + '</div>');
  for (const item of state.LocationStatus || []) rows.push('<div>Lab_Data: ' + escapeHtml(item.LabDataRoot) + ' · ' + escapeHtml(item.Source) + ' · ' + escapeHtml(item.Status) + (item.IsDefault ? ' · globaler Standard' : '') + '</div>');
  $('#initial-setup-roots').innerHTML = rows.join('') || 'Noch keine Roots konfiguriert.';
  $('#initial-setup-status').textContent = state.ConfigurationStatus !== 'READY' ? 'Storage-Konfiguration ungültig. Bestehende Konfiguration separat prüfen.' : state.Complete ? 'Grundkonfiguration vollständig. Ergänzungen und Providerprüfung bleiben verfügbar.' : 'Grundkonfiguration unvollständig. Fehlende Roots ergänzen und Vorschau prüfen.';
  $('#initial-setup-media').value = state.MediaRoot || '';
  $('#initial-setup-data').value = '';
  $('#initial-setup-default').value = state.DefaultLocation?.LabDataRoot || '';
  invalidateInitialSetupPlan();
}
async function runInitialSetupRequest(operation, receive) {
  if (initialSetupBusy) return;
  const revision = ++initialSetupRevision;
  initialSetupBusy = true; updateInitialSetupControls();
  try {
    const result = await operation();
    if (revision === initialSetupRevision && $('#initial-setup-dialog').open) receive(result);
  } catch (error) {
    if (revision === initialSetupRevision && $('#initial-setup-dialog').open) {
      invalidateInitialSetupPlan(); $('#initial-setup-status').textContent = error.message;
    }
  } finally {
    if (revision === initialSetupRevision) { initialSetupBusy = false; updateInitialSetupControls(); }
  }
}
function readInitialSetup() {
  invalidateInitialSetupPlan();
  return runInitialSetupRequest(() => requestInitialSetup(), renderInitialSetupState);
}
$('#configuration-storage').addEventListener('click', () => {
  initialSetupRevision++; initialSetupBusy = false; initialSetupState = null;
  invalidateInitialSetupPlan();
  $('#initial-setup-roots').innerHTML = '';
  $('#initial-setup-status').textContent = 'Roots werden gelesen …';
  $('#initial-setup-provider-status').textContent = 'Noch nicht geprüft.';
  $('#initial-setup-dialog').showModal();
  return readInitialSetup();
});
$('#initial-setup-dialog').addEventListener('close', () => {
  initialSetupRevision++; initialSetupBusy = false; invalidateInitialSetupPlan();
});
$('#initial-setup-read').addEventListener('click', readInitialSetup);
for (const id of ['initial-setup-media', 'initial-setup-data', 'initial-setup-default']) $('#' + id).addEventListener('input', invalidateInitialSetupPlan);
$('#initial-setup-form').addEventListener('submit', (event) => {
  event.preventDefault(); invalidateInitialSetupPlan();
  const parameters = { MediaRoot: $('#initial-setup-media').value.trim(), LabDataRoot: $('#initial-setup-data').value.split(/\r?\n/).map((item) => item.trim()).filter(Boolean), DefaultDataRoot: $('#initial-setup-default').value.trim() };
  return runInitialSetupRequest(() => requestInitialSetup('PlanInitialSetup', parameters), (plan) => {
    initialSetupPlan = plan;
    const rows = [];
    if (plan.MediaAction) rows.push('Neuer Lab_Base-Root: ' + plan.MediaAction.MediaRoot);
    for (const item of plan.LocationActions || []) rows.push('Neuer Lab_Data-Root: ' + item.LabDataRoot);
    rows.push('Globaler Standard: ' + plan.DefaultDataRoot);
    if (plan.IsNoOp) rows.push('Keine Änderung erforderlich.');
    $('#initial-setup-plan').innerHTML = rows.map((row) => '<div>' + escapeHtml(row) + '</div>').join('');
    $('#initial-setup-plan').hidden = false;
    $('#initial-setup-status').textContent = 'Vorschau geprüft. Noch keine Änderungen angewendet.';
  });
});
$('#initial-setup-apply').addEventListener('click', () => {
  if (!initialSetupPlan || initialSetupBusy) return;
  const plan = initialSetupPlan; invalidateInitialSetupPlan();
  return runInitialSetupRequest(() => requestInitialSetup('ApplyInitialSetup', { InitialSetupPlan: plan, ConfirmSetup: true }), renderInitialSetupState);
});
$('#initial-setup-provider').addEventListener('change', () => { $('#initial-setup-provider-status').textContent = 'Noch nicht geprüft.'; });
$('#initial-setup-provider-refresh').addEventListener('click', () => {
  const provider = $('#initial-setup-provider').value;
  $('#initial-setup-provider-status').textContent = 'Gewählter Provider wird geprüft …';
  return runInitialSetupRequest(() => requestInitialSetup('RefreshSetupProvider', { SetupProvider: provider }), (result) => {
    $('#initial-setup-provider-status').textContent = result.Provider + ': ' + result.Check.Status + ' · ' + result.Check.Code + (result.Check.NextStep ? ' · ' + result.Check.NextStep : '');
  });
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
  const password = $('#container-operation-password').value;
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
  if (action === 'InspectContainerDatabaseMigrationDependencies') {
    const databaseName = $('#container-database-name').value.trim();
    if (!/^[A-Za-z][A-Za-z0-9_]{0,127}$/.test(databaseName)) {
      showError(new Error('Der Datenbankname ist ungültig. Erlaubt sind Buchstaben, Zahlen und Unterstrich; das erste Zeichen muss ein Buchstabe sein.'));
      return;
    }
    if (!password) {
      showError(new Error('Bitte das SA-Passwort angeben.'));
      return;
    }
    queueBackgroundAction(action, {
      BuildId: $('#container-operation-run').value,
      InstanceId: $('#container-operation-instance').value,
      DatabaseName: databaseName,
      SaPassword: password
    }, $('#container-operation-dialog'), () => { $('#container-operation-password').value = ''; });
    return;
  }
  const targetPort = Number($('#container-operation-port').value);
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

let retainedStoreRemovalPreview = null;
function renderRetainedStoreRemovalOptions(items) {
  const select = $('#retained-store-source');
  const previous = select.value;
  select.innerHTML = '<option value="">Speicher auswählen …</option>' + items.map((item) =>
    '<option value="' + escapeHtml(item.PersistentStorageId) + '">' +
    escapeHtml(item.DisplayName + ' · ' + item.Provider + ' · ' + item.State + ' · ' + shortId(item.PersistentStorageId)) + '</option>').join('');
  if (items.some((item) => item.PersistentStorageId === previous)) select.value = previous;
  retainedStoreRemovalPreview = null;
  updateRetainedStoreRemovalSelection();
}
function updateRetainedStoreRemovalSelection() {
  const selected = (workflow?.RetainedStoreRemovalCandidates || []).find((item) => item.PersistentStorageId === $('#retained-store-source').value);
  retainedStoreRemovalPreview = null;
  $('#retained-store-preview').disabled = !selected || Boolean(selected.OperationId);
  $('#retained-store-delete').disabled = !selected?.OperationId;
  $('#retained-store-delete').textContent = selected?.OperationId ? 'Löschung fortsetzen' : 'Endgültig löschen';
  $('#retained-store-details').textContent = selected?.OperationId
    ? 'Ausstehender Löschvorgang ' + selected.OperationId + '. Die ursprüngliche Bindung und der Restzustand werden erneut geprüft.'
    : 'Alle Datenbanken und Serverobjekte gehen endgültig verloren. Ein Backup wird nicht geprüft.';
}
$('#retained-store-source').addEventListener('change', updateRetainedStoreRemovalSelection);
$('#retained-store-preview').addEventListener('click', async () => {
  const id = $('#retained-store-source').value;
  $('#retained-store-delete').disabled = true;
  try {
    const response = await fetch('/api/persistent-storage/retained-removal-plan', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ persistentStorageId: id })
    });
    if (!response.ok) throw new Error(await response.text());
    const plan = await response.json();
    if ($('#retained-store-source').value !== id) return;
    retainedStoreRemovalPreview = plan;
    $('#retained-store-delete').disabled = plan.Status !== 'READY';
    $('#retained-store-details').textContent = 'Eigentum und Abtrennung geprüft. Alle Inhalte werden endgültig gelöscht. Backup nicht geprüft.';
  }
  catch (error) { showError(error); }
});
$('#retained-store-delete').addEventListener('click', () => {
  const selected = (workflow?.RetainedStoreRemovalCandidates || []).find((item) => item.PersistentStorageId === $('#retained-store-source').value);
  if (!selected) return;
  const parameters = { PersistentStorageId: selected.PersistentStorageId, DataRoot: workflow?.Defaults?.DataRoot || '' };
  if (selected.OperationId) parameters.PersistentStorageOperationId = selected.OperationId;
  else {
    if (!retainedStoreRemovalPreview || retainedStoreRemovalPreview.PersistentStorageId !== selected.PersistentStorageId) return;
    parameters.ExpectedCatalogRevision = retainedStoreRemovalPreview.CatalogRevision;
    parameters.ExpectedPlanKey = retainedStoreRemovalPreview.PlanKey;
  }
  openConfirmation('Behaltenen SQL-Speicher endgültig löschen',
    'Alle Datenbanken und Serverobjekte dieses Speichers gehen unwiederbringlich verloren. Ein Backup wurde nicht geprüft. Speicher-ID: ' + selected.PersistentStorageId,
    'RemoveRetainedStore', parameters, 'Endgültig löschen');
});

let llamaInstallerView = null;
let llamaInstallerPlan = null;
let llamaInstallerBusy = false;
let llamaInstallerRequest = 0;
function invalidateLlamaInstallerPlan() {
  llamaInstallerPlan = null;
  $('#llama-installer-confirm').checked = false;
  $('#llama-installer-confirm').disabled = true;
  $('#llama-installer-apply').disabled = true;
  $('#llama-installer-preview').disabled = llamaInstallerBusy || !$('#llama-installer-root').value || !$('#llama-installer-release').value;
}
async function requestLlamaInstaller(action) {
  if (llamaInstallerBusy) return;
  const candidateId = $('#llama-installer-release').value;
  const rootId = $('#llama-installer-root').value;
  if (['preview', 'apply'].includes(action) && (!candidateId || !rootId)) return;
  if (action === 'apply' && (!llamaInstallerPlan?.CanApply || llamaInstallerPlan.IsNoOp || !$('#llama-installer-confirm').checked)) return;
  const payload = action === 'read' ? null : { action };
  if (['preview', 'apply'].includes(action)) Object.assign(payload, { candidateId, rootId });
  if (action === 'apply') Object.assign(payload, { expectedKey: llamaInstallerPlan.ExpectedKey, confirmed: true });
  if (action === 'read') {
    llamaInstallerView = null;
    for (const id of ['release', 'root']) { $('#llama-installer-' + id).innerHTML = ''; $('#llama-installer-' + id).value = ''; }
    $('#llama-installer-details').textContent = '';
  }
  const generation = ++llamaInstallerRequest;
  llamaInstallerBusy = true;
  invalidateLlamaInstallerPlan();
  for (const id of ['release', 'root', 'refresh', 'upstream-read', 'close']) $('#llama-installer-' + id).disabled = true;
  $('#llama-installer-status').textContent = action === 'apply' ? 'Bestätigte Installation und begrenzte Probe laufen …' : 'Wird gelesen …';
  try {
    const response = await fetch('/api/llama-installer', payload ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) } : { cache: 'no-store' });
    if (!response.ok) throw new Error('LLAMA_INSTALL_UNCONFIRMED');
    const result = await response.json();
    if (generation !== llamaInstallerRequest || !$('#llama-installer-dialog').open) return;
    if (action === 'read') {
      if (!Array.isArray(result.Items) || !Array.isArray(result.Roots)) throw new Error('LLAMA_INSTALL_RESPONSE_INVALID');
      llamaInstallerView = result;
      $('#llama-installer-release').innerHTML = '<option value="">Release wählen</option>' + result.Items.map(item => '<option value="' + escapeHtml(item.Id) + '">' + escapeHtml(item.Release + ' · ' + item.Status) + '</option>').join('');
      $('#llama-installer-root').innerHTML = '<option value="">Lab_Base wählen</option>' + result.Roots.map(root => '<option value="' + escapeHtml(root.Id) + '">' + escapeHtml(root.Label) + '</option>').join('');
      $('#llama-installer-release').value = ''; $('#llama-installer-root').value = '';
      $('#llama-installer-details').textContent = result.Notice;
      $('#llama-installer-status').textContent = result.Roots.length ? 'Katalog gelesen; Release und vorhandenen Lab_Base auswählen.' : 'Kein gültiger Lab_Base: zuerst Grundkonfiguration prüfen.';
    } else if (action === 'upstream') {
      $('#llama-installer-upstream').textContent = 'Upstream: ' + result.Status + ' · ' + result.Release + ' · keine unabhängige Signatur';
      $('#llama-installer-status').textContent = 'Nur offizielle Metadaten geprüft; keine Binärdatei bezogen.';
    } else if (action === 'preview') {
      if (result.CandidateId !== candidateId || result.RootId !== rootId || !/^[a-f0-9]{64}$/.test(result.ExpectedKey)) throw new Error('LLAMA_INSTALL_RESPONSE_INVALID');
      llamaInstallerPlan = result;
      $('#llama-installer-details').textContent = JSON.stringify(result, null, 2);
      $('#llama-installer-confirm').disabled = !result.CanApply || result.IsNoOp;
      $('#llama-installer-status').textContent = result.State + ' · ' + result.Prerequisite;
    } else {
      $('#llama-installer-details').textContent = JSON.stringify(result, null, 2);
      $('#llama-installer-status').textContent = result.Status + ' · Compute/SQL/Modelle NOT_CHECKED. Für jede weitere Aktion frisch vorprüfen.';
    }
  } catch {
    if (generation !== llamaInstallerRequest) return;
    invalidateLlamaInstallerPlan();
    $('#llama-installer-status').textContent = 'Ergebnis nicht bestätigt. Frisch vorprüfen; keine automatische Wiederholung, Reparatur oder Prerequisiteinstallation.';
  } finally {
    if (generation === llamaInstallerRequest) {
      llamaInstallerBusy = false;
      for (const id of ['refresh', 'upstream-read', 'close']) $('#llama-installer-' + id).disabled = false;
      $('#llama-installer-release').disabled = !llamaInstallerView?.Items.length;
      $('#llama-installer-root').disabled = !llamaInstallerView?.Roots.length;
      $('#llama-installer-preview').disabled = !$('#llama-installer-root').value || !$('#llama-installer-release').value;
    }
  }
}
$('#llama-installer-open').addEventListener('click', () => {
  if (llamaInstallerBusy) return;
  llamaInstallerView = null; invalidateLlamaInstallerPlan();
  $('#llama-installer-dialog').showModal(); return requestLlamaInstaller('read');
});
for (const id of ['release', 'root']) $('#llama-installer-' + id).addEventListener('change', invalidateLlamaInstallerPlan);
$('#llama-installer-confirm').addEventListener('change', () => { $('#llama-installer-apply').disabled = llamaInstallerBusy || !llamaInstallerPlan?.CanApply || llamaInstallerPlan.IsNoOp || !$('#llama-installer-confirm').checked; });
for (const [id, action] of [['refresh', 'read'], ['upstream-read', 'upstream'], ['preview', 'preview'], ['apply', 'apply']]) $('#llama-installer-' + id).addEventListener('click', () => requestLlamaInstaller(action));
$('#llama-installer-close').addEventListener('click', () => { if (!llamaInstallerBusy) { llamaInstallerRequest++; invalidateLlamaInstallerPlan(); $('#llama-installer-dialog').close(); } });
$('#llama-installer-dialog').addEventListener('cancel', event => { if (llamaInstallerBusy) event.preventDefault(); else { llamaInstallerRequest++; invalidateLlamaInstallerPlan(); } });
$('#llama-installer-dialog').addEventListener('close', () => { if (!llamaInstallerBusy) { llamaInstallerRequest++; invalidateLlamaInstallerPlan(); } });

let maintenanceView = null;
let maintenancePlan = null;
let maintenanceRequest = 0;
let maintenanceBusy = false;
function renderMaintenanceSelection() {
  maintenancePlan = null;
  $('#maintenance-confirm').checked = false;
  $('#maintenance-confirm').disabled = true;
  $('#maintenance-apply').disabled = true;
  const row = maintenanceView?.Rows.find(entry => entry.Id === $('#maintenance-selection').value);
  $('#maintenance-details').hidden = !row;
  $('#maintenance-details').innerHTML = row ? '<dl>' + row.Fields.map(field => '<dt>' + escapeHtml(field.Label) + '</dt><dd>' + escapeHtml(field.Value) + '</dd>').join('') + '</dl>' : '';
  $('#maintenance-preview').disabled = maintenanceBusy || !row?.CandidateId || maintenanceView.Incomplete;
}
function resetMaintenanceView() {
  maintenanceView = null;
  $('#maintenance-selection').innerHTML = '<option value="">Zuerst lesen</option>';
  $('#maintenance-selection').value = '';
  $('#maintenance-selection').disabled = true;
  renderMaintenanceSelection();
}
$('#maintenance-open').addEventListener('click', () => {
  maintenanceRequest++; maintenanceBusy = false; resetMaintenanceView();
  $('#maintenance-read').disabled = false;
  $('#maintenance-status').textContent = 'Noch nicht gelesen. Keine automatische Reparatur oder Löschung.';
  $('#maintenance-notice').textContent = '';
  $('#maintenance-dialog').showModal();
});
$('#maintenance-selection').addEventListener('change', () => { maintenanceRequest++; renderMaintenanceSelection(); });
$('#maintenance-confirm').addEventListener('change', () => { $('#maintenance-apply').disabled = maintenanceBusy || maintenancePlan?.Status !== 'READY' || !$('#maintenance-confirm').checked; });
async function requestMaintenance(action) {
  if (maintenanceBusy) return;
  const row = maintenanceView?.Rows.find(entry => entry.Id === $('#maintenance-selection').value);
  if (action !== 'read' && (!row?.CandidateId || maintenanceView.Incomplete)) return;
  if (action === 'apply' && (maintenancePlan?.Status !== 'READY' || !$('#maintenance-confirm').checked)) return;
  const payload = action === 'read' ? null : { action, candidateId: row.CandidateId };
  if (action === 'apply') { payload.expectedKey = maintenancePlan.ExpectedKey; payload.confirmed = true; }
  const generation = ++maintenanceRequest;
  maintenanceBusy = true; maintenancePlan = null;
  $('#maintenance-read').disabled = true; $('#maintenance-selection').disabled = true;
  $('#maintenance-preview').disabled = true; $('#maintenance-apply').disabled = true;
  $('#maintenance-confirm').checked = false; $('#maintenance-confirm').disabled = true;
  $('#maintenance-status').textContent = action === 'apply' ? 'Katalogergebnis wird abgewartet …' : 'Befund / Zuordnung wird gelesen …';
  try {
    const response = await fetch('/api/maintenance', payload ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) } : { cache: 'no-store' });
    if (!response.ok) throw new Error('MAINTENANCE_UNCONFIRMED');
    const result = await response.json();
    if (generation !== maintenanceRequest || !$('#maintenance-dialog').open) return;
    if (action === 'read') {
      if (!Array.isArray(result.Rows)) throw new Error('MAINTENANCE_RESPONSE_INVALID');
      maintenanceView = result;
      $('#maintenance-selection').innerHTML = '<option value="">Befund auswählen</option>' + result.Rows.map(entry => '<option value="' + escapeHtml(entry.Id) + '">' + escapeHtml(entry.Label) + '</option>').join('');
      $('#maintenance-selection').value = '';
      $('#maintenance-notice').textContent = result.Notice;
      $('#maintenance-status').textContent = result.Rows.length + ' Befunde · ' + result.InventoryStatus + ' · ' + result.UnavailableProviders + ' Provider nicht vollständig prüfbar';
      renderMaintenanceSelection();
    } else if (action === 'preview') {
      if (!['READY', 'NO_CHANGE'].includes(result.Status) || result.CandidateId !== row.CandidateId) throw new Error('MAINTENANCE_RESPONSE_INVALID');
      maintenancePlan = result;
      $('#maintenance-confirm').disabled = result.Status !== 'READY';
      $('#maintenance-status').textContent = result.Status + ' · ' + result.Notice;
    } else {
      resetMaintenanceView();
      $('#maintenance-status').textContent = 'Katalogergebnis: ' + result.Status + '. Befunde erneut lesen.';
    }
  } catch {
    if (generation !== maintenanceRequest || !$('#maintenance-dialog').open) return;
    resetMaintenanceView();
    $('#maintenance-status').textContent = 'Ergebnis nicht bestätigt. Befunde erneut lesen und vorprüfen; keine automatische Wiederholung.';
  } finally {
    if (generation === maintenanceRequest) {
      maintenanceBusy = false; $('#maintenance-read').disabled = false;
      $('#maintenance-selection').disabled = !maintenanceView?.Rows.length;
      $('#maintenance-preview').disabled = !maintenanceView?.Rows.find(entry => entry.Id === $('#maintenance-selection').value)?.CandidateId || maintenanceView.Incomplete;
    }
  }
}
$('#maintenance-read').addEventListener('click', () => requestMaintenance('read'));
$('#maintenance-preview').addEventListener('click', () => requestMaintenance('preview'));
$('#maintenance-apply').addEventListener('click', () => requestMaintenance('apply'));
$('#maintenance-dialog').addEventListener('close', () => { maintenanceRequest++; maintenanceBusy = false; resetMaintenanceView(); });

let evaluationWatchView = null;
let evaluationWatchRequest = 0;

function renderEvaluationWatchDetails() {
  const selected = $('#evaluation-watch-selection').value;
  const row = evaluationWatchView?.Rows.find((entry) => entry.Id === selected);
  const details = $('#evaluation-watch-details');
  details.hidden = !row;
  details.innerHTML = row ? '<dl>' + row.Fields.map((field) => '<dt>' + escapeHtml(field.Label) + '</dt><dd>' + escapeHtml(field.Value) + '</dd>').join('') + '</dl>' : '';
}

function clearEvaluationWatchView() {
  evaluationWatchView = null;
  $('#evaluation-watch-selection').innerHTML = '<option value="">Zuerst ausdrücklich lesen</option>';
  $('#evaluation-watch-selection').value = '';
  $('#evaluation-watch-selection').disabled = true;
  $('#evaluation-watch-scope').textContent = '';
  renderEvaluationWatchDetails();
}

$('#evaluation-watch-open').addEventListener('click', () => {
  evaluationWatchRequest++;
  clearEvaluationWatchView();
  $('#evaluation-watch-status').textContent = 'Noch nicht gelesen. Es werden keine Ereignisse gespeichert.';
  $('#evaluation-watch-read').disabled = false;
  $('#evaluation-watch-dialog').showModal();
});
$('#evaluation-watch-selection').addEventListener('change', renderEvaluationWatchDetails);
$('#evaluation-watch-read').addEventListener('click', async () => {
  const request = ++evaluationWatchRequest;
  clearEvaluationWatchView();
  $('#evaluation-watch-read').disabled = true;
  $('#evaluation-watch-status').textContent = 'Gespeicherte Evaluationsdaten werden gelesen …';
  try {
    const response = await fetch('/api/evaluation-watch', { cache: 'no-store' });
    if (!response.ok) throw new Error('EVALUATION_WATCH_READ_UNAVAILABLE');
    const view = await response.json();
    if (!view || !Array.isArray(view.Rows)) throw new Error('EVALUATION_WATCH_RESPONSE_INVALID');
    if (request !== evaluationWatchRequest || !$('#evaluation-watch-dialog').open) return;
    evaluationWatchView = view;
    $('#evaluation-watch-status').textContent = view.Rows.length ? 'Gelesen: ' + view.GeneratedAt + ' · Eintrag für Details auswählen.' : view.EmptyMessage;
    $('#evaluation-watch-scope').textContent = view.Scope + ' ' + view.Notice;
    $('#evaluation-watch-selection').innerHTML = '<option value="">Eintrag auswählen</option>' + view.Rows.map((row) => '<option value="' + escapeHtml(row.Id) + '">' + escapeHtml(row.Label + ' · ' + row.Summary) + '</option>').join('');
    $('#evaluation-watch-selection').disabled = view.Rows.length === 0;
  }
  catch {
    if (request !== evaluationWatchRequest || !$('#evaluation-watch-dialog').open) return;
    clearEvaluationWatchView();
    $('#evaluation-watch-status').textContent = 'Evaluationsfristen konnten nicht gelesen werden. State-Konfiguration und Leserechte prüfen; danach erneut lesen. Keine gültige Fristaussage.';
  }
  finally {
    if (request === evaluationWatchRequest) $('#evaluation-watch-read').disabled = false;
  }
});

function cancelDialog(dialog) {
  if (!dialog?.open) return;
  if (dialog.id === 'confirmation-dialog') pendingConfirmation = null;
  if (dialog.id === 'evaluation-watch-dialog') { evaluationWatchRequest++; clearEvaluationWatchView(); }
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
  if (confirmation.action === '__PublicCommand') {
    $('#confirmation-dialog').close();
    const submit = $('#command-submit');
    submit.disabled = true;
    try {
      await startPublicCommand(
        confirmation.parameters.command,
        confirmation.parameters.parameterSet,
        confirmation.parameters.parameters,
        true
      );
    }
    catch (error) { showError(error); }
    finally { submit.disabled = false; }
    return;
  }
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

$('#resource-instance').addEventListener('change', () => readResourcePlan(true));
$('#resource-preview').addEventListener('click', () => resourceTargets.length ? readResourcePlan($('#resource-processors').disabled) : openResourceDialog({ dataset: { run: $('#resource-run').value } }));
for (const id of ['#resource-processors', '#resource-memory']) {
  $(id).addEventListener('input', () => { if ($(id).disabled) return; invalidateResourcePlan(); $('#resource-note').textContent = 'Werte geändert: neue Vorschau erforderlich.'; });
}
$('#resource-dialog').addEventListener('close', invalidateResourcePlan);
$('#resource-dialog').addEventListener('cancel', invalidateResourcePlan);
$('#resource-form').addEventListener('submit', (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  const plan = resourcePlan;
  if (!plan || !plan.CanApply || plan.NoChange || !plan.PlanKey || Number($('#resource-memory').value) !== plan.Desired.MemoryMB || Number($('#resource-processors').value) !== plan.Desired.Cpu) return;
  invalidateResourcePlan();
  queueBackgroundAction('SetLabResources', { BuildId: plan.RunId, InstanceId: plan.InstanceId, MemoryMB: plan.Desired.MemoryMB, ResourceCpu: plan.Desired.Cpu, ExpectedPlanKey: plan.PlanKey }, $('#resource-dialog'));
});
$('#ai-shared-gateway-service-secret-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const submit = $('#ai-shared-gateway-service-secret-submit');
  const result = $('#ai-shared-gateway-service-secret-result');
  if (uiConfig.aiSharedGatewayServiceSecret?.available !== true) {
    showError(new Error(uiConfig.aiSharedGatewayServiceSecret?.reason || 'Dienst-Secret-Prüfung ist auf diesem Host nicht verfügbar.'));
    return;
  }
  let plan;
  let servicePlan;
  try {
    plan = JSON.parse($('#ai-shared-gateway-plan-json').value);
    servicePlan = JSON.parse($('#ai-shared-gateway-service-plan-json').value);
  }
  catch {
    showError(new Error('Gateway-Plan und Dienstplan müssen gültiges JSON enthalten.'));
    return;
  }
  submit.disabled = true;
  result.textContent = 'SecretManagement-Referenzen werden für den aktuellen Principal geprüft …';
  try {
    const response = await fetch('/api/ai-shared-gateway/service-secret', {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ plan, servicePlan })
    });
    if (!response.ok) throw new Error(await response.text());
    const receipt = await response.json();
    const pending = Array.isArray(receipt.PendingEvidence) ? receipt.PendingEvidence.join(', ') : 'keine';
    result.textContent = 'Status: ' + String(receipt.Status || 'UNKNOWN') +
      ' · Evidence: ' + String(receipt.EvidenceStatus || 'UNKNOWN') +
      ' · Referenzen: ' + String(receipt.ReferenceCount ?? 0) +
      ' · gültig bis: ' + String(receipt.ExpiresAtUtc || '–') +
      ' · ausstehend: ' + pending;
  }
  catch (error) {
    result.textContent = 'Prüfung fehlgeschlagen. Details stehen in der Fehlermeldung.';
    showError(error);
  }
  finally {
    submit.disabled = uiConfig.aiSharedGatewayServiceSecret?.available !== true;
  }
});

$('#action-feedback-log').addEventListener('click', () => { showWorkspaceArea('messages'); $('#jobs').closest('.panel')?.scrollIntoView({ behavior: 'smooth', block: 'start' }); });

$('#command-search').addEventListener('input', renderPublicCommandCatalog);
document.querySelectorAll('[data-workspace-target]').forEach((button) => button.addEventListener('click', () => showWorkspaceArea(button.dataset.workspaceTarget)));
$('#workspace-back').addEventListener('click', () => { if (workspaceHistory.length) showWorkspaceArea(workspaceHistory.pop(), false); });
$('#command-area').addEventListener('change', renderPublicCommandCatalog);
$('#command-name').addEventListener('change', () => {
  $('#command-parameter-set').innerHTML = '<option value="">Parametersatz auswählen</option>';
  renderPublicCommandForm();
});
$('#command-parameter-set').addEventListener('change', renderPublicCommandForm);
$('#command-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  const command = selectedPublicCommand();
  const parameterSet = selectedPublicCommandParameterSet();
  if (!command || !parameterSet) {
    showError(new Error('Bitte Funktion und Ausführungsvariante auswählen.'));
    return;
  }
  let parameters;
  try { parameters = collectPublicCommandParameters(); }
  catch (error) { showError(error); return; }
  if (command.RequiresConfirmation) {
    openConfirmation(
      command.Name + ' ausführen',
      'Diese Funktion kann den Lab-Zustand verändern. Prüfen Sie die angezeigten Eingaben und bestätigen Sie den Start.',
      '__PublicCommand',
      { command, parameterSet, parameters },
      'Funktion starten'
    );
    return;
  }
  const submit = $('#command-submit');
  submit.disabled = true;
  try { await startPublicCommand(command, parameterSet, parameters, false); }
  catch (error) { showError(error); }
  finally { submit.disabled = false; }
});

$('#refresh').addEventListener('click', () => refresh().catch(showError));

refreshUiConfig().catch(() => {});
refreshPublicCommandCatalog().catch(showError);
refresh().catch(showError);
refreshJobs();
// Der Sekunden-Takt ist ausschließlich für sichtbares Fortschritts-Feedback.
// Eine Workflow-Aktualisierung kann ISO- und VHDX-Metadaten untersuchen und
// darf daher keinen Klickpfad oder den lokalen HTTP-Server blockieren.
window.setInterval(() => { refreshJobs(); }, 1000);
window.setInterval(() => { refresh().catch(() => {}); }, 15000);
let slotReserveState = null;
let slotReservePlan = null;
let slotReserveRevision = 0;
let slotReserveBusy = false;
const slotReserveFields = { WindowsReserve: 'windows', SqlReserve: 'sql', MinimumDaysRemaining: 'minimum', WarningDaysRemaining: 'warning' };
function updateSlotReserveControls() {
  const ready = slotReserveState && slotReserveState.Configuration.Status !== 'INVALID' && !slotReserveBusy;
  for (const suffix of Object.values(slotReserveFields)) $('#slot-reserve-' + suffix).disabled = !ready;
  $('#slot-reserve-preview').disabled = !ready;
  $('#slot-reserve-apply').disabled = !ready || !slotReservePlan || slotReservePlan.IsNoOp;
  $('#slot-reserve-read').disabled = slotReserveBusy;
}
function invalidateSlotReservePlan() {
  slotReservePlan = null; $('#slot-reserve-plan').hidden = true; updateSlotReserveControls();
}
async function requestSlotReserve(action, parameters) {
  const response = await fetch('/api/slot-reserve', action ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action, parameters }) } : { cache: 'no-store' });
  if (!response.ok) throw new Error('Slotreserve konnte nicht geprüft oder gespeichert werden. Zustand erneut lesen.');
  return (await response.json()).Result;
}
async function runSlotReserveRequest(operation, receive) {
  if (slotReserveBusy) return;
  const revision = ++slotReserveRevision;
  slotReserveBusy = true; updateSlotReserveControls();
  try {
    const result = await operation();
    if (revision === slotReserveRevision && $('#slot-reserve-dialog').open) receive(result);
  } catch (error) {
    if (revision === slotReserveRevision && $('#slot-reserve-dialog').open) {
      slotReserveState = null; invalidateSlotReservePlan(); $('#slot-reserve-inventory').textContent = '';
      $('#slot-reserve-status').textContent = error.message;
    }
  } finally { if (revision === slotReserveRevision) { slotReserveBusy = false; updateSlotReserveControls(); } }
}
function renderSlotReserve(view) {
  slotReserveState = view; invalidateSlotReservePlan();
  $('#slot-reserve-status').textContent = view.Configuration.Status + ' · Registrierte Kandidaten: ' + view.CandidateCount + ' · Verfügbare Reserve und Auffüllzahl: unbekannt';
  const rows = [view.Notice, view.Recommendation === 'NO_RESERVE_REQUESTED' ? 'Keine Reserve angefordert; kein Nachweis eines gesunden Pools.' : 'Poolzugehörigkeit und Reservierungen separat prüfen.'];
  for (const row of view.Rows || []) rows.push(row.Reference + ' · ' + row.Kind + ' · ' + row.RegisteredState + ' · Zuordnung: ' + row.Allocation + ' · Windows: ' + row.WindowsLifetime + ' · Resttage: ' + (row.WindowsDays ?? 'unbekannt') + ' · Warnung: ' + row.Warning + ' · SQL: ' + row.SqlLifetime + ' · SQL-Evidence: ' + row.SqlEvidence + ' · SQL-Mindestrest: ' + row.SqlMinimum + ' · Windows-Evidence: historisch, nicht live geprüft');
  $('#slot-reserve-inventory').innerHTML = rows.map(row => '<div>' + escapeHtml(row) + '</div>').join('');
  for (const [field, suffix] of Object.entries(slotReserveFields)) $('#slot-reserve-' + suffix).value = view.Configuration.Policy?.[field] ?? '';
}
function readSlotReserve() {
  invalidateSlotReservePlan(); return runSlotReserveRequest(() => requestSlotReserve(), renderSlotReserve);
}
function openSlotReserveDialog() {
  slotReserveRevision++; slotReserveBusy = false; slotReserveState = null; invalidateSlotReservePlan();
  $('#slot-reserve-inventory').textContent = ''; $('#slot-reserve-status').textContent = 'Policy und Kandidaten werden gelesen …';
  $('#slot-reserve-dialog').showModal(); return readSlotReserve();
}
$('#configuration-reserve').addEventListener('click', openSlotReserveDialog);
$('#templates-reserve').addEventListener('click', openSlotReserveDialog);
$('#slot-reserve-close').addEventListener('click', () => $('#slot-reserve-dialog').close());
$('#slot-reserve-dialog').addEventListener('close', () => { slotReserveRevision++; slotReserveBusy = false; invalidateSlotReservePlan(); });
$('#slot-reserve-read').addEventListener('click', readSlotReserve);
for (const suffix of Object.values(slotReserveFields)) $('#slot-reserve-' + suffix).addEventListener('input', invalidateSlotReservePlan);
$('#slot-reserve-form').addEventListener('submit', event => {
  event.preventDefault(); invalidateSlotReservePlan();
  const policy = {};
  for (const [field, suffix] of Object.entries(slotReserveFields)) {
    const value = $('#slot-reserve-' + suffix).value;
    if (value === '' || !Number.isInteger(Number(value))) { $('#slot-reserve-status').textContent = 'Alle vier ganzen Zahlen ausdrücklich eingeben; null ist gültig.'; return; }
    policy[field] = Number(value);
  }
  return runSlotReserveRequest(() => requestSlotReserve('PlanSlotReserve', { SlotReservePolicy: policy }), plan => {
    slotReservePlan = plan;
    $('#slot-reserve-plan').textContent = 'Windows: ' + plan.Policy.WindowsReserve + ' · SQL: ' + plan.Policy.SqlReserve + ' · Mindestresttage: ' + plan.Policy.MinimumDaysRemaining + ' · Warnfrist: ' + plan.Policy.WarningDaysRemaining + ' · ' + plan.Notice;
    $('#slot-reserve-plan').hidden = false;
    $('#slot-reserve-status').textContent = 'Vorschau; noch nicht gespeichert. Keine Slotaktion.';
  });
});
$('#slot-reserve-apply').addEventListener('click', () => {
  if (!slotReservePlan || slotReserveBusy) return;
  const plan = slotReservePlan; invalidateSlotReservePlan();
  return runSlotReserveRequest(async () => {
    await requestSlotReserve('ApplySlotReserve', { SlotReservePlan: plan, ConfirmSlotReserve: true });
    return requestSlotReserve();
  }, renderSlotReserve);
});

let testGroupPlan = null;
let testGroupRevision = 0;
function invalidateTestGroupPlan() {
  testGroupPlan = null; testGroupRevision++;
  $('#test-group-confirm').checked = false; $('#test-group-apply').disabled = true;
}
function renderTestGroupPlan(plan) {
  $('#test-group-status').textContent = plan.Total + ' Mitglieder · Power: ' + plan.PowerStatus + ' · SQL-Bereitschaft: nicht geprüft';
  $('#test-group-members').innerHTML = (plan.Members || []).map(member => '<div>' + escapeHtml(member.Key + ' · ' + member.Provider + ' · ' + member.Power + ' → ' + member.Desired + ' · ' + member.Change + (member.Reason ? ' · ' + member.Reason : '')) + '</div>').join('');
  $('#test-group-notice').textContent = plan.Notice;
}
async function readTestGroupPlan() {
  invalidateTestGroupPlan();
  const revision = testGroupRevision;
  $('#test-group-status').textContent = 'Gruppe und gebundene Runtimezustände werden gelesen …';
  $('#test-group-selection').disabled = true;
  $('#test-group-members').innerHTML = '';
  try {
    const response = await fetch('/api/test-group?' + new URLSearchParams({ powerAction: $('#test-group-action').value }), { cache: 'no-store' });
    if (!response.ok) throw new Error('Gruppe nicht lesbar. Erneut lesen; keine Poweraktion angefordert.');
    const plan = await response.json();
    if (revision !== testGroupRevision || !$('#test-group-dialog').open) return;
    $('#test-group-selection').innerHTML = plan.Total ? '<option value="">Gruppe auswählen</option><option value="registered">' + escapeHtml(plan.Group) + '</option>' : '<option value="">Keine registrierte Gruppe</option>';
    $('#test-group-selection').value = '';
    $('#test-group-selection').disabled = !plan.Total;
    testGroupPlan = plan; renderTestGroupPlan(plan);
  } catch (error) {
    if (revision === testGroupRevision) $('#test-group-status').textContent = error.message;
  }
}
function openTestGroupDialog() {
  $('#test-group-action').value = 'Start';
  if (!$('#test-group-dialog').open) $('#test-group-dialog').showModal();
  return readTestGroupPlan();
}
function updateTestGroupApply() {
  $('#test-group-apply').disabled = !testGroupPlan?.CanApply || !testGroupPlan.Total || testGroupPlan.NoChange || !testGroupPlan.PlanKey || $('#test-group-selection').value !== 'registered' || !$('#test-group-confirm').checked;
}
function testGroupResult(lines) {
  const line = [...(lines || [])].reverse().find(item => String(item).startsWith('[TESTGROUP] '));
  if (!line) return '<p>Ergebnis noch unbestätigt. Bei Verbindungsverlust Gruppe erneut lesen; nicht automatisch wiederholen.</p>';
  try {
    const result = JSON.parse(String(line).slice(12));
    return '<section class="job-inventory"><strong>Gruppe: ' + escapeHtml(result.Status) + ' · SQL-Bereitschaft nicht geprüft</strong>' + (result.Details || []).map(item => '<div>' + escapeHtml(item.Key + ' · ' + item.Status + ' · ' + (item.Action || item.Change) + (item.Reason ? ' · ' + item.Reason : '')) + '</div>').join('') + '<p>Aktuellen Gruppenstatus lesen. Wiederholung nur nach neuer Vorschau und Bestätigung.</p></section>';
  } catch { return '<p>Gruppenergebnis nicht lesbar. Zustand erneut prüfen.</p>'; }
}
$('#test-group-open').addEventListener('click', openTestGroupDialog);
$('#test-group-read').addEventListener('click', readTestGroupPlan);
$('#test-group-action').addEventListener('change', readTestGroupPlan);
$('#test-group-selection').addEventListener('change', () => { $('#test-group-confirm').checked = false; updateTestGroupApply(); });
$('#test-group-confirm').addEventListener('change', updateTestGroupApply);
$('#test-group-close').addEventListener('click', () => $('#test-group-dialog').close());
$('#test-group-dialog').addEventListener('close', invalidateTestGroupPlan);
$('#test-group-dialog').addEventListener('cancel', invalidateTestGroupPlan);
$('#test-group-apply').addEventListener('click', async () => {
  updateTestGroupApply();
  if ($('#test-group-apply').disabled || testGroupPlan.PowerAction !== $('#test-group-action').value) return;
  const plan = testGroupPlan;
  invalidateTestGroupPlan(); $('#test-group-dialog').close();
  try { await startAction(plan.PowerAction === 'Start' ? 'StartTestGroupPower' : 'StopTestGroupPower', { ExpectedPlanKey: plan.PlanKey }); }
  catch { showError(new Error('Poweraktion: Annahme oder Ergebnis unbestätigt. Gruppenstatus erneut lesen; nicht automatisch wiederholen.')); }
});

let mediaOverrideState = null;
let mediaOverridePlan = null;
let mediaOverrideRevision = 0;
let mediaOverrideBusy = false;
function updateMediaOverrideControls() {
  const readable = !!mediaOverrideState && !mediaOverrideBusy;
  for (const suffix of ['selection', 'reset']) $('#media-override-' + suffix).disabled = !readable;
  for (const suffix of ['url', 'preview']) $('#media-override-' + suffix).disabled = !readable || mediaOverrideState.Status !== 'READY';
  $('#media-override-apply').disabled = !readable || !mediaOverridePlan || mediaOverridePlan.IsNoOp;
  $('#media-override-read').disabled = mediaOverrideBusy;
}
function invalidateMediaOverridePlan() {
  mediaOverridePlan = null; $('#media-override-plan').hidden = true; updateMediaOverrideControls();
}
async function requestMediaOverride(action, parameters) {
  const response = await fetch('/api/media-overrides', action ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action, parameters }) } : { cache: 'no-store' });
  if (!response.ok) throw new Error('Quellenanfrage abgelehnt; Eingabe und aktuellen Zustand erneut prüfen.');
  return (await response.json()).Result;
}
async function runMediaOverrideRequest(operation, receive) {
  if (mediaOverrideBusy || !$('#media-override-dialog').open) return;
  const revision = mediaOverrideRevision;
  mediaOverrideBusy = true; updateMediaOverrideControls();
  try {
    const result = await operation();
    if (revision === mediaOverrideRevision && $('#media-override-dialog').open) receive(result);
  } catch (error) {
    if (revision === mediaOverrideRevision && $('#media-override-dialog').open) {
      mediaOverrideState = null; invalidateMediaOverridePlan(); $('#media-override-details').textContent = '';
      $('#media-override-status').textContent = error.message;
    }
  } finally { if (revision === mediaOverrideRevision) { mediaOverrideBusy = false; updateMediaOverrideControls(); } }
}
function selectMediaOverride() {
  invalidateMediaOverridePlan();
  const item = mediaOverrideState?.Items?.find(item => item.Id === $('#media-override-selection').value);
  $('#media-override-details').textContent = item ? item.Provenance + '\nRepository: ' + item.RepositoryUrl + '\nEffektiv: ' + (item.EffectiveUrl || 'INVALID') + '\nBytes: ' + item.ExpectedBytes + '\nSHA-256: ' + item.ExpectedSha256 : '';
  $('#media-override-url').value = item?.EffectiveUrl || '';
}
function renderMediaOverride(state) {
  mediaOverrideState = state;
  const selected = $('#media-override-selection').value;
  $('#media-override-selection').innerHTML = state.Items.map(item => '<option value="' + escapeHtml(item.Id) + '">' + escapeHtml(item.DisplayName) + '</option>').join('');
  $('#media-override-selection').value = state.Items.some(item => item.Id === selected) ? selected : state.Items[0]?.Id || '';
  $('#media-override-status').textContent = state.Status + ' · ' + state.Notice;
  selectMediaOverride();
}
function readMediaOverride() {
  invalidateMediaOverridePlan(); return runMediaOverrideRequest(() => requestMediaOverride(), renderMediaOverride);
}
function openMediaOverrideDialog() {
  mediaOverrideRevision++; mediaOverrideBusy = false; mediaOverrideState = null; invalidateMediaOverridePlan();
  $('#media-override-details').textContent = ''; $('#media-override-status').textContent = 'Quellenkonfiguration wird gelesen …';
  $('#media-override-dialog').showModal(); return readMediaOverride();
}
function previewMediaOverride(operation) {
  if (mediaOverrideBusy || !mediaOverrideState || !$('#media-override-dialog').open) return;
  invalidateMediaOverridePlan();
  const parameters = { MediaSourceId: $('#media-override-selection').value, MediaSourceOperation: operation, MediaSourceUrl: operation === 'Edit' ? $('#media-override-url').value : '' };
  return runMediaOverrideRequest(() => requestMediaOverride('PlanMediaOverride', parameters), plan => {
    mediaOverridePlan = plan; $('#media-override-plan').textContent = plan.Operation + ': ' + plan.EffectiveUrl + ' · ' + plan.Notice + (plan.IsNoOp ? ' Keine Änderung.' : '');
    $('#media-override-plan').hidden = false;
  });
}
$('#media-override-open').addEventListener('click', openMediaOverrideDialog);
$('#media-override-selection').addEventListener('change', selectMediaOverride);
$('#media-override-url').addEventListener('input', invalidateMediaOverridePlan);
$('#media-override-preview').addEventListener('click', () => previewMediaOverride('Edit'));
$('#media-override-reset').addEventListener('click', () => previewMediaOverride('Reset'));
$('#media-override-read').addEventListener('click', readMediaOverride);
$('#media-override-close').addEventListener('click', () => $('#media-override-dialog').close());
$('#media-override-dialog').addEventListener('close', () => { mediaOverrideRevision++; mediaOverrideBusy = false; invalidateMediaOverridePlan(); });
$('#media-override-apply').addEventListener('click', () => {
  if (mediaOverrideBusy || !mediaOverridePlan || mediaOverridePlan.IsNoOp || !$('#media-override-dialog').open) return;
  const plan = mediaOverridePlan; invalidateMediaOverridePlan();
  return runMediaOverrideRequest(async () => {
    await requestMediaOverride('ApplyMediaOverride', { MediaSourcePlan: plan, ConfirmMediaSource: true });
    return requestMediaOverride();
  }, renderMediaOverride);
});
let resourceWatchRevision = 0;
let resourceWatchBusy = false;
function updateResourceWatchControls() {
  $('#resource-watch-read').disabled = resourceWatchBusy;
  $('#resource-watch-check').disabled = resourceWatchBusy;
}
async function readResourceWatch(refresh = false) {
  if (resourceWatchBusy || !$('#resource-watch-dialog').open) return;
  const revision = resourceWatchRevision;
  resourceWatchBusy = true; updateResourceWatchControls();
  try {
    const response = await fetch('/api/resource-watch', refresh ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ action: 'RefreshResourceWatch', parameters: {} }) } : { cache: 'no-store' });
    if (!response.ok) throw new Error('RESOURCE_WATCH_UNAVAILABLE');
    const view = (await response.json()).Result;
    if (revision !== resourceWatchRevision || !$('#resource-watch-dialog').open) return;
    $('#resource-watch-status').textContent = view.Status + ' · ' + view.ReasonCode + ' · Quellenversuch: ' + (view.CheckedAtUtc || 'noch keiner');
    $('#resource-watch-details').textContent = (view.Items || []).map(item => item.Name + '\nKatalogversion: ' + item.CatalogVersion + '\nAktueller Quellenbefund: ' + (item.ObservedVersion || 'unbestätigt') + ' · ' + item.Status + ' · ' + item.ReasonCode + '\nLetzte erfolgreiche Beobachtung: ' + (item.LastSuccessfulVersion || 'keine') + ' · ' + (item.LastSuccessfulAtUtc || '') + '\nQuelle: ' + item.SourceUrl).join('\n\n') + '\n\n' + view.Notice;
  } catch {
    if (revision === resourceWatchRevision && $('#resource-watch-dialog').open) {
      $('#resource-watch-status').textContent = 'UNCLEAR · RESOURCE_WATCH_UNAVAILABLE';
      $('#resource-watch-details').textContent = '';
    }
  } finally { if (revision === resourceWatchRevision) { resourceWatchBusy = false; updateResourceWatchControls(); } }
}
$('#resource-watch-open').addEventListener('click', () => {
  resourceWatchRevision++; resourceWatchBusy = false;
  $('#resource-watch-status').textContent = 'Sitzungsbefund wird gelesen …'; $('#resource-watch-details').textContent = '';
  $('#resource-watch-dialog').showModal(); return readResourceWatch();
});
$('#resource-watch-read').addEventListener('click', () => readResourceWatch());
$('#resource-watch-check').addEventListener('click', () => readResourceWatch(true));
$('#resource-watch-close').addEventListener('click', () => $('#resource-watch-dialog').close());
for (const event of ['close', 'cancel']) $('#resource-watch-dialog').addEventListener(event, () => { resourceWatchRevision++; resourceWatchBusy = false; updateResourceWatchControls(); });

// Own module-session stop: only an opaque server preview authorizes the target.
let llamaSessionView = null, llamaSessionPlan = null, llamaSessionBusy = false, llamaSessionStopping = false, llamaSessionRevision = 0;
function updateLlamaSessionControls() {
  const selected = llamaSessionView?.Items.find(item => item.OperationId === $('#llama-session-selection').value);
  $('#llama-session-selection').disabled = llamaSessionBusy || !llamaSessionView?.Items.length;
  $('#llama-session-read').disabled = llamaSessionBusy;
  $('#llama-session-plan').disabled = llamaSessionBusy || !selected;
  $('#llama-session-confirm').disabled = llamaSessionBusy || !llamaSessionPlan;
  $('#llama-session-stop').disabled = llamaSessionBusy || !llamaSessionPlan || !$('#llama-session-confirm').checked;
  $('#llama-session-close').disabled = llamaSessionStopping;
}
function invalidateLlamaSessionPlan() {
  llamaSessionPlan = null; $('#llama-session-confirm').checked = false;
  $('#llama-session-preview').hidden = true; updateLlamaSessionControls();
}
async function requestLlamaSession(action = 'read') {
  if (llamaSessionBusy) return;
  const operationId = $('#llama-session-selection').value;
  if (action === 'preview' && !llamaSessionView?.Items.some(item => item.OperationId === operationId)) return;
  if (action === 'stop' && (!llamaSessionPlan || !$('#llama-session-confirm').checked)) return;
  const payload = action === 'read' ? null : action === 'preview' ? { action, operationId } : { action, planId: llamaSessionPlan.PlanId, confirmed: true };
  const revision = ++llamaSessionRevision;
  llamaSessionBusy = true; llamaSessionStopping = action === 'stop'; invalidateLlamaSessionPlan();
  $('#llama-session-status').textContent = llamaSessionStopping ? 'Bestätigter Stop wird abgewartet; Schließen erst nach Ergebnis. Eine gestartete Aktion wird nicht zurückgenommen.' : 'Ergebnis wird abgewartet …';
  try {
    const response = await fetch('/api/llama-sessions', payload ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) } : { cache: 'no-store' });
    if (!response.ok) throw new Error('LLAMA_SESSION_UNCONFIRMED');
    const result = await response.json();
    if (revision !== llamaSessionRevision || !$('#llama-session-dialog').open) return;
    if (action === 'read') {
      if (!Array.isArray(result.Items)) throw new Error('LLAMA_SESSION_RESPONSE_INVALID');
      llamaSessionView = result;
      $('#llama-session-selection').innerHTML = '<option value="">Sitzung auswählen</option>' + result.Items.map(item => '<option value="' + escapeHtml(item.OperationId) + '">Port ' + escapeHtml(item.Port) + ' · ' + escapeHtml(item.OperationId) + ' · ' + escapeHtml(item.Status) + '</option>').join('');
      $('#llama-session-selection').value = '';
      $('#llama-session-notice').textContent = result.Notice;
      $('#llama-session-status').textContent = result.Items.length ? result.Items.length + ' eigene Sitzungen' : 'Keine Sitzung dieses Modulhosts. Im selben PowerShell-Modulhost starten und UI ohne erneuten Force-Import öffnen.';
    } else if (action === 'preview') {
      if (result.OperationId !== operationId || result.ConsumerCoverage !== 'UNKNOWN' || !result.PlanId) throw new Error('LLAMA_SESSION_RESPONSE_INVALID');
      llamaSessionPlan = result;
      $('#llama-session-preview').textContent = 'Stop: ' + result.OperationId + ' · Port ' + result.Port + ' · Rechte: ' + result.Rights + ' · bekannte Verbraucher: ' + result.KnownConsumerCount + ' · Coverage UNKNOWN. ' + result.Notice;
      $('#llama-session-preview').hidden = false;
      $('#llama-session-status').textContent = 'Vorschau erstellt. Bewusste Bestätigung erforderlich.';
    } else {
      llamaSessionView = null; $('#llama-session-selection').innerHTML = ''; $('#llama-session-selection').value = '';
      $('#llama-session-status').textContent = 'Stop / Cleanup: ' + result.Status + '. Sitzungen erneut lesen.';
    }
  } catch {
    if (revision !== llamaSessionRevision || !$('#llama-session-dialog').open) return;
    llamaSessionView = null; invalidateLlamaSessionPlan();
    $('#llama-session-status').textContent = 'Stop nicht bestätigt. Neu lesen und vorprüfen; eigene Recovery separat prüfen. Keine automatische Wiederholung.';
  } finally { if (revision === llamaSessionRevision) { llamaSessionBusy = false; llamaSessionStopping = false; updateLlamaSessionControls(); } }
}
$('#llama-session-open').addEventListener('click', () => {
  llamaSessionRevision++; llamaSessionBusy = false; llamaSessionView = null; invalidateLlamaSessionPlan();
  $('#llama-session-dialog').showModal(); return requestLlamaSession();
});
$('#llama-session-selection').addEventListener('change', () => { llamaSessionRevision++; invalidateLlamaSessionPlan(); });
$('#llama-session-confirm').addEventListener('change', updateLlamaSessionControls);
$('#llama-session-read').addEventListener('click', () => requestLlamaSession());
$('#llama-session-plan').addEventListener('click', () => requestLlamaSession('preview'));
$('#llama-session-stop').addEventListener('click', () => requestLlamaSession('stop'));
$('#llama-session-close').addEventListener('click', () => { if (!llamaSessionStopping) $('#llama-session-dialog').close(); });
$('#llama-session-dialog').addEventListener('close', () => { llamaSessionRevision++; llamaSessionBusy = false; llamaSessionView = null; invalidateLlamaSessionPlan(); });
$('#llama-session-dialog').addEventListener('cancel', event => { if (llamaSessionStopping) event.preventDefault(); });
$('#llama-session-dialog').addEventListener('keydown', event => { if (event.key === 'F5') { event.preventDefault(); return requestLlamaSession(); } });
