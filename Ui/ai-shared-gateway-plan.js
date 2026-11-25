'use strict';

(() => {
  const element = name => document.querySelector('#ai-shared-gateway-' + name);
  const form = element('author');
  if (!form) return;
  const consumers = element('consumers');
  const status = element('plan-status');
  const result = element('plan-result');
  const resultBox = element('plan-result-box');
  const add = element('add-consumer');
  const create = element('create-plan');
  const use = element('use-plan');
  const read = element('read-status');
  const probe = element('probe-upstream');
  const preflight = element('preflight');
  const openPreflight = element('open-preflight');
  const openRegistration = element('open-registration');
  const verify = element('verify-files');
  const fileEffect = element('file-action-effect');
  const registrationConfirmation = element('registration-confirmation');
  const confirmRegistration = preflight.elements.namedItem('ConfirmRegistration');
  const preflightName = 'Test-SqlServerLabAiSharedGatewayPreflight';
  const registrationName = 'Register-SqlServerLabAiSharedGatewayStorage';
  const servicePlanName = 'Get-SqlServerLabAiSharedGatewayServicePlan';
  const serviceControls = element('service-controls');
  const serviceMode = element('service-mode');
  const prepareService = element('prepare-service');
  const openSessionStart = element('open-session-start');
  const sessionDialog = element('session-dialog');
  const sessionForm = element('session-start');
  const sessionLease = element('session-lease');
  const sessionReference = element('session-upstream-reference');
  const sessionStartConfirm = element('session-start-confirmed');
  const sessionStart = element('session-start-submit');
  const sessionSelection = element('session-selection');
  const sessionStopConfirm = element('session-stop-confirmed');
  const sessionStop = element('session-stop');
  const sessionRead = element('session-read');
  const sessionClose = element('session-close');
  const sessionStatus = element('session-status');
  const pathFields = ['RuntimePath', 'ModelPath', 'CertificatePath', 'PrivateKeyPath', 'CertificateAuthorityPath'];
  const fields = ['GatewayId', 'Location', 'UpstreamBackend', 'UpstreamLocation', 'RuntimeModel', 'InputProfile',
    'ModelSha256', 'RuntimeSha256', 'ServerCertificateSha256', 'CertificateAuthoritySha256'];
  const consumerFields = ['RunId', 'InstanceId', 'DatabaseId', 'ExternalModelName', 'ApiKeyReference'];
  let revision = 0;
  let busy = false;
  let checkingPlan = false;
  let currentPlan = null;
  let fileAction = null;
  let serviceJob = null;
  let sessionPlan = null;
  let sessionRows = [];
  let sessionBusy = false;
  let vaultAvailable = false;
  const operationIdPattern = /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;

  function closePreflight() {
    preflight.reset();
    preflight.hidden = true;
    registrationConfirmation.hidden = true;
    confirmRegistration.required = false;
    fileAction = null;
  }

  function updatePlanActions() {
    const disabled = !currentPlan || checkingPlan;
    read.disabled = disabled;
    probe.disabled = disabled;
    openPreflight.disabled = disabled;
    openRegistration.disabled = disabled;
    verify.disabled = disabled;
    serviceControls.hidden = !currentPlan;
    serviceMode.disabled = disabled;
    prepareService.disabled = disabled;
    openSessionStart.disabled = disabled;
  }

  function clearPlan() {
    revision++;
    currentPlan = null;
    serviceJob = null;
    serviceMode.value = 'Auto';
    result.value = '';
    resultBox.hidden = true;
    use.disabled = true;
    closePreflight();
    updatePlanActions();
    status.textContent = 'Plan für die aktuellen Eingaben anzeigen.';
  }

  function updateConsumers() {
    add.disabled = consumers.children.length >= 64;
    for (const row of consumers.children) {
      row.querySelector('[data-remove-consumer]').disabled = consumers.children.length === 1;
    }
  }

  function addConsumer() {
    if (consumers.children.length >= 64) return;
    const row = element('consumer-template').content.firstElementChild.cloneNode(true);
    row.querySelector('[data-remove-consumer]').addEventListener('click', () => {
      if (consumers.children.length <= 1) return;
      row.remove();
      clearPlan();
      updateConsumers();
    });
    consumers.appendChild(row);
    clearPlan();
    updateConsumers();
  }

  add.addEventListener('click', addConsumer);
  form.addEventListener('input', () => {
    const backend = form.elements.namedItem('UpstreamBackend').value;
    const path = backend === 'OpenVinoModelServer' ? '/v3/embeddings' : '/v1/embeddings';
    form.elements.namedItem('UpstreamLocation').placeholder = 'http://127.0.0.1:18080' + path;
    clearPlan();
  });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (busy || !form.reportValidity()) return;
    clearPlan();
    const current = revision;
    const request = Object.fromEntries(fields.map(name => [name, form.elements.namedItem(name).value.trim()]));
    request.Dimension = Number(form.elements.namedItem('Dimension').value);
    request.Consumer = Array.from(consumers.children, row => Object.fromEntries(
      consumerFields.map(name => [name, row.querySelector('[name="' + name + '"]').value.trim()])
    ));
    busy = true;
    create.disabled = true;
    status.textContent = 'Gateway-Konfiguration wird geprüft …';
    try {
      const response = await sqlServerLabUiFetch('/api/ai-shared-gateway/plan', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(request)
      });
      if (!response.ok) throw new Error('Gateway input rejected');
      const plan = await response.json();
      if (plan?.Contract?.Name !== 'SqlServerLab.AiSharedGatewayPlan' || plan.Contract.Version !== '1.0' ||
          plan.Status !== 'BLOCKED' || plan.EvidenceStatus !== 'CONFIGURATION_ONLY' || plan.GatewayId !== request.GatewayId ||
          !Array.isArray(plan.Consumers) || plan.Consumers.length !== request.Consumer.length || !/^[a-f0-9]{64}$/.test(plan.PlanKey)) {
        throw new Error('Gateway plan unconfirmed');
      }
      if (current !== revision) return;
      currentPlan = plan;
      result.value = JSON.stringify(plan, null, 2);
      resultBox.hidden = false;
      use.disabled = false;
      updatePlanActions();
      status.textContent = 'Konfigurationsplan erstellt. Bereitstellung erfordert weitere Nachweise.';
    } catch {
      if (current === revision) status.textContent = 'Plan nicht erstellt. Prüfe Endpunkte, Digests und Verbraucherreferenzen.';
    } finally {
      busy = false;
      create.disabled = false;
    }
  });
  async function checkSelectedPlan(button, commandName, inputs = null) {
    if (button.disabled || checkingPlan || !currentPlan) return;
    const matches = publicCommandCatalog.filter(command => command?.Name === commandName);
    const command = matches.length === 1 ? matches[0] : null;
    const sets = command?.ParameterSets;
    const parameterSet = Array.isArray(sets) && sets.length === 1 ? sets[0] : null;
    const descriptors = parameterSet?.Parameters;
    const required = Array.isArray(descriptors) ? descriptors.filter(field => field?.Mandatory === true) : [];
    const register = commandName === registrationName;
    const filePreflight = commandName === preflightName;
    const service = commandName === servicePlanName;
    const confirmed = register || filePreflight;
    const expectedNames = confirmed ? ['Plan', ...pathFields] : ['Plan'];
    const modeFields = service && Array.isArray(descriptors) ? descriptors.filter(field => field?.Name === 'ServiceMode') : [];
    if (command?.RequiresConfirmation !== confirmed || command.SupportsShouldProcess !== register ||
        parameterSet?.Name !== '__AllParameterSets' || required.length !== expectedNames.length ||
        (filePreflight && descriptors.length !== expectedNames.length) ||
        (service && (modeFields.length !== 1 || modeFields[0].Mandatory !== false || modeFields[0].Sensitive !== false ||
          modeFields[0].TypeName !== 'System.String' || modeFields[0].IsCredential !== false)) || !expectedNames.every(name =>
          required.some(field => field.Name === name && field.IsCredential === false &&
            field.TypeName === (name === 'Plan' ? 'System.Object' : 'System.String') &&
            field.Sensitive === (name === 'PrivateKeyPath')))) {
      status.textContent = 'Prüfung für diesen Gateway-Plan ist nicht verfügbar.';
      return;
    }
    const current = revision;
    checkingPlan = true;
    if (service) serviceJob = null;
    closePreflight();
    updatePlanActions();
    try {
      const accepted = await startPublicCommand(command, parameterSet, { Plan: currentPlan, ...inputs }, confirmed);
      if (current === revision) {
        if (service && /^[a-f0-9]{32}$/.test(accepted?.id)) serviceJob = { id: accepted.id, mode: inputs.ServiceMode };
        status.textContent = service ? 'Der Dienstplan steht im Auftragsprotokoll.' : (register
          ? 'Das Auftragsprotokoll zeigt die geschützte Registrierung.' : 'Das Auftragsprotokoll zeigt die Prüfung.');
      }
    } catch {
      if (current === revision) status.textContent = 'Annahme des Auftrags unbestätigt. Prüfe das Auftragsprotokoll.';
    } finally {
      checkingPlan = false;
      updatePlanActions();
    }
  }
  read.addEventListener('click', () => checkSelectedPlan(read, 'Get-SqlServerLabAiSharedGatewayStatus'));
  probe.addEventListener('click', () => checkSelectedPlan(probe, 'Test-SqlServerLabAiSharedGatewayUpstream'));
  prepareService.addEventListener('click', () => {
    if (!['Auto','WindowsS4U','SystemdUser'].includes(serviceMode.value)) return;
    return checkSelectedPlan(prepareService, servicePlanName, { ServiceMode: serviceMode.value });
  });
  function openFileAction(button, commandName) {
    if (button.disabled || !currentPlan) return;
    closePreflight();
    fileAction = commandName;
    const register = commandName === registrationName;
    verify.textContent = register ? 'Dateien geschützt registrieren' : 'Dateien jetzt prüfen';
    registrationConfirmation.hidden = !register;
    confirmRegistration.required = register;
    fileEffect.textContent = register
      ? 'Die Registrierung prüft und kopiert alle fünf Dateien einschließlich des Schlüssels in die geschützte Lab-Ablage.'
      : 'Die Prüfung liest alle fünf Dateien und gleicht sie mit dem angezeigten Plan ab.';
    preflight.hidden = false;
    preflight.elements.namedItem('RuntimePath').focus();
  }
  openPreflight.addEventListener('click', () => openFileAction(openPreflight, preflightName));
  openRegistration.addEventListener('click', () => openFileAction(openRegistration, registrationName));
  element('cancel-preflight').addEventListener('click', () => {
    const opener = fileAction === registrationName ? openRegistration : openPreflight;
    closePreflight();
    opener.focus();
  });
  preflight.addEventListener('submit', event => {
    event.preventDefault();
    if (preflight.hidden || !fileAction || verify.disabled || !preflight.reportValidity()) return;
    const paths = Object.fromEntries(pathFields.map(name => [name, preflight.elements.namedItem(name).value]));
    return checkSelectedPlan(verify, fileAction, paths);
  });

  function updateSessionActions() {
    const selected = sessionRows.some(row => row.OperationId === sessionSelection.value);
    sessionStart.disabled = sessionBusy || !sessionPlan || !vaultAvailable || !sessionStartConfirm.checked;
    sessionSelection.disabled = sessionBusy || !sessionRows.length;
    sessionStop.disabled = sessionBusy || !selected || !sessionStopConfirm.checked;
    sessionRead.disabled = sessionBusy;
    sessionClose.disabled = sessionBusy;
  }

  function clearSessionRows() {
    sessionRows = [];
    sessionSelection.replaceChildren();
    sessionStopConfirm.checked = false;
  }

  async function requestSession(payload) {
    const options = payload ? { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) } : { cache: 'no-store' };
    const response = await sqlServerLabUiFetch('/api/ai-shared-gateway/sessions', options);
    const data = await response.json();
    if (!response.ok) throw new Error(data?.Code);
    return data;
  }

  async function readSessions() {
    if (sessionBusy) return;
    clearSessionRows();
    vaultAvailable = false;
    sessionBusy = true;
    updateSessionActions();
    sessionStatus.textContent = 'Eigene Worker werden gelesen …';
    try {
      const view = await requestSession();
      if (typeof view?.VaultAvailable !== 'boolean' || !Array.isArray(view.Items) || !view.Items.every(row =>
        operationIdPattern.test(row.OperationId) && /^[a-z][a-z0-9-]{0,62}$/.test(row.GatewayId) &&
        Number.isInteger(row.Port) && row.Port >= 1024 && row.Port <= 65535 && ['OWNED_SESSION', 'CLEANUP_PENDING'].includes(row.Status))) {
        throw new Error('Gateway session view unconfirmed');
      }
      sessionRows = view.Items;
      vaultAvailable = view.VaultAvailable;
      const placeholder = document.createElement('option');
      placeholder.value = '';
      placeholder.textContent = 'Sitzung auswählen';
      sessionSelection.appendChild(placeholder);
      for (const row of sessionRows) {
        const option = document.createElement('option');
        option.value = row.OperationId;
        const state = row.Status === 'CLEANUP_PENDING' ? 'Cleanup offen' : 'Eigener Worker';
        option.textContent = `${row.GatewayId} · Port ${row.Port} · ${state}`;
        sessionSelection.appendChild(option);
      }
      sessionStatus.textContent = sessionPlan && !vaultAvailable
        ? 'PowerShell SecretManagement fehlt in diesem UI-Server. Der Start benötigt Zugriff auf den lokalen Vault.'
        : sessionRows.length ? 'Wähle eine eigene Sitzung, um sie zu stoppen.' : 'Dieser UI-Server besitzt keine Gateway-Sitzung.';
    } catch {
      sessionStatus.textContent = 'Eigene Sitzungen konnten nicht gelesen werden.';
    } finally {
      sessionBusy = false;
      updateSessionActions();
    }
  }

  async function openSessions(plan) {
    if (sessionDialog.open) return;
    sessionPlan = plan;
    sessionForm.reset();
    sessionForm.hidden = !plan;
    element('session-target').textContent = plan ? `Gateway ${plan.GatewayId} · ${plan.Consumers.length} gebundene Verbraucher` : '';
    sessionDialog.showModal();
    await readSessions();
  }

  async function changeSession(payload) {
    sessionBusy = true;
    clearSessionRows();
    updateSessionActions();
    sessionStatus.textContent = 'Bestätigter Auftrag läuft. Das Schließen ist nach dem Ergebnis wieder möglich.';
    try {
      const result = await requestSession(payload);
      const start = payload.Action === 'Start';
      const expected = start
        ? result?.Status === 'SESSION_ENDPOINT_VERIFIED' && result.PlanKey === payload.Plan.PlanKey && operationIdPattern.test(result.OperationId)
        : result?.Status === 'CLEANUP_SUCCEEDED' && result.OperationId === payload.OperationId;
      if (!expected) throw new Error('Gateway session result unconfirmed');
      sessionStatus.textContent = start
        ? 'Der eigene Gateway-Endpunkt wurde bestätigt. SQL-Zugriff ist separat zu prüfen. Lies die Sitzungen zum Stop neu.'
        : 'Eigener Gateway-Worker beendet und temporärer Zustand bereinigt.';
    } catch (error) {
      const reasons = {
        AI_SHARED_GATEWAY_SESSION_HTTP_NOT_READY: 'Prüfe die passende Registrierung und ob der Gateway-Port frei ist.',
        AI_SHARED_GATEWAY_SESSION_HTTP_VAULT_UNAVAILABLE: 'Der UI-Server hat keinen Zugriff auf PowerShell SecretManagement.',
        AI_SHARED_GATEWAY_SESSION_HTTP_SECRET_UNAVAILABLE: 'Prüfe die gebundenen Referenzen und den Zugriff des UI-Servers auf den lokalen Vault.',
        AI_SHARED_GATEWAY_SESSION_HTTP_SECRET_INVALID: 'Prüfe Typ und Format der gebundenen Schlüssel im Vault.',
        AI_SHARED_GATEWAY_SESSION_HTTP_CONFIRM_POLICY_BLOCKED: 'Die Bestätigungseinstellung des UI-Servers blockiert die Aktion.'
      };
      sessionStatus.textContent = 'Aktion unbestätigt. ' + (reasons[error.message] ?? 'Lies die eigenen Sitzungen und prüfe den Zustand vor weiteren Aktionen.');
    } finally {
      sessionBusy = false;
      updateSessionActions();
    }
  }

  openSessionStart.addEventListener('click', () => openSessionStart.disabled || !currentPlan ? undefined : openSessions(currentPlan));
  element('open-sessions').addEventListener('click', () => openSessions(null));
  sessionRead.addEventListener('click', readSessions);
  sessionStartConfirm.addEventListener('change', updateSessionActions);
  sessionSelection.addEventListener('change', () => {
    sessionStopConfirm.checked = false;
    updateSessionActions();
  });
  sessionStopConfirm.addEventListener('change', updateSessionActions);
  sessionClose.addEventListener('click', () => { if (!sessionBusy) sessionDialog.close(); });
  sessionDialog.addEventListener('cancel', event => { if (sessionBusy) event.preventDefault(); });
  sessionDialog.addEventListener('close', () => {
    sessionPlan = null;
    vaultAvailable = false;
    sessionForm.reset();
    clearSessionRows();
  });
  sessionForm.addEventListener('submit', event => {
    event.preventDefault();
    if (sessionStart.disabled || !sessionPlan || currentPlan?.PlanKey !== sessionPlan.PlanKey || !sessionForm.reportValidity()) return;
    const lease = Number(sessionLease.value);
    const reference = sessionReference.value.trim();
    if (!Number.isInteger(lease) || lease < 60 || lease > 3600 || (reference && !/^SQL_SERVER_LAB_SECRET_[A-Z0-9_]{1,96}$/.test(reference))) {
      sessionStatus.textContent = 'Prüfe die Sitzungsdauer und die optionale Vault-Referenz.';
      return;
    }
    const payload = { Action: 'Start', Confirmed: true, Plan: sessionPlan, LeaseSeconds: lease, UpstreamReference: reference };
    sessionPlan = null;
    sessionForm.reset();
    sessionForm.hidden = true;
    return changeSession(payload);
  });
  sessionStop.addEventListener('click', () => {
    if (sessionStop.disabled || !sessionRows.some(row => row.OperationId === sessionSelection.value)) return;
    return changeSession({ Action: 'Stop', Confirmed: true, OperationId: sessionSelection.value });
  });

  function matchesReadyServicePlan(plan) {
    const mode = { WindowsS4U: 'WINDOWS_S4U_TASK', SystemdUser: 'LINUX_SYSTEMD_USER' }[serviceMode.value];
    return plan?.Contract?.Name === 'SqlServerLab.AiSharedGatewayServicePlan' && plan.Contract.Version === '1.0' &&
      plan.Status === 'READY' && plan.GatewayId === currentPlan.GatewayId && plan.GatewayPlanKey === currentPlan.PlanKey &&
      /^[a-f0-9]{64}$/.test(plan.PlanKey) && ['WINDOWS_S4U_TASK','LINUX_SYSTEMD_USER'].includes(plan.ServiceMode) &&
      (!mode || plan.ServiceMode === mode);
  }

  function readyServicePlanFromJob() {
    if (!serviceJob || serviceJob.mode !== serviceMode.value) return null;
    const job = observedJobs.get(serviceJob.id);
    if (job?.State !== 'Completed' || job.Action !== 'Command: ' + servicePlanName) return null;
    const prefix = '[ERGEBNIS] ';
    const lines = (jobLineCache[serviceJob.id] || []).filter(line => typeof line === 'string' && line.startsWith(prefix));
    if (lines.length !== 1 || lines[0].length > 16384) return null;
    try {
      const receipt = JSON.parse(lines[0].slice(prefix.length));
      const plan = Array.isArray(receipt?.Result) && receipt.Result.length === 1 ? receipt.Result[0] : null;
      if (receipt.Command !== servicePlanName || receipt.ParameterSet !== '__AllParameterSets' || !matchesReadyServicePlan(plan)) return null;
      return plan;
    } catch { return null; }
  }

  use.addEventListener('click', () => {
    if (use.disabled || !result.value || !currentPlan) return;
    const field = element('service-plan-json');
    const confirmedServicePlan = readyServicePlanFromJob();
    if (confirmedServicePlan) {
      field.value = JSON.stringify(confirmedServicePlan, null, 2);
    } else {
      try {
        if (!matchesReadyServicePlan(JSON.parse(field.value))) field.value = '';
      } catch { field.value = ''; }
    }
    element('plan-json').value = result.value;
    element('service-secret-result').textContent = confirmedServicePlan
      ? 'Der passende bereite Dienstplan ist übernommen. Wähle Dienst-Secrets prüfen, um den Vault zu lesen.'
      : 'Gateway-Plan übernommen. Prüfe den zugehörigen Dienstplan vor der Dienst-Secret-Prüfung.';
    const panel = element('service-secret-panel');
    panel.open = true;
    panel.scrollIntoView({ block: 'nearest' });
  });
  addConsumer();
})();

(() => {
  const element = name => document.querySelector('#' + 'external-model-endpoint-' + name);
  const dialog = element('dialog');
  if (!dialog) return;
  const form = element('form');
  const planField = element('plan');
  const caField = element('ca');
  const referenceField = element('reference');
  const confirm = element('confirm');
  const submit = element('submit');
  const close = element('close');
  const status = element('status');
  const result = element('result');
  const resultBox = element('result-box');
  const sqlPlanButton = element('sql-plan');
  let plan = null;
  let receiptForSqlPlan = null;
  let busy = false;
  const digest = /^[a-f0-9]{64}$/;

  function updateActions() {
    submit.disabled = busy || !plan || !confirm.checked;
    close.disabled = busy;
    for (const control of [planField, caField, referenceField, confirm]) control.disabled = busy;
  }

  function clearReceipt() {
    result.value = '';
    resultBox.hidden = true;
    receiptForSqlPlan = null;
    sqlPlanButton.disabled = true;
  }

  function formatPlan() {
    plan = null;
    clearReceipt();
    confirm.checked = false;
    status.textContent = '';
    element('selection').textContent = '';
    try {
      const value = JSON.parse(planField.value);
      const url = new URL(value.Location);
      if (value?.Contract?.Name === 'SqlServerLab.AiExternalModelPlan' && value.Contract.Version === '1.0' &&
          value.Status === 'NOT_PROBED' && value.EvidenceStatus === 'CONFIGURATION_ONLY' && digest.test(value.PlanKey) &&
          digest.test(value.ServerCertificateSha256) && url.protocol === 'https:' &&
          typeof value.RuntimeModel === 'string' && value.RuntimeModel.length <= 256 &&
          Number.isInteger(value.Dimension) && value.Dimension >= 1 && value.Dimension <= 1998) {
        plan = value;
        element('selection').textContent = `${url.origin} · Modell ${value.RuntimeModel} · Dimension ${value.Dimension}`;
      }
    } catch { /* Wait for a complete plan. */ }
    if (planField.value && !plan) status.textContent = 'Der Plan kann für diese Prüfung nicht übernommen werden.';
    updateActions();
  }

  element('open').addEventListener('click', () => {
    form.reset();
    formatPlan();
    dialog.showModal();
  });
  planField.addEventListener('input', formatPlan);
  dialog.addEventListener('sqlserverlab:prepared-plan', event => {
    if (busy || dialog.open) return;
    form.reset();
    planField.value = JSON.stringify(event.detail, null, 2);
    formatPlan();
    if (plan) dialog.showModal();
  });
  for (const control of [caField, referenceField]) {
    control.addEventListener('input', () => {
      confirm.checked = false;
      clearReceipt();
      updateActions();
    });
  }
  confirm.addEventListener('change', updateActions);
  close.addEventListener('click', () => { if (!busy) dialog.close(); });
  dialog.addEventListener('cancel', event => { if (busy) event.preventDefault(); });
  dialog.addEventListener('close', () => { form.reset(); formatPlan(); });
  sqlPlanButton.addEventListener('click', () => {
    if (busy || !plan || !receiptForSqlPlan || !dialog.open) return;
    const pair = {Plan:plan,EndpointReceipt:receiptForSqlPlan};
    dialog.close();
    document.querySelector('#external-model-sql-plan-dialog')?.dispatchEvent(
      new CustomEvent('sqlserverlab:model-sql-plan-input', {detail:pair})
    );
  });

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (submit.disabled || !dialog.open || !form.reportValidity()) return;
    const keyReference = referenceField.value.trim();
    if (keyReference && !/^SQL_SERVER_LAB_SECRET_[A-Z0-9_]{1,96}$/.test(keyReference)) {
      status.textContent = 'Die Vault-Referenz muss mit SQL_SERVER_LAB_SECRET_ beginnen.';
      return;
    }
    const request = {Plan: plan, Confirmed: true, TrustedRootPem: caField.value.trim(), ApiKeyReference: keyReference};
    const body = JSON.stringify(request);
    if (new TextEncoder().encode(body).length > 65536) {
      status.textContent = 'Plan und CA-Zertifikat überschreiten die Grenze von zusammen 64 KiB.';
      return;
    }
    busy = true;
    confirm.checked = false;
    clearReceipt();
    status.textContent = 'Der lokale Endpunkt wird geprüft …';
    updateActions();
    try {
      const response = await sqlServerLabUiFetch('/api/ai-external-model/endpoint', {
        method: 'POST', headers: {'Content-Type': 'application/json'}, body
      });
      const receipt = await response.json();
      if (!response.ok) throw new Error(receipt?.Code);
      const names = ['Contract','Status','EvidenceStatus','PlanKey','Backend','Dimension','HttpStatus','ServerCertificateSha256',
        'DurationMilliseconds','VerifiedAtUtc','ReceiptKey','VerifiedEvidence','PendingEvidence'];
      const verified = ['HTTPS_CERTIFICATE_MATCH','OPENAI_RESPONSE_SHAPE_MATCH','RUNTIME_MODEL_MATCH','EMBEDDING_DIMENSION_MATCH','FINITE_NUMERIC_VECTOR_MATCH'];
      const pending = ['RUNTIME_BINARY_MATCH','MODEL_FILE_MATCH','ACCELERATOR_RUNTIME_ATTESTATION'];
      if (!receipt || Object.keys(receipt).length !== names.length || !names.every(name => Object.hasOwn(receipt,name)) ||
          receipt.Contract?.Name !== 'SqlServerLab.AiExternalModelEndpointReceipt' || receipt.Contract.Version !== '1.0' ||
          Object.keys(receipt.Contract).length !== 2 || receipt.Status !== 'ENDPOINT_VERIFIED' || receipt.EvidenceStatus !== 'LIVE_ENDPOINT' ||
          receipt.PlanKey !== request.Plan.PlanKey || receipt.Backend !== request.Plan.Backend || receipt.Dimension !== request.Plan.Dimension ||
          receipt.ServerCertificateSha256 !== request.Plan.ServerCertificateSha256 || !digest.test(receipt.ReceiptKey) ||
          !Number.isInteger(receipt.HttpStatus) || receipt.HttpStatus < 200 || receipt.HttpStatus > 299 ||
          !Number.isSafeInteger(receipt.DurationMilliseconds) || receipt.DurationMilliseconds < 0 ||
          typeof receipt.VerifiedAtUtc !== 'string' || !/^\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{7}(?:Z|\+00:00)$/.test(receipt.VerifiedAtUtc) ||
          !Array.isArray(receipt.VerifiedEvidence) || receipt.VerifiedEvidence.length !== verified.length || !verified.every(code => receipt.VerifiedEvidence.includes(code)) ||
          !Array.isArray(receipt.PendingEvidence) || receipt.PendingEvidence.length !== pending.length || !pending.every(code => receipt.PendingEvidence.includes(code))) {
        throw new Error('AI_EXTERNAL_MODEL_GUIDED_UNCONFIRMED');
      }
      result.value = JSON.stringify(receipt, null, 2);
      resultBox.hidden = false;
      receiptForSqlPlan = receipt;
      sqlPlanButton.disabled = false;
      status.textContent = 'HTTPS-Endpunkt bestätigt. Modellartefakte, Beschleuniger und SQL-Bindung bleiben separat zu prüfen.';
    } catch (error) {
      const messages = {
        AI_EXTERNAL_MODEL_GUIDED_CA_INVALID: 'Das optionale PEM muss ein einzelnes öffentliches CA-Zertifikat enthalten.',
        AI_EXTERNAL_MODEL_GUIDED_VAULT_UNAVAILABLE: 'Die optionale Referenz konnte im lokalen Vault nicht gelesen werden.',
        AI_EXTERNAL_MODEL_GUIDED_KEY_INVALID: 'Die Referenz muss einen Schlüssel vom Typ SecureString liefern.',
        AI_EXTERNAL_MODEL_ENDPOINT_TIMEOUT: 'Die Anfrage hat ihr Zeitbudget überschritten.',
        AI_EXTERNAL_MODEL_TLS_CERTIFICATE_MISMATCH: 'Das präsentierte Zertifikat weicht vom Plan ab.'
      };
      status.textContent = 'Endpunktprüfung unbestätigt. ' + (Object.hasOwn(messages,error.message)
        ? messages[error.message] : 'Prüfe den Plan, den lokalen Dienst und die Zertifikatskette.');
    } finally {
      busy = false;
      updateActions();
    }
  });
})();

(() => {
  const element = id => document.querySelector('#' + 'ovms-gateway-' + id);
  const dialog = element('dialog');
  if (!dialog) return;
  const form = element('form');
  const start = element('start');
  const startConfirm = element('start-confirm');
  const stop = element('stop');
  const stopConfirm = element('stop-confirm');
  const selection = element('selection');
  const status = element('status');
  const result = element('result');
  const resultBox = element('result-box');
  const stringFields = ['UpstreamLocation','RuntimeModel','CertificatePath','PrivateKeyPath','TrustedRootPath','ApiKeyReference'];
  const numberFields = ['Port','Dimension','StartTimeoutSeconds','LeaseSeconds'];
  const operationId = /^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
  const digest = /^[a-f0-9]{64}$/;
  let busy = false;
  let available = false;
  let ownSessions = [];

  function updateActions() {
    start.disabled = busy || !available || !startConfirm.checked;
    selection.disabled = busy || !ownSessions.length;
    stop.disabled = busy || !stopConfirm.checked || !ownSessions.some(row => row.OperationId === selection.value);
    element('read').disabled = busy;
    element('close').disabled = busy;
  }

  function clearSessions() {
    ownSessions = [];
    selection.replaceChildren();
    stopConfirm.checked = false;
  }

  function clearResult() {
    result.value = '';
    resultBox.hidden = true;
  }

  async function request(payload) {
    const options = payload ? {method:'POST',headers:{'Content-Type':'application/json'},body:JSON.stringify(payload)} : {cache:'no-store'};
    const response = await sqlServerLabUiFetch('/api/ai-ovms-gateway/sessions', options);
    const view = await response.json();
    if (!response.ok) throw new Error(view?.Code);
    return view;
  }

  async function readSessions() {
    if (busy) return;
    clearSessions();
    available = false;
    busy = true;
    updateActions();
    status.textContent = 'Eigene OVMS-Sitzungen werden gelesen …';
    try {
      const view = await request();
      if (typeof view?.Supported !== 'boolean' || typeof view.VaultAvailable !== 'boolean' || !Array.isArray(view.Items) ||
          !view.Items.every(row => operationId.test(row.OperationId) && Number.isInteger(row.Port) && row.Port >= 1024 &&
            row.Port <= 65535 && ['OWNED_SESSION','CLEANUP_PENDING'].includes(row.Status))) throw new Error('Invalid session view');
      available = view.Supported && view.VaultAvailable;
      ownSessions = view.Items;
      const placeholder = document.createElement('option');
      placeholder.value = '';
      placeholder.textContent = 'Eigene Sitzung auswählen';
      selection.appendChild(placeholder);
      for (const row of ownSessions) {
        const option = document.createElement('option');
        option.value = row.OperationId;
        option.textContent = `Port ${row.Port} · ${row.Status === 'CLEANUP_PENDING' ? 'Cleanup offen' : 'Eigene Sitzung'}`;
        selection.appendChild(option);
      }
      status.textContent = !view.Supported ? 'Der OVMS-HTTPS-Worker benötigt Windows.' :
        !view.VaultAvailable ? 'Für einen neuen Worker braucht der UI-Server Zugriff auf PowerShell SecretManagement.' :
        ownSessions.length ? 'Wähle eine eigene Sitzung zum Stop.' : 'Keine eigene OVMS-Sitzung in diesem UI-Server.';
    } catch {
      status.textContent = 'Eigene OVMS-Sitzungen konnten nicht gelesen werden.';
    } finally {
      busy = false;
      updateActions();
    }
  }

  async function dispatch(payload) {
    busy = true;
    clearSessions();
    clearResult();
    updateActions();
    status.textContent = 'Die bestätigte Aktion läuft …';
    try {
      const view = await request(payload);
      if (payload.Action === 'Start') {
        const fields = ['Contract','Status','OperationId','Location','RuntimeModel','Dimension','ServerCertificateSha256','UpstreamBindingKey','LeaseSeconds','BindingKey'];
        if (!view || Object.keys(view).length !== fields.length || !fields.every(name => Object.hasOwn(view,name)) ||
            view.Contract !== 'SqlServerLab.AiOvmsHttpsGateway/1.0' || view.Status !== 'ENDPOINT_VERIFIED' ||
            !operationId.test(view.OperationId) || view.Location !== `https://127.0.0.1:${payload.Port}/v3/embeddings` ||
            view.RuntimeModel !== payload.RuntimeModel || view.Dimension !== payload.Dimension || view.LeaseSeconds !== payload.LeaseSeconds ||
            ![view.ServerCertificateSha256,view.UpstreamBindingKey,view.BindingKey].every(value => typeof value === 'string' && digest.test(value))) {
          throw new Error('Unconfirmed start');
        }
        result.value = JSON.stringify(view,null,2);
        resultBox.hidden = false;
        status.textContent = 'Eigener OVMS-HTTPS-Endpunkt bestätigt. Die Bindung kann für den External-Model-Plan übernommen werden.';
      } else {
        if (view?.Status !== 'CLEANUP_SUCCEEDED' || view.OperationId !== payload.OperationId) throw new Error('Unconfirmed cleanup');
        status.textContent = 'Eigene OVMS-Sitzung beendet und temporärer Schlüssel bereinigt.';
      }
    } catch (error) {
      const reasons = {
        AI_OVMS_GUIDED_INPUT_INVALID:'Prüfe Ziel, Modell, Port, Dimension und Zeitgrenzen.',
        AI_OVMS_GUIDED_KEY_INVALID:'Der lokale Vault muss einen gültigen SecureString liefern.',
        AI_OVMS_GUIDED_VAULT_UNAVAILABLE:'Der UI-Server konnte den lokalen Vault nicht lesen.',
        AI_SHARED_GATEWAY_GUIDED_PATH_INVALID:'Prüfe die lokalen PEM-Dateipfade.'
      };
      status.textContent = 'OVMS-Aktion unbestätigt. ' + (Object.hasOwn(reasons,error.message)
        ? reasons[error.message] : 'Lies die eigenen Sitzungen neu und prüfe den Zustand vor einer weiteren Aktion.');
    } finally {
      busy = false;
      updateActions();
    }
  }

  element('open').addEventListener('click', () => {
    form.reset();
    clearResult();
    dialog.showModal();
    return readSessions();
  });
  element('read').addEventListener('click', readSessions);
  startConfirm.addEventListener('change', updateActions);
  for (const name of [...stringFields,...numberFields]) {
    form.elements.namedItem(name).addEventListener('input', () => { startConfirm.checked = false; updateActions(); });
  }
  selection.addEventListener('change', () => { stopConfirm.checked = false; updateActions(); });
  stopConfirm.addEventListener('change', updateActions);
  element('close').addEventListener('click', () => { if (!busy) dialog.close(); });
  dialog.addEventListener('cancel', event => { if (busy) event.preventDefault(); });
  dialog.addEventListener('close', () => { form.reset(); clearSessions(); clearResult(); });
  form.addEventListener('submit', event => {
    event.preventDefault();
    if (start.disabled || !dialog.open || !form.reportValidity()) return;
    const payload = {Action:'Start',Confirmed:true};
    for (const name of stringFields) payload[name] = form.elements.namedItem(name).value.trim();
    for (const name of numberFields) payload[name] = Number(form.elements.namedItem(name).value);
    if (!numberFields.every(name => Number.isInteger(payload[name])) || payload.LeaseSeconds <= payload.StartTimeoutSeconds ||
        !/^SQL_SERVER_LAB_SECRET_[A-Z0-9_]{1,96}$/.test(payload.ApiKeyReference)) {
      status.textContent = 'Prüfe Startbudget, Laufzeit und die lokale Vault-Referenz.';
      return;
    }
    form.reset();
    return dispatch(payload);
  });
  stop.addEventListener('click', () => {
    if (!stop.disabled && ownSessions.some(row => row.OperationId === selection.value)) {
      return dispatch({Action:'Stop',Confirmed:true,OperationId:selection.value});
    }
  });
})();

(() => {
  const element = name => document.querySelector('#external-model-plan-' + name);
  const dialog = element('dialog');
  if (!dialog) return;
  const form = element('form');
  const submit = element('submit');
  const use = element('use');
  const status = element('status');
  const result = element('result');
  const resultBox = element('result-box');
  const textFields = ['Backend','Accelerator','Location','ExternalModelName','RuntimeModel','ModelSha256',
    'RuntimeSha256','ServerCertificateSha256','TlsMode','InputProfile','GatewayBindingJson'];
  let plan = null;
  let revision = 0;
  let busy = false;

  function invalidate() {
    revision++;
    plan = null;
    use.disabled = true;
    result.value = '';
    resultBox.hidden = true;
    status.textContent = '';
  }

  element('open').addEventListener('click', () => { form.reset(); invalidate(); dialog.showModal(); });
  element('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => { form.reset(); invalidate(); });
  form.addEventListener('input', invalidate);

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (busy || !dialog.open || !form.reportValidity()) return;
    invalidate();
    const requestId = revision;
    const payload = Object.fromEntries(textFields.map(name => [name,form.elements.namedItem(name).value.trim()]));
    payload.Dimension = Number(form.elements.namedItem('Dimension').value);
    const body = JSON.stringify(payload);
    if (new TextEncoder().encode(body).length > 16384 || !Number.isInteger(payload.Dimension) ||
        payload.Dimension < 1 || payload.Dimension > 1998) {
      status.textContent = 'Prüfe die Dimension und die Größe der Eingaben.';
      return;
    }
    busy = true;
    submit.disabled = true;
    status.textContent = 'Konfiguration wird geprüft …';
    try {
      const response = await sqlServerLabUiFetch('/api/ai-external-model/plan', {
        method:'POST',headers:{'Content-Type':'application/json'},body
      });
      if (!response.ok) throw new Error('PLAN_REQUEST_REJECTED');
      const view = await response.json();
      if (revision !== requestId || !dialog.open) return;
      if (view?.Status === 'BLOCKED' && view.Plan === null && Array.isArray(view.Blockers) &&
          view.Blockers.length > 0 && view.Blockers.length <= 16 &&
          view.Blockers.every(code => typeof code === 'string' && /^AI_EXTERNAL_MODEL_[A-Z0-9_]{1,80}$/.test(code))) {
        status.textContent = 'Plan blockiert · ' + view.Blockers.join(' · ');
        return;
      }
      const candidate = view?.Plan;
      const exact = ['Backend','Accelerator','ExternalModelName','RuntimeModel','Dimension','TlsMode','InputProfile'];
      const hashes = ['ModelSha256','RuntimeSha256','ServerCertificateSha256'];
      if (view?.Status !== 'NOT_PROBED' || candidate?.Contract?.Name !== 'SqlServerLab.AiExternalModelPlan' ||
          candidate.Contract.Version !== '1.0' || candidate.Status !== 'NOT_PROBED' ||
          candidate.EvidenceStatus !== 'CONFIGURATION_ONLY' || !/^[a-f0-9]{64}$/.test(candidate.PlanKey) ||
          !exact.every(name => candidate[name] === payload[name]) ||
          !hashes.every(name => candidate[name] === payload[name].toLowerCase()) ||
          candidate.Location !== new URL(payload.Location).href) throw new Error('UNCONFIRMED_PLAN');
      plan = candidate;
      result.value = JSON.stringify(plan,null,2);
      resultBox.hidden = false;
      use.disabled = false;
      status.textContent = 'Konfiguration gebunden. Laufzeit und SQL-Einsatz benötigen eigene Prüfungen.';
    } catch {
      if (revision === requestId && dialog.open) status.textContent = 'Vorschau unbestätigt. Prüfe die Eingaben.';
    } finally {
      busy = false;
      submit.disabled = false;
    }
  });

  use.addEventListener('click', () => {
    if (!plan || !dialog.open || use.disabled) return;
    const prepared = plan;
    dialog.close();
    document.querySelector('#external-model-endpoint-dialog')?.dispatchEvent(
      new CustomEvent('sqlserverlab:prepared-plan', {detail:prepared})
    );
  });
})();

(() => {
  const element = name => document.querySelector('#external-model-sql-plan-' + name);
  const dialog = element('dialog');
  if (!dialog) return;
  const form = element('form');
  const submit = element('submit');
  const status = element('status');
  const result = element('result');
  const resultBox = element('result-box');
  const digest = /^[a-f0-9]{64}$/;
  let revision = 0;
  let busy = false;

  function clearPlan() {
    revision++;
    result.value = '';
    if (element('preflight')) element('preflight').hidden = true;
    resultBox.hidden = true;
    status.textContent = '';
  }
  function show(pair) {
    if (dialog.open) return;
    form.reset();
    clearPlan();
    if (pair) {
      element('plan').value = JSON.stringify(pair.Plan, null, 2);
      element('receipt').value = JSON.stringify(pair.EndpointReceipt, null, 2);
    }
    dialog.showModal();
  }
  element('open').addEventListener('click', () => show(null));
  dialog.addEventListener('sqlserverlab:model-sql-plan-input', event => show(event.detail));
  element('close').addEventListener('click', () => dialog.close());
  element('preflight')?.addEventListener('click', () => {
    const targetDialog = document.querySelector('#external-model-sql-preflight-dialog');
    if (!targetDialog || !result.value || resultBox.hidden) return;
    const sqlPlanText = result.value;
    dialog.close();
    targetDialog.dispatchEvent(new CustomEvent('sqlserverlab:model-sql-preflight-input', {detail:sqlPlanText}));
  });
  dialog.addEventListener('close', () => { form.reset(); clearPlan(); });
  form.addEventListener('input', clearPlan);

  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (busy || !dialog.open || !form.reportValidity()) return;
    clearPlan();
    const requestId = revision;
    let request;
    let body;
    try {
      request = {Plan:JSON.parse(element('plan').value),EndpointReceipt:JSON.parse(element('receipt').value),
        DatabaseName:element('database').value.trim(),MaxEndpointAgeSeconds:Number(element('age').value)};
      if (!digest.test(request.Plan?.PlanKey) || request.EndpointReceipt?.PlanKey !== request.Plan.PlanKey ||
          !digest.test(request.EndpointReceipt.ReceiptKey) || !/^[A-Za-z_][A-Za-z0-9_]{0,127}$/.test(request.DatabaseName) ||
          !Number.isInteger(request.MaxEndpointAgeSeconds) || request.MaxEndpointAgeSeconds < 30 || request.MaxEndpointAgeSeconds > 3600) {
        throw new Error('BAD_INPUT');
      }
      body = JSON.stringify(request);
      if (new TextEncoder().encode(body).length > 32768) throw new Error('BAD_INPUT');
    } catch {
      status.textContent = 'Prüfe Plan, passende Quittung, Datenbanknamen und Quittungsalter.';
      return;
    }
    busy = true;
    submit.disabled = true;
    status.textContent = 'SQL-Plan wird gebunden …';
    try {
      const response = await sqlServerLabUiFetch('/api/ai-external-model/sql-plan', {
        method:'POST',headers:{'Content-Type':'application/json'},body
      });
      const view = await response.json();
      if (revision !== requestId || !dialog.open) return;
      if (!response.ok && view?.Code === 'AI_EXTERNAL_MODEL_ENDPOINT_RECEIPT_EXPIRED') {
        status.textContent = 'Die Quittung ist abgelaufen. Prüfe den Endpunkt erneut.';
        return;
      }
      if (!response.ok || view?.Contract?.Name !== 'SqlServerLab.AiExternalModelSqlPlan' || view.Contract.Version !== '1.0' ||
          view.Status !== 'PLANNED' || view.EvidenceStatus !== 'LIVE_ENDPOINT_BOUND' || view.SqlMajorVersion !== 17 ||
          view.DatabaseName !== request.DatabaseName || view.SourcePlanKey !== request.Plan.PlanKey ||
          view.EndpointReceiptKey !== request.EndpointReceipt.ReceiptKey || !digest.test(view.SqlPlanKey)) throw new Error('BAD_PLAN');
      result.value = JSON.stringify(view,null,2);
      if (element('preflight')) element('preflight').hidden = false;
      resultBox.hidden = false;
      status.textContent = 'SQL-Plan gebunden. Rechte, Datenbank-Master-Key und Ausführung werden separat geprüft.';
    } catch {
      if (revision === requestId && dialog.open) status.textContent = 'SQL-Plan unbestätigt. Prüfe Plan, Endpunktquittung und Datenbanknamen.';
    } finally {
      busy = false;
      submit.disabled = false;
    }
  });
})();

(function () {
  'use strict';
  const element = name => document.querySelector('#external-model-sql-preflight-' + name);
  const dialog = element('dialog');
  if (!dialog || !element('open')) return;
  const form = element('form');
  const select = element('target');
  const confirm = element('confirm');
  const status = element('status');
  const submit = element('submit');
  const action = 'ReadExternalModelSqlPreflight';
  const runFormat = /^[a-f0-9]{8}-(?:[a-f0-9]{4}-){3}[a-f0-9]{12}$/;
  const instanceFormat = /^[A-Za-z][A-Za-z0-9_-]{0,63}$/;
  let submitting = false;
  let offeredTargets = new Map();

  function candidates(snapshot) {
    const entries = new Map();
    function add(lab, instanceId, version, provider) {
      if (!runFormat.test(lab.RunId) || !instanceFormat.test(instanceId) ||
          !/^2025(?:-|$)/.test(version) || !['docker', 'podman', 'hyperv'].includes(provider)) return;
      const key = lab.RunId + '/' + instanceId;
      const label = (lab.Name || lab.RunId) + ' · ' + instanceId + ' · ' + provider;
      entries.set(key, entries.has(key) ? null : { RunId:lab.RunId, InstanceId:instanceId, Label:label, Provider:provider });
    }
    for (const lab of snapshot?.ActiveLabs || []) {
      if (lab.State !== 'RUNNING') continue;
      for (const instance of lab.Instances || []) add(lab, instance.Id, instance.SqlVersion, instance.Provider);
    }
    for (const lab of snapshot?.HyperVLabs || []) {
      if (lab.State !== 'RUNNING' || lab.VMState !== 'Running' || lab.Workload === 'windows' ||
          lab.SqlCompletionState === 'PENDING_SLOT_INSTALL' || lab.SqlCompletionState === 'PENDING_COMPLETE_IMAGE') continue;
      add(lab, lab.InstanceId, lab.SqlVersion, 'hyperv');
    }
    return entries;
  }

  function open(sqlPlan) {
    if (dialog.open || submitting) return;
    form.reset();
    select.replaceChildren(new Option('Instanz auswählen', ''));
    offeredTargets = candidates(workflow);
    const targets = [...offeredTargets.entries()].filter(([, target]) => target);
    for (const [key, target] of targets) select.add(new Option(target.Label, key));
    status.textContent = targets.length ? '' : 'Keine laufende SQL-2025-Instanz in der aktuellen Übersicht.';
    submit.disabled = targets.length === 0;
    if (sqlPlan) element('plan').value = sqlPlan;
    dialog.showModal();
  }

  element('open').addEventListener('click', () => open(null));
  dialog.addEventListener('sqlserverlab:model-sql-preflight-input', event => open(event.detail));
  element('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => { form.reset(); offeredTargets.clear(); });
  form.addEventListener('input', event => {
    if (event.target === select || event.target === element('plan')) confirm.checked = false;
  });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (!dialog.open || submitting || !form.reportValidity()) return;
    const target = candidates(workflow).get(select.value);
    if (!target || target.Provider !== offeredTargets.get(select.value)?.Provider) {
      status.textContent = 'Die Instanz ist in der aktuellen Übersicht nicht mehr auswählbar.';
      return;
    }
    let sqlPlan;
    try {
      sqlPlan = JSON.parse(element('plan').value);
      if (sqlPlan?.Contract?.Name !== 'SqlServerLab.AiExternalModelSqlPlan' ||
          sqlPlan.Contract.Version !== '1.0' || !/^[a-f0-9]{64}$/.test(sqlPlan.SqlPlanKey)) throw new Error('PLAN');
    } catch {
      status.textContent = 'Der gebundene SQL-Plan konnte nicht gelesen werden.';
      return;
    }
    if (!confirm.checked) return;
    submitting = true;
    submit.disabled = true;
    dialog.close();
    try {
      await submitUiAction(action, '/api/ai-external-model/sql-preflight', {
        parameters:{SqlPlan:sqlPlan, RunId:target.RunId, InstanceId:target.InstanceId}
      });
    } catch {
      showError(new Error('Annahme der SQL-Zielprüfung unbestätigt. Prüfe die Vorgangsanzeige.'));
    } finally {
      submitting = false;
      submit.disabled = false;
    }
  });
})();
