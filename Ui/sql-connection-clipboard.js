/* Explicitly copy the connection text already visible at one lab instance. */
(() => {
  'use strict';
  let generation = 0;
  let pending = false;
  let controls = [];
  const waiting = 'Ein Kopiervorgang wartet auf den Browser.';
  const unavailable = 'Zwischenablage nicht verfügbar. Connection String manuell markieren und kopieren.';
  const failed = 'Kopieren nicht möglich. Browserfreigabe prüfen oder Connection String manuell kopieren.';

  function current(c, text, version) {
    return generation === version && c.row.isConnected && c.code.isConnected &&
      c.button.isConnected && c.root.contains(c.row) && c.row.contains(c.code) &&
      c.code.textContent === text;
  }

  async function copy(c) {
    if (pending || c.button.disabled || !c.row.isConnected || !c.button.isConnected) return;
    const text = c.code.textContent;
    const version = generation;
    if (typeof text !== 'string' || !text.trim() || text.length > 65536 || !current(c, text, version)) return;
    pending = true;
    for (const item of controls) { item.button.disabled = true; item.status.textContent = waiting; }
    try {
      if (!window.isSecureContext || typeof navigator.clipboard?.writeText !== 'function') {
        if (current(c, text, version)) c.status.textContent = unavailable;
        return;
      }
      await navigator.clipboard.writeText(text);
      if (current(c, text, version)) c.status.textContent = 'Connection String kopiert.';
    } catch {
      if (current(c, text, version)) c.status.textContent = failed;
    } finally {
      pending = false;
      for (const item of controls) {
        if (!item.button.isConnected) continue;
        item.button.disabled = false;
        if (item.status.textContent === waiting) item.status.textContent = '';
      }
    }
  }

  function mount(root) {
    if (!root?.isConnected) return;
    generation++;
    for (const c of controls) {
      if (root.contains(c.row)) { c.button.remove(); c.status.remove(); }
      else c.status.textContent = pending ? waiting : '';
    }
    controls = controls.filter((c) => c.row.isConnected && !root.contains(c.row));
    for (const row of root.querySelectorAll('.connection-string')) {
      const codes = row.querySelectorAll('code');
      if (codes.length !== 1) continue;
      const code = codes[0];
      if (typeof code.textContent !== 'string' || !code.textContent.trim() || code.textContent.length > 65536) continue;
      const button = document.createElement('button');
      button.type = 'button'; button.className = 'button secondary';
      button.textContent = 'Connection String kopieren';
      button.dataset.sqlConnectionCopy = 'true'; button.disabled = pending;
      const status = document.createElement('span');
      status.className = 'sql-connection-copy-status'; status.setAttribute('role', 'status');
      status.textContent = pending ? waiting : '';
      const c = { root, row, code, button, status };
      controls.push(c); row.append(button, status);
      button.addEventListener('click', () => copy(c));
    }
  }

  window.sqlServerLabConnectionClipboard = { mount };
})();
