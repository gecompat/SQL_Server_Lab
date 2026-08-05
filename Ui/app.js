let workflow = null;

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
  renderList('#active-labs', data.ActiveLabs, (item) => listItem(item.Name || shortId(item.RunId), item.State + ' · ' + shortId(item.RunId)));
  const disabled = !host.HyperV.Supported || !host.HyperV.Available || !host.IsElevated;
  document.querySelectorAll('[data-open-build]').forEach((button) => { button.disabled = disabled; });
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
  $('#job-count').textContent = jobs.length + ' Aktion(en)';
  $('#jobs').innerHTML = jobs.length ? jobs.map((job) => {
    const lines = job.Lines.length ? job.Lines.join('\n') : 'Aktion läuft …';
    return '<article class="job"><div class="job-header"><strong>' + escapeHtml(job.Action) + '</strong><span class="status ' + (job.State === 'Failed' ? 'failed' : job.State === 'Completed' ? 'done' : 'pending') + '">' + escapeHtml(job.State) + '</span></div><pre class="log">' + escapeHtml(lines) + '</pre></article>';
  }).join('') : empty('Noch keine Aktion wurde aus der Oberfläche gestartet.');
}

async function startAction(action, parameters) {
  const response = await fetch('/api/actions', {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ action, parameters })
  });
  if (!response.ok) throw new Error(await response.text());
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

document.addEventListener('click', async (event) => {
  const opener = event.target.closest('[data-open-build]');
  if (opener) { openBuild(opener.dataset.openBuild); return; }
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
    $('#publish-dialog').showModal();
    return;
  }
  try { await startAction(action, { BuildId: buildId }); } catch (error) { showError(error); }
});

$('#build-form').addEventListener('submit', async (event) => {
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
  event.preventDefault();
  const password = $('#guest-password').value;
  try {
    await startAction($('#credential-action').value, { BuildId: $('#credential-build').value, GuestUserName: $('#guest-user').value, GuestPassword: password });
    $('#guest-password').value = '';
    $('#credential-dialog').close();
  } catch (error) { showError(error); }
});

$('#publish-form').addEventListener('submit', async (event) => {
  event.preventDefault();
  try {
    await startAction($('#publish-action').value, { BuildId: $('#publish-build').value, EvaluationExpiresAt: $('#evaluation-expiry').value });
    $('#publish-dialog').close();
  } catch (error) { showError(error); }
});

$('#refresh').addEventListener('click', () => refresh().catch(showError));

refresh().catch(showError);
refreshJobs();
window.setInterval(() => { refreshJobs(); refresh().catch(() => {}); }, 3000);
