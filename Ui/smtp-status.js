'use strict';
(() => {
  const el = id => document.getElementById('smtp-status-' + id);
  const dialog = el('dialog');
  const selection = el('lab');
  const result = el('result');
  const read = el('read');
  const webMail = el('webmail');
  const webMailNotice = el('webmail-notice');
  const contract = 'SqlServerLab.SmtpStatusGuidance/1.0';
  const runPattern = /^[a-f0-9]{8}(?:-[a-f0-9]{4}){3}-[a-f0-9]{12}$/;
  const descriptions = {
    READY: 'Der gebundene Mailpit-Receiver läuft.',
    STOPPED: 'Der gebundene Mailpit-Receiver ist gestoppt.',
    UNAVAILABLE: 'Der Mailpit-Receiver ist derzeit nicht eindeutig prüfbar.'
  };
  let revision = 0;
  let candidates = new Set();
  let readyRun = '';

  function clearWebMail() {
    readyRun = '';
    webMail.hidden = true;
    webMail.disabled = true;
    webMailNotice.hidden = true;
  }

  async function readJson(path) {
    const response = await sqlServerLabUiFetch(path, { cache: 'no-store' });
    if (!response.ok) throw new Error('SMTP_STATUS_UNAVAILABLE');
    const data = await response.json();
    if (data?.ContractVersion !== contract) throw new Error('SMTP_STATUS_RESPONSE_INVALID');
    return data;
  }

  el('open').addEventListener('click', async () => {
    const current = ++revision;
    candidates = new Set();
    clearWebMail();
    selection.replaceChildren();
    read.disabled = true;
    result.textContent = 'Registrierte Labs werden gelesen.';
    dialog.showModal();
    try {
      const { Candidates: labs } = await readJson('/api/smtp-status');
      if (current !== revision || !dialog.open) return;
      if (!Array.isArray(labs) || !labs.every(lab => runPattern.test(lab?.RunId) && typeof lab.Name === 'string')) {
        throw new Error('SMTP_STATUS_RESPONSE_INVALID');
      }
      for (const lab of labs) {
        if (candidates.has(lab.RunId)) continue;
        candidates.add(lab.RunId);
        const option = document.createElement('option');
        option.value = lab.RunId;
        option.textContent = (lab.Name || 'SMTP-Lab') + ' · ' + lab.RunId;
        selection.append(option);
      }
      read.disabled = !candidates.size;
      result.textContent = candidates.size ? 'Wähle ein Lab. Die Mailzustellung wird separat geprüft.' : 'Kein Lab mit SMTP-Testdienst registriert.';
    } catch {
      if (current === revision && dialog.open) result.textContent = 'Die SMTP-Labs konnten nicht gelesen werden.';
    }
  });
  el('close').addEventListener('click', () => dialog.close());
  dialog.addEventListener('close', () => { revision++; clearWebMail(); });
  selection.addEventListener('change', () => {
    revision++;
    clearWebMail();
    read.disabled = !candidates.has(selection.value);
    result.textContent = 'Prüfe den Receiver des ausgewählten Labs.';
  });
  el('form').addEventListener('submit', async event => {
    event.preventDefault();
    const runId = selection.value;
    if (!dialog.open || read.disabled || !candidates.has(runId)) return;
    const current = ++revision;
    clearWebMail();
    read.disabled = true;
    result.textContent = 'Der gebundene Mailpit-Receiver wird geprüft.';
    try {
      const status = await readJson('/api/smtp-status?' + new URLSearchParams({ runId }));
      if (current !== revision || !dialog.open || selection.value !== runId) return;
      if (status.RunId !== runId || !['docker', 'podman'].includes(status.Provider) || !Object.hasOwn(descriptions, status.Status)) {
        throw new Error('SMTP_STATUS_RESPONSE_INVALID');
      }
      result.textContent = status.Provider + ' · ' + descriptions[status.Status];
      if (status.Status === 'READY') {
        readyRun = runId;
        webMail.hidden = false;
        webMail.disabled = false;
        webMailNotice.hidden = false;
      }
    } catch {
      if (current === revision && dialog.open) result.textContent = 'Der ausgewählte SMTP-Testdienst konnte nicht eindeutig geprüft werden.';
    } finally {
      if (current === revision && dialog.open) read.disabled = false;
    }
  });
  webMail.addEventListener('click', async () => {
    const runId = selection.value;
    if (!dialog.open || webMail.disabled || runId !== readyRun) return;
    const current = ++revision;
    webMail.disabled = true;
    read.disabled = true;
    result.textContent = 'WebMail wird im Standardbrowser geöffnet.';
    try {
      const response = await sqlServerLabUiFetch('/api/smtp-webmail/open', {
        method: 'POST', cache: 'no-store', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ RunId: runId, Confirmed: true })
      });
      if (!response.ok) throw new Error('SMTP_WEBMAIL_OPEN_UNAVAILABLE');
      const receipt = await response.json();
      if (receipt?.ContractVersion !== 'SqlServerLab.GuidedSmtpWebMailOpen/1.0' ||
          receipt.RunId !== runId || receipt.Status !== 'OPENED') throw new Error('SMTP_WEBMAIL_OPEN_UNCONFIRMED');
      if (current === revision && dialog.open) result.textContent = 'WebMail wurde im Standardbrowser geöffnet.';
    } catch {
      if (current === revision && dialog.open) result.textContent = 'WebMail konnte nicht geöffnet werden. Prüfe den Receiver erneut.';
    } finally {
      if (current === revision && dialog.open) read.disabled = false;
    }
  });
})();
