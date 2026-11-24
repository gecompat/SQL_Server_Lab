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
  const fields = ['GatewayId', 'Location', 'UpstreamBackend', 'UpstreamLocation', 'RuntimeModel', 'InputProfile',
    'ModelSha256', 'RuntimeSha256', 'ServerCertificateSha256', 'CertificateAuthoritySha256'];
  const consumerFields = ['RunId', 'InstanceId', 'DatabaseId', 'ExternalModelName', 'ApiKeyReference'];
  let revision = 0;
  let busy = false;
  let readingStatus = false;
  let currentPlan = null;

  function clearPlan() {
    revision++;
    currentPlan = null;
    result.value = '';
    resultBox.hidden = true;
    use.disabled = true;
    read.disabled = true;
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
      read.disabled = readingStatus;
      status.textContent = 'Konfigurationsplan erstellt. Bereitstellung erfordert weitere Nachweise.';
    } catch {
      if (current === revision) status.textContent = 'Plan nicht erstellt. Prüfe Endpunkte, Digests und Verbraucherreferenzen.';
    } finally {
      busy = false;
      create.disabled = false;
    }
  });
  read.addEventListener('click', async () => {
    if (read.disabled || readingStatus || !currentPlan) return;
    const matches = publicCommandCatalog.filter(command => command?.Name === 'Get-SqlServerLabAiSharedGatewayStatus');
    const command = matches.length === 1 ? matches[0] : null;
    const sets = command?.ParameterSets;
    const parameterSet = Array.isArray(sets) && sets.length === 1 ? sets[0] : null;
    const descriptors = parameterSet?.Parameters;
    const planFields = Array.isArray(descriptors) ? descriptors.filter(field => field?.Mandatory === true) : [];
    if (command?.RequiresConfirmation !== false || command.SupportsShouldProcess !== false ||
        parameterSet?.Name !== '__AllParameterSets' || planFields.length !== 1 ||
        planFields[0].Name !== 'Plan' || planFields[0].TypeName !== 'System.Object' ||
        planFields[0].Sensitive !== false || planFields[0].IsCredential !== false) {
      status.textContent = 'Statusprüfung für diesen Gateway-Plan ist nicht verfügbar.';
      return;
    }
    const current = revision;
    readingStatus = true;
    read.disabled = true;
    try {
      await startPublicCommand(command, parameterSet, { Plan: currentPlan }, false);
      if (current === revision) status.textContent = 'Das Auftragsprotokoll zeigt die Statusprüfung.';
    } catch {
      if (current === revision) status.textContent = 'Annahme der Statusprüfung unbestätigt. Prüfe das Auftragsprotokoll.';
    } finally {
      readingStatus = false;
      read.disabled = !currentPlan;
    }
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
