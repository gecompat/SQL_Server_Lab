'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const nodes = {};
for (const id of ['cms-sync-open', 'cms-inspection-dialog', 'cms-sync-status']) {
  nodes[id] = {
    open: id === 'cms-inspection-dialog',
    addEventListener(name, fn) { this[name + 'Handler'] = fn; },
    close() { this.open = false; this.closeHandler?.(); },
  };
}
const confirmations = [];
const target = '11111111-2222-4333-8444-555555555555';
const selectedKey = 'a'.repeat(64);
const context = vm.createContext({
  window: {}, document: { getElementById: id => nodes[id] },
  cmsInspectionView: null, cmsInspectionBusy: false,
  publicCommandCatalog: [{
    Name: 'Sync-SqlServerLabCms', RequiresConfirmation: true,
    ParameterSets: [{ Name: 'RegistrationBound', Parameters: [{
      Name: 'ExpectedRegistrationKey', Mandatory: true, Sensitive: false, IsCredential: false,
    }] }],
  }],
  openConfirmation(...args) { confirmations.push(args); },
});
vm.runInContext(fs.readFileSync(path.resolve(__dirname, '../../../Ui/cms-sync.js'), 'utf8'), context);
context.window.sqlServerLabCmsSync.update();
assert.equal(nodes['cms-sync-open'].disabled, true);
nodes['cms-sync-open'].clickHandler();
assert.deepEqual(confirmations, []);
context.cmsInspectionView = { Status: 'NOT_CHECKED', Provider: 'hyperv', RunId: target, SelectionKey: selectedKey };
context.window.sqlServerLabCmsSync.update();
assert.equal(nodes['cms-sync-open'].disabled, true);
context.cmsInspectionView.Provider = 'podman';
context.window.sqlServerLabCmsSync.update();
assert.equal(nodes['cms-sync-open'].disabled, false);
nodes['cms-sync-open'].clickHandler();
assert.equal(confirmations.length, 1);
assert.equal(confirmations[0][2], '__PublicCommand');
assert.equal(confirmations[0][3].command.Name, 'Sync-SqlServerLabCms');
assert.equal(confirmations[0][3].parameterSet.Name, 'RegistrationBound');
assert.equal(JSON.stringify(confirmations[0][3].parameters), JSON.stringify({ ExpectedRegistrationKey: selectedKey }));
assert.equal(nodes['cms-inspection-dialog'].open, false);
nodes['cms-sync-open'].clickHandler();
assert.equal(confirmations.length, 1);
console.log('CMS BOUND SYNC BROWSER: PASS');
