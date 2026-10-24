'use strict';
const fs = require('node:fs'), path = require('node:path'), vm = require('node:vm'), assert = require('node:assert/strict');
const root = path.resolve(__dirname, '../../..');
const source = fs.readFileSync(path.join(root, 'Ui/app.js'), 'utf8');
const match = source.match(/^function renderContainerVersionOptions\(data\) \{[\s\S]*?^\}/m);
assert(match, 'Actual pinned version renderer must exist');
let passed = 0;
function render(data, selected = '2022') {
  const select = { value: selected, options: [], html: '' };
  Object.defineProperty(select, 'innerHTML', { get() { return this.html; }, set(html) {
    this.html = html; this.options = [...html.matchAll(/<option value="([^"]+)">([^<]+)<\/option>/g)].map(m => ({ value: m[1], label: m[2] }));
    this.value = this.options[0]?.value || '';
  } });
  const ctx = vm.createContext({ $: id => { assert.equal(id, '#container-version'); return select; }, escapeHtml: value => String(value).replaceAll('&', '&amp;').replaceAll('<', '&lt;').replaceAll('"', '&quot;') });
  vm.runInContext(match[0], ctx); ctx.renderContainerVersionOptions(data); return select;
}
const pins = ['2025-CU9', '2022-CU27', '2019-CU32'].map(VersionId => ({ VersionId, Cu: VersionId.split('-')[1] }));
let result = render({ ContainerPinnedBuilds: pins }, '2019-CU32');
assert.deepEqual(result.options.map(x => x.value), ['2022', '2019', '2025', '2025-CU9', '2022-CU27', '2019-CU32']); passed++;
assert.equal(result.value, '2019-CU32'); passed++;
for (const value of pins) { assert(result.options.find(x => x.value === value.VersionId)?.label.includes(value.VersionId.substring(0, 4))); passed++; }
result = render({ ContainerSql2025PinnedBuilds: [pins[0]] }, '2025-CU9'); assert.equal(result.value, '2025-CU9'); passed++;
result = render({ ContainerSql2025PinnedBuilds: pins }); assert.deepEqual(result.options.map(x => x.value), ['2022', '2019', '2025', '2025-CU9']); passed++;
result = render({ ContainerPinnedBuilds: [] }); assert.deepEqual(result.options.map(x => x.value), ['2022', '2019', '2025']); passed++;
result = render({ ContainerPinnedBuilds: [pins[0], pins[0], null, { VersionId: '2022-CU27', Cu: 'CU26' }, { VersionId: '2019-CU32<script>', Cu: 'CU32' }, { VersionId: '2017-CU31', Cu: 'CU31' }, { VersionId: ['2022-CU27'], Cu: 'CU27' }, { VersionId: '2022-CU27', Cu: ['CU27'] }] });
assert.deepEqual(result.options.map(x => x.value), ['2022', '2019', '2025', '2025-CU9']); passed++;
result = render({ ContainerPinnedBuilds: {}, ContainerSql2025PinnedBuilds: [pins[0]] }); assert(result.options.some(x => x.value === '2025-CU9')); passed++;
result = render({}); assert.equal(result.html, ''); passed++;
result = render({ ContainerPinnedBuilds: pins }, 'removed-version'); assert.equal(result.value, '2022'); passed++;
result = render({ ContainerPinnedBuilds: Array.from({ length: 100 }, (_, i) => ({ VersionId: `2022-CU${i + 1}`, Cu: `CU${i + 1}` })) }); assert.equal(result.options.length, 99); passed++;
process.stdout.write(JSON.stringify({ Status: 'PASS', Cases: passed, ActualRenderer: true, BrowserOrProviderActions: 0 }) + '\n');
