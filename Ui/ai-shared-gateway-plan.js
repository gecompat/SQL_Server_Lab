'use strict';

{
  const element = name => document.querySelector('#ai-shared-gateway-' + name);
  const form = element('author');
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
}
