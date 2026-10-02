'use strict';
// RAM-only decisions from registered metadata; no job, Apply or transfer.
let evaluationRefreshRevision = 0;
let evaluationRefreshBusy = false;
let evaluationRefreshRuns = [];
let evaluationRefreshRoot = '';
const evaluationRefreshElement = id => document.querySelector('#evaluation-refresh-' + id);
const evaluationRefreshModes = ['FREE_SLOT_REPLACEMENT', 'RECONSTRUCT_LAB', 'STATEFUL_MIGRATION'];
const evaluationRefreshGuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value) && value !== '00000000-0000-0000-0000-000000000000';
function evaluationRefreshShape(value, names) {
  return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === names.length && names.every(name => Object.hasOwn(value, name));
}
function evaluationRefreshSelection(value) {
  return evaluationRefreshShape(value, ['RunId', 'ScopeId', 'InstanceId', 'State', 'Digest']) && evaluationRefreshGuid(value.RunId) && evaluationRefreshGuid(value.ScopeId) && typeof value.InstanceId === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(value.InstanceId) && ['RUNNING', 'STOPPED'].includes(value.State) && /^[a-f0-9]{64}$/.test(value.Digest || '');
}
function evaluationRefreshOwn() { return evaluationRefreshRuns.find(run => run.RunId === evaluationRefreshElement('run').value); }
function updateEvaluationRefreshControls() {
  for (const id of ['root', 'read', 'run', 'mode']) evaluationRefreshElement(id).disabled = evaluationRefreshBusy;
  evaluationRefreshElement('preview').disabled = evaluationRefreshBusy || !evaluationRefreshOwn() || !evaluationRefreshModes.includes(evaluationRefreshElement('mode').value);
}
function invalidateEvaluationRefresh(clearRuns = false) {
  evaluationRefreshRevision++; evaluationRefreshBusy = false;
  if (clearRuns) { evaluationRefreshRuns = []; evaluationRefreshRoot = ''; evaluationRefreshElement('run').replaceChildren(); }
  evaluationRefreshElement('result').textContent = ''; updateEvaluationRefreshControls();
}
function validEvaluationRefreshMetadata(view) {
  return evaluationRefreshShape(view, ['ContractVersion', 'Status', 'Runs', 'SqlReadiness', 'Actions', 'MutationAllowed', 'ExecutionSupported']) && view.ContractVersion === 'SqlServerLab.EvaluationRefreshBrowser/1.0' && view.Status === 'METADATA_ONLY' && view.SqlReadiness === 'NOT_CHECKED' && view.MutationAllowed === false && view.ExecutionSupported === false && Array.isArray(view.Actions) && view.Actions.length === 0 && Array.isArray(view.Runs) && view.Runs.length <= 64 && view.Runs.every(evaluationRefreshSelection) && new Set(view.Runs.map(run => run.RunId)).size === view.Runs.length;
}
function validEvaluationRefreshPlan(view, own, mode) {
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
  if (!preview) invalidateEvaluationRefresh(true);
  const revision = evaluationRefreshRevision;
  const root = preview ? evaluationRefreshRoot : evaluationRefreshElement('root').value.trim();
  const payload = { Action: preview ? 'Preview' : 'Read', DataRoot: root };
  if (preview) { payload.Selection = { ...own }; payload.Mode = mode; }
  evaluationRefreshBusy = true; updateEvaluationRefreshControls(); evaluationRefreshElement('result').textContent = '';
  evaluationRefreshElement('status').textContent = preview ? 'Gespeicherten Ersatzentscheid lesen …' : 'Registrierte Hyper-V-SQL-Metadaten lesen …';
  try {
    const response = await fetch('/api/evaluation-refresh-plan', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    if (!response.ok) throw new Error('EVALUATION_REFRESH_REQUEST_FAILED');
    const view = await response.json();
    if (revision !== evaluationRefreshRevision || !evaluationRefreshElement('dialog').open) return;
    if (!preview) {
      if (!validEvaluationRefreshMetadata(view)) throw new Error('EVALUATION_REFRESH_RESULT_INVALID');
      evaluationRefreshRoot = root; evaluationRefreshRuns = view.Runs;
      evaluationRefreshElement('run').replaceChildren();
      for (const run of view.Runs) { const option = document.createElement('option'); option.value = run.RunId; option.textContent = run.InstanceId + ' · Hyper-V · ' + run.State + ' · Run ' + run.RunId; evaluationRefreshElement('run').appendChild(option); }
      evaluationRefreshElement('run').value = view.Runs[0]?.RunId || '';
      evaluationRefreshElement('status').textContent = view.Runs.length ? 'Gespeicherte Bindungen gelesen. Instanz und Entscheidungsart bewusst auswählen.' : 'Keine vollständig gebundene einzelne Hyper-V-SQL-Instanz verfügbar.';
    } else {
      if (!validEvaluationRefreshPlan(view, own, mode)) throw new Error('EVALUATION_REFRESH_RESULT_INVALID');
      evaluationRefreshElement('status').textContent = 'BLOCKED · reine Planung · SQL NOT_CHECKED · keine Speicherung oder Ausführung.';
      evaluationRefreshElement('result').textContent = 'Keine frische Windows-Lizenzprüfung. Gleichwertigkeit nicht verifiziert; keine Transferfreigabe.\n' + view.Evaluations.map(item => (item.Component === 'Windows' ? 'Windows' : 'SQL Server') + ': ' + item.Status + ' · Quelle: ' + item.DeadlineSource + ' · Evidence: ' + item.EvidenceStatus + ' · Frist UTC: ' + (item.EvaluationExpiresAt ?? 'nicht belegt / nicht anwendbar') + ' · Resttage: ' + (item.DaysRemaining ?? 'unbekannt / nicht anwendbar')).join('\n') + '\nOffen:\n' + view.Blockers.join('\n') + '\nNächste Schritte:\n' + view.NextSteps.join('\n');
    }
  } catch {
    if (revision === evaluationRefreshRevision && evaluationRefreshElement('dialog').open) { invalidateEvaluationRefresh(true); evaluationRefreshElement('status').textContent = 'Vorschau nicht bestätigt. Registrierte Metadaten erneut lesen und auswählen; keine Änderung ausgeführt.'; }
  } finally { if (revision === evaluationRefreshRevision) { evaluationRefreshBusy = false; updateEvaluationRefreshControls(); } }
}
evaluationRefreshElement('open').addEventListener('click', () => { invalidateEvaluationRefresh(true); evaluationRefreshElement('status').textContent = 'Noch nicht gelesen. Keine Lizenz- oder SQL-Abfrage.'; evaluationRefreshElement('dialog').showModal(); });
evaluationRefreshElement('read').addEventListener('click', () => requestEvaluationRefresh());
evaluationRefreshElement('preview').addEventListener('click', () => requestEvaluationRefresh(true));
evaluationRefreshElement('root').addEventListener('input', () => invalidateEvaluationRefresh(true));
for (const id of ['run', 'mode']) evaluationRefreshElement(id).addEventListener('change', () => invalidateEvaluationRefresh());
evaluationRefreshElement('close').addEventListener('click', () => evaluationRefreshElement('dialog').close());
for (const event of ['close', 'cancel']) evaluationRefreshElement('dialog').addEventListener(event, () => invalidateEvaluationRefresh(true));
