'use strict';
(() => {
  const element = id => document.querySelector('#windows-slot-pool-' + id);
  const dialog = element('dialog');
  const baseline = element('baseline');
  const next = element('next');
  const status = element('status');
  const uuid = /^(?!00000000-0000-0000-0000-000000000000$)[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}$/i;
  const allowed = () => workflow?.Host?.IsElevated === true && workflow.Host.HyperV?.Available === true;
  const candidates = () => (workflow?.WindowsBaselines || []).filter(item =>
    item?.SlotPoolEligible === true && /^hyperv-os-sealed-[a-f0-9]{64}$/.test(item.ArtifactId) &&
    ['core', 'desktop-experience'].includes(item.InstallationType) && /^[a-z]{2}-[a-z]{2}$/i.test(item.Language));
  const integer = (id, minimum, maximum) => {
    const input = element(id).value;
    const value = /^[0-9]+$/.test(input) ? Number(input) : NaN;
    return Number.isInteger(value) && value >= minimum && value <= maximum ? value : NaN;
  };
  function selectBaseline() {
    const matches = candidates().filter(item => item.ArtifactId === baseline.value);
    return matches.length === 1 ? matches[0] : null;
  }
  element('open').addEventListener('click', () => {
    baseline.options.length = 0;
    baseline.add(new Option('Baseline auswählen', ''));
    if (allowed()) {
      for (const item of candidates()) {
        baseline.add(new Option([item.DisplayName || item.ArtifactId, item.InstallationType, item.Language].join(' · '), item.ArtifactId));
      }
    }
    element('id').value = globalThis.crypto?.randomUUID?.() || '';
    next.disabled = true;
    status.textContent = !allowed()
      ? 'Starte das Lab auf dem Hyper-V-Host mit Administratorrechten.'
      : baseline.options.length === 1 ? 'Keine Baseline mit ausreichender Restlaufzeit verfügbar.' : '';
    dialog.showModal();
  });
  baseline.addEventListener('change', () => { next.disabled = !allowed() || !selectBaseline(); });
  element('close').addEventListener('click', () => dialog.close());
  element('form').addEventListener('submit', event => {
    event.preventDefault();
    const item = selectBaseline();
    if (!allowed() || !item || next.disabled) return;
    const parameters = {
      PoolId: element('id').value.trim(),
      ArtifactId: item.ArtifactId,
      InstallationType: item.InstallationType,
      UiLanguage: item.Language,
      NamePrefix: element('prefix').value.trim(),
      Count: integer('count', 1, 100),
      StartIndex: integer('start', 1, 9999),
      ProcessorCount: integer('cpu', 1, 64),
      MemoryMinimumMB: integer('memory-min', 512, 1048576),
      MemoryStartupMB: integer('memory-start', 512, 1048576),
      MemoryMaximumMB: integer('memory-max', 512, 1048576),
      GenerateAdministratorPasswords: true,
    };
    const end = parameters.StartIndex + parameters.Count - 1;
    if (!uuid.test(parameters.PoolId) || !/^[a-z0-9][a-z0-9_-]{0,52}$/i.test(parameters.NamePrefix) ||
        !Object.values(parameters).every(value => typeof value !== 'number' || Number.isInteger(value)) || end > 9999 ||
        parameters.MemoryMinimumMB > parameters.MemoryStartupMB || parameters.MemoryStartupMB > parameters.MemoryMaximumMB) {
      status.textContent = 'Prüfe Pool-ID, Namenspräfix, Slotbereich und die Reihenfolge der RAM-Werte.';
      return;
    }
    const commands = publicCommandCatalog.filter(command => command?.Name === 'New-SqlServerLabWindowsSlotPool');
    const command = commands.length === 1 ? commands[0] : null;
    const sets = command?.ParameterSets?.filter(set => set.Name === 'GeneratedPassword') || [];
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    if (command?.RequiresConfirmation !== true || !parameterSet ||
        fields.some(field => field?.Mandatory === true && !Object.hasOwn(parameters, field.Name)) ||
        !fields.some(field => field?.Name === 'GenerateAdministratorPasswords' && field.TypeName === 'System.Management.Automation.SwitchParameter') ||
        Object.keys(parameters).some(name => fields.filter(field => field?.Name === name && field.Sensitive === false && field.IsCredential === false).length !== 1)) {
      status.textContent = 'Die geführte Anlage ist auf diesem Host nicht verfügbar.';
      return;
    }
    dialog.close();
    openConfirmation('Windows-OS-Slot-Pool vorbereiten', [
      'Pool-ID: ' + parameters.PoolId,
      'Baseline: ' + (item.DisplayName || item.ArtifactId) + ' · ' + item.Language,
      parameters.NamePrefix + ' · Slots ' + parameters.StartIndex + ' bis ' + end + ' · je ' + parameters.ProcessorCount + ' vCPU',
      'RAM je Slot: ' + [parameters.MemoryMinimumMB, parameters.MemoryStartupMB, parameters.MemoryMaximumMB].join(' / ') + ' MB (Minimum / Start / Maximum)',
      'Der Host erstellt und startet eigene VMs für die Windows-Ersteinrichtung. Die Evaluation kann einen temporären externen Netzwerkadapter für die Aktivierung verwenden.',
      'Der Host generiert und schützt die Passwörter. Fertige Slots werden gestoppt.',
    ].join('\n'), '__PublicCommand', { command, parameterSet, parameters }, 'Pool vorbereiten');
  });
})();
