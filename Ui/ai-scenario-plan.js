'use strict';
(() => {
  const element = id => document.getElementById('ai-scenario-plan-' + id);
  const dialog = element('dialog');
  const target = element('target');
  const status = element('status');
  const result = element('result');
  const read = element('read');
  const uuid = /^[0-9a-f]{8}-(?:[0-9a-f]{4}-){3}[0-9a-f]{12}$/i;
  let selections = new Map();
  let revision = 0;
  function clear() {
    revision++;
    status.textContent = '';
    result.hidden = true;
    read.disabled = false;
  }
  element('open').addEventListener('click', () => {
    selections = new Map();
    target.replaceChildren(new Option('Nur aus dem Katalog', ''));
    for (const lab of workflow?.ActiveLabs || []) {
      if (lab.State !== 'RUNNING' || typeof lab.RunId !== 'string' || !uuid.test(lab.RunId)) continue;
      for (const instance of lab.Instances || []) {
        if (!['docker', 'podman'].includes(instance.Provider) || !/^2025(?:-|$)/.test(instance.SqlVersion) ||
            typeof instance.Id !== 'string' || !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(instance.Id)) continue;
        const runId = lab.RunId.toLowerCase();
        const key = runId + '/' + instance.Id;
        if (selections.has(key)) continue;
        selections.set(key, { runId, instanceId: instance.Id });
        target.add(new Option([lab.Name || runId, instance.Id, instance.Provider].join(' · '), key));
      }
    }
    clear();
    dialog.showModal();
  });
  element('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', clear);
  target.addEventListener('change', clear);
  element('form').addEventListener('submit', async event => {
    event.preventDefault();
    if (read.disabled) return;
    const selection = selections.get(target.value);
    if (target.value && !selection) return;
    clear();
    const current = revision;
    read.disabled = true;
    status.textContent = 'Szenarioplan wird gelesen.';
    try {
      const route = '/api/ai-scenario-plan' + (selection ? '?' + new URLSearchParams(selection) : '');
      const response = await sqlServerLabUiFetch(route, { cache: 'no-store' });
      if (!response.ok) throw new Error('AI_SCENARIO_PLAN_UNAVAILABLE');
      const plan = await response.json();
      if (plan?.ScenarioId !== 'vector-core-ci' || plan.Version !== '1.0' || !/^[a-f0-9]{64}$/.test(plan.PlanKey) ||
          (selection ? !['READY', 'BLOCKED'].includes(plan.Status) || plan.RunId !== selection.runId || plan.InstanceId !== selection.instanceId
            : plan.Status !== 'CATALOG_SUPPORTED' || plan.RunId != null || plan.InstanceId != null) ||
          !Array.isArray(plan.Blockers) || !Array.isArray(plan.RequiredCapabilities)) throw new Error('AI_SCENARIO_PLAN_INVALID');
      if (revision !== current || !dialog.open) return;
      element('verdict').textContent = { READY: 'Gespeicherter Plan passt', BLOCKED: 'Blockiert', CATALOG_SUPPORTED: 'Im Katalog unterstützt' }[plan.Status];
      element('capabilities').textContent = plan.RequiredCapabilities.join(', ') || 'keine';
      element('blockers').textContent = plan.Blockers.join(', ') || 'keine';
      result.hidden = false;
      status.textContent = 'Plan gelesen. Es wurde kein Szenario gestartet.';
    } catch {
      if (revision === current && dialog.open) status.textContent = 'Der Szenarioplan konnte nicht gelesen werden.';
    } finally {
      if (revision === current && dialog.open) read.disabled = false;
    }
  });
})();
