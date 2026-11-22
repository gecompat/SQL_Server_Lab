'use strict';
(() => {
  const el = id => document.getElementById('container-network-plan-' + id);
  const dialog = el('dialog');
  const form = el('form');
  const status = el('status');
  const read = el('read');
  const apply = el('apply');
  const subnetPattern = /^\d{1,3}(?:\.\d{1,3}){3}\/\d{1,2}$/;
  const messages = {
    NO_NETWORK: 'Für den gewählten Provider wurde kein Lab-Netz gefunden.',
    NO_CONFLICT: 'Das vorhandene Lab-Netz hat keinen erkannten Subnetzkonflikt.',
    LAB_NETWORK_MIGRATION_TARGET_INVALID: 'Das Ziel muss ein IPv4-Netz in CIDR-Schreibweise sein.',
    LAB_NETWORK_MIGRATION_TARGET_CONFLICT: 'Das Zielnetz überschneidet sich mit einem bekannten Netz.',
    LAB_NETWORK_MIGRATION_PENDING_RECOVERY: 'Eine unterbrochene Migration benötigt Recovery.',
    LAB_NETWORK_MIGRATION_RUNTIME_UNVERIFIED: 'Die Runtime oder ihre Netzbindung konnte nicht eindeutig verifiziert werden.'
  };
  let revision = 0;
  let plan = null;

  function invalidate() {
    revision++;
    plan = null;
    apply.disabled = true;
    apply.hidden = true;
    read.disabled = false;
  }

  el('open').addEventListener('click', () => {
    invalidate();
    form.reset();
    status.textContent = '';
    dialog.showModal();
  });
  el('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', invalidate);
  for (const field of ['provider', 'subnet']) {
    el(field).addEventListener('input', () => { invalidate(); status.textContent = ''; });
  }
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (!dialog.open || read.disabled) return;
    invalidate();
    const current = revision;
    const provider = el('provider').value;
    const targetSubnet = el('subnet').value.trim();
    if (!['docker', 'podman'].includes(provider)) return;
    if (targetSubnet && !subnetPattern.test(targetSubnet)) {
      status.textContent = messages.LAB_NETWORK_MIGRATION_TARGET_INVALID;
      return;
    }
    const query = new URLSearchParams({ provider });
    if (targetSubnet) query.set('targetSubnet', targetSubnet);
    read.disabled = true;
    status.textContent = 'Lab-Netz und Zielsubnetz werden gelesen.';
    try {
      const response = await sqlServerLabUiFetch('/api/container-network-migration?' + query, { cache: 'no-store' });
      const view = await response.json();
      if (revision !== current || !dialog.open) return;
      if (!response.ok) {
        status.textContent = Object.hasOwn(messages, view.Code) ? messages[view.Code] : 'Das Lab-Netz konnte nicht eindeutig geprüft werden.';
        return;
      }
      if (view.ContractVersion !== 'SqlServerLab.GuidedContainerNetworkPlan/1.0' || view.Provider !== provider) {
        throw new Error('CONTAINER_NETWORK_PLAN_INVALID');
      }
      if (view.Status === 'MIGRATION_BLOCKED') {
        status.textContent = Object.hasOwn(messages, view.Code) ? messages[view.Code] : 'Die Migration ist gesperrt.';
        if (view.Code === 'LAB_NETWORK_MIGRATION_PENDING_RECOVERY' && view.Recovery) {
          const phase = view.Recovery.LastRecordedPhase;
          const code = view.Recovery.FailureCode;
          if (['PREPARED', 'TEMPORARY_NETWORK_READY', 'MANAGED_CONTAINERS_DETACHED', 'CANONICAL_NETWORK_READY', 'UNKNOWN'].includes(phase) &&
              /^(?:LAB_NETWORK_MIGRATION_[A-Z_]+|UNKNOWN)$/.test(code)) {
            status.textContent += ' Letzte protokollierte Phase ' + phase + ' · Fehlercode ' + code + '.';
          }
        }
        return;
      }
      if (Object.hasOwn(messages, view.Status)) { status.textContent = messages[view.Status]; return; }
      if (view.Status !== 'MIGRATION_REQUIRED' || !/^[a-f0-9]{64}$/.test(view.PlanKey) ||
          !subnetPattern.test(view.CurrentSubnet) || !subnetPattern.test(view.TargetSubnet) ||
          !Number.isSafeInteger(view.ContainerCount) || view.ContainerCount < 0) {
        throw new Error('CONTAINER_NETWORK_PLAN_INVALID');
      }
      plan = view;
      status.textContent = view.CurrentSubnet + ' → ' + view.TargetSubnet + ' · Verwaltete Container: ' + view.ContainerCount;
      apply.hidden = false;
      apply.disabled = false;
    } catch {
      if (revision === current && dialog.open) status.textContent = 'Das Lab-Netz konnte nicht eindeutig geprüft werden.';
    } finally {
      if (revision === current && dialog.open) read.disabled = false;
    }
  });
  apply.addEventListener('click', () => {
    if (!dialog.open || apply.disabled || !plan || plan.Provider !== el('provider').value) return;
    const commands = publicCommandCatalog.filter(command => command?.Name === 'Move-SqlServerLabContainerNetwork');
    const command = commands.length === 1 ? commands[0] : null;
    const sets = Array.isArray(command?.ParameterSets) ? command.ParameterSets : [];
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    const validField = (name, mandatory) => fields.filter(field => field?.Name === name && field.Mandatory === mandatory &&
      field.TypeName === 'System.String' && field.Sensitive === false && field.IsCredential === false).length === 1;
    if (command?.RequiresConfirmation !== true || command?.SupportsShouldProcess !== true ||
        typeof parameterSet?.Name !== 'string' || fields.filter(field => field?.Mandatory === true).length !== 1 ||
        !validField('Provider', true) || !validField('TargetSubnet', false) || !validField('ExpectedPlanKey', false)) {
      status.textContent = 'Die Ausführung ist auf diesem Host nicht verfügbar.';
      return;
    }
    const parameters = { Provider: plan.Provider, TargetSubnet: plan.TargetSubnet, ExpectedPlanKey: plan.PlanKey };
    const description = plan.CurrentSubnet + ' → ' + plan.TargetSubnet + ' für ' + plan.ContainerCount +
      ' verwaltete Container. SQL-Verbindungen können unterbrochen werden.';
    invalidate();
    dialog.close();
    openConfirmation('Gebundenes ' + parameters.Provider + '-Lab-Netz migrieren', description,
      '__PublicCommand', { command, parameterSet, parameters }, 'Migration ausführen');
  });
})();
