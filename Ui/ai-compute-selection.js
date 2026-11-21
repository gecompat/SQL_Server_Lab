'use strict';
(() => {
  const element = id => document.getElementById('compute-selection-' + id);
  const dialog = element('dialog');
  const form = element('form');
  const candidatesInput = element('candidates');
  const benchmarksInput = element('benchmarks');
  const choice = element('choice');
  const status = element('status');
  const next = element('next');
  const keyPattern = /^[a-z0-9][a-z0-9._-]{0,127}$/;
  const hashPattern = /^[a-f0-9]{64}$/i;
  const benchmarkProperties = ['Contract', 'CandidateId', 'WorkloadKey', 'ModelSha256', 'BenchmarkProfileSha256',
    'InventorySha256', 'RuntimeSha256', 'EvidenceStatus'];
  const benchmarkNumbers = ['ThroughputPerSecond', 'P95LatencyMilliseconds', 'PeakWorkingSetBytes', 'SuccessfulIterations', 'TotalIterations'];
  let revision = 0;

  async function readReceipt(file) {
    if (!file || !/\.json$/i.test(file.name) || file.size < 1 || file.size > 256 * 1024) throw new Error('COMPUTE_RECEIPT_FILE_INVALID');
    return JSON.parse(await file.text());
  }

  function getCandidates(receipt) {
    if (receipt?.Contract !== 'SqlServerLab.AiComputeCandidateSet/1.0' || receipt.Status !== 'COMPLETE' ||
        !hashPattern.test(receipt.InventorySha256) || !Array.isArray(receipt.Candidates) ||
        receipt.Candidates.length < 1 || receipt.Candidates.length > 64) throw new Error('COMPUTE_CANDIDATE_RECEIPT_INVALID');
    return receipt.Candidates.map(item => {
      if (typeof item?.CandidateId !== 'string' || !keyPattern.test(item.CandidateId) ||
          typeof item.Backend !== 'string' || !/^[A-Za-z0-9]{1,80}$/.test(item.Backend) || !hashPattern.test(item.RuntimeSha256) ||
          typeof item.Eligible !== 'boolean' || !Array.isArray(item.Blockers) || item.Blockers.length > 64 ||
          item.Blockers.some(blocker => typeof blocker !== 'string' || !/^[A-Z][A-Z0-9_]{2,127}$/.test(blocker)) ||
          !Array.isArray(item.Devices) || item.Devices.length < 1 || item.Devices.length > 16 ||
          item.Devices.some(device => !['CPU', 'GPU', 'NPU'].includes(device?.Kind) ||
            typeof device.DeviceId !== 'string' || !/^[A-Za-z0-9][A-Za-z0-9._:-]{0,127}$/.test(device.DeviceId))) {
        throw new Error('COMPUTE_CANDIDATE_RECEIPT_INVALID');
      }
      return {
        CandidateId: item.CandidateId, Backend: item.Backend, RuntimeSha256: item.RuntimeSha256,
        Eligible: item.Eligible, Blockers: item.Blockers, Devices: item.Devices.map(device => ({ Kind: device.Kind, DeviceId: device.DeviceId })),
      };
    });
  }

  element('open').addEventListener('click', () => {
    revision++;
    form.reset();
    choice.replaceChildren(new Option('Schnellsten gemessenen Kandidaten wählen', ''));
    status.textContent = '';
    next.disabled = false;
    dialog.showModal();
  });
  element('close').addEventListener('click', () => { revision++; dialog.close(); });
  candidatesInput.addEventListener('change', async () => {
    const current = ++revision;
    const file = candidatesInput.files[0];
    choice.replaceChildren(new Option('Schnellsten gemessenen Kandidaten wählen', ''));
    try {
      const candidates = getCandidates(await readReceipt(file));
      if (revision !== current || !dialog.open) return;
      for (const candidate of candidates) {
        if (candidate.Eligible === true && keyPattern.test(candidate.CandidateId)) choice.add(new Option(candidate.CandidateId, candidate.CandidateId));
      }
      status.textContent = '';
    } catch {
      if (revision === current && dialog.open) status.textContent = 'Kandidatensatz fehlt oder ist ungültig.';
    }
  });
  form.addEventListener('submit', async event => {
    event.preventDefault();
    if (next.disabled) return;
    const current = revision;
    const candidateFile = candidatesInput.files[0];
    const benchmarkFile = benchmarksInput.files[0];
    const pinned = choice.value;
    next.disabled = true;
    try {
      const [candidateSet, benchmarkSet] = await Promise.all([readReceipt(candidateFile), readReceipt(benchmarkFile)]);
      if (revision !== current || !dialog.open || candidateFile !== candidatesInput.files[0] ||
          benchmarkFile !== benchmarksInput.files[0] || pinned !== choice.value) return;
      const selection = benchmarkSet?.Selection;
      const candidates = getCandidates(candidateSet);
      if (benchmarkSet?.Contract !== 'SqlServerLab.AiComputeBenchmarkSet/1.0' || benchmarkSet.Status !== 'SELECTED' ||
          selection?.Contract !== 'SqlServerLab.AiComputeSelection/1.0' ||
          selection.InventorySha256 !== candidateSet.InventorySha256 || !keyPattern.test(selection.WorkloadKey) ||
          !hashPattern.test(selection.ModelSha256) || !hashPattern.test(selection.BenchmarkProfileSha256) ||
          !Array.isArray(benchmarkSet.Benchmarks) || benchmarkSet.Benchmarks.length < 1 || benchmarkSet.Benchmarks.length > 64 ||
          (pinned && !candidates.some(item => item.CandidateId === pinned && item.Eligible === true))) throw new Error('COMPUTE_BENCHMARK_RECEIPT_INVALID');

      const parameters = { Candidate: candidates, InventorySha256: candidateSet.InventorySha256, WorkloadKey: selection.WorkloadKey,
        ModelSha256: selection.ModelSha256, BenchmarkProfileSha256: selection.BenchmarkProfileSha256 };
      if (pinned) parameters.PinnedCandidateId = pinned;
      else parameters.Benchmark = benchmarkSet.Benchmarks.map(item => {
        if (!item || benchmarkProperties.some(name => typeof item[name] !== 'string' || item[name].length > 128) ||
            benchmarkNumbers.some(name => !Number.isFinite(item[name]))) throw new Error('COMPUTE_BENCHMARK_RECEIPT_INVALID');
        return Object.fromEntries([...benchmarkProperties, ...benchmarkNumbers].map(name => [name, item[name]]));
      });
      const commands = publicCommandCatalog.filter(command => command?.Name === 'Get-SqlServerLabAiComputeSelection');
      const command = commands.length === 1 ? commands[0] : null;
      const sets = (command?.ParameterSets || []).filter(set => set.Name === (pinned ? 'Pinned' : 'Auto'));
      const parameterSet = sets.length === 1 ? sets[0] : null;
      const required = (parameterSet?.Parameters || []).filter(field => field?.Mandatory === true);
      if (required.length !== Object.keys(parameters).length || Object.keys(parameters).some(name =>
        required.filter(field => field.Name === name && field.Sensitive === false && field.IsCredential === false).length !== 1)) throw new Error('COMPUTE_UI_CATALOG_INVALID');

      dialog.close();
      openConfirmation('KI-Gerätekombination wählen', pinned ? 'Kandidat ' + pinned + ' aus den gewählten Belegen fixieren?' :
        'Schnellsten gemessenen Kandidaten aus den gewählten Belegen berechnen?',
      '__PublicCommand', { command, parameterSet, parameters }, 'Auswahl berechnen');
    } catch {
      if (revision === current && dialog.open) status.textContent = 'Die Belege fehlen, gehören nicht zusammen oder sind ungültig.';
    } finally {
      if (dialog.open) next.disabled = false;
    }
  });
})();
