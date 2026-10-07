'use strict';
// Browser-only draft state. The server revalidates registered metadata; no job or Apply.
let componentRelationsRevision = 0;
let componentRelationsBusy = false;
let componentRelationsRuns = [];
let componentRelationsDraft = [];
let componentRelationsRoot = '';
const componentRelationsElement = id => document.querySelector('#component-relations-' + id);
const componentRelationsGuid = value => typeof value === 'string' && /^[a-f0-9]{8}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{4}-[a-f0-9]{12}$/.test(value) && value !== '00000000-0000-0000-0000-000000000000';
const componentRelationsStates = ['INITIALIZING', 'PROVISIONING', 'SQL_READY', 'DATABASES_CREATED', 'POST_PROVISIONED', 'RUNNING', 'STOPPED', 'PROVISION_FAILED', 'CLEANUP_PENDING', 'CLEANUP_RUNNING', 'CLEANED_UP', 'RECOVERY_REQUIRED'];
function componentRelationsOwn() { return componentRelationsRuns.find(run => run.RunId === componentRelationsElement('run').value); }
function componentRelationsOptions(id, choices) {
  const select = componentRelationsElement(id); const previous = select.value;
  select.replaceChildren();
  for (const choice of choices) {
    const option = document.createElement('option'); option.value = choice.id; option.textContent = choice.label; select.appendChild(option);
  }
  select.value = choices.some(choice => choice.id === previous) ? previous : (choices[0]?.id || '');
}
function updateComponentRelationsControls() {
  const own = componentRelationsOwn();
  for (const id of ['root', 'read', 'run', 'source', 'target', 'clear']) componentRelationsElement(id).disabled = componentRelationsBusy;
  componentRelationsElement('add').disabled = componentRelationsBusy || !own || !componentRelationsElement('target').value || componentRelationsDraft.length >= 4;
  componentRelationsElement('preview').disabled = componentRelationsBusy || !own;
}
function renderComponentRelationsChoices() {
  const own = componentRelationsOwn();
  componentRelationsOptions('source', (own?.Instances || []).map(instance => ({ id: instance.Id, label: instance.Id + ' · SQL ' + instance.Version + ' · Provider: ' + instance.Provider })));
  const shared = componentRelationsDraft.find(relation => relation.Target.RunId !== own?.RunId)?.Target;
  const source = componentRelationsElement('source').value;
  const targets = [];
  for (const run of componentRelationsRuns) for (const instance of run.Instances) {
    if (run.RunId === own?.RunId && instance.Id === source) continue;
    if (shared && run.RunId !== own?.RunId && (run.RunId !== shared.RunId || instance.Id !== shared.InstanceId)) continue;
    if (componentRelationsDraft.some(relation => relation.SourceInstanceId === source && relation.Target.RunId === run.RunId && relation.Target.InstanceId === instance.Id)) continue;
    targets.push({ id: run.RunId + ':' + instance.Id, label: (run.RunId === own?.RunId ? 'Eigene' : 'Shared-Referenz') + ' · ' + instance.Id + ' · SQL ' + instance.Version + ' · Provider: ' + instance.Provider + ' · Run ' + run.RunId });
  }
  componentRelationsOptions('target', own ? targets : []);
  componentRelationsElement('draft').textContent = componentRelationsDraft.length ? componentRelationsDraft.map(relation => relation.SourceInstanceId + ' benötigt ' + relation.Target.InstanceId + (relation.Target.RunId === own?.RunId ? ' (eigene Instanz)' : ' (Shared-Referenz, PRESERVE)')).join('\n') : 'Keine Beziehungen vorgeschlagen.';
  updateComponentRelationsControls();
}
function invalidateComponentRelations(clearRuns = false) {
  componentRelationsRevision++; componentRelationsBusy = false; componentRelationsDraft = [];
  if (clearRuns) { componentRelationsRuns = []; componentRelationsRoot = ''; componentRelationsOptions('run', []); }
  componentRelationsElement('result').textContent = ''; renderComponentRelationsChoices();
}
function validComponentRelationsMetadata(view) {
  return view?.ContractVersion === 'SqlServerLab.ComponentRelationBrowser/1.0' && view.Status === 'METADATA_ONLY' && view.MutationAllowed === false && view.ExecutionSupported === false && view.SqlReadiness === 'NOT_CHECKED' && view.SharedRemovalPolicy === 'PRESERVE' && Array.isArray(view.Runs) && view.Runs.length <= 64 &&
    new Set(view.Runs.map(run => run.RunId)).size === view.Runs.length && view.Runs.every(run => componentRelationsGuid(run.RunId) && componentRelationsGuid(run.ScopeId) && /^[a-f0-9]{64}$/.test(run.Digest || '') && componentRelationsStates.includes(run.State) && Array.isArray(run.Instances) && run.Instances.length >= 1 && run.Instances.length <= 2 && run.Instances.every(instance => /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(instance.Id || '') && ['docker', 'podman'].includes(instance.Provider) && /^[0-9]{4}(R2)?$/.test(instance.Version || '')));
}
async function requestComponentRelations(preview = false) {
  if (componentRelationsBusy || !componentRelationsElement('dialog').open) return;
  const own = componentRelationsOwn(); if (preview && !own) return;
  if (!preview) invalidateComponentRelations(true);
  const revision = componentRelationsRevision;
  const root = preview ? componentRelationsRoot : componentRelationsElement('root').value.trim();
  const payload = { Action: preview ? 'Preview' : 'Read', DataRoot: root };
  if (preview) {
    const ids = new Set([own.RunId, ...componentRelationsDraft.map(relation => relation.Target.RunId)]);
    payload.RunId = own.RunId; payload.ProposedRelations = componentRelationsDraft;
    payload.Bindings = componentRelationsRuns.filter(run => ids.has(run.RunId)).map(run => ({ RunId: run.RunId, ScopeId: run.ScopeId, State: run.State, Digest: run.Digest }));
  }
  componentRelationsBusy = true; updateComponentRelationsControls(); componentRelationsElement('result').textContent = '';
  componentRelationsElement('status').textContent = preview ? 'Gebundene Vorschau wird gelesen …' : 'Registrierte Metadaten werden gelesen …';
  try {
    const response = await sqlServerLabUiFetch('/api/component-relations', { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(payload) });
    if (!response.ok) throw new Error('COMPONENT_RELATION_REQUEST_FAILED');
    const view = await response.json();
    if (revision !== componentRelationsRevision || !componentRelationsElement('dialog').open) return;
    if (!preview) {
      if (!validComponentRelationsMetadata(view)) throw new Error('COMPONENT_RELATION_RESULT_INVALID');
      componentRelationsRoot = root; componentRelationsRuns = view.Runs;
      componentRelationsOptions('run', view.Runs.map(run => ({ id: run.RunId, label: 'Run ' + run.RunId + ' · ' + run.State + ' · ' + run.Instances.map(instance => instance.Id).join(', ') })));
      componentRelationsElement('status').textContent = view.Runs.length ? 'Metadaten gelesen. SQL-Bereitschaft nicht geprüft.' : 'Keine vollständig gebundenen Container-Runs verfügbar.';
      renderComponentRelationsChoices();
    } else {
      if (view.ContractVersion !== 'SqlServerLab.ComponentRelationBrowser/1.0' || view.RunId !== own.RunId || view.Mode !== 'COMPONENT_RELATIONS_PLAN_ONLY' || view.MutationAllowed !== false || view.ExecutionSupported !== false || !Array.isArray(view.Actions) || view.Actions.length || view.SqlReadiness !== 'NOT_CHECKED' || view.SharedRemovalPolicy !== 'PRESERVE' || !['NO_RELATION_CHANGE', 'BLOCKED_SQL_READINESS_NOT_CHECKED', 'BLOCKED_COMPONENT_RECOVERY_REQUIRED'].includes(view.Status) || !Array.isArray(view.PrerequisiteOrder) || view.PrerequisiteOrder.length > 3 || view.PrerequisiteOrder.some(item => !/^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(item.InstanceId || '') || !['docker', 'podman'].includes(item.Provider) || !componentRelationsStates.includes(item.LifecycleState) || !['PROVISIONED', 'EXTERNAL_READ_ONLY'].includes(item.ManagementMode))) throw new Error('COMPONENT_RELATION_RESULT_INVALID');
      const messages = { NO_RELATION_CHANGE: 'Keine Beziehungen vorgeschlagen.', BLOCKED_SQL_READINESS_NOT_CHECKED: 'Vorschau vorhanden; Ausführung bleibt gesperrt, SQL-Bereitschaft nicht geprüft.', BLOCKED_COMPONENT_RECOVERY_REQUIRED: 'Recoverybedarf: Ausführung bleibt gesperrt.' };
      componentRelationsElement('status').textContent = messages[view.Status];
      componentRelationsElement('result').textContent = 'PLAN_ONLY · SQL: NOT_CHECKED · Shared: PRESERVE\nVoraussetzungsreihenfolge:\n' + view.PrerequisiteOrder.map(item => item.InstanceId + ' · Provider: ' + item.Provider + ' · ' + item.LifecycleState + ' · ' + item.ManagementMode).join('\n');
    }
  } catch {
    if (revision === componentRelationsRevision && componentRelationsElement('dialog').open) {
      invalidateComponentRelations(true); componentRelationsElement('status').textContent = 'Vorschau nicht bestätigt. Registrierte Metadaten erneut lesen und bewusst auswählen.';
    }
  } finally { if (revision === componentRelationsRevision) { componentRelationsBusy = false; updateComponentRelationsControls(); } }
}
componentRelationsElement('open').addEventListener('click', () => { invalidateComponentRelations(true); componentRelationsElement('status').textContent = 'Noch keine Metadaten gelesen.'; componentRelationsElement('dialog').showModal(); });
componentRelationsElement('read').addEventListener('click', () => requestComponentRelations());
componentRelationsElement('preview').addEventListener('click', () => requestComponentRelations(true));
componentRelationsElement('run').addEventListener('change', () => invalidateComponentRelations());
componentRelationsElement('source').addEventListener('change', renderComponentRelationsChoices);
componentRelationsElement('root').addEventListener('input', () => invalidateComponentRelations(true));
componentRelationsElement('clear').addEventListener('click', () => invalidateComponentRelations());
componentRelationsElement('close').addEventListener('click', () => componentRelationsElement('dialog').close());
for (const event of ['close', 'cancel']) componentRelationsElement('dialog').addEventListener(event, () => invalidateComponentRelations(true));
componentRelationsElement('add').addEventListener('click', () => {
  const own = componentRelationsOwn(); if (componentRelationsBusy || !own || componentRelationsDraft.length >= 4) return;
  const selected = componentRelationsElement('target').value.split(':');
  const run = componentRelationsRuns.find(item => item.RunId === selected[0]); const instance = run?.Instances.find(item => item.Id === selected[1]);
  const source = componentRelationsElement('source').value;
  const shared = componentRelationsDraft.find(relation => relation.Target.RunId !== own.RunId)?.Target;
  if (!instance || !own.Instances.some(item => item.Id === source) || (run.RunId === own.RunId && instance.Id === source) || (shared && run.RunId !== own.RunId && (run.RunId !== shared.RunId || instance.Id !== shared.InstanceId)) || componentRelationsDraft.some(relation => relation.SourceInstanceId === source && relation.Target.RunId === run.RunId && relation.Target.InstanceId === instance.Id)) return;
  componentRelationsDraft.push({ SourceInstanceId: source, Type: 'requires-sql', Target: { RunId: run.RunId, ScopeId: run.ScopeId, InstanceId: instance.Id, ManagementMode: run.RunId === own.RunId ? 'PROVISIONED' : 'EXTERNAL_READ_ONLY' } });
  componentRelationsRevision++; componentRelationsElement('result').textContent = ''; renderComponentRelationsChoices();
});
