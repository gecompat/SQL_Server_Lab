'use strict';
// Transient explicit inputs. Cancel after dispatch affects display only.
let llamaStartRevision = 0;
let llamaStartBusy = false;
let llamaStartAttempted = false;
const llamaStartElement = id => document.querySelector('#llama-start-' + id);
const llamaStartFields = { RuntimeDirectory: 'runtime', Backend: 'backend', Accelerator: 'accelerator', ModelPath: 'model', ModelName: 'alias', Dimension: 'dimension', Pooling: 'pooling', Port: 'port', CertificatePath: 'certificate', PrivateKeyPath: 'private-key', ApiKey: 'api-key', TrustedRootPath: 'trusted-root', StartTimeoutSeconds: 'timeout', LeaseSeconds: 'lease', ContextSize: 'context' };
const llamaStartLimits = { Dimension: [1, 1998], Port: [1024, 65535], StartTimeoutSeconds: [1, 600], LeaseSeconds: [30, 3600], ContextSize: [32, 8192] };
function updateLlamaStartControls() {
  for (const id of [...Object.values(llamaStartFields), 'confirm']) llamaStartElement(id).disabled = llamaStartBusy;
  for (const id of ['start', 'whatif']) llamaStartElement(id).disabled = llamaStartBusy || llamaStartAttempted;
}
function clearLlamaStartInputs() {
  for (const id of Object.values(llamaStartFields)) llamaStartElement(id).value = '';
  llamaStartElement('confirm').checked = false;
}
function invalidateLlamaStart(clear = false) {
  const uncertain = llamaStartBusy || llamaStartAttempted;
  llamaStartRevision++; llamaStartBusy = false;
  llamaStartElement('result').textContent = '';
  llamaStartElement('status').textContent = uncertain ? 'Anzeige abgebrochen. Eine eigene Sitzung könnte aktiv sein. Modulhost behalten; nicht blind wiederholen. Kein Stop oder Cleanup bestätigt.' : 'Noch nichts gestartet oder geprüft.';
  if (clear) clearLlamaStartInputs();
  updateLlamaStartControls();
}
function readLlamaStartInputs() {
  const values = {};
  for (const [name, id] of Object.entries(llamaStartFields)) values[name] = llamaStartElement(id).value;
  for (const name of ['RuntimeDirectory', 'ModelPath', 'CertificatePath', 'PrivateKeyPath', 'TrustedRootPath']) if (typeof values[name] !== 'string' || values[name].length > 4096 || (name !== 'TrustedRootPath' && !values[name].trim())) throw new Error('INPUT_INVALID');
  if (!['LlamaCppCuda', 'LlamaCppOpenVino'].includes(values.Backend) || !['CPU', 'GPU', 'NPU'].includes(values.Accelerator) || !['mean', 'cls', 'last'].includes(values.Pooling) || (values.Backend === 'LlamaCppCuda' && values.Accelerator === 'NPU') || !/^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$/.test(values.ModelName) || !/^[A-Za-z0-9_-]{24,256}$/.test(values.ApiKey)) throw new Error('INPUT_INVALID');
  for (const [name, [min, max]] of Object.entries(llamaStartLimits)) {
    if (!/^[0-9]{1,5}$/.test(values[name])) throw new Error('INPUT_INVALID');
    values[name] = Number(values[name]); if (values[name] < min || values[name] > max) throw new Error('INPUT_INVALID');
  }
  if (values.LeaseSeconds <= values.StartTimeoutSeconds) throw new Error('INPUT_INVALID');
  return values;
}
function validLlamaStartResult(view, action) {
  const names = ['Contract', 'Status', 'OperationId', 'SqlReadiness', 'PossibleOwnSession', 'SameModuleRequired', 'AutoStopAllowed', 'RetryAllowed'];
  if (view === null || typeof view !== 'object' || Array.isArray(view) || Object.keys(view).sort().join(',') !== names.sort().join(',') || view.Contract !== 'SqlServerLab.BrowserLlamaStartResult/1.0' || view.SqlReadiness !== 'NOT_CHECKED' || view.SameModuleRequired !== true || view.AutoStopAllowed !== false || view.RetryAllowed !== false || typeof view.PossibleOwnSession !== 'boolean') return false;
  if (view.Status === 'ENDPOINT_VERIFIED') return action === 'Start' && view.PossibleOwnSession === true && typeof view.OperationId === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(view.OperationId);
  if (!['WHATIF_ONLY', 'NOT_CONFIRMED', 'RECOVERY_REQUIRED'].includes(view.Status) || view.OperationId !== null) return false;
  return view.Status !== 'WHATIF_ONLY' || view.PossibleOwnSession === false;
}
async function requestLlamaStart(action) {
  if (llamaStartBusy || llamaStartAttempted || !llamaStartElement('dialog').open) return;
  if (action === 'Start' && !llamaStartElement('confirm').checked) { llamaStartElement('status').textContent = 'Eigene Wirkung erst bewusst bestätigen; noch nichts gestartet.'; return; }
  let inputs, body;
  try {
    inputs = readLlamaStartInputs(); body = JSON.stringify({ Action: action, Confirmed: action === 'Start', Parameters: inputs });
    if (body.length > 32768 || new TextEncoder().encode(body).length > 65536) throw new Error('INPUT_INVALID');
  } catch { inputs = null; body = null; llamaStartElement('status').textContent = 'Explizite Eingaben und gemeinsame Größenlimits prüfen; noch nichts gestartet.'; return; }
  const revision = ++llamaStartRevision;
  llamaStartBusy = true; llamaStartAttempted = true; updateLlamaStartControls(); llamaStartElement('result').textContent = '';
  llamaStartElement('status').textContent = action === 'WhatIf' ? 'WhatIf ohne Start oder Bereitschaft …' : 'Eigener Start läuft synchron. Der UI-Listener kann blockieren; Startbudget begrenzt nur die Bereitschaftspolls. Abbrechen beendet keinen Worker.';
  try {
    const responsePromise = fetch('/api/llama-start', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body });
    inputs = null; body = null; clearLlamaStartInputs();
    const response = await responsePromise;
    if (revision !== llamaStartRevision || !llamaStartElement('dialog').open) return;
    if (!response.ok) throw new Error('RESULT_UNCONFIRMED');
    const view = await response.json();
    if (revision !== llamaStartRevision || !llamaStartElement('dialog').open) return;
    if (!validLlamaStartResult(view, action)) throw new Error('RESULT_UNCONFIRMED');
    llamaStartElement('status').textContent = view.Status === 'WHATIF_ONLY' ? 'WhatIf: kein Start und keine Bereitschaftsprüfung.' : view.Status === 'ENDPOINT_VERIFIED' ? 'ENDPOINT_VERIFIED · eigene Sitzung in diesem Modulhost. SQL: NOT_CHECKED.' : view.Status === 'RECOVERY_REQUIRED' ? 'RECOVERY_REQUIRED: eigenes Ende unbestätigt. Modulhost behalten; kein automatischer Stop oder Retry.' : 'Start nicht bestätigt. Eigene Sitzung könnte aktiv sein; kein Stop, Retry oder Cleanup-Erfolg.';
    llamaStartElement('result').textContent = view.Status === 'ENDPOINT_VERIFIED' ? 'Eigene Sitzung: ' + view.OperationId + '\nBestehende eigene Sitzungsführung separat verwenden. SQL-Funktion nicht geprüft.' : '';
  } catch {
    if (revision === llamaStartRevision && llamaStartElement('dialog').open) llamaStartElement('status').textContent = 'Antwort nicht bestätigt. Eigene Sitzung könnte aktiv sein. Modulhost behalten; kein automatischer Stop, Retry oder Cleanup-Erfolg.';
  } finally {
    inputs = null; body = null;
    if (revision === llamaStartRevision) { llamaStartBusy = false; clearLlamaStartInputs(); updateLlamaStartControls(); }
  }
}
llamaStartElement('open').addEventListener('click', () => {
  invalidateLlamaStart(true); llamaStartAttempted = false;
  const defaults = { backend: 'LlamaCppCuda', accelerator: 'CPU', pooling: 'mean', dimension: '768', port: '19435', timeout: '120', lease: '900', context: '512' };
  for (const [id, value] of Object.entries(defaults)) llamaStartElement(id).value = value;
  updateLlamaStartControls(); llamaStartElement('dialog').showModal();
});
for (const id of [...Object.values(llamaStartFields), 'confirm']) for (const event of ['input', 'change']) llamaStartElement(id).addEventListener(event, () => invalidateLlamaStart());
llamaStartElement('start').addEventListener('click', () => requestLlamaStart('Start'));
llamaStartElement('whatif').addEventListener('click', () => requestLlamaStart('WhatIf'));
llamaStartElement('close').addEventListener('click', () => llamaStartElement('dialog').close());
for (const event of ['close', 'cancel']) llamaStartElement('dialog').addEventListener(event, () => invalidateLlamaStart(true));
