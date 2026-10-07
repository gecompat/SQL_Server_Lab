'use strict';
// Explicit RAM-only draft. No job, Start, session ownership or execute token.
let llamaStartPlanRevision = 0;
let llamaStartPlanBusy = false;
const llamaStartPlanElement = id => document.querySelector('#llama-start-plan-' + id);
const llamaStartPlanFields = { RuntimeDirectory: 'runtime', ModelPath: 'model', Backend: 'backend', Accelerator: 'accelerator', Dimension: 'dimension', Pooling: 'pooling', Port: 'port', StartTimeoutSeconds: 'timeout', LeaseSeconds: 'lease', ContextSize: 'context' };
const llamaStartPlanLimits = { Dimension: [1, 1998], Port: [1024, 65535], StartTimeoutSeconds: [1, 600], LeaseSeconds: [30, 3600], ContextSize: [32, 8192] };
const llamaStartPlanFixed = { Mode: 'PLAN_ONLY', Status: 'BLOCKED', RuntimeEvidence: 'FILES_ONLY', ModelFormat: 'GGUF', InputObservation: 'METADATA_STABLE_NOT_CAS', DeviceReadiness: 'NOT_CHECKED', PortAvailability: 'NOT_CHECKED', EmbeddingReadiness: 'NOT_CHECKED', TlsReadiness: 'NOT_CHECKED', PrivateKeyMatch: 'NOT_CHECKED', SanTrust: 'NOT_CHECKED', SqlReadiness: 'NOT_CHECKED' };
const llamaStartPlanArrays = { Blockers: ['LIVE_READINESS_NOT_CHECKED', 'TLS_AND_SECRETS_NOT_SUPPLIED', 'SQL_EMBEDDING_NOT_CHECKED'], NextSteps: ['SELECT_EXPLICIT_START_INPUTS', 'VALIDATE_TLS_AND_DEVICE_READINESS_SEPARATELY', 'USE_EXISTING_START_WITH_FRESH_INPUT_VALIDATION'] };
function llamaStartPlanShape(value, names) { return value !== null && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).sort().join(',') === names.slice().sort().join(','); }
function validLlamaStartPlan(view, inputs) {
  const names = [...Object.keys(llamaStartPlanFixed), ...Object.keys(llamaStartPlanLimits), 'Backend', 'Accelerator', 'Pooling', 'Contract', 'Actions', 'ExecutionSupported', 'MutationAllowed', 'Blockers', 'NextSteps'];
  return llamaStartPlanShape(view, names) && llamaStartPlanShape(view.Contract, ['Name', 'Version']) && view.Contract.Name === 'SqlServerLab.LlamaCppStartPlan' && view.Contract.Version === '1.0' &&
    Object.entries(llamaStartPlanFixed).every(([key, value]) => view[key] === value) && ['Backend', 'Accelerator', 'Pooling'].every(key => view[key] === inputs[key]) &&
    Object.keys(llamaStartPlanLimits).every(key => Number.isInteger(view[key]) && view[key] === inputs[key]) && view.ExecutionSupported === false && view.MutationAllowed === false && Array.isArray(view.Actions) && view.Actions.length === 0 &&
    Object.entries(llamaStartPlanArrays).every(([key, values]) => Array.isArray(view[key]) && view[key].length === values.length && view[key].every((value, i) => value === values[i]));
}
function updateLlamaStartPlanControls() {
  for (const id of [...Object.values(llamaStartPlanFields), 'preview']) llamaStartPlanElement(id).disabled = llamaStartPlanBusy;
}
function invalidateLlamaStartPlan(clear = false) {
  llamaStartPlanRevision++; llamaStartPlanBusy = false;
  llamaStartPlanElement('result').textContent = '';
  llamaStartPlanElement('status').textContent = 'Noch keine Dateien gelesen.';
  if (clear) {
    for (const id of Object.values(llamaStartPlanFields)) llamaStartPlanElement(id).value = '';
  }
  updateLlamaStartPlanControls();
}
function readLlamaStartPlanInputs() {
  const values = {};
  for (const [name, id] of Object.entries(llamaStartPlanFields)) values[name] = llamaStartPlanElement(id).value;
  for (const name of ['RuntimeDirectory', 'ModelPath']) if (typeof values[name] !== 'string' || !values[name] || values[name].length > 4096) throw new Error('INPUT_INVALID');
  if (!['LlamaCppCuda', 'LlamaCppOpenVino'].includes(values.Backend) || !['CPU', 'GPU', 'NPU'].includes(values.Accelerator) || !['mean', 'cls', 'last'].includes(values.Pooling) || (values.Backend === 'LlamaCppCuda' && values.Accelerator === 'NPU')) throw new Error('INPUT_INVALID');
  for (const [name, [min, max]] of Object.entries(llamaStartPlanLimits)) {
    if (!/^[0-9]{1,5}$/.test(values[name])) throw new Error('INPUT_INVALID');
    values[name] = Number(values[name]); if (values[name] < min || values[name] > max) throw new Error('INPUT_INVALID');
  }
  if (values.LeaseSeconds <= values.StartTimeoutSeconds) throw new Error('INPUT_INVALID');
  return values;
}
async function requestLlamaStartPlan() {
  if (llamaStartPlanBusy || !llamaStartPlanElement('dialog').open) return;
  let inputs;
  try { inputs = readLlamaStartPlanInputs(); } catch { llamaStartPlanElement('status').textContent = 'Explizite Eingaben und Grenzen prüfen; noch keine Dateien gelesen.'; return; }
  const revision = ++llamaStartPlanRevision;
  llamaStartPlanBusy = true; updateLlamaStartPlanControls(); llamaStartPlanElement('result').textContent = '';
  llamaStartPlanElement('status').textContent = 'Explizite Dateivorschau wird gelesen …';
  try {
    const response = await sqlServerLabUiFetch('/api/llama-start-plan', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ Action: 'Preview', Parameters: inputs }) });
    if (revision !== llamaStartPlanRevision || !llamaStartPlanElement('dialog').open) return;
    if (!response.ok) throw new Error('RESULT_INVALID');
    const view = await response.json();
    if (revision !== llamaStartPlanRevision || !llamaStartPlanElement('dialog').open) return;
    if (!validLlamaStartPlan(view, inputs)) throw new Error('RESULT_INVALID');
    llamaStartPlanElement('status').textContent = 'Dateivorschau vorhanden. Ausführung bleibt gesperrt; Live-Bereitschaft nicht geprüft.';
    llamaStartPlanElement('result').textContent = 'PLAN_ONLY / BLOCKED · keine Actions\nBackend: ' + view.Backend + ' · Beschleuniger: ' + view.Accelerator + '\nDimension: ' + view.Dimension + ' · Pooling: ' + view.Pooling + '\nGeräte, Port, TLS, Modellkompatibilität und SQL: NOT_CHECKED\nZwei Dateimetadatenbeobachtungen sind kein Integritäts- oder späterer Ausführungsnachweis.';
  } catch {
    if (revision === llamaStartPlanRevision && llamaStartPlanElement('dialog').open) llamaStartPlanElement('status').textContent = 'Dateivorschau nicht bestätigt. Explizite Dateien und Eingabegrenzen prüfen; keine Ausführung.';
  } finally { if (revision === llamaStartPlanRevision) { llamaStartPlanBusy = false; updateLlamaStartPlanControls(); } }
}
llamaStartPlanElement('open').addEventListener('click', () => {
  invalidateLlamaStartPlan(true);
  const defaults = { backend: 'LlamaCppCuda', accelerator: 'CPU', pooling: 'mean', dimension: '768', port: '19435', timeout: '120', lease: '900', context: '512' };
  for (const [id, value] of Object.entries(defaults)) llamaStartPlanElement(id).value = value;
  llamaStartPlanElement('dialog').showModal();
});
for (const id of Object.values(llamaStartPlanFields)) {
  llamaStartPlanElement(id).addEventListener('input', () => invalidateLlamaStartPlan());
  llamaStartPlanElement(id).addEventListener('change', () => invalidateLlamaStartPlan());
}
llamaStartPlanElement('preview').addEventListener('click', requestLlamaStartPlan);
llamaStartPlanElement('close').addEventListener('click', () => llamaStartPlanElement('dialog').close());
for (const event of ['close', 'cancel']) llamaStartPlanElement('dialog').addEventListener(event, () => invalidateLlamaStartPlan(true));
