'use strict';
(() => {
  const el = id => document.getElementById('test-group-create-' + id);
  const dialog = el('dialog');
  const provider = el('provider');
  const version = el('version');
  const patch = el('patch');
  const status = el('status');
  const confirmation = el('confirm');
  const apply = el('apply');
  const preview = el('preview');
  const endpoint = '/api/test-group-linux-create';
  let revision = 0;
  let plan = null;
  let patches = {};

  function setPatchOptions() {
    const choices = Object.hasOwn(patches, version.value) ? patches[version.value] : [];
    patch.replaceChildren(new Option('Aktueller Patch laut Lab-Katalog', 'latest'),
      ...choices.map(value => new Option(value.toUpperCase(), value)));
    patch.value = version.value ? 'latest' : '';
    patch.disabled = !version.value;
  }

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
    patches = {};
    setPatchOptions();
    provider.disabled = true;
    version.disabled = true;
    preview.disabled = true;
    status.textContent = 'Verfügbare SQL-Versionen werden gelesen.';
    dialog.showModal();
    try {
      const catalog = await read();
      if (current !== revision || !dialog.open) return;
      if (!Array.isArray(catalog.Versions) || !catalog.Patches || !catalog.Versions.every(value =>
        typeof value === 'string' && /^20\d{2}$/.test(value) && Array.isArray(catalog.Patches[value]) &&
        catalog.Patches[value].every(item => typeof item === 'string' && /^cu[1-9][0-9]{0,5}$/.test(item)))) {
        throw new Error('TEST_GROUP_LINUX_CREATE_PLAN_UNAVAILABLE');
      }
      patches = catalog.Patches;
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
  for (const field of [provider, version, patch]) {
    field.addEventListener('change', () => {
      invalidate();
      if (field === version) setPatchOptions();
      status.textContent = '';
      preview.disabled = !provider.value || !version.value || !patch.value;
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
      const view = await read('?' + new URLSearchParams({ provider: provider.value, sqlVersion: version.value, patch: patch.value }));
      if (current !== revision || !dialog.open) return;
      if (view.Provider !== provider.value || view.SqlVersion !== version.value || view.Patch !== patch.value ||
          !/^[A-Z][A-Z0-9_]{1,80}$/.test(view.Key) || !/^[a-f0-9]{64}$/.test(view.PlanKey)) {
        throw new Error('TEST_GROUP_LINUX_CREATE_PLAN_UNAVAILABLE');
      }
      plan = view;
      const patchLabel = view.Patch === 'latest' ? 'Aktueller Patch laut Lab-Katalog' : view.Patch.toUpperCase();
      status.textContent = 'SQL Server ' + view.SqlVersion + ' · ' + patchLabel + ' · ' + view.Provider + ' · Gruppeneintrag ' + view.Key;
      confirmation.disabled = false;
    } catch {
      if (current === revision && dialog.open) status.textContent = 'Vorschau nicht verfügbar. Prüfe Runtime, Lab_Data und offene Vormerkungen in der Testsystem-Matrix.';
    } finally {
      if (current === revision && dialog.open) preview.disabled = false;
    }
  });
  apply.addEventListener('click', async () => {
    if (!dialog.open || !plan || !confirmation.checked || apply.disabled) return;
    const parameters = { Provider: plan.Provider, SqlVersion: plan.SqlVersion, TestGroupPatch: plan.Patch, ExpectedPlanKey: plan.PlanKey };
    invalidate();
    dialog.close();
    try { await startAction('CreateLinuxTestGroupMember', parameters); }
    catch (error) { showError(error); }
  });
})();
