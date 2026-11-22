'use strict';
(() => {
  let cmsManagementRevision = 0;
  let cmsManagementBusy = false;
  let cmsManagementState = null;
  function updateCmsManagementControls() {
    const state = cmsManagementState;
    const busy = cmsManagementBusy;
    $('#cms-management-read').disabled = busy;
    $('#cms-management-create-submit').disabled = busy || !state?.CanCreate || !$('#cms-management-create-confirm').checked || !/^[A-Za-z0-9][A-Za-z0-9_.-]{0,79}$/.test($('#cms-management-lab-name').value) || !state.Providers?.includes($('#cms-management-provider').value);
    $('#cms-management-adopt-submit').disabled = busy || !state?.CanAdopt || !$('#cms-management-adopt-confirm').checked || !/^[a-f0-9]{64}$/.test(state.PlanKey || '') || !state.Candidates?.some(item => item.RunId === $('#cms-management-candidate').value);
  }
  function renderCmsManagement(state) {
    if (!state || state.ContractVersion !== 'SqlServerLab.CmsManagement/1.0' || !/^[a-f0-9]{64}$/.test(state.PlanKey || '') || !Array.isArray(state.Providers) || !Array.isArray(state.Candidates)) throw new Error('CMS_MANAGEMENT_STATE_INVALID');
    for (const id of ['cms-management-create-confirm','cms-management-adopt-confirm']) $('#' + id).checked = false;
    cmsManagementState = state;
    const configured = state.Status === 'CONFIGURED' && state.Cms;
    const removed = configured && state.Cms.State === 'REMOVED';
    $('#cms-management-status').textContent = state.Status === 'UNKNOWN' ? 'CMS-Zustand nicht bestätigt. Es werden keine Aktionen angeboten.' : configured ? 'Ein verwalteter CMS ist registriert.' : 'Kein verwalteter CMS ist registriert.';
    $('#cms-management-summary').textContent = configured ? 'Provider: ' + state.Cms.Provider + ' · Run: ' + state.Cms.RunId + ' · Status: ' + state.Cms.State : state.DataRootConfigured ? 'Ein persistenter Data Root ist konfiguriert.' : 'Für einen neuen persistenten CMS muss zuerst ein Data Root konfiguriert werden.';
    $('#cms-management-create').hidden = configured && !removed;
    $('#cms-management-adopt').hidden = configured;
    const provider = $('#cms-management-provider');
    provider.innerHTML = state.Providers.map(item => '<option value="' + escapeHtml(item) + '">' + escapeHtml(item) + '</option>').join('');
    provider.disabled = state.Providers.length === 0;
    $('#cms-management-create').hidden = $('#cms-management-create').hidden || !state.CanCreate;
    const candidate = $('#cms-management-candidate');
    candidate.innerHTML = state.Candidates.map(item => '<option value="' + escapeHtml(item.RunId) + '">' + escapeHtml(item.Name) + ' · ' + escapeHtml(item.Provider) + ' · ' + escapeHtml(item.RunId) + '</option>').join('');
    candidate.disabled = state.Candidates.length === 0;
    $('#cms-management-adopt').hidden = $('#cms-management-adopt').hidden || !state.CanAdopt;
    if (removed) $('#cms-management-status').textContent = 'Der registrierte CMS-Run ist entfernt. Ein neuer CMS kann die terminale Registrierung gezielt ersetzen.';
    updateCmsManagementControls();
  }
  async function readCmsManagementState() {
    if (cmsManagementBusy || !$('#cms-management-dialog').open) return;
    const revision = cmsManagementRevision;
    cmsManagementState = null;
    for (const id of ['cms-management-create-confirm','cms-management-adopt-confirm']) $('#' + id).checked = false;
    cmsManagementBusy = true; updateCmsManagementControls();
    $('#cms-management-status').textContent = 'CMS-Status wird gelesen …';
    try {
      const response = await sqlServerLabUiFetch('/api/cms-management', { cache: 'no-store' });
      if (!response.ok) throw new Error('CMS_MANAGEMENT_STATE_UNAVAILABLE');
      const payload = await response.json();
      if (revision !== cmsManagementRevision || !$('#cms-management-dialog').open) return;
      renderCmsManagement(payload?.Result);
    } catch {
      if (revision === cmsManagementRevision && $('#cms-management-dialog').open) {
        cmsManagementState = null;
        $('#cms-management-status').textContent = 'CMS-Status unbekannt. Registrierung erneut lesen; keine automatische Wiederholung.';
        $('#cms-management-summary').textContent = '';
        for (const id of ['cms-management-create','cms-management-adopt']) $('#' + id).hidden = true;
        updateCmsManagementControls();
      }
    } finally { if (revision === cmsManagementRevision) { cmsManagementBusy = false; updateCmsManagementControls(); } }
  }
  async function queueCmsManagementAction(action, parameters) {
    if (cmsManagementBusy || !cmsManagementState || !$('#cms-management-dialog').open) return;
    const revision = cmsManagementRevision;
    cmsManagementState = null;
    cmsManagementBusy = true; updateCmsManagementControls();
    $('#cms-management-status').textContent = 'Aktion wird übermittelt. Ergebnis und Laufstatus werden unten bei Vorgänge angezeigt; bei unbestätigter Annahme nicht wiederholen.';
    try {
      await startAction(action, parameters);
      if (revision !== cmsManagementRevision || !$('#cms-management-dialog').open) return;
      await refreshJobs();
      if (revision !== cmsManagementRevision || !$('#cms-management-dialog').open) return;
      $('#cms-management-status').textContent = 'Aktion angenommen. Ergebnis unter Vorgänge prüfen; keine automatische Wiederholung.';
      cmsManagementState = null;
    } catch {
      if (revision === cmsManagementRevision && $('#cms-management-dialog').open) $('#cms-management-status').textContent = 'Annahme oder Ergebnis nicht bestätigt. Status erneut lesen; keine automatische Wiederholung.';
    } finally {
      if (revision === cmsManagementRevision) { cmsManagementBusy = false; updateCmsManagementControls(); }
    }
  }
  $('#cms-management-open').addEventListener('click', () => {
    cmsManagementRevision++; cmsManagementBusy = false; cmsManagementState = null;
    $('#cms-management-summary').textContent = '';
    for (const id of ['cms-management-create-confirm','cms-management-adopt-confirm']) $('#' + id).checked = false;
    $('#cms-management-dialog').showModal(); updateCmsManagementControls(); void readCmsManagementState();
  });
  $('#cms-management-read').addEventListener('click', () => { if (!cmsManagementBusy) { cmsManagementRevision++; void readCmsManagementState(); } });
  $('#cms-management-create-confirm').addEventListener('change', updateCmsManagementControls);
  $('#cms-management-adopt-confirm').addEventListener('change', updateCmsManagementControls);
  for (const [id, event, confirmation] of [
    ['provider', 'change', 'create-confirm'], ['lab-name', 'input', 'create-confirm'], ['candidate', 'change', 'adopt-confirm'],
  ]) $('#cms-management-' + id).addEventListener(event, () => {
    $('#cms-management-' + confirmation).checked = false;
    updateCmsManagementControls();
  });
  $('#cms-management-create-submit').addEventListener('click', () => {
    const state = cmsManagementState;
    if (!state?.CanCreate || !$('#cms-management-create-confirm').checked) return;
    void queueCmsManagementAction('InitializeCms', { Provider: $('#cms-management-provider').value, LabName: $('#cms-management-lab-name').value, ExpectedPlanKey: state.PlanKey, ConfirmCmsOperation: true, ReplaceRemovedCms: state.Cms?.State === 'REMOVED' });
  });
  $('#cms-management-adopt-submit').addEventListener('click', () => {
    const state = cmsManagementState; const parameters = { RunId: $('#cms-management-candidate').value, ExpectedPlanKey: state?.PlanKey, ConfirmCmsOperation: true };
    if (!state?.CanAdopt || !$('#cms-management-adopt-confirm').checked) return;
    void queueCmsManagementAction('AdoptCms', parameters);
  });
  $('#cms-management-close').addEventListener('click', () => $('#cms-management-dialog').close());
  for (const event of ['close','cancel']) $('#cms-management-dialog').addEventListener(event, () => { cmsManagementRevision++; cmsManagementBusy = false; cmsManagementState = null; });
})();
