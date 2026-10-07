// Startgebundene Capability bleibt ausschließlich in dieser Closure.
(() => {
  'use strict';
  const nativeFetch = globalThis.fetch.bind(globalThis);
  const origin = globalThis.location.origin;
  let capability = null;
  const fragment = globalThis.location.hash;
  const match = /^#sql-lab-operator=([a-f0-9]{64})$/.exec(fragment);
  try {
    // Auch ungültige Fragmente sofort entfernen; kein DOM, Storage oder Log.
    globalThis.history.replaceState(null, '', globalThis.location.pathname + globalThis.location.search);
    const bootstrapUrl = new URL(globalThis.location.href);
    if (match && bootstrapUrl.protocol === 'http:' && bootstrapUrl.hostname === '127.0.0.1' &&
        Number(bootstrapUrl.port) >= 1025 && Number(bootstrapUrl.port) <= 65535 && bootstrapUrl.origin === origin &&
        !bootstrapUrl.username && !bootstrapUrl.password) capability = match[1];
  } catch { capability = null; }
  globalThis.sqlServerLabUiFetch = async (input, options = {}) => {
    if (!capability || typeof input !== 'string' || !options || typeof options !== 'object') throw new Error('UI_OPERATOR_REQUIRED');
    const url = new URL(input, origin + '/');
    if (url.origin !== origin || url.username || url.password || url.hash || !url.pathname.startsWith('/api/')) throw new Error('UI_OPERATOR_TARGET_INVALID');
    const headers = new Headers(options.headers);
    if (headers.has('X-SqlServerLab-Operator')) throw new Error('UI_OPERATOR_HEADER_INVALID');
    headers.set('X-SqlServerLab-Operator', capability);
    return nativeFetch(url.href, { ...options, headers, redirect: 'error' });
  };
})();
