'use strict';
(() => {
  const el = id => document.querySelector('#run-artifact-' + id);
  const contract = 'SqlServerLab.RunArtifactRemovalBrowser/1.0';
  const shape = (v,names) => v !== null && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === names.length && Object.keys(v).every(n => names.includes(n));
  const guid = v => typeof v === 'string' && /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/.test(v);
  const notice = 'Nur Run-Metadaten werden endgültig entfernt. Abschlussreceipt bleibt erhalten. Providerressourcen und Sicherungen bleiben erhalten.';
  const unconfirmed = 'Entfernung nicht bestätigt. Derselbe Run kann eine begonnene Entfernung haben. Metadaten erneut lesen und frisch vorprüfen; keine automatische Wiederholung.';
  let revision = 0, targets = [], preview = null, busy = false, pendingApply = false;
  function controls() {
    const selected = targets.find((t,index) => String(index) === el('target').value);
    el('target').disabled = pendingApply || !targets.length;
    el('read').disabled = busy || pendingApply;
    el('preview').disabled = busy || pendingApply || !selected;
    el('confirm').disabled = busy || pendingApply || preview?.CanApply !== true;
    el('apply').disabled = busy || pendingApply || preview?.CanApply !== true || el('confirm').checked !== true;
  }
  function invalidate() { revision++; busy = false; preview = null; el('confirm').checked = false; el('result').textContent = ''; controls(); }
  function close() { invalidate(); targets = []; el('target').replaceChildren(); el('dialog').close(); controls(); }
  function validPreview(v,runId) {
    if (!shape(v,['ContractVersion','RunId','Status','CanApply','FileCount','ReasonCode','PreviewToken']) || v.ContractVersion !== contract || v.RunId !== runId || !guid(v.RunId) ||
      !['READY','RECOVERY_REQUIRED','REMOVED','BLOCKED'].includes(v.Status) || typeof v.CanApply !== 'boolean' || !Number.isInteger(v.FileCount) || v.FileCount < 0 || v.FileCount > 2147483647) return false;
    if (['READY','RECOVERY_REQUIRED'].includes(v.Status)) return v.CanApply === true && typeof v.PreviewToken === 'string' && /^[a-f0-9]{32}$/.test(v.PreviewToken) && v.ReasonCode === null;
    return v.CanApply === false && v.PreviewToken === null && v.FileCount === 0 && (v.Status === 'REMOVED' ? v.ReasonCode === null : typeof v.ReasonCode === 'string' && /^RUN_ARTIFACT_[A-Z_]+$/.test(v.ReasonCode));
  }
  function reason(code) {
    const reasons = {
      RUN_ARTIFACT_HYPERV_ABSENCE_UNVERIFIABLE:'Hyper-V: Physische VHDX-Abwesenheit ist nicht sicher nachweisbar. Artefakte bleiben erhalten.',
      RUN_ARTIFACT_CLEANUP_INCOMPLETE:'Der reguläre Cleanup ist unvollständig. Zuerst den gebundenen Cleanup-/Recovery-Vorgang klären.',
      RUN_ARTIFACT_RESOURCE_PRESENT:'Gebundene Providerressourcen sind noch vorhanden. Dieser Dialog entfernt sie nicht.',
      RUN_ARTIFACT_ORIGINAL_RUNTIME_UNVERIFIABLE:'Die ursprüngliche Runtimebindung ist nicht verifizierbar.',
      RUN_ARTIFACT_RETAINED_OR_PROTECTED:'Retention, persistente Daten oder geschützte Referenzen sperren die Entfernung.',
      RUN_ARTIFACT_REFERENCED_OR_RETAINED:'Retention, persistente Daten oder geschützte Referenzen sperren die Entfernung.',
      RUN_ARTIFACT_PROTECTED_GROUP:'Eine geschützte Gruppe sperrt die Entfernung.',
      RUN_ARTIFACT_RECOVERY_REQUIRED:'Recovery-Evidence sperrt die Entfernung. Zuerst den ursprünglichen Vorgang klären.'
    };
    return reasons[code] || 'Die erforderliche Evidence ist nicht vollständig verifizierbar. Artefakte erhalten und den gebundenen Vorgang klären.';
  }
  async function request(action) {
    if (busy || pendingApply || !el('dialog').open) return;
    const selected = targets.find((t,index) => String(index) === el('target').value);
    if (action !== 'Read' && !selected) return;
    if (action === 'Apply' && (preview?.CanApply !== true || preview.RunId !== selected.RunId || el('confirm').checked !== true)) return;
    const payload = action === 'Read' ? {Action:'Read'} : action === 'Preview' ? {Action:'Preview',RunId:selected.RunId} : {Action:'Apply',RunId:selected.RunId,PreviewToken:preview.PreviewToken,Confirmed:true};
    invalidate(); const current = revision; busy = true; pendingApply = action === 'Apply';
    if (action === 'Read') { targets = []; el('target').replaceChildren(); }
    el('status').textContent = action === 'Apply' ? 'Entfernung angefordert. Schließen beendet nur die Anzeige; der Vorgang kann weiterlaufen.' : action === 'Read' ? 'Run-Metadaten werden gelesen.' : 'Gebundenen Run prüfen …';
    controls();
    try {
      const response = await fetch('/api/run-artifact-removal',{method:'POST',headers:{'Content-Type':'application/json; charset=utf-8'},body:JSON.stringify(payload)});
      if (current !== revision || !el('dialog').open) return;
      if (!response.ok) throw new Error('UNCONFIRMED');
      const view = await response.json();
      if (current !== revision || !el('dialog').open) return;
      if (new TextEncoder().encode(JSON.stringify(view)).length > 1048576) throw new Error('UNCONFIRMED');
      if (action === 'Read') {
        if (!shape(view,['ContractVersion','Status','CanApply','Targets']) || view.ContractVersion !== contract || view.Status !== 'METADATA_ONLY' || view.CanApply !== false || !Array.isArray(view.Targets) || view.Targets.length > 4096 ||
          !view.Targets.every(t => shape(t,['RunId']) && guid(t.RunId)) || new Set(view.Targets.map(t => t.RunId)).size !== view.Targets.length) throw new Error('UNCONFIRMED');
        targets = view.Targets;
        const placeholder = document.createElement('option'); placeholder.value = ''; placeholder.textContent = 'Bitte einen Run auswählen'; el('target').appendChild(placeholder);
        for (const [index,t] of targets.entries()) { const option = document.createElement('option'); option.value = String(index); option.textContent = 'Run / Artefaktvorgang · ' + t.RunId; el('target').appendChild(option); }
        el('status').textContent = targets.length ? 'Nur Metadaten gelesen. Einzelauswahl ist keine Löschberechtigung; Vorschau bewusst anfordern.' : 'Keine entfernten Runs oder Artefaktvorgänge im aktuellen Lab-Datenbereich.';
      } else if (action === 'Preview') {
        if (!validPreview(view,selected.RunId)) throw new Error('UNCONFIRMED');
        preview = view;
        el('result').textContent = 'Run: ' + view.RunId + '\nArtefaktstatus: ' + view.Status + '\nMetadatendateien: ' + view.FileCount + '\n' + notice;
        el('status').textContent = view.Status === 'BLOCKED' ? reason(view.ReasonCode) : view.Status === 'REMOVED' ? 'Die Artefaktentfernung ist bereits abgeschlossen.' : view.Status === 'RECOVERY_REQUIRED' ? 'Begonnene Entfernung nur vorwärts fortsetzen. Entfernte Metadaten werden nicht wiederhergestellt. Vorschau gilt fünf Minuten; erneut bestätigen.' : 'Entfernung möglich. Vorschau gilt fünf Minuten; genau diesen Run separat bestätigen.';
        el('apply').textContent = view.Status === 'RECOVERY_REQUIRED' ? 'Artefaktentfernung fortsetzen' : 'Geprüfte Metadaten endgültig entfernen';
      } else {
        if (!shape(view,['ContractVersion','RunId','Status','Changed']) || view.ContractVersion !== contract || view.RunId !== selected.RunId || !['REMOVED','CANCELLED'].includes(view.Status) || typeof view.Changed !== 'boolean' || (view.Status === 'CANCELLED' && view.Changed)) throw new Error('UNCONFIRMED');
        el('result').textContent = 'Run: ' + view.RunId + '\nArtefaktentfernung: ' + view.Status + '\n' + notice;
        el('status').textContent = view.Status === 'CANCELLED' ? 'Entfernung abgebrochen.' : view.Changed ? 'Geprüfte Run-Metadaten entfernt. Abschlussreceipt bleibt erhalten.' : 'Artefaktentfernung war bereits abgeschlossen.';
      }
    } catch { if (current === revision && el('dialog').open) { preview = null; el('result').textContent = ''; el('status').textContent = unconfirmed; } }
    finally {
      if (action === 'Apply') pendingApply = false;
      if (current === revision) busy = false;
      controls();
    }
  }
  el('open').addEventListener('click', () => { invalidate(); targets = []; el('target').replaceChildren(); el('dialog').showModal(); el('status').textContent = pendingApply ? unconfirmed : notice; controls(); request('Read'); });
  el('read').addEventListener('click', () => request('Read'));
  el('preview').addEventListener('click', () => request('Preview'));
  el('apply').addEventListener('click', () => request('Apply'));
  el('target').addEventListener('change', () => { invalidate(); el('status').textContent = 'Auswahl geändert; Vorschau erneut anfordern.'; });
  el('confirm').addEventListener('change', controls);
  el('close').addEventListener('click', close);
  el('dialog').addEventListener('cancel', close);
  el('dialog').addEventListener('close', () => { invalidate(); targets = []; el('target').replaceChildren(); controls(); });
})();
