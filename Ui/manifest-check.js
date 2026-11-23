'use strict';
(() => {
  let manifestCheckRevision = 0;
  function clearManifestCheck() {
    manifestCheckRevision++;
    $('#manifest-run-check').disabled = false;
    $('#manifest-run-check-status').textContent = '';
  }
  $('#manifest-run-path').addEventListener('input', clearManifestCheck);
  $('#manifest-run-dialog').addEventListener('close', clearManifestCheck);
  $('#manifest-run-check').addEventListener('click', async () => {
    const path = $('#manifest-run-path').value.trim();
    const status = $('#manifest-run-check-status');
    if (!path) {
      status.textContent = 'Absoluten lokalen Manifestpfad angeben.';
      return;
    }
    const current = ++manifestCheckRevision;
    $('#manifest-run-check').disabled = true;
    status.textContent = 'Manifest wird geprüft.';
    try {
      const response = await sqlServerLabUiFetch('/api/manifest-check', {
        method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ Path: path })
      });
      if (!response.ok) throw new Error('MANIFEST_CHECK_UNAVAILABLE');
      const view = await response.json();
      const labels = { SCHEMA: 'Schema', SMTP_TEST_SCOPE: 'SMTP-Testscope', COLLATION: 'Sortierung',
        BACKUP_SOURCE: 'Backupquelle', SQL_SCRIPT: 'SQL-Skript', MANIFEST_RULE: 'Manifestregeln' };
      if (typeof view?.IsValid !== 'boolean' || ![view.ErrorCount, view.WarningCount].every(count => Number.isSafeInteger(count) && count >= 0) ||
          !Array.isArray(view.ErrorClasses) || view.ErrorClasses.some(code => !Object.hasOwn(labels, code))) throw new Error('MANIFEST_CHECK_RESULT_INVALID');
      if (current !== manifestCheckRevision || !$('#manifest-run-dialog').open) return;
      status.textContent = (view.IsValid ? 'Gültig' : 'Ungültig') + ' · ' + view.ErrorCount + ' Fehler · ' + view.WarningCount + ' Hinweise' +
        (view.ErrorClasses.length ? ' · ' + view.ErrorClasses.map(code => labels[code]).join(', ') : '');
    } catch {
      if (current === manifestCheckRevision && $('#manifest-run-dialog').open) status.textContent = 'Die lokale Manifestdatei konnte nicht geprüft werden.';
    } finally {
      if (current === manifestCheckRevision) $('#manifest-run-check').disabled = false;
    }
  });
})();
