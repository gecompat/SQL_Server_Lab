'use strict';
(() => {
  const element = id => document.getElementById('automation-api-plan-' + id);
  const dialog = element('dialog');
  const form = element('form');
  const action = element('action');
  const status = element('status');
  const result = element('result');
  let revision = 0;
  function clear() {
    revision++;
    status.textContent = '';
    result.hidden = true;
  }
  element('open').addEventListener('click', () => { form.reset(); clear(); dialog.showModal(); });
  element('close').addEventListener('click', () => { clear(); dialog.close(); });
  action.addEventListener('change', clear);
  form.addEventListener('submit', async event => {
    event.preventDefault();
    clear();
    const current = revision;
    const requestedAction = action.value;
    status.textContent = 'Schnittstelle wird gelesen.';
    try {
      const response = await sqlServerLabUiFetch('/api/automation-plan?action=' + encodeURIComponent(requestedAction), { cache: 'no-store' });
      if (!response.ok) throw new Error('AUTOMATION_API_PLAN_READ_FAILED');
      const plan = await response.json();
      if (plan?.ContractVersion !== 'SqlServerLab.AutomationApiPlan/1.0' || plan.Status !== 'READY' ||
          plan.Request?.Action !== requestedAction || plan.Request.LocalOnly !== true || plan.ExecutionImplemented !== false ||
          plan.Result?.Status !== 'NOT_EXECUTED' || plan.Result.ExecutionImplemented !== false || plan.Plan?.Mutation !== 'NONE' ||
          typeof plan.Plan.Command !== 'string' || typeof plan.Plan.ContractVersion !== 'string' ||
          !Array.isArray(plan.Plan.RequiredParameters) || plan.Plan.RequiredParameters.some(name => typeof name !== 'string') ||
          (plan.Result.ActionCommand !== null && typeof plan.Result.ActionCommand !== 'string')) throw new Error('AUTOMATION_API_PLAN_INVALID');
      if (revision !== current || !dialog.open || action.value !== requestedAction) return;
      element('command').textContent = plan.Plan.Command;
      element('contract').textContent = plan.Plan.ContractVersion;
      element('required').textContent = plan.Plan.RequiredParameters.join(', ') || 'keine';
      element('execution').textContent = plan.Result.ActionCommand || 'nicht verfügbar';
      result.hidden = false;
      status.textContent = 'Schnittstelle gelesen.';
    } catch {
      if (revision === current && dialog.open) status.textContent = 'Die Schnittstelle konnte nicht gelesen werden.';
    }
  });
})();
