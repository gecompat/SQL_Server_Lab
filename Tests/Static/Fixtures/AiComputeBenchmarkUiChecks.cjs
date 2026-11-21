'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const items = new Map();
const item = id => {
  if (!items.has(id)) items.set(id, {
    addEventListener(event, callback) { this[event] = callback; },
    replaceChildren(option) { this.options = [option]; this.value = option.value; },
    add(option) { this.options.push(option); },
    showModal() { this.open = true; }, close() { this.open = false; }, reset() {},
  });
  return items.get(id);
};
const key = 'a'.repeat(64);
const runtimeHash = 'b'.repeat(64);
const candidate = { CandidateId: 'cpu', Backend: 'LlamaCppCpu', RuntimeSha256: runtimeHash, Eligible: true, Devices: [{ DeviceId: 'cpu0' }] };
const payload = {
  ModelPath: 'C:/Local/model.gguf',
  Inventory: { Contract: 'SqlServerLab.AiComputeInventory/1.0', Status: 'COMPLETE', InventorySha256: key },
  CandidateSet: { Contract: 'SqlServerLab.AiComputeCandidateSet/1.0', InventorySha256: key, Candidates: [candidate] },
  Packages: [{ RuntimeSha256: runtimeHash, Directory: 'C:/Local/llama' }],
};
const keys = ['Inventory','ModelPath','WorkloadKey','Candidate','RuntimeDirectory'];
const commands = ['', 'Set'].map(suffix => ({ Name: 'Measure-SqlServerLabAiComputeCandidate' + suffix, RequiresConfirmation: true,
  SupportsShouldProcess: true, ParameterSets: [{ Name: '__AllParameterSets', Parameters: [...keys, 'BenchmarkMode'].map(Name => ({
    Name, Mandatory: keys.includes(Name), IsCredential: false, Sensitive: false,
  })) }] }));
const calls = [];
const reads = [];
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/ai-compute-benchmark.js'), 'utf8');
vm.runInNewContext(source, {
  document: { getElementById: item }, publicCommandCatalog: commands,
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  openConfirmation(...args) { calls.push(args); },
  async sqlServerLabUiFetch(url, init) { reads.push({ url, init }); return { ok: true, json: async () => payload }; },
});
const el = name => item('compute-benchmark-' + name);
const submit = () => el('form').submit({ preventDefault() {} });
(async () => {
  el('open').click();
  el('model').value = '//external/a.gguf';
  await el('read').click();
  assert.equal(reads.length, 0);
  el('model').value = payload.ModelPath;
  await el('read').click();
  assert.equal(calls.length, 0);
  assert.equal(reads[0].url, '/api/ai-compute-benchmark-options');
  assert.deepEqual(JSON.parse(reads[0].init.body), { ModelPath: payload.ModelPath });
  assert.deepEqual(el('candidate').options.map(option => option.value), ['', 'all', 'candidate:cpu']);
  el('candidate').value = 'candidate:cpu';
  el('mode').value = 'Embedding';
  submit();
  assert.equal(calls[0][2], '__PublicCommand');
  assert.equal(calls[0][3].command.Name, 'Measure-SqlServerLabAiComputeCandidate');
  assert.equal(calls[0][3].parameters.RuntimeDirectory, 'C:/Local/llama');
  assert.equal(calls[0][3].parameters.WorkloadKey, 'sql-ai-embedding');
  el('open').click();
  await el('read').click();
  el('candidate').value = 'all';
  el('mode').value = 'Generation';
  el('model').value = 'C:/Local/changed.gguf';
  el('model').input();
  submit();
  assert.equal(calls.length, 1);
  el('model').value = payload.ModelPath;
  await el('read').click();
  el('candidate').value = 'all';
  submit();
  assert.equal(calls[1][3].command.Name, 'Measure-SqlServerLabAiComputeCandidateSet');
  assert.deepEqual(Array.from(calls[1][3].parameters.RuntimeDirectory), ['C:/Local/llama']);
  assert.equal(calls[1][3].parameters.Candidate[0].CandidateId, 'cpu');
  console.log('AI COMPUTE BENCHMARK BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
