'use strict';
(() => {
  const el = id => document.getElementById('test-group-create-' + id);
  const dialog = el('dialog');
  const provider = el('provider');
  const version = el('version');
  const status = el('status');
  const confirmation = el('confirm');
  const apply = el('apply');
  const preview = el('preview');
  const endpoint = '/api/test-group-linux-create';
  let revision = 0;
  let plan = null;

  function invalidate() {
    revision++;
    plan = null;
    confirmation.checked = false;
    confirmation.disabled = true;
    apply.disabled = true;
  }

  async function read(query = '') {
    const response = await sqlServerLabUiFetch(endpoint + query, { cache: 'no-store' });
    if (!response.ok) throw new Error('TEST_GROUP_LINUX_CREATE_PLAN_UNAVAILABLE');
    return response.json();
  }

  el('open').addEventListener('click', async () => {
    invalidate();
    const current = revision;
    el('form').reset();
    provider.disabled = true;
    version.disabled = true;
    preview.disabled = true;
    status.textContent = 'Verfügbare SQL-Versionen werden gelesen.';
    dialog.showModal();
    try {
      const catalog = await read();
      if (current !== revision || !dialog.open) return;
      if (!Array.isArray(catalog.Versions) || !catalog.Versions.every(value => typeof value === 'string' && /^20\d{2}$/.test(value))) {
        throw new Error('TEST_GROUP_LINUX_CREATE_PLAN_UNAVAILABLE');
      }
      version.replaceChildren(new Option('Bitte auswählen', ''), ...catalog.Versions.map(value => new Option('SQL Server ' + value, value)));
      status.textContent = catalog.Versions.length ? '' : 'Kein unterstütztes Linux-Image im Lab-Katalog.';
      provider.disabled = !catalog.Versions.length;
      version.disabled = !catalog.Versions.length;
    } catch {
      if (current === revision && dialog.open) status.textContent = 'Die SQL-Versionen konnten nicht gelesen werden.';
    }
  });
  el('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', invalidate);
  for (const field of [provider, version]) {
    field.addEventListener('change', () => {
      invalidate();
      status.textContent = '';
      preview.disabled = !provider.value || !version.value;
    });
  }
  confirmation.addEventListener('change', () => { apply.disabled = !plan || !confirmation.checked; });

  el('form').addEventListener('submit', async event => {
    event.preventDefault();
    if (!dialog.open || preview.disabled) return;
    invalidate();
    const current = revision;
    preview.disabled = true;
    status.textContent = 'Runtime und Gruppenregistrierung werden geprüft.';
    try {
      const view = await read('?' + new URLSearchParams({ provider: provider.value, sqlVersion: version.value }));
      if (current !== revision || !dialog.open) return;
      if (view.Provider !== provider.value || view.SqlVersion !== version.value || view.Patch !== 'latest' ||
          !/^[A-Z][A-Z0-9_]{1,80}$/.test(view.Key) || !/^[a-f0-9]{64}$/.test(view.PlanKey)) {
        throw new Error('TEST_GROUP_LINUX_CREATE_PLAN_UNAVAILABLE');
      }
      plan = view;
      status.textContent = 'SQL Server ' + view.SqlVersion + ' · ' + view.Provider + ' · Gruppeneintrag ' + view.Key;
      confirmation.disabled = false;
    } catch {
      if (current === revision && dialog.open) status.textContent = 'Vorschau nicht verfügbar. Prüfe Runtime, Lab_Data und offene Vormerkungen in der Testsystem-Matrix.';
    } finally {
      if (current === revision && dialog.open) preview.disabled = false;
    }
  });
  apply.addEventListener('click', async () => {
    if (!dialog.open || !plan || !confirmation.checked || apply.disabled) return;
    const parameters = { Provider: plan.Provider, SqlVersion: plan.SqlVersion, ExpectedPlanKey: plan.PlanKey };
    invalidate();
    dialog.close();
    try { await startAction('CreateLinuxTestGroupMember', parameters); }
    catch (error) { showError(error); }
  });
})();
