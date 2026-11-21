'use strict';
(() => {
  const element = id => document.getElementById('container-tool-check-' + id);
  const dialog = element('dialog');
  const target = element('target');
  const status = element('status');
  const submit = element('submit');
  const known = new Map();
  const runPattern = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  element('open').addEventListener('click', () => {
    known.clear();
    target.replaceChildren(new Option('Instanz auswählen', ''));
    for (const lab of workflow?.ActiveLabs || []) {
      if (lab.State !== 'RUNNING' || typeof lab.RunId !== 'string' || !runPattern.test(lab.RunId)) continue;
      for (const instance of lab.Instances || []) {
        if (!['docker', 'podman'].includes(instance.Provider) ||
            typeof instance.Id !== 'string' || !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(instance.Id)) continue;
        const id = lab.RunId.toLowerCase() + '/' + instance.Id;
        if (known.has(id)) continue;
        const label = [lab.Name || lab.RunId, instance.Id, instance.Provider].join(' · ');
        known.set(id, { label, parameters: { RunId: lab.RunId.toLowerCase(), InstanceId: instance.Id } });
        target.add(new Option(label, id));
      }
    }
    status.textContent = known.size ? 'Die Prüfung verwendet das bereits provisionierte SqlPackage.' : 'Keine registrierte laufende SQL-Containerinstanz gefunden.';
    submit.disabled = !known.size;
    dialog.showModal();
  });
  element('close').addEventListener('click', () => dialog.close());
  element('form').addEventListener('submit', event => {
    event.preventDefault();
    if (!dialog.open) return;
    const selection = known.get(target.value);
    if (!selection) return;
    const commands = publicCommandCatalog.filter(item => item?.Name === 'Test-SqlServerLabContainerTool');
    const command = commands.length === 1 ? commands[0] : null;
    const sets = command?.ParameterSets || [];
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    if (!command || !parameterSet || Object.keys(selection.parameters).some(name =>
      fields.filter(field => field.Name === name && field.Sensitive === false && field.IsCredential === false).length !== 1)) {
      status.textContent = 'Die Versionsprüfung ist auf diesem Host nicht verfügbar.';
      return;
    }
    dialog.close();
    openConfirmation('SqlPackage-Version prüfen', selection.label + '\nSqlPackage /Version ausführen? Das Ergebnis erscheint im Live-Log.',
      '__PublicCommand', { command, parameterSet, parameters: selection.parameters }, 'Version prüfen');
  });
})();
