'use strict';
(() => {
  const element = id => document.getElementById('portable-import-plan-' + id);
  const dialog = element('dialog');
  const form = element('form');
  const fileInput = element('file');
  const target = element('target');
  const status = element('status');
  const read = element('read');
  const guid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  let targets = new Map();
  let revision = 0;

  function clear() {
    revision++;
    status.textContent = targets.size ? '' : 'Es ist kein passender Ziel-Run registriert.';
    read.disabled = !targets.size;
  }
  element('open').addEventListener('click', () => {
    form.reset();
    targets = new Map();
    target.replaceChildren(new Option('Ziel wählen', ''));
    for (const lab of workflow?.ActiveLabs || []) {
      if (!['RUNNING', 'STOPPED'].includes(lab.State) || !guid.test(lab.RunId)) continue;
      for (const instance of lab.Instances || []) {
        if (!['docker', 'podman'].includes(instance.Provider)) continue;
        const id = lab.RunId.toLowerCase();
        const key = id + '/' + instance.Provider;
        if (targets.has(key)) continue;
        targets.set(key, { TargetRunId: id, TargetProvider: instance.Provider });
        target.add(new Option([lab.Name || id, instance.Provider, lab.State].join(' · '), key));
      }
    }
    clear();
    dialog.showModal();
  });
  element('close').addEventListener('click', () => { clear(); dialog.close(); });
  fileInput.addEventListener('change', clear);
  target.addEventListener('change', clear);
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (read.disabled) return;
    const selected = targets.get(target.value);
    const file = fileInput.files[0];
    if (!selected || !file) return;
    const current = ++revision;
    read.disabled = true;
    status.textContent = 'Importplan wird gelesen.';
    try {
      if (!/\.json$/i.test(file.name) || file.size < 1 || file.size > 256 * 1024) throw new Error('PORTABLE_IMPORT_FILE_INVALID');
      const packageText = await file.text();
      const packageContent = JSON.parse(packageText);
      const exactKeys = (value, names) => value && Object.keys(value).sort().join(',') === names;
      if (!exactKeys(packageContent, 'BackupReferences,ContractVersion,PackageId,Source') ||
          packageContent.ContractVersion !== 'SqlServerLab.PortableLabPackage/1.1' ||
          !guid.test(packageContent.PackageId) || !['docker', 'podman'].includes(packageContent.Source?.Provider) ||
          !exactKeys(packageContent.Source, 'Provider,SqlMajorVersion') ||
          typeof packageContent.Source.SqlMajorVersion !== 'string' || !/^[0-9]{2,4}$/.test(packageContent.Source.SqlMajorVersion) ||
          !Array.isArray(packageContent.BackupReferences) || packageContent.BackupReferences.some(item =>
            !exactKeys(item, 'BackupChecksum,BackupSetId,Bytes,RestoreVerifyOnly,Sha256') ||
            !guid.test(item.BackupSetId) || typeof item.Sha256 !== 'string' || !/^[a-f0-9]{64}$/i.test(item.Sha256) ||
            !Number.isSafeInteger(item.Bytes) || item.Bytes < 1 ||
            typeof item.BackupChecksum !== 'boolean' || typeof item.RestoreVerifyOnly !== 'boolean')) throw new Error('PORTABLE_IMPORT_FILE_INVALID');
      if (current !== revision || !dialog.open) return;
      const selection = JSON.stringify(selected);
      const body = selection.slice(0, -1) + ',"Package":' + packageText + '}';
      const response = await sqlServerLabUiFetch('/api/portable-lab-import-plan', {
        method: 'POST', cache: 'no-store', headers: {'Content-Type': 'application/json'},
        body,
      });
      if (!response.ok) throw new Error('PORTABLE_IMPORT_PLAN_UNAVAILABLE');
      const result = await response.json();
      if (current !== revision || !dialog.open) return;
      if (result?.ContractVersion !== 'SqlServerLab.PortableContainerTransferPlan/1.0' ||
          result.ExecutionImplemented !== false || result.PackageId !== packageContent.PackageId ||
          result.TargetRunId !== selected.TargetRunId || result.TargetProvider !== selected.TargetProvider ||
          !['READY', 'BLOCKED'].includes(result.Status) || !Array.isArray(result.BackupReferences) || !Array.isArray(result.Blockers) ||
          result.Blockers.some(code => typeof code !== 'string' || !/^[A-Z_]+$/.test(code))) throw new Error('PORTABLE_IMPORT_PLAN_INVALID');
      status.textContent = (result.Status === 'READY' ? 'Importplan bereit' : 'Importplan blockiert') +
        ' · Backupreferenzen: ' + result.BackupReferences.length +
        (result.Blockers.length ? ' · Befunde: ' + result.Blockers.join(', ') : '');
    } catch {
      if (current === revision && dialog.open) status.textContent = 'Importplan nicht verfügbar. Prüfe Paketdatei und Ziel-Run.';
    } finally {
      if (current === revision && dialog.open) read.disabled = false;
    }
  });
})();
