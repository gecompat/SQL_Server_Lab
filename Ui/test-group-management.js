'use strict';
(() => {
  const el = name => document.getElementById('test-group-management-' + name);
  const dialog = el('dialog');
  const operation = el('operation');
  const image = el('image');
  const status = el('status');
  const targets = el('targets');
  const read = el('read');
  const apply = el('apply');
  const confirm = el('confirm');
  const actions = { CreateWindows: 'CreateWindowsTestGroupMember', Repair: 'RepairTestGroup', Remove: 'RemoveTestGroup', Export: 'ExportTestGroup' };
  const effects = {
    CreateWindows: 'Klon einer freigegebenen SQL-Prepared-Vorlage mit automatischer Windows-Einrichtung. Die Windows-Aktivierung kann vorübergehend einen externen Netzwerkadapter verwenden.',
    Repair: 'Kann Container ersetzen, Windows-VMs neu starten und für die Windows-Aktivierung vorübergehend einen externen Netzwerkadapter verwenden.',
    Remove: 'Entfernt alle aufgeführten Umgebungen samt ihren zugeordneten Ressourcen und Gruppenexporten. Dieser Vorgang ist endgültig.',
    Export: 'Aktualisiert die lokalen Gruppenexporte unter Lab_Data. Die Exportdateien enthalten Zugangsdaten und gehören in den geschützten lokalen Ordner.'
  };
  let revision = 0;
  let plan = null;

  function invalidate() {
    revision++;
    plan = null;
    targets.replaceChildren();
    confirm.checked = false;
    confirm.disabled = true;
    apply.disabled = true;
  }

  async function get(parameters) {
    const response = await sqlServerLabUiFetch('/api/test-group-management?' + new URLSearchParams(parameters), { cache: 'no-store' });
    if (!response.ok) throw new Error('TEST_GROUP_MANAGEMENT_PLAN_UNAVAILABLE');
    return response.json();
  }

  el('open').addEventListener('click', () => {
    invalidate();
    operation.value = '';
    el('effect').textContent = '';
    status.textContent = '';
    el('image-field').hidden = true;
    read.disabled = true;
    dialog.showModal();
  });
  el('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', invalidate);
  operation.addEventListener('change', async () => {
    invalidate();
    const current = revision;
    const selected = operation.value;
    el('effect').textContent = Object.hasOwn(effects, selected) ? effects[selected] : '';
    status.textContent = '';
    el('image-field').hidden = selected !== 'CreateWindows';
    read.disabled = !Object.hasOwn(actions, selected) || selected === 'CreateWindows';
    if (selected !== 'CreateWindows') return;
    image.replaceChildren(new Option('Bitte auswählen', ''));
    image.disabled = true;
    try {
      const view = await get({ operation: selected });
      if (revision !== current || !dialog.open) return;
      if (view.Operation !== selected || !Array.isArray(view.Artifacts)) throw new Error('TEST_GROUP_MANAGEMENT_PLAN_UNAVAILABLE');
      const choices = view.Artifacts.map(item => new Option('SQL Server ' + item.SqlVersion + ' · ' + item.Build + ' · Vorlage ' + item.ArtifactId.slice(-8), item.ArtifactId));
      image.replaceChildren(new Option('Bitte auswählen', ''), ...choices);
      image.disabled = !choices.length;
      if (!choices.length) status.textContent = 'Keine geeignete SQL-Prepared-Vorlage verfügbar.';
    } catch {
      if (revision === current && dialog.open) status.textContent = 'Vorlagen konnten nicht gelesen werden.';
    }
  });
  image.addEventListener('change', () => { invalidate(); read.disabled = !image.value; status.textContent = ''; });
  confirm.addEventListener('change', () => { apply.disabled = !plan || !confirm.checked; });
  el('form').addEventListener('submit', async event => {
    event.preventDefault();
    if (!dialog.open || read.disabled) return;
    invalidate();
    const current = revision;
    const selected = operation.value;
    const parameters = { operation: selected };
    if (selected === 'CreateWindows') parameters.artifactId = image.value;
    read.disabled = true;
    status.textContent = 'Ziele und Bindungen werden geprüft.';
    try {
      const view = await get(parameters);
      if (revision !== current || !dialog.open) return;
      if (view.Operation !== selected || (selected === 'CreateWindows' && view.ArtifactId !== parameters.artifactId)) {
        throw new Error('TEST_GROUP_MANAGEMENT_PLAN_UNAVAILABLE');
      }
      const rows = selected === 'CreateWindows' ? [view.Key + ' · SQL Server ' + view.SqlVersion + ' · ' + view.Build] :
        view.Members.map(member => member.Key + ' · ' + member.Target +
          (!member.Verified ? ' · Bindung unklar' : member.Power ? ' · ' + member.Power : ''));
      for (const row of rows) {
        const item = document.createElement('li');
        item.textContent = row;
        targets.append(item);
      }
      if (view.CanApply === true && /^[a-f0-9]{64}$/.test(view.PlanKey)) {
        plan = view;
        confirm.disabled = false;
      }
      status.textContent = plan ? 'Vorschau bereit.' : 'Aktion gesperrt. Prüfe Registrierung und Runtime-Bindung in der Testsystem-Matrix.';
    } catch {
      if (revision === current && dialog.open) status.textContent = 'Vorschau nicht verfügbar.';
    } finally {
      if (revision === current && dialog.open) read.disabled = false;
    }
  });
  apply.addEventListener('click', async () => {
    if (!dialog.open || !plan || apply.disabled || !confirm.checked) return;
    const action = actions[plan.Operation];
    const parameters = { ExpectedPlanKey: plan.PlanKey };
    if (plan.Operation === 'CreateWindows') parameters.ArtifactId = plan.ArtifactId;
    invalidate();
    dialog.close();
    try { await startAction(action, parameters); } catch (error) { showError(error); }
  });
})();
