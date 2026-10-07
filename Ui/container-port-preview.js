'use strict';
(() => {
  const el = id => document.querySelector('#port-preview-' + id);
  const shape = (v, names) => v !== null && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === names.length && Object.keys(v).every(n => names.includes(n));
  const guid = v => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
  const targetValid = t => shape(t, ['RunId','InstanceId','Provider']) && guid(t.RunId) && typeof t.InstanceId === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(t.InstanceId) && ['docker','podman'].includes(t.Provider);
  const reasons = ['PORT_PREVIEW_BINDING_UNAVAILABLE','PORT_PREVIEW_PROVIDER_UNSUPPORTED','PORT_PREVIEW_PROTECTED_TARGET','PORT_PREVIEW_RUNNING_REQUIRED','PORT_PREVIEW_JOURNAL_BLOCKED','PORT_PREVIEW_TOPOLOGY_UNSUPPORTED','PORT_PREVIEW_LIMITS_UNKNOWN','PORT_PREVIEW_MOUNTS_UNSUPPORTED','PORT_PREVIEW_APPLY_NOT_IMPLEMENTED'];
  function validPlan(v, provider) {
    if (!shape(v,['Contract','Mode','Status','Reason','Provider','ObservationKey','Actual','Desired','NoChange','ChangeClass','CanApply','MutationAllowed','Actions','Preview']) ||
      !shape(v.Contract,['Name','Version']) || v.Contract.Name !== 'SqlServerLab.ContainerPortPreview' || v.Contract.Version !== '1.0' || v.Mode !== 'CONTAINER_PORT_PREVIEW_PLAN_ONLY' ||
      !['PLAN_ONLY','BLOCKED','UNSUPPORTED'].includes(v.Status) || !reasons.includes(v.Reason) || v.CanApply !== false || v.MutationAllowed !== false || !Array.isArray(v.Actions) || v.Actions.length ||
      !shape(v.Actual,['Evidence','SqlBinding','Lifecycle']) || !shape(v.Desired,['PortChange']) || !shape(v.Preview,['Downtime','Endpoint','Sql','Backup','DataImpact','Mounts']) ||
      v.Preview.Endpoint !== 'NOT_CHECKED' || v.Preview.Sql !== 'NOT_CHECKED' || v.Preview.Backup !== 'NOT_CHECKED' || v.Preview.DataImpact !== 'NOT_VERIFIED' || ![null,'docker','podman'].includes(v.Provider)) return false;
    if (v.Status !== 'PLAN_ONLY') return v.ObservationKey === null && v.NoChange === null && v.ChangeClass === 'unsupported' && v.Actual.Evidence === 'UNKNOWN' && v.Actual.SqlBinding === 'UNKNOWN' && v.Actual.Lifecycle === 'UNKNOWN' && v.Desired.PortChange === 'UNKNOWN' && v.Preview.Downtime === 'UNKNOWN' && v.Preview.Mounts === null;
    const m = v.Preview.Mounts;
    return v.Provider === provider && v.Reason === 'PORT_PREVIEW_APPLY_NOT_IMPLEMENTED' && typeof v.ObservationKey === 'string' && /^[a-f0-9]{64}$/.test(v.ObservationKey) && typeof v.NoChange === 'boolean' &&
      v.Actual.Evidence === 'MEASURED' && v.Actual.SqlBinding === 'SINGLE_LOOPBACK_1433_TCP' && v.Actual.Lifecycle === 'RUNNING' && v.Desired.PortChange === (v.NoChange ? 'SAME_PORT' : 'DIFFERENT_PORT') && v.ChangeClass === (v.NoChange ? 'no-op' : 'recreate') && v.Preview.Downtime === (v.NoChange ? 'NONE' : 'REQUIRED') &&
      shape(m,['Status','TotalMountCount','VolumeMountCount','HostBindCount','WritableHostBindCount','OtherMountCount','VolumeOwnership']) && m.Status === 'MEASURED' && m.VolumeOwnership === 'NOT_CHECKED' &&
      ['TotalMountCount','VolumeMountCount','HostBindCount','WritableHostBindCount','OtherMountCount'].every(n => Number.isInteger(m[n]) && m[n] >= 0 && m[n] <= 1024) && m.TotalMountCount === m.VolumeMountCount + m.HostBindCount + m.OtherMountCount && m.WritableHostBindCount <= m.HostBindCount;
  }
  let revision = 0, targets = [], busy = false;
  function invalidate() { revision++; busy = false; el('result').textContent = ''; el('plan').disabled = false; el('read').disabled = false; el('status').textContent = 'Endpoint, SQL, Backup und Volumeeigentum: NOT_CHECKED. Datenerhalt: NOT_VERIFIED.'; }
  function close() { invalidate(); targets = []; el('target').replaceChildren(); el('target').disabled = true; el('port').value = ''; el('dialog').close(); }
  async function request(action) {
    if (busy || !el('dialog').open) return;
    const selected = targets.find((t, index) => String(index) === el('target').value);
    const text = el('port').value, port = Number(text);
    if (action === 'Preview' && (!selected || !/^[0-9]{4,5}$/.test(text) || !Number.isInteger(port) || port < 1024 || port > 65535)) { invalidate(); el('status').textContent = 'Vollständiges Ziel und Port 1024–65535 auswählen.'; return; }
    invalidate(); const current = revision; busy = true; el('plan').disabled = true; el('read').disabled = true;
    const payload = action === 'Read' ? {Action:'Read'} : {Action:'Preview',RunId:selected.RunId,InstanceId:selected.InstanceId,Port:port};
    try {
      const response = await sqlServerLabUiFetch('/api/container-port-preview',{method:'POST',headers:{'Content-Type':'application/json; charset=utf-8'},body:JSON.stringify(payload)});
      if (current !== revision || !el('dialog').open) return;
      if (!response.ok) throw new Error('INVALID');
      const view = await response.json();
      if (current !== revision || !el('dialog').open) return;
      if (new TextEncoder().encode(JSON.stringify(view)).length > 1048576) throw new Error('INVALID');
      if (action === 'Read') {
        if (!shape(view,['ContractVersion','Status','Targets','CanApply','MutationAllowed','Actions']) || view.ContractVersion !== 'SqlServerLab.ContainerPortBrowser/1.0' || view.Status !== 'METADATA_ONLY' || view.CanApply !== false || view.MutationAllowed !== false || !Array.isArray(view.Actions) || view.Actions.length || !Array.isArray(view.Targets) || view.Targets.length > 4096 || !view.Targets.every(targetValid) || new Set(view.Targets.map(t => t.RunId+'|'+t.InstanceId)).size !== view.Targets.length) throw new Error('INVALID');
        targets = view.Targets; el('target').replaceChildren();
        for (const [index,t] of targets.entries()) { const option=document.createElement('option');option.value=String(index);option.textContent=t.RunId+' · '+t.InstanceId+' · '+t.Provider;el('target').appendChild(option); }
        el('target').disabled = !targets.length;el('status').textContent = targets.length ? 'Registrierte Metadaten gelesen. Keine Runtimeprüfung; Wunschport eingeben.' : 'Keine gebundene laufende SQL-Instanz verfügbar.';
      } else {
        if (!validPlan(view, selected.Provider)) throw new Error('INVALID');
        let result = 'PLAN_ONLY · CanApply=false · Actions: 0 · keine Änderung oder Reservierung.\nEndpoint, SQL, Backup und Volumeeigentum: NOT_CHECKED. Datenerhalt: NOT_VERIFIED.\n';
        if (view.Status === 'PLAN_ONLY') { const m=view.Preview.Mounts;result += view.Desired.PortChange+' · '+view.ChangeClass+' · Ausfallzeit: '+view.Preview.Downtime+'\nMounts: '+m.TotalMountCount+' gesamt; '+m.VolumeMountCount+' Volumes; '+m.HostBindCount+' Host-Bindings ('+m.WritableHostBindCount+' schreibbar); '+m.OtherMountCount+' andere.\nInhaltsbindung vorhanden; keine Ausführungsautorität.'; }
        else result += 'Vorschau blockiert oder Topologie nicht unterstützt. Istwerte bleiben UNKNOWN.';
        el('result').textContent = result;
      }
    } catch { if (current === revision && el('dialog').open) { el('result').textContent = '';el('status').textContent = 'PORT_HTTP_INVALID: Auswahl oder Vorschau nicht sicher bestätigt.';if (action === 'Read') {targets=[];el('target').replaceChildren();el('target').disabled=true;} } }
    finally { if (current === revision && el('dialog').open) {busy=false;el('read').disabled=false;el('plan').disabled=!targets.length;} }
  }
  el('open').addEventListener('click', () => { invalidate();targets=[];el('target').replaceChildren();el('target').disabled=true;el('port').value='';el('dialog').showModal();request('Read'); });
  el('read').addEventListener('click', () => request('Read'));
  el('plan').addEventListener('click', () => request('Preview'));
  el('port').addEventListener('input', invalidate);
  el('target').addEventListener('change', invalidate);
  el('close').addEventListener('click', close);
  el('dialog').addEventListener('cancel', close);
  el('dialog').addEventListener('close', () => { invalidate();targets=[];el('port').value=''; });
})();
