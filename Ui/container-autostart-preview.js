'use strict';
(() => {
  const el = id => document.querySelector('#autostart-preview-' + id);
  const shape = (v, names) => v !== null && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === names.length && Object.keys(v).every(n => names.includes(n));
  const guid = v => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(v);
  const targetValid = t => shape(t, ['RunId','InstanceId','Provider']) && guid(t.RunId) && typeof t.InstanceId === 'string' && /^[A-Za-z][A-Za-z0-9_-]{0,63}$/.test(t.InstanceId) && ['docker','podman'].includes(t.Provider);
  const reasons = ['AUTOSTART_PREVIEW_BINDING_UNAVAILABLE','AUTOSTART_PREVIEW_PROVIDER_UNSUPPORTED','AUTOSTART_PREVIEW_PROTECTED_TARGET','AUTOSTART_PREVIEW_RUNNING_REQUIRED','AUTOSTART_PREVIEW_POLICY_UNKNOWN','AUTOSTART_PREVIEW_POLICY_UNSUPPORTED','AUTOSTART_PREVIEW_POLICY_DRIFTED','AUTOSTART_PREVIEW_JOURNAL_BLOCKED','AUTOSTART_PREVIEW_TOPOLOGY_UNSUPPORTED','AUTOSTART_PREVIEW_LIMITS_UNKNOWN','AUTOSTART_PREVIEW_MOUNTS_UNSUPPORTED','AUTOSTART_PREVIEW_APPLY_NOT_IMPLEMENTED'];
  function validPlan(v, provider) {
    if (!shape(v,['Contract','Mode','Status','Reason','Provider','ObservationKey','Actual','Desired','NoChange','ChangeClass','CanApply','MutationAllowed','Actions','Preview']) ||
      !shape(v.Contract,['Name','Version']) || v.Contract.Name !== 'SqlServerLab.ContainerAutoStartPreview' || v.Contract.Version !== '1.0' || v.Mode !== 'CONTAINER_AUTOSTART_PREVIEW_PLAN_ONLY' ||
      !['PLAN_ONLY','BLOCKED','UNSUPPORTED'].includes(v.Status) || !reasons.includes(v.Reason) || v.CanApply !== false || v.MutationAllowed !== false || !Array.isArray(v.Actions) || v.Actions.length ||
      !shape(v.Actual,['Evidence','SqlBinding','Lifecycle','AutoStart']) || !shape(v.Desired,['AutoStartChange']) || !shape(v.Preview,['Downtime','Endpoint','Sql','Backup','HostLogin','DataImpact','Mounts']) ||
      v.Preview.Endpoint !== 'NOT_CHECKED' || v.Preview.Sql !== 'NOT_CHECKED' || v.Preview.Backup !== 'NOT_CHECKED' || v.Preview.HostLogin !== 'NOT_CHECKED' || v.Preview.DataImpact !== 'NOT_VERIFIED' || ![null,'docker','podman'].includes(v.Provider)) return false;
    if (v.Status !== 'PLAN_ONLY') return v.Provider === null && v.Actual.AutoStart === (v.Reason === 'AUTOSTART_PREVIEW_POLICY_DRIFTED' ? 'DRIFTED' : 'UNKNOWN') && v.ObservationKey === null && v.NoChange === null && v.ChangeClass === 'unsupported' && v.Actual.Evidence === 'UNKNOWN' && v.Actual.SqlBinding === 'UNKNOWN' && v.Actual.Lifecycle === 'UNKNOWN' && v.Desired.AutoStartChange === 'UNKNOWN' && v.Preview.Downtime === 'UNKNOWN' && v.Preview.Mounts === null;
    const m = v.Preview.Mounts;
    return v.Provider === provider && v.Reason === 'AUTOSTART_PREVIEW_APPLY_NOT_IMPLEMENTED' && typeof v.ObservationKey === 'string' && /^[a-f0-9]{64}$/.test(v.ObservationKey) && typeof v.NoChange === 'boolean' &&
      v.Actual.Evidence === 'MEASURED' && v.Actual.SqlBinding === 'SINGLE_LOOPBACK_1433_TCP' && v.Actual.Lifecycle === 'RUNNING' && ['ON','OFF'].includes(v.Actual.AutoStart) && v.Desired.AutoStartChange === (v.NoChange ? 'SAME_POLICY' : 'DIFFERENT_POLICY') && v.ChangeClass === (v.NoChange ? 'no-op' : 'recreate') && v.Preview.Downtime === (v.NoChange ? 'NONE' : 'REQUIRED') &&
      shape(m,['Status','TotalMountCount','VolumeMountCount','HostBindCount','WritableHostBindCount','OtherMountCount','VolumeOwnership']) && m.Status === 'MEASURED' && m.VolumeOwnership === 'NOT_CHECKED' &&
      ['TotalMountCount','VolumeMountCount','HostBindCount','WritableHostBindCount','OtherMountCount'].every(n => Number.isInteger(m[n]) && m[n] >= 0 && m[n] <= 1024) && m.TotalMountCount === m.VolumeMountCount + m.HostBindCount + m.OtherMountCount && m.WritableHostBindCount <= m.HostBindCount;
  }
  let revision = 0, targets = [], busy = false;
  function invalidate() { revision++; busy = false; el('result').textContent = ''; el('plan').disabled = false; el('read').disabled = false; el('status').textContent = 'Hostlogin, Endpoint, SQL, Backup und Volumeeigentum: NOT_CHECKED. Datenerhalt: NOT_VERIFIED.'; }
  function close() { invalidate(); targets = []; el('target').replaceChildren(); el('target').disabled = true; el('policy').value = ''; el('dialog').close(); }
  async function request(action) {
    if (busy || !el('dialog').open) return;
    const selected = targets.find((t, index) => String(index) === el('target').value);
    const policy = el('policy').value;
    if (action === 'Preview' && (!selected || !['on','off'].includes(policy))) { invalidate(); el('status').textContent = 'Vollständiges Ziel und Autostart on/off auswählen.'; return; }
    invalidate(); const current = revision; busy = true; el('plan').disabled = true; el('read').disabled = true;
    const payload = action === 'Read' ? {Action:'Read'} : {Action:'Preview',RunId:selected.RunId,InstanceId:selected.InstanceId,AutoStart:policy};
    try {
      const response = await fetch('/api/container-autostart-preview',{method:'POST',headers:{'Content-Type':'application/json; charset=utf-8'},body:JSON.stringify(payload)});
      if (current !== revision || !el('dialog').open) return;
      if (!response.ok) throw new Error('INVALID');
      const view = await response.json();
      if (current !== revision || !el('dialog').open) return;
      if (new TextEncoder().encode(JSON.stringify(view)).length > 1048576) throw new Error('INVALID');
      if (action === 'Read') {
        if (!shape(view,['ContractVersion','Status','Targets','CanApply','MutationAllowed','Actions']) || view.ContractVersion !== 'SqlServerLab.ContainerAutoStartBrowser/1.0' || view.Status !== 'METADATA_ONLY' || view.CanApply !== false || view.MutationAllowed !== false || !Array.isArray(view.Actions) || view.Actions.length || !Array.isArray(view.Targets) || view.Targets.length > 4096 || !view.Targets.every(targetValid) || new Set(view.Targets.map(t => t.RunId+'|'+t.InstanceId)).size !== view.Targets.length) throw new Error('INVALID');
        targets = view.Targets; el('target').replaceChildren();
        for (const [index,t] of targets.entries()) { const option=document.createElement('option');option.value=String(index);option.textContent=t.RunId+' · '+t.InstanceId+' · '+t.Provider;el('target').appendChild(option); }
        el('target').disabled = !targets.length;el('status').textContent = targets.length ? 'Registrierte Metadaten gelesen. Keine Runtimeprüfung; Autostart on/off auswählen.' : 'Keine gebundene laufende SQL-Instanz verfügbar.';
      } else {
        if (!validPlan(view, selected.Provider)) throw new Error('INVALID');
        let result = 'PLAN_ONLY · CanApply=false · MutationAllowed=false · Actions: 0 · keine Änderung oder Reservierung.\nHostlogin, Endpoint, SQL, Backup und Volumeeigentum: NOT_CHECKED. Datenerhalt: NOT_VERIFIED.\n';
        if (view.Status === 'PLAN_ONLY') { const m=view.Preview.Mounts;result += 'Istpolicy: '+view.Actual.AutoStart+' · '+view.Desired.AutoStartChange+' · '+view.ChangeClass+' · Ausfallzeit: '+view.Preview.Downtime+'\nMounts: '+m.TotalMountCount+' gesamt; '+m.VolumeMountCount+' Volumes; '+m.HostBindCount+' Host-Bindings ('+m.WritableHostBindCount+' schreibbar); '+m.OtherMountCount+' andere.\nInhaltsbindung vorhanden; keine Ausführungsautorität.'; }
        else result += 'Vorschau blockiert oder Topologie nicht unterstützt. Istpolicy: '+view.Actual.AutoStart+'.';
        el('result').textContent = result;
      }
    } catch { if (current === revision && el('dialog').open) { el('result').textContent = '';el('status').textContent = 'AUTOSTART_HTTP_INVALID: Auswahl oder Vorschau nicht sicher bestätigt.';if (action === 'Read') {targets=[];el('target').replaceChildren();el('target').disabled=true;} } }
    finally { if (current === revision && el('dialog').open) {busy=false;el('read').disabled=false;el('plan').disabled=!targets.length;} }
  }
  el('open').addEventListener('click', () => { invalidate();targets=[];el('target').replaceChildren();el('target').disabled=true;el('policy').value='';el('dialog').showModal();request('Read'); });
  el('read').addEventListener('click', () => request('Read'));
  el('plan').addEventListener('click', () => request('Preview'));
  el('policy').addEventListener('input', invalidate);
  el('target').addEventListener('change', invalidate);
  el('close').addEventListener('click', close);
  el('dialog').addEventListener('cancel', close);
  el('dialog').addEventListener('close', () => { invalidate();targets=[];el('policy').value=''; });
})();
