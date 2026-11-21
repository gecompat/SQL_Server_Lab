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
const candidate = { CandidateId: 'cpu', Backend: 'LlamaCppCpu', Eligible: true, RuntimeSha256: 'a'.repeat(64), Blockers: [],
  Devices: [{ Kind: 'CPU', DeviceId: 'cpu0' }], UnusedPrivateProperty: 'CANARY' };
const identity = { WorkloadKey: 'sql-ai-generation', InventorySha256: 'b'.repeat(64), ModelSha256: 'c'.repeat(64), BenchmarkProfileSha256: 'd'.repeat(64) };
const candidateSet = { Contract: 'SqlServerLab.AiComputeCandidateSet/1.0', Status: 'COMPLETE', InventorySha256: identity.InventorySha256, Candidates: [candidate] };
const observation = { ...identity, Contract: 'SqlServerLab.AiComputeBenchmark/1.0', CandidateId: 'cpu', RuntimeSha256: candidate.RuntimeSha256,
  EvidenceStatus: 'BENCHMARK_VERIFIED', ThroughputPerSecond: 2, P95LatencyMilliseconds: 5, PeakWorkingSetBytes: 123, SuccessfulIterations: 3, TotalIterations: 3 };
const benchmarkSet = { Contract: 'SqlServerLab.AiComputeBenchmarkSet/1.0', Status: 'SELECTED',
  Selection: { Contract: 'SqlServerLab.AiComputeSelection/1.0', ...identity }, Benchmarks: [observation] };
const commands = [{ Name: 'Get-SqlServerLabAiComputeSelection', ParameterSets: ['Auto', 'Pinned'].map(Name => ({
  Name, Parameters: ['Candidate', ...Object.keys(identity), Name === 'Pinned' ? 'PinnedCandidateId' : 'Benchmark'].map(Name => ({
    Name, Mandatory: true, Sensitive: false, IsCredential: false,
  })),
})) }];
const calls = [];
const source = fs.readFileSync(path.resolve(__dirname, '../../../Ui/ai-compute-selection.js'), 'utf8');
vm.runInNewContext(source, {
  document: { getElementById: item }, publicCommandCatalog: commands,
  Option: class { constructor(text, value) { this.text = text; this.value = value; } },
  openConfirmation(...args) { calls.push(args); },
});
const el = name => item('compute-selection-' + name);
const file = data => ({ name: 'receipt.json', size: 1024, text: async () => JSON.stringify(data) });
const submit = () => el('form').submit({ preventDefault() {} });
(async () => {
  el('open').click();
  el('candidates').files = [file(candidateSet)];
  await el('candidates').change();
  assert.deepEqual(el('choice').options.map(option => option.value), ['', 'cpu']);
  el('benchmarks').files = [file({ ...benchmarkSet, Selection: { ...benchmarkSet.Selection, InventorySha256: 'f'.repeat(64) } })];
  await submit();
  assert.equal(calls.length, 0);
  el('benchmarks').files = [file(benchmarkSet)];
  await submit();
  assert.equal(calls[0][2], '__PublicCommand');
  assert.equal(calls[0][3].parameterSet.Name, 'Auto');
  assert.equal(calls[0][3].parameters.Benchmark[0].CandidateId, 'cpu');
  assert.equal(calls[0][3].parameters.Candidate[0].UnusedPrivateProperty, undefined);
  el('open').click();
  await el('candidates').change();
  el('choice').value = 'cpu';
  await submit();
  assert.equal(calls[1][3].parameterSet.Name, 'Pinned');
  assert.equal(calls[1][3].parameters.PinnedCandidateId, 'cpu');
  assert.equal(calls[1][3].parameters.Benchmark, undefined);
  console.log('AI COMPUTE SELECTION BROWSER UI: PASS');
})().catch(error => { console.error(error.message); process.exitCode = 1; });
