let queueBatchId = '';

function updateBatchDraftPosition(position) {
  const kind = position.querySelector('[name="kind"]').value;
  const linux = kind === 'SqlEnvironment';
  const optionGroups = { sql: kind !== 'WindowsEnvironment', linux, windows: !linux };
  for (const [name, enabled] of Object.entries(optionGroups)) {
    const fields = position.querySelector('[data-batch-options="' + name + '"]');
    fields.hidden = !enabled;
    fields.disabled = !enabled;
  }
}

function addBatchDraftPosition() {
  const positions = $('#batch-draft-positions');
  if (positions.childElementCount >= 100) return;
  const position = $('#batch-draft-position').content.firstElementChild.cloneNode(true);
  updateBatchDraftPosition(position);
  positions.append(position);
  return position;
}

function readBatchDraftPosition(position) {
  const value = name => position.querySelector('[name="' + name + '"]').value;
  const kind = value('kind');
  const item = { kind, name: value('environmentName'), count: Number(value('count')) };
  if (kind !== 'WindowsEnvironment') item.version = value('version');
  if (kind === 'SqlEnvironment') {
    item.provider = value('provider');
    item.secretReference = value('secretReference');
  } else {
    item.operatingSystem = value('operatingSystem');
    item.variant = value('variant');
    item.cpu = Number(value('cpu'));
    item.memoryMB = Number(value('memoryMB'));
  }
  return item;
}

document.getElementById?.('batch-draft')?.addEventListener('toggle', () => {
  if ($('#batch-draft').open && !$('#batch-draft-positions').childElementCount) addBatchDraftPosition();
});

document.getElementById?.('batch-draft-form')?.addEventListener('submit', async event => {
  event.preventDefault();
  const form = event.currentTarget;
  if (form.inert) return;
  const positions = $('#batch-draft-positions');
  const items = Array.from(positions.children, readBatchDraftPosition);
  const status = $('#batch-draft-status');
  if (!items.length || items.reduce((count, item) => count + item.count, 0) > 100) {
    status.textContent = 'Ein Entwurf benötigt insgesamt 1 bis 100 Umgebungen.';
    return;
  }
  const data = {
    command: 'SaveGuidedDraft',
    name: form.elements.batchName.value.trim(),
    priority: form.elements.priority.value,
    items
  };
  form.inert = true;
  status.textContent = 'Entwurf wird geprüft …';
  try {
    const response = await sqlServerLabUiFetch('/api/batches', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(data)
    });
    if (response.status === 400) throw new Error('Bitte Umgebungsnamen, Positionen und Kennwortreferenzen prüfen.');
    if (!response.ok) throw new Error('Speicherung unbestätigt. Bitte die Batchübersicht und Providerbereitschaft prüfen.');
    const draft = await response.json();
    if (!/^batch-\d{14}-[0-9a-f]{8}$/.test(draft.BatchId) || draft.Status !== 'Validated' ||
        !Number.isSafeInteger(draft.Positions) || !Number.isSafeInteger(draft.Dependencies)) {
      throw new Error('Speicherung unbestätigt. Bitte die Batchübersicht prüfen.');
    }
    status.textContent = draft.BatchId + ' gespeichert · ' + draft.Positions + ' Umgebungen · ' +
      draft.Dependencies + ' gemeinsame Abhängigkeiten.';
    form.reset();
    positions.replaceChildren();
    addBatchDraftPosition();
    await refresh();
  } catch (error) {
    status.textContent = error.message;
  } finally {
    form.inert = false;
  }
});

function renderBatchOverview(batches, queue, background = false) {
  if (background && document.activeElement?.matches('[data-queue-batch]')) return;
  const openBatches = new Set((queue?.items || []).map(item => item.batchId));
  const labels = {
    Draft: 'Entwurf', Validated: 'Validiert', Queued: 'Vorgemerkt', Running: 'Läuft',
    Waiting: 'Wartet', CleanupQueued: 'Bereinigung vorgemerkt', Completed: 'Abgeschlossen',
    CompletedWithErrors: 'Mit Fehlern abgeschlossen', Cancelled: 'Abgebrochen'
  };
  const rows = $('#batch-overview-rows');
  rows.replaceChildren();
  for (const batch of Array.isArray(batches) ? batches : []) {
    if (typeof batch?.BatchId !== 'string' || !/^batch-\d{14}-[0-9a-f]{8}$/.test(batch.BatchId) || !Object.hasOwn(labels, batch.Status) ||
        !Number.isFinite(batch.Percent) || batch.Percent < 0 || batch.Percent > 100 ||
        ![batch.Total, batch.Failed, batch.Cancelled].every(value => Number.isInteger(value) && value >= 0)) continue;
    const row = document.createElement('tr');
    const batchCell = document.createElement('td');
    if (openBatches.has(batch.BatchId)) {
      const show = document.createElement('button');
      show.type = 'button';
      show.className = 'button secondary';
      show.dataset.queueBatch = batch.BatchId;
      show.textContent = batch.BatchId;
      show.setAttribute('aria-label', 'Offene Vorgänge für ' + batch.BatchId + ' anzeigen');
      show.setAttribute('aria-pressed', String(queueBatchId === batch.BatchId));
      batchCell.append(show);
      if (['Queued', 'Running', 'Waiting', 'CleanupQueued'].includes(batch.Status)) {
        const stop = document.createElement('button');
        stop.type = 'button';
        stop.className = 'button secondary';
        stop.dataset.batchStop = batch.BatchId;
        stop.textContent = 'Unfertige Positionen stoppen';
        batchCell.append(stop);
      }
    } else {
      batchCell.textContent = batch.BatchId;
    }
    row.append(batchCell);
    for (const value of [labels[batch.Status], batch.Percent + ' %', batch.Total, batch.Failed, batch.Cancelled]) {
      const cell = document.createElement('td');
      cell.textContent = String(value);
      row.append(cell);
    }
    rows.append(row);
  }
  $('#batch-overview-table').hidden = !rows.childElementCount;
  const status = $('#batch-overview-status');
  status.textContent = rows.childElementCount ? 'Offene Vorgänge nach Batch filtern. Bis zu 50 zuletzt angelegte Batches.' : 'Keine Batchstände verfügbar.';
  if (queueBatchId) {
    status.textContent = 'Offene Vorgänge für ' + queueBatchId + ' ';
    const reset = document.createElement('button');
    reset.type = 'button';
    reset.className = 'button secondary';
    reset.dataset.queueBatch = '';
    reset.textContent = 'Alle Vorgänge anzeigen';
    status.append(reset);
  }
}

const operationPriorityLabels = { High: 'Hoch', Normal: 'Normal', Low: 'Niedrig' };
const operationOrderingInFlight = new Set();

function renderOperationOrderingControls(item, waitingItems) {
  if (item.status === 'Running' || waitingItems.length < 2 || !Object.hasOwn(operationPriorityLabels, item.priority)) return '';
  const operationId = escapeHtml(item.operationId);
  const disabled = operationOrderingInFlight.has(item.operationId) ? ' disabled' : '';
  const options = Object.entries(operationPriorityLabels).map(([value, label]) =>
    '<option value="' + value + '"' + (value === item.priority ? ' selected' : '') + '>' + label + '</option>'
  ).join('');
  const priority = '<label>Priorität<select data-operation-priority="' + operationId +
    '" data-current-priority="' + item.priority + '"' + disabled + '>' + options + '</select></label>';
  const peers = waitingItems.filter(peer => peer.priority === item.priority);
  const position = peers.findIndex(peer => peer.operationId === item.operationId);
  const move = (command, label) => '<button type="button" class="button secondary" data-operation-command="' + command +
    '" data-operation="' + operationId + '"' + disabled + '>' + label + '</button>';
  const up = position > 0 ? move('MoveUp', 'Nach oben') : '';
  const down = position >= 0 && position < peers.length - 1 ? move('MoveDown', 'Nach unten') : '';
  return priority + up + down;
}

function renderOperationQueue(queue, background = false) {
  if (background && document.activeElement?.matches('[data-operation-priority]')) return;
  const allItems = queue?.items || [];
  const items = queueBatchId ? allItems.filter(item => item.batchId === queueBatchId) : allItems;
  const waitingItems = allItems.filter(item => item.status !== 'Running');
  $('#queue-count').textContent = (queue?.runningWorkers || 0) + '/' + (queue?.maxWorkers || 2) + ' Worker · ' + items.length + (queueBatchId ? ' offen im Batch' : ' offen');
  $('#operation-queue').innerHTML = items.length ? items.map((item) => {
    const gate = item.userGate;
    const gateDetails = gate ? '<div class="operation-gate"><strong>' + escapeHtml(gate.reason) + '</strong><ol>' + (gate.instructions || []).map((step) => '<li>' + escapeHtml(step) + '</li>').join('') + '</ol><span>Erwartet: ' + escapeHtml(gate.expectedResult) + '</span></div>' : '';
    const confirmation = ['WaitingForUser', 'CandidateSatisfied'].includes(item.status)
      ? '<button class="button primary" data-operation-command="Confirm" data-operation="' + escapeHtml(item.operationId) + '" data-verification="' + escapeHtml(gate?.verification?.type || '') + '">Erledigt - prüfen und fortsetzen</button>'
      : '';
    const pause = item.status === 'Paused'
      ? '<button class="button secondary" data-operation-command="Resume" data-operation="' + escapeHtml(item.operationId) + '">Freigeben</button>'
      : (item.status === 'Queued' || item.status === 'WaitingForDependency' ? '<button class="button secondary" data-operation-command="Suspend" data-operation="' + escapeHtml(item.operationId) + '">Pausieren</button>' : '');
    return '<article class="build-card operation-card"><div class="build-card-top"><div><div class="build-title">' + escapeHtml(item.title) + '</div><div class="build-meta">' + escapeHtml(item.priority + ' · ' + item.resourceClass + ' · ' + item.provider) + '</div></div><span class="status ' + statusClass(item.status) + '">' + escapeHtml(item.status) + '</span></div><progress max="100" value="' + escapeHtml(item.progress || 0) + '"></progress>' + gateDetails + '<div class="build-actions">' + confirmation + pause + renderOperationOrderingControls(item, waitingItems) + '<button class="button danger" data-operation-command="StopCleanup" data-operation="' + escapeHtml(item.operationId) + '">Stoppen + Cleanup</button></div><div class="build-meta">' + escapeHtml(item.blockedReason || item.operationId) + '</div></article>';
  }).join('') : empty(queueBatchId ? 'Keine offenen Vorgänge in diesem Batch.' : 'Keine offenen persistenten Vorgänge.');
}

async function requestBrowserBatchStop(payload) {
  const response = await sqlServerLabUiFetch('/api/operations', {
    method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload)
  });
  if (!response.ok) throw new Error(await response.text());
  return response.json();
}

async function previewBrowserBatchStop(batchId) {
  const preview = await requestBrowserBatchStop({ command: 'BatchStopPreview', batchId });
  if (preview.BatchId !== batchId || !/^[0-9a-f]{32}$/.test(preview.PreviewId) ||
      !Number.isSafeInteger(preview.Pending) || preview.Pending < 1 ||
      !Number.isSafeInteger(preview.Running) || preview.Running < 0 || preview.Running > preview.Pending) {
    throw new Error('Die Vorschau für diesen Batch konnte nicht bestätigt werden.');
  }
  openConfirmation('Unfertige Batchpositionen stoppen',
    'Batch ' + batchId + ': ' + preview.Pending + ' unfertige Positionen, davon ' + preview.Running +
      ' laufend. Der Stopp reiht ihre Bereinigung ein. Bereits abgeschlossene Positionen bleiben erhalten.',
    '__BatchStop', { batchId, previewId: preview.PreviewId }, 'Unfertige Positionen stoppen');
}

async function applyBrowserBatchStop(parameters) {
  const result = await requestBrowserBatchStop({ command: 'BatchStopApply', batchId: parameters.batchId,
    previewId: parameters.previewId, confirmed: true });
  if (result.BatchId !== parameters.batchId || !Number.isSafeInteger(result.Requested) || result.Requested < 0) {
    throw new Error('Ergebnis unbestätigt. Bitte den Batchstatus prüfen.');
  }
  await refresh();
  const notice = $('#notice');
  notice.hidden = false;
  notice.textContent = result.Requested
    ? 'Stopp für ' + result.Requested + ' Positionen angenommen. Den Fortschritt zeigt die Warteschlange.'
    : 'Keine unfertige Position musste gestoppt werden.';
}

async function requestOperationHost() {
  const button = $('#operation-host-start');
  if (button.disabled) return;
  button.disabled = true;
  try {
    const response = await sqlServerLabUiFetch('/api/operations', { method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ command: 'StartOperationHost', confirmed: true }) });
    if (!response.ok) throw new Error(await response.text());
    if ((await response.json()).state !== 'Requested') {
      throw new Error('Scheduler-Anforderung unbestätigt. Bitte die Warteschlange prüfen.');
    }
    await refresh();
    const notice = $('#notice');
    notice.hidden = false;
    notice.textContent = 'Scheduler angefordert. Die Warteschlange zeigt, sobald Vorgänge anlaufen.';
  } finally {
    button.disabled = false;
  }
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
  const ordering = ['MoveUp', 'MoveDown', 'PriorityHigh', 'PriorityNormal', 'PriorityLow'].includes(command);
  if (ordering && operationOrderingInFlight.has(operationId)) {
    throw new Error('Die Reihenfolge dieses Vorgangs wird bereits geändert.');
  }
  if (ordering) operationOrderingInFlight.add(operationId);
  try {
    const response = await sqlServerLabUiFetch('/api/operations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    if (!response.ok) throw new Error(await response.text());
  } finally {
    if (ordering) operationOrderingInFlight.delete(operationId);
  }
  await refresh();
}

document.addEventListener('change', async (event) => {
  const kind = event.target.closest('.batch-draft-position [name="kind"]');
  if (kind) {
    updateBatchDraftPosition(kind.closest('.batch-draft-position'));
    return;
  }
  const select = event.target.closest('[data-operation-priority]');
  if (!select || select.disabled || !Object.hasOwn(operationPriorityLabels, select.value) ||
      select.value === select.dataset.currentPriority) return;
  select.disabled = true;
  try {
    await runOperationCommand(select.dataset.operationPriority, 'Priority' + select.value);
  } catch (error) {
    select.value = select.dataset.currentPriority;
    showError(error);
  } finally {
    select.disabled = false;
  }
});

document.addEventListener('click', async (event) => {
  if (event.target.closest('#batch-draft-add')) {
    addBatchDraftPosition()?.querySelector('[name="environmentName"]').focus();
    return;
  }
  const removeDraftPosition = event.target.closest('[data-batch-draft-remove]');
  if (removeDraftPosition) {
    removeDraftPosition.closest('.batch-draft-position').remove();
    $('#batch-draft-add').focus();
    return;
  }
  const hostStart = event.target.closest('#operation-host-start');
  if (hostStart) {
    if (!hostStart.disabled) {
      openConfirmation('Hintergrundscheduler anfordern',
        'Der Scheduler kann alle freigegebenen Vorgänge der aktuellen Warteschlange ausführen.',
        '__StartOperationHost', {}, 'Scheduler anfordern');
    }
    return;
  }
  const batchStop = event.target.closest('[data-batch-stop]');
  if (batchStop) {
    if (batchStop.disabled) return;
    batchStop.disabled = true;
    try { await previewBrowserBatchStop(batchStop.dataset.batchStop); }
    catch (error) { showError(error); }
    finally { batchStop.disabled = false; }
    return;
  }
  const batchFilter = event.target.closest('[data-queue-batch]');
  if (batchFilter) {
    const selected = batchFilter.dataset.queueBatch;
    const batches = Array.isArray(workflow?.Batches) ? workflow.Batches : [];
    if (typeof selected !== 'string' || (selected && !batches.some(batch => batch?.BatchId === selected))) return;
    queueBatchId = queueBatchId === selected ? '' : selected;
    renderOperationQueue(workflow?.Queue);
    renderBatchOverview(batches, workflow?.Queue);
    return;
  }
  const button = event.target.closest('[data-operation-command]');
  if (!button) return;
  button.disabled = true;
  try { await runOperationCommand(button.dataset.operation, button.dataset.operationCommand, button.dataset.verification); }
  catch (error) { window.alert(error.message); }
  finally { button.disabled = false; }
});
