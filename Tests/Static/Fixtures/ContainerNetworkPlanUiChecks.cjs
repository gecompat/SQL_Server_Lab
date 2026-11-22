'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const items = new Map();
function item(id) {
  if (!items.has(id)) items.set(id, {
    value: '',
    addEventListener(event, callback) { this[event] = callback; },
    showModal() { this.open = true; },
    close() { this.open = false; },
    reset() {}
  });
  return items.get(id);
}
const field = (name, mandatory) => ({ Name: name, Mandatory: mandatory, TypeName: 'System.String', Sensitive: false, IsCredential: false });
const command = { Name: 'Move-SqlServerLabContainerNetwork', RequiresConfirmation: true, SupportsShouldProcess: true,
  ParameterSets: [{ Name: '__AllParameterSets', Parameters: [field('Provider', true), field('TargetSubnet', false), field('ExpectedPlanKey', false)] }] };
const calls = [];
const confirmations = [];
const receipt = { ContractVersion: 'SqlServerLab.GuidedContainerNetworkPlan/1.0', Provider: 'podman', Status: 'MIGRATION_REQUIRED',
  CurrentSubnet: '172.27.0.0/16', TargetSubnet: '198.19.2.0/24', ContainerCount: 2, PlanKey: 'a'.repeat(64) };
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/container-network-plan.js'), 'utf8');
vm.runInNewContext(source, {
  document: { getElementById: item }, publicCommandCatalog: [command], URLSearchParams,
  sqlServerLabUiFetch(url, options) {
    assert.equal(options.method, undefined);
    assert.equal(options.cache, 'no-store');
    return new Promise(resolve => calls.push({ url, resolve }));
  },
  openConfirmation(...args) { confirmations.push(args); }
});
const el = name => item('container-network-plan-' + name);
const submit = () => el('form').submit({ preventDefault() {} });
const reply = (index, view) => calls[index].resolve({ ok: true, json: async () => view });
(async () => {
  el('open').click();
  el('provider').value = 'podman';
  el('subnet').value = 'invalid';
  await submit();
  assert.equal(calls.length, 0);
  el('subnet').value = receipt.TargetSubnet;
  const outdated = submit();
  el('subnet').value = '198.19.3.0/24';
  el('subnet').input();
  reply(0, receipt);
  await outdated;
  assert.equal(el('apply').disabled, true);
  const preview = submit();
  assert.match(calls[1].url, /provider=podman&targetSubnet=198\.19\.3\.0%2F24$/);
  reply(1, { ...receipt, TargetSubnet: '198.19.3.0/24' });
  await preview;
  assert.equal(confirmations.length, 0);
  assert.equal(el('apply').disabled, false);
  command.ParameterSets[0].Parameters.pop();
  el('apply').click();
  assert.equal(confirmations.length, 0, 'ExpectedPlanKey must be available');
  command.ParameterSets[0].Parameters.push(field('ExpectedPlanKey', false));
  el('apply').click();
  assert.equal(confirmations[0][2], '__PublicCommand');
  assert.deepEqual(JSON.parse(JSON.stringify(confirmations[0][3].parameters)), {
    Provider: 'podman', TargetSubnet: '198.19.3.0/24', ExpectedPlanKey: receipt.PlanKey
  });
  el('apply').click();
  assert.equal(confirmations.length, 1);
  el('open').click();
  const recovery = submit();
  reply(2, { ...receipt, Status: 'MIGRATION_BLOCKED', Code: 'LAB_NETWORK_MIGRATION_PENDING_RECOVERY',
    Recovery: { LastRecordedPhase: 'TEMPORARY_NETWORK_READY', FailureCode: 'LAB_NETWORK_MIGRATION_DISCONNECT_FAILED' } });
  await recovery;
  assert.match(el('status').textContent, /TEMPORARY_NETWORK_READY.*LAB_NETWORK_MIGRATION_DISCONNECT_FAILED/);
  assert.equal(el('apply').hidden, true);
  el('apply').click();
  assert.equal(confirmations.length, 1);
  console.log('CONTAINER NETWORK PLAN BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
