'use strict';
(() => {
  const element = id => document.getElementById('hyperv-autostart-' + id);
  const dialog = element('dialog');
  const run = element('run');
  const desired = element('desired');
  const mode = element('mode');
  const plan = element('plan');
  const apply = element('apply');
  const confirm = element('confirm');
  const status = element('status');
  let token = null;
  let revision = 0;
  let applying = false;
  function clearSelection() {
    ++revision;
    token = null;
    confirm.checked = false;
    confirm.disabled = true;
    apply.disabled = true;
    plan.disabled = !run.value || applying;
    desired.disabled = applying || mode.value === 'recovery';
    status.textContent = '';
  }
  element('open').addEventListener('click', () => {
    run.replaceChildren(new Option('Hyper-V-Lab auswählen', ''));
    for (const lab of workflow?.HyperVLabs || []) {
      if (['RUNNING', 'STOPPED'].includes(lab.State)) {
        run.add(new Option(lab.Name || lab.RunId, lab.RunId));
      }
    }
    desired.value = 'off';
    mode.value = 'change';
    clearSelection();
    dialog.showModal();
  });
  element('close').addEventListener('click', () => { if (!applying) dialog.close(); });
  dialog.addEventListener('cancel', event => { if (applying) event.preventDefault(); });
  dialog.addEventListener('close', clearSelection);
  run.addEventListener('change', clearSelection);
  desired.addEventListener('change', clearSelection);
  mode.addEventListener('change', clearSelection);
  confirm.addEventListener('change', () => { apply.disabled = !token || !confirm.checked || applying; });
  async function request(body) {
    const response = await sqlServerLabUiFetch('/api/hyperv-autostart', {
      method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(body),
    });
    if (!response.ok) throw new Error('HYPERV_AUTOSTART_UNAVAILABLE');
    return response.json();
  }
  plan.addEventListener('click', async () => {
    if (plan.disabled) return;
    clearSelection();
    const generation = revision;
    plan.disabled = true;
    status.textContent = 'Startpolicy wird geprüft …';
    try {
      const recovery = mode.value === 'recovery';
      const result = await request(recovery ? { Action: 'PlanRecovery', RunId: run.value } :
        { Action: 'Plan', RunId: run.value, AutoStart: desired.value });
      if (generation !== revision || !dialog.open) return;
      if (recovery) {
        if (!['ON', 'OFF'].includes(result?.Desired) || !/^[a-f0-9]{32}$/.test(result.Selection)) {
          throw new Error('HYPERV_AUTOSTART_INVALID');
        }
        token = result.Selection;
        confirm.disabled = false;
        status.textContent = 'Verifizierte Policy ' + result.Desired + ' · nur Lab-State nachtragen.';
        return;
      }
      if (!['ON', 'OFF'].includes(result?.Current) || result.Desired !== desired.value.toUpperCase() ||
          typeof result.NoChange !== 'boolean' || (result.NoChange ? result.Selection !== null : !/^[a-f0-9]{32}$/.test(result.Selection))) {
        throw new Error('HYPERV_AUTOSTART_INVALID');
      }
      token = result.Selection;
      confirm.disabled = result.NoChange;
      status.textContent = result.NoChange ? 'Die gewünschte Policy ist bereits aktiv und gespeichert.' :
        'Aktuell ' + result.Current + ' · geplant ' + result.Desired + ' · Power-Zustand bleibt erhalten.';
    } catch {
      if (generation === revision && dialog.open) status.textContent = 'Vorschau nicht verfügbar. Prüfe Lab-Schutz und offene Autostart-Recovery.';
    } finally {
      if (generation === revision) plan.disabled = !run.value;
    }
  });
  apply.addEventListener('click', async () => {
    if (!token || !confirm.checked || applying) return;
    const confirmed = token;
    const recovery = mode.value === 'recovery';
    applying = true;
    clearSelection();
    run.disabled = true;
    desired.disabled = true;
    mode.disabled = true;
    status.textContent = recovery ? 'Lab-State wird nachgetragen …' : 'Bestätigte Startpolicy wird übernommen …';
    try {
      const result = await request({ Action: 'Apply', Selection: confirmed, Confirmed: true });
      const allowed = recovery ? ['RECOVERY_SUCCEEDED'] : ['NO_OP', 'SUCCEEDED'];
      if (!allowed.includes(result?.Status)) throw new Error('HYPERV_AUTOSTART_INVALID');
      status.textContent = recovery ? 'Autostart-Recovery abgeschlossen.' :
        'Startpolicy bestätigt. Der Power-Zustand wurde beibehalten.';
    } catch {
      status.textContent = 'Vorgang nicht bestätigt. Prüfe das Lab und gegebenenfalls die offene Autostart-Recovery.';
    } finally {
      applying = false;
      run.disabled = false;
      desired.disabled = recovery;
      mode.disabled = false;
      plan.disabled = !run.value;
    }
  });
})();
