let workflow = null;
let activeJobCount = 0;

const $ = (selector) => document.querySelector(selector);
const escapeHtml = (value) => String(value ?? '').replace(/[&<>"']/g, (char) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[char]));
const shortId = (value) => value ? String(value).slice(0, 12) + '…' : '–';

function statusClass(state) {
  if (['OS_SEALED', 'SQL_PREPARED_SEALED', 'TESTS_PASSED'].includes(state)) return 'done';
  if (state === 'FAILED') return 'failed';
  return 'pending';
}

function empty(message) {
  return '<p class="empty">' + escapeHtml(message) + '</p>';
}

function renderSummary(summary) {
  const values = [
    [summary.WindowsBaselines, 'OS-Baselines'],
    [summary.SqlPreparedImages, 'SQL-Prepared-Images'],
    [summary.PendingWindowsBuilds, 'offene Windows-Builds'],
    [summary.PendingSqlBuilds, 'offene SQL-Builds'],
    [summary.ActiveContainerLabs, 'aktive Container-Labs']
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
        ? { label: 'Windows generalisieren', action: 'GeneralizeWindowsBuild', credential: true }
        : { label: 'Windows bestätigen', action: 'ConfirmWindowsInstall', credential: true });
      return result;
    }
    if (state === 'REBOOT_REQUIRED') return [{ label: 'Generalisierung fortsetzen', action: 'GeneralizeWindowsBuild', credential: false }];
    if (state === 'RESUME_PENDING') return [{ label: 'Image veröffentlichen', action: 'PublishWindowsBuild', publish: true }];
    if (state === 'MANUAL_ACTION_REQUIRED') return [{ label: 'Generalisieren', action: 'GeneralizeWindowsBuild', credential: true }];
  }
  if (kind === 'sql') {
    if (['MANUAL_ACTION_REQUIRED', 'REBOOT_REQUIRED'].includes(state)) {
      const result = [{ label: 'VMConnect öffnen', action: 'OpenSqlConsole' }];
      result.push({
        label: state === 'MANUAL_ACTION_REQUIRED' ? 'SQL vorbereiten + Sysprep' : 'SQL-PrepareImage fortsetzen',
        action: 'PrepareSqlImage',
        credential: true
      });
      return result;
    }
    if (state === 'RESUME_PENDING') return [{ label: 'Prepared-Image veröffentlichen', action: 'PublishSqlImage', publish: true }];
    if (state === 'FAILED') return [{ label: 'Offline-Recovery versuchen', action: 'ResumeSqlImage' }];
  }
  return [];
}

function renderBuilds(target, kind, items) {
  $(target).innerHTML = items.length ? items.map((item) => {
    const title = kind === 'sql'
      ? 'Windows ' + escapeHtml(item.OperatingSystem.replace('windows-server-', 'Server ')) + ' · SQL Server ' + escapeHtml(item.SqlVersion)
      : escapeHtml(item.OperatingSystem.replace('windows-server-', 'Windows Server '));
    const metadata = kind === 'sql'
      ? escapeHtml(item.WindowsEdition + ' · ' + item.InstallationType + ' · ' + item.SqlEdition)
      : escapeHtml(item.Edition + ' · ' + item.InstallationType);
    const buttons = actionsFor(kind, item).map((button) =>
      '<button class="button ' + (button.publish ? 'primary' : 'secondary') + '" data-action="' + button.action + '" data-build="' + escapeHtml(item.BuildId) + '" data-credential="' + Boolean(button.credential) + '" data-publish="' + Boolean(button.publish) + '">' + escapeHtml(button.label) + '</button>'
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

function renderWorkflow(data) {
  workflow = data;
  const host = data.Host;
  const hostChip = $('#host-status');
  if (!host.HyperV.Supported) {
    hostChip.textContent = 'Hyper-V: nur Windows-Host';
    hostChip.className = 'chip warn';
    $('#notice').hidden = false;
    $('#notice').textContent = 'Diese Oberfläche funktioniert unter Linux für Docker und Podman. Hyper-V-Aktionen benötigen einen lokalen Windows-Host.';
  } else if (host.HyperV.Available && host.IsElevated) {
    hostChip.textContent = 'Hyper-V bereit · Administrator';
    hostChip.className = 'chip ok';
    $('#notice').hidden = true;
  } else {
    hostChip.textContent = host.HyperV.Available ? 'Hyper-V · UAC erforderlich' : 'Hyper-V nicht verfügbar';
    hostChip.className = 'chip warn';
    $('#notice').hidden = false;
    $('#notice').textContent = host.HyperV.Message || 'Hyper-V ist auf diesem Host nicht verfügbar.';
  }
  renderSummary(data.Summary);
  renderBuilds('#windows-builds', 'windows', data.WindowsBuilds);
  renderBuilds('#sql-builds', 'sql', data.SqlBuilds);
  $('#windows-count').textContent = data.WindowsBuilds.length + ' Build(s)';
  $('#sql-count').textContent = data.SqlBuilds.length + ' Build(s)';
  renderList('#windows-baselines', data.WindowsBaselines, (item) => listItem(item.OperatingSystem + ' · ' + item.Edition, item.InstallationType + ' · ' + shortId(item.ArtifactId)));
  renderList('#sql-images', data.SqlPreparedImages, (item) => listItem(item.OperatingSystem + ' · SQL Server ' + item.SqlVersion, item.WindowsEdition + ' · ' + item.SqlEdition + ' · ' + shortId(item.ArtifactId)));
  renderList('#acceptance', data.AcceptanceEnvironments, (item) => listItem('SQL Server ' + item.SqlVersion + ' · ' + item.State, (item.VMName || '–') + ' · ' + (item.Edition || '')));
  renderActiveLabs(data.ActiveLabs);
  const disabled = !host.HyperV.Supported || !host.HyperV.Available || !host.IsElevated;
  document.querySelectorAll('[data-open-build]').forEach((button) => { button.disabled = disabled; });
}

function renderActiveLabs(items) {
  $('#active-labs').innerHTML = items.length ? items.map((item) => {
    const running = item.State === 'RUNNING';
    const instance = (item.Instances || [])[0] || {};
    const connection = instance.Port ? ' · ' + (instance.Host || '127.0.0.1') + ':' + instance.Port : '';
    const actions = [
      '<button class="button secondary" data-container-action="' + (running ? 'StopContainerLab' : 'StartContainerLab') + '" data-run="' + escapeHtml(item.RunId) + '">' + (running ? 'Stoppen' : 'Starten') + '</button>',
      running ? '<button class="button secondary" data-container-action="RestartContainerLab" data-run="' + escapeHtml(item.RunId) + '">Neustarten</button>' : '',
      running && instance.Port ? '<button class="button secondary" data-container-operation="CreateContainerDatabase" data-run="' + escapeHtml(item.RunId) + '" data-port="' + escapeHtml(instance.Port) + '">Datenbank anlegen</button>' : '',
      running && instance.Port ? '<button class="button secondary" data-container-operation="ExecuteContainerScript" data-run="' + escapeHtml(item.RunId) + '" data-port="' + escapeHtml(instance.Port) + '">SQL-Skript ausführen</button>' : '',
      '<button class="button secondary" data-container-remove="true" data-run="' + escapeHtml(item.RunId) + '" data-name="' + escapeHtml(item.Name || item.RunId) + '">Entfernen</button>'
    ].join('');
    return '<article class="build-card"><div class="build-card-top"><div><div class="build-title">' + escapeHtml(item.Name || shortId(item.RunId)) + '</div><div class="build-meta">' + escapeHtml(item.State + connection) + '</div></div><span class="status ' + statusClass(item.State === 'RUNNING' ? 'TESTS_PASSED' : item.State) + '">' + escapeHtml(item.State) + '</span></div><div class="build-actions">' + actions + '</div><div class="build-meta">Run: ' + escapeHtml(shortId(item.RunId)) + '</div></article>';
  }).join('') : empty('Noch keine Container-Labs vorhanden.');
}

async function refresh() {
  const response = await fetch('/api/workflow');
  if (!response.ok) throw new Error(await response.text());
  renderWorkflow(await response.json());
}

async function refreshJobs() {
  const response = await fetch('/api/jobs');
  if (!response.ok) return;
  const jobs = await response.json();
  activeJobCount = jobs.filter((job) => ['Running', 'NotStarted'].includes(job.State)).length;
  $('#job-count').textContent = jobs.length + ' Aktion(en)';
  $('#jobs').innerHTML = jobs.length ? jobs.map((job) => {
    const lines = job.Lines.length ? job.Lines.join('\n') : 'Aktion läuft …';
    const running = ['Running', 'NotStarted'].includes(job.State);
    const elapsed = Number(job.ElapsedSeconds || 0);
    const runtime = running ? ' · läuft seit ' + elapsed + ' s' : '';
    return '<article class="job"><div class="job-header"><strong>' + escapeHtml(job.Action + runtime) + '</strong><span class="status ' + (job.State === 'Failed' ? 'failed' : job.State === 'Completed' ? 'done' : 'pending') + '">' + escapeHtml(job.State) + '</span></div>' + (running ? '<div class="job-progress" aria-label="Aktion läuft"></div>' : '') + '<pre class="log">' + escapeHtml(lines) + '</pre></article>';
  }).join('') : empty('Noch keine Aktion wurde aus der Oberfläche gestartet.');
}

async function startAction(action, parameters) {
  const response = await fetch('/api/actions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, parameters })
  });
  if (!response.ok) throw new Error(await response.text());
  activeJobCount = 1;
  await refreshJobs();
  window.setTimeout(() => refresh().catch(showError), 800);
}

function showError(error) {
  const notice = $('#notice');
  notice.hidden = false;
  notice.textContent = error.message || String(error);
}

function openBuild(kind) {
  $('#build-type').value = kind;
  $('#build-kind').textContent = kind === 'sql' ? 'SQL-PREPARED-IMAGE' : 'WINDOWS-OS-BASELINE';
  $('#build-title').textContent = kind === 'sql' ? 'Neues SQL-Prepared-Image' : 'Neue Windows-OS-Baseline';
  $('#sql-fields').hidden = kind !== 'sql';
  $('#os-id').disabled = kind === 'sql';
  $('#os-id').value = kind === 'sql' ? 'windows-server-2025' : 'windows-server-2025';
  $('#media-root').value = workflow?.Defaults?.MediaRoot || '';
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

function openContainerOperation(action, runId, port) {
  const databaseAction = action === 'CreateContainerDatabase';
  $('#container-operation-action').value = action;
  $('#container-operation-run').value = runId;
  $('#container-operation-port').value = port;
  $('#container-operation-title').textContent = databaseAction ? 'Datenbank anlegen' : 'SQL-Skript ausführen';
  $('#container-database-field').hidden = !databaseAction;
  $('#container-script-field').hidden = databaseAction;
  $('#container-script-database-field').hidden = databaseAction;
  $('#container-operation-dialog').showModal();
}

document.addEventListener('click', async (event) => {
  const opener = event.target.closest('[data-open-build]');
  if (opener) { openBuild(opener.dataset.openBuild); return; }
  const containerAction = event.target.closest('[data-container-action]');
  if (containerAction) {
    try { await startAction(containerAction.dataset.containerAction, { BuildId: containerAction.dataset.run }); } catch (error) { showError(error); }
    return;
  }
  const operation = event.target.closest('[data-container-operation]');
  if (operation) { openContainerOperation(operation.dataset.containerOperation, operation.dataset.run, operation.dataset.port); return; }
  const remove = event.target.closest('[data-container-remove]');
  if (remove) {
    if (window.confirm('Container-Lab „' + remove.dataset.name + '“ wirklich entfernen?')) {
      try { await startAction('RemoveContainerLab', { BuildId: remove.dataset.run }); } catch (error) { showError(error); }
    }
    return;
  }
  const button = event.target.closest('[data-action]');
  if (!button) return;
  const action = button.dataset.action;
  const buildId = button.dataset.build;
  if (button.dataset.credential === 'true') {
    $('#credential-action').value = action;
    $('#credential-build').value = buildId;
    $('#credential-title').textContent = action === 'PrepareSqlImage' ? 'SQL PrepareImage und Sysprep' : 'Windows-Installation bestätigen';
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
    OperatingSystemId: $('#os-id').value,
    WindowsEdition: $('#windows-edition').value,
    InstallationType: $('#installation-type').value,
    MemoryStartupMB: Number($('#memory-mb').value),
    ProcessorCount: Number($('#processor-count').value),
    OsDiskSizeGB: Number($('#disk-gb').value),
    SqlVersion: $('#sql-version').value,
    SqlEdition: $('#sql-edition').value
  };
  try {
    await startAction(kind === 'sql' ? 'NewSqlBuild' : 'NewWindowsBuild', parameters);
    $('#build-dialog').close();
  } catch (error) { showError(error); }
});

$('#credential-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  const password = $('#guest-password').value;
  try {
    await startAction($('#credential-action').value, { BuildId: $('#credential-build').value, GuestUserName: $('#guest-user').value, GuestPassword: password });
    $('#guest-password').value = '';
    $('#credential-dialog').close();
  } catch (error) { showError(error); }
});

$('#publish-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  try {
    await startAction($('#publish-action').value, { BuildId: $('#publish-build').value, EvaluationExpiresAt: parseGermanDate($('#evaluation-expiry').value) });
    $('#publish-dialog').close();
  } catch (error) { showError(error); }
});

$('#new-container').addEventListener('click', () => $('#container-dialog').showModal());

$('#container-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  if ($('#container-password').value !== $('#container-password-repeat').value) { showError(new Error('Die beiden SA-Passwörter stimmen nicht überein.')); return; }
  try {
    await startAction('NewContainerLab', { Provider: $('#container-provider').value, SqlVersion: $('#container-version').value, Profile: $('#container-profile').value, InstanceId: $('#container-instance').value, SaPassword: $('#container-password').value });
    $('#container-password').value = ''; $('#container-password-repeat').value = ''; $('#container-dialog').close();
  } catch (error) { showError(error); }
});

$('#container-operation-form').addEventListener('submit', async (event) => {
  if (event.submitter?.value === 'cancel') return;
  event.preventDefault();
  const action = $('#container-operation-action').value;
  const parameters = { BuildId: $('#container-operation-run').value, Port: Number($('#container-operation-port').value), SaPassword: $('#container-operation-password').value };
  if (action === 'CreateContainerDatabase') parameters.DatabaseName = $('#container-database-name').value;
  else { parameters.ScriptPath = $('#container-script-path').value; parameters.Database = $('#container-script-database').value; }
  try {
    await startAction(action, parameters);
    $('#container-operation-password').value = ''; $('#container-operation-dialog').close();
  } catch (error) { showError(error); }
});

$('#refresh').addEventListener('click', () => refresh().catch(showError));

refresh().catch(showError);
refreshJobs();
window.setInterval(() => {
  refreshJobs().then(() => { if (activeJobCount) refresh().catch(() => {}); });
}, 1000);
window.setInterval(() => { if (!activeJobCount) refresh().catch(() => {}); }, 10000);
