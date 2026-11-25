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
  const pathFields = ['RuntimePath', 'ModelPath', 'CertificatePath', 'PrivateKeyPath', 'CertificateAuthorityPath'];
  const fields = ['GatewayId', 'Location', 'UpstreamBackend', 'UpstreamLocation', 'RuntimeModel', 'InputProfile',
    'ModelSha256', 'RuntimeSha256', 'ServerCertificateSha256', 'CertificateAuthoritySha256'];
  const consumerFields = ['RunId', 'InstanceId', 'DatabaseId', 'ExternalModelName', 'ApiKeyReference'];
  let revision = 0;
  let busy = false;
  let checkingPlan = false;
  let currentPlan = null;
  let fileAction = null;

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
  }

  function clearPlan() {
    revision++;
    currentPlan = null;
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
    closePreflight();
    updatePlanActions();
    try {
      await startPublicCommand(command, parameterSet, { Plan: currentPlan, ...inputs }, confirmed);
      if (current === revision) {
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
  use.addEventListener('click', () => {
    if (use.disabled || !result.value) return;
    element('plan-json').value = result.value;
    const panel = element('service-secret-panel');
    panel.open = true;
    panel.scrollIntoView({ block: 'nearest' });
  });
  addConsumer();
}
