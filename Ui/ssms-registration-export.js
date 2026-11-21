'use strict';
(() => {
  $('#ssms-registration-download').addEventListener('click', async () => {
    const button = $('#ssms-registration-download');
    const status = $('#ssms-registration-status');
    if (button.disabled) return;
    button.disabled = true;
    status.textContent = 'Registrierungen werden aus dem gespeicherten Zustand gelesen.';
    try {
      const response = await sqlServerLabUiFetch('/api/ssms-registration', { cache: 'no-store' });
      if (!response.ok || !/^application\/xml(?:;|$)/i.test(response.headers.get('Content-Type') || '')) {
        throw new Error('SSMS_REGISTRATION_UNAVAILABLE');
      }
      const registration = await response.blob();
      if (!registration.size || registration.size > 2097152) throw new Error('SSMS_REGISTRATION_INVALID');
      const url = URL.createObjectURL(registration);
      try {
        const link = document.createElement('a');
        link.href = url;
        link.download = 'sql-server-lab.regsrvr';
        link.click();
      } finally {
        window.setTimeout(() => URL.revokeObjectURL(url), 1000);
      }
      status.textContent = 'Download gestartet. Die Datei kann in SSMS importiert werden.';
    } catch {
      status.textContent = 'Die gespeicherten Registrierungen konnten nicht exportiert werden.';
    } finally {
      button.disabled = false;
    }
  });
})();
