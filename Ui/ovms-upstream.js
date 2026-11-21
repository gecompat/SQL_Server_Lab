'use strict';
(() => {
  const element = id => document.getElementById('ovms-upstream-' + id);
  const dialog = element('dialog');
  const form = element('form');
  const status = element('status');
  element('open').addEventListener('click', () => {
    form.reset();
    status.textContent = '';
    dialog.showModal();
  });
  element('close').addEventListener('click', () => dialog.close());
  form.addEventListener('submit', event => {
    event.preventDefault();
    const address = element('address').value;
    const port = element('port').valueAsNumber;
    const dimension = element('dimension').valueAsNumber;
    const timeout = element('timeout').valueAsNumber;
    const model = element('model').value;
    const integerInRange = (value, minimum, maximum) => Number.isInteger(value) && value >= minimum && value <= maximum;
    if (!['127.0.0.1', '[::1]'].includes(address) || !integerInRange(port, 1024, 65535) ||
        !integerInRange(dimension, 1, 1998) || !integerInRange(timeout, 1, 300) ||
        !/^[A-Za-z0-9][A-Za-z0-9._:/+-]{0,255}$/.test(model)) {
      status.textContent = 'Prüfe Adresse, Port, Modellnamen, Embedding-Dimension und Timeout.';
      return;
    }
    const candidates = publicCommandCatalog.filter(command => command?.Name === 'Test-SqlServerLabOvmsUpstreamEndpoint');
    const command = candidates.length === 1 ? candidates[0] : null;
    const sets = Array.isArray(command?.ParameterSets) ? command.ParameterSets : [];
    const parameterSet = sets.length === 1 ? sets[0] : null;
    const fields = parameterSet?.Parameters || [];
    const expected = { Location: 'System.String', RuntimeModel: 'System.String', Dimension: 'System.Int32', TimeoutSeconds: 'System.Int32' };
    if (!command || typeof parameterSet?.Name !== 'string' || fields.filter(field => field?.Mandatory === true).length !== 3 ||
        !Object.entries(expected).every(([name, type]) => {
          const matches = fields.filter(field => field?.Name === name);
          return matches.length === 1 && matches[0].TypeName === type && matches[0].Sensitive === false &&
            matches[0].IsCredential === false && matches[0].Mandatory === (name !== 'TimeoutSeconds');
        })) {
      status.textContent = 'Die OVMS-Prüfung ist auf diesem Host nicht verfügbar.';
      return;
    }
    const location = 'http://' + address + ':' + port + '/v3/embeddings';
    dialog.close();
    openConfirmation('OVMS-Embedding prüfen', 'Einen synthetischen Embedding-Request an ' + location + ' senden?',
      '__PublicCommand', { command, parameterSet, parameters: {
        Location: location, RuntimeModel: model, Dimension: String(dimension), TimeoutSeconds: String(timeout),
      } }, 'OVMS prüfen');
  });
})();
