'use strict';
// The explicit guest observations run as transient read-only jobs.
let evaluationRefreshRevision = 0;
let evaluationRefreshBusy = false;
let evaluationRefreshRuns = [];
let evaluationRefreshRoot = '';
const evaluationRefreshElement = id => document.querySelector('#evaluation-refresh-' + id);
const evaluationRefreshModes = ['FREE_SLOT_REPLACEMENT', 'RECONSTRUCT_LAB', 'STATEFUL_MIGRATION'];
const evaluationRefreshTargetChecks = ['TARGET_WINDOWS_LICENSE_NOT_VERIFIED', 'TARGET_SQL_READINESS_NOT_CHECKED', 'TARGET_STORAGE_AND_TRANSFER_NOT_VERIFIED'];
const evaluationRefreshGuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value) && value !== '00000000-0000-0000-0000-000000000000';
function evaluationRefreshShape(value, names) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === names.length && names.every(name => Object.hasOwn(value, name));
}
function evaluationRefreshSelection(value) {
  return evaluationRefreshShape(value, ['RunId', 'ScopeId', 'InstanceId', 'State', 'Digest']) && evaluationRefreshGuid(value.RunId) && evaluationRefreshGuid(value.ScopeId) && typeof value.InstanceId === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(value.InstanceId) && ['RUNNING', 'STOPPED'].includes(value.State) && /^[a-f0-9]{64}$/.test(value.Digest || '');
}
function evaluationRefreshOwn() { return evaluationRefreshRuns.find(run => run.RunId === evaluationRefreshElement('run').value); }

function evaluationRefreshTargets() {
  const own = evaluationRefreshOwn();
  if (!own || evaluationRefreshElement('mode').value !== 'STATEFUL_MIGRATION') return [];
  return evaluationRefreshRuns.filter(run => run.RunId !== own.RunId && run.ScopeId !== own.ScopeId);
}

function evaluationRefreshTarget() {
  const id = evaluationRefreshElement('target').value;
  return evaluationRefreshTargets().find(run => run.RunId === id);
}

function refreshEvaluationTargetChoices() {
  const field = evaluationRefreshElement('target');
  const current = field.value;
  const candidates = evaluationRefreshTargets();
  evaluationRefreshElement('target-field').hidden = candidates.length === 0;
  field.replaceChildren();
  const empty = document.createElement('option');
  empty.value = '';
  empty.textContent = 'Ohne Ziellab vorprüfen';
  field.appendChild(empty);
  for (const run of candidates) {
    const option = document.createElement('option');
    option.value = run.RunId;
    option.textContent = run.InstanceId + ' · ' + run.State + ' · Run ' + run.RunId;
    field.appendChild(option);
  }
  field.value = candidates.some(run => run.RunId === current) ? current : '';
}

function updateEvaluationRefreshControls() {
  for (const id of ['root', 'read', 'run', 'mode']) evaluationRefreshElement(id).disabled = evaluationRefreshBusy;
  evaluationRefreshElement('preview').disabled = evaluationRefreshBusy || !evaluationRefreshOwn() || !evaluationRefreshModes.includes(evaluationRefreshElement('mode').value);
  evaluationRefreshElement('observe').disabled = evaluationRefreshBusy || evaluationRefreshOwn()?.State !== 'RUNNING' ||
    evaluationRefreshElement('mode').value !== 'STATEFUL_MIGRATION';
  evaluationRefreshElement('observe-windows').disabled = evaluationRefreshBusy || evaluationRefreshOwn()?.State !== 'RUNNING';
  evaluationRefreshElement('target').disabled = evaluationRefreshBusy || evaluationRefreshElement('target-field').hidden;
  const target = evaluationRefreshTarget();
  for (const id of ['observe-target-windows', 'observe-target-sql', 'observe-target-storage']) {
    const control = evaluationRefreshElement(id);
    control.hidden = evaluationRefreshElement('target-field').hidden;
    control.disabled = evaluationRefreshBusy || target?.State !== 'RUNNING';
  }
}
async function observeEvaluationRefreshGuest(button, action, noun, target = null) {
  if (!evaluationRefreshElement('dialog').open || evaluationRefreshElement(button).disabled) return;
  const own = evaluationRefreshOwn();
  const revision = evaluationRefreshRevision;
  evaluationRefreshBusy = true;
  updateEvaluationRefreshControls();
  try {
    const parameters = {
      RunId: own.RunId, InstanceId: own.InstanceId, DataRoot: evaluationRefreshRoot, ExpectedPlanKey: own.Digest
    };
    if (target) {
      parameters.TargetRunId = target.RunId;
      parameters.TargetInstanceId = target.InstanceId;
      parameters.ExpectedTargetPlanKey = target.Digest;
    }
    await startAction(action, parameters);
    if (revision === evaluationRefreshRevision && evaluationRefreshElement('dialog').open) {
      evaluationRefreshElement('status').textContent = 'Lesender Auftrag angenommen. ' + noun + ' unter Vorgänge ansehen.';
    }
  } catch {
    if (revision === evaluationRefreshRevision && evaluationRefreshElement('dialog').open) {
      evaluationRefreshElement('status').textContent = 'Lesender Auftrag nicht bestätigt. Prüfe die Vorgänge und lies die Auswahl erneut.';
    }
  } finally { if (revision === evaluationRefreshRevision) { evaluationRefreshBusy = false; updateEvaluationRefreshControls(); } }
}
function invalidateEvaluationRefresh(clearRuns = false) {
  evaluationRefreshRevision++; evaluationRefreshBusy = false;
  if (clearRuns) { evaluationRefreshRuns = []; evaluationRefreshRoot = ''; evaluationRefreshElement('run').replaceChildren(); }
  refreshEvaluationTargetChoices();
  evaluationRefreshElement('result').textContent = ''; updateEvaluationRefreshControls();
}
function validEvaluationRefreshMetadata(view) {
  return evaluationRefreshShape(view, ['ContractVersion', 'Status', 'Runs', 'SqlReadiness', 'Actions', 'MutationAllowed', 'ExecutionSupported']) && view.ContractVersion === 'SqlServerLab.EvaluationRefreshBrowser/1.0' && view.Status === 'METADATA_ONLY' && view.SqlReadiness === 'NOT_CHECKED' && view.MutationAllowed === false && view.ExecutionSupported === false && Array.isArray(view.Actions) && view.Actions.length === 0 && Array.isArray(view.Runs) && view.Runs.length <= 64 && view.Runs.every(evaluationRefreshSelection) && new Set(view.Runs.map(run => run.RunId)).size === view.Runs.length;
}
function validEvaluationRefreshPlan(view, own, mode, target) {
  if (target) {
    if (!view || typeof view !== 'object' || Array.isArray(view)) return false;
    const { TargetAssessment: assessment, ...basePlan } = view;
    if (!evaluationRefreshShape(assessment, ['Status', 'RunId', 'ScopeId', 'InstanceId', 'RegisteredState', 'ObservedContentSha256', 'SqlVersion', 'Checks']) ||
        assessment.Status !== 'METADATA_ONLY' || assessment.RunId !== target.RunId || assessment.ScopeId !== target.ScopeId ||
        assessment.InstanceId !== target.InstanceId || assessment.RegisteredState !== target.State || assessment.ObservedContentSha256 !== target.Digest ||
        assessment.SqlVersion !== '2025' || !Array.isArray(assessment.Checks) || assessment.Checks.length !== evaluationRefreshTargetChecks.length ||
        !assessment.Checks.every((check, index) => check === evaluationRefreshTargetChecks[index])) return false;
    view = basePlan;
  }
  const blockers = ['CURRENT_WINDOWS_LICENSE_PROOF_NOT_AVAILABLE', 'SQL_EVALUATION_EVIDENCE_REQUIRED', 'SLOT_MEMBERSHIP_AND_REPLACEMENT_TARGET_NOT_ASSESSED', 'DECLARATIVE_RECONSTRUCTION_AND_DATA_DISPOSABILITY_NOT_VERIFIED', 'FULL_INSTANCE_INVENTORY_NOT_AVAILABLE', 'EQUIVALENCE_CUTOVER_AND_ROLLBACK_NOT_VERIFIED'];
  const steps = {
    FREE_SLOT_REPLACEMENT: ['Freien Slot und getrennte Restlaufzeiten prüfen.', 'Neue Medien und Zielbindung separat bestätigen; ein Clone erneuert keine Evaluation.'],
    RECONSTRUCT_LAB: ['Deklarative Rekonstruktion und entbehrlichen Zustand klären.', 'Datenübernahme, Gleichwertigkeit und Rückfall separat nachweisen.'],
    STATEFUL_MIGRATION: ['Serverobjekte, Schlüssel und externe Abhängigkeiten getrennt inventarisieren.', 'DATABASE_FILES_ONLY ist kein vollständiger Instanztransfer; Cutover und Rückfall fehlen.']
  };
  return evaluationRefreshShape(view, ['ContractVersion', 'Status', 'Mode', 'RunId', 'ScopeId', 'InstanceId', 'Evaluations', 'Blockers', 'NextSteps', 'SqlReadiness', 'FreshWindowsLicenseProof', 'FullInstanceMigration', 'EquivalenceStatus', 'TransferAuthority', 'Actions', 'MutationAllowed', 'ExecutionSupported']) && view.ContractVersion === 'SqlServerLab.EvaluationRefreshBrowser/1.0' && view.Status === 'BLOCKED' && view.Mode === mode && view.RunId === own.RunId && view.ScopeId === own.ScopeId && view.InstanceId === own.InstanceId && view.SqlReadiness === 'NOT_CHECKED' && view.FreshWindowsLicenseProof === false && view.FullInstanceMigration === false && view.EquivalenceStatus === 'NOT_VERIFIED' && view.TransferAuthority === 'NONE' && view.MutationAllowed === false && view.ExecutionSupported === false && Array.isArray(view.Actions) && view.Actions.length === 0 && Array.isArray(view.Blockers) && view.Blockers.length >= 2 && view.Blockers.length <= 4 && view.Blockers.every(code => blockers.includes(code)) && Array.isArray(view.NextSteps) && view.NextSteps.length === 2 && view.NextSteps.every((step, index) => step === steps[mode][index]) && Array.isArray(view.Evaluations) && view.Evaluations.length === 2 && view.Evaluations.every((item, index) =>
    evaluationRefreshShape(item, ['Component', 'Status', 'DeadlineSource', 'EvidenceStatus', 'EvaluationExpiresAt', 'DaysRemaining']) && item.Component === (index === 0 ? 'Windows' : 'SqlServer') && ['OK', 'WARNING', 'CRITICAL', 'EXPIRED', 'UNKNOWN', 'NOT_APPLICABLE'].includes(item.Status) && (index === 0 ? ['PERSISTED_WINDOWS_ACTIVATION', 'PERSISTED_WINDOWS_ACTIVATION_MISSING_OR_INVALID'] : ['SQL_GUEST_OBSERVED', 'SQL_GUEST_NO_DEADLINE', 'EVIDENCE_MISSING', 'EVIDENCE_INVALID']).includes(item.DeadlineSource) && (index === 0 ? ['HISTORICAL_METADATA'] : ['CURRENT', 'EVIDENCE_MISSING', 'EVIDENCE_INVALID', 'EVIDENCE_STALE', 'NOT_EVALUATION', 'DEADLINE_UNKNOWN']).includes(item.EvidenceStatus) && (item.DaysRemaining === null || (Number.isSafeInteger(item.DaysRemaining) && item.DaysRemaining >= 0)) && (item.EvaluationExpiresAt === null || (typeof item.EvaluationExpiresAt === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$/.test(item.EvaluationExpiresAt) && Number.isFinite(Date.parse(item.EvaluationExpiresAt)))));
}
async function requestEvaluationRefresh(preview = false) {
  if (evaluationRefreshBusy || !evaluationRefreshElement('dialog').open) return;
  const own = evaluationRefreshOwn(); const mode = evaluationRefreshElement('mode').value;
  if (preview && (!own || !evaluationRefreshModes.includes(mode))) return;
  const targetId = evaluationRefreshElement('target').value;
  const target = preview && targetId ? evaluationRefreshTarget() : null;
  if (preview && targetId && !target) return;
  if (!preview) invalidateEvaluationRefresh(true);
  const revision = evaluationRefreshRevision;
  const root = preview ? evaluationRefreshRoot : evaluationRefreshElement('root').value.trim();
  const payload = { Action: preview ? 'Preview' : 'Read', DataRoot: root };
  if (preview) { payload.Selection = { ...own }; payload.Mode = mode; }
  if (target) payload.Target = { ...target };
  evaluationRefreshBusy = true; updateEvaluationRefreshControls(); evaluationRefreshElement('result').textContent = '';
  evaluationRefreshElement('status').textContent = preview ? 'Gespeicherten Ersatzentscheid lesen …' : 'Registrierte Hyper-V-SQL-Metadaten lesen …';
  try {
    const response = await sqlServerLabUiFetch('/api/evaluation-refresh-plan', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    if (!response.ok) throw new Error('EVALUATION_REFRESH_REQUEST_FAILED');
    const view = await response.json();
    if (revision !== evaluationRefreshRevision || !evaluationRefreshElement('dialog').open) return;
    if (!preview) {
      if (!validEvaluationRefreshMetadata(view)) throw new Error('EVALUATION_REFRESH_RESULT_INVALID');
      evaluationRefreshRoot = root; evaluationRefreshRuns = view.Runs;
      evaluationRefreshElement('run').replaceChildren();
      for (const run of view.Runs) { const option = document.createElement('option'); option.value = run.RunId; option.textContent = run.InstanceId + ' · Hyper-V · ' + run.State + ' · Run ' + run.RunId; evaluationRefreshElement('run').appendChild(option); }
      evaluationRefreshElement('run').value = view.Runs[0]?.RunId || '';
      refreshEvaluationTargetChoices();
      evaluationRefreshElement('status').textContent = view.Runs.length ? 'Gespeicherte Bindungen gelesen. Instanz und Entscheidungsart bewusst auswählen.' : 'Keine vollständig gebundene einzelne Hyper-V-SQL-Instanz verfügbar.';
    } else {
      if (!validEvaluationRefreshPlan(view, own, mode, target)) throw new Error('EVALUATION_REFRESH_RESULT_INVALID');
      evaluationRefreshElement('status').textContent = 'BLOCKED · reine Planung · SQL NOT_CHECKED · keine Speicherung oder Ausführung.';
      evaluationRefreshElement('result').textContent = 'Keine frische Windows-Lizenzprüfung. Gleichwertigkeit nicht verifiziert; keine Transferfreigabe.\n' + view.Evaluations.map(item => (item.Component === 'Windows' ? 'Windows' : 'SQL Server') + ': ' + item.Status + ' · Quelle: ' + item.DeadlineSource + ' · Evidence: ' + item.EvidenceStatus + ' · Frist UTC: ' + (item.EvaluationExpiresAt ?? 'nicht belegt / nicht anwendbar') + ' · Resttage: ' + (item.DaysRemaining ?? 'unbekannt / nicht anwendbar')).join('\n') + '\nOffen:\n' + view.Blockers.join('\n') + '\nNächste Schritte:\n' + view.NextSteps.join('\n');
      if (target) {
        evaluationRefreshElement('result').textContent += '\nZiellab ' + target.RunId + ' / ' + target.InstanceId +
          ' · SQL 2025 · registriert als ' + target.State + ' · nur Metadaten\n' + view.TargetAssessment.Checks.join('\n');
      }
    }
  } catch {
    if (revision === evaluationRefreshRevision && evaluationRefreshElement('dialog').open) { invalidateEvaluationRefresh(true); evaluationRefreshElement('status').textContent = 'Vorschau nicht bestätigt. Registrierte Metadaten erneut lesen und auswählen; keine Änderung ausgeführt.'; }
  } finally { if (revision === evaluationRefreshRevision) { evaluationRefreshBusy = false; updateEvaluationRefreshControls(); } }
}
evaluationRefreshElement('open').addEventListener('click', () => { invalidateEvaluationRefresh(true); evaluationRefreshElement('status').textContent = 'Noch nicht gelesen. Keine Lizenz- oder SQL-Abfrage.'; evaluationRefreshElement('dialog').showModal(); });
evaluationRefreshElement('read').addEventListener('click', () => requestEvaluationRefresh());
evaluationRefreshElement('preview').addEventListener('click', () => requestEvaluationRefresh(true));
evaluationRefreshElement('observe').addEventListener('click', () => observeEvaluationRefreshGuest('observe', 'ReadHyperVEvaluationSqlSource', 'SQL-Quellzähler'));
evaluationRefreshElement('observe-windows').addEventListener('click', () => observeEvaluationRefreshGuest('observe-windows', 'ReadHyperVEvaluationWindowsLicense', 'Windows-Lizenzbefund der Quelle'));
evaluationRefreshElement('observe-target-windows').addEventListener('click', () => {
  const target = evaluationRefreshTarget();
  if (target?.State !== 'RUNNING') return;
  return observeEvaluationRefreshGuest('observe-target-windows', 'ReadHyperVEvaluationWindowsLicense', 'Windows-Lizenzbefund des Ziellabs', target);
});
evaluationRefreshElement('observe-target-sql').addEventListener('click', () => {
  const target = evaluationRefreshTarget();
  if (target?.State !== 'RUNNING') return;
  return observeEvaluationRefreshGuest('observe-target-sql', 'ReadHyperVEvaluationTargetSqlReadiness', 'SQL-Bereitschaft des Ziellabs', target);
});
evaluationRefreshElement('observe-target-storage').addEventListener('click', () => {
  const target = evaluationRefreshTarget();
  if (target?.State !== 'RUNNING') return;
  return observeEvaluationRefreshGuest('observe-target-storage', 'ReadHyperVEvaluationTargetStorage', 'Freier Speicher im Ziellab', target);
});
evaluationRefreshElement('root').addEventListener('input', () => invalidateEvaluationRefresh(true));
for (const id of ['run', 'mode', 'target']) evaluationRefreshElement(id).addEventListener('change', () => invalidateEvaluationRefresh());
evaluationRefreshElement('close').addEventListener('click', () => evaluationRefreshElement('dialog').close());
for (const event of ['close', 'cancel']) evaluationRefreshElement('dialog').addEventListener(event, () => invalidateEvaluationRefresh(true));
