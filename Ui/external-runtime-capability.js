'use strict';
(() => {
  const element = id => document.querySelector('#external-runtime-' + id);
  const shape = (v, names) => v !== null && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === names.length && Object.keys(v).every(k => names.includes(k));
  const catalogs = ['NONE','CATALOG_DECISION_UNAVAILABLE','SOFTWARE_NOT_CATALOGUED','SQL_VERSION_UNKNOWN','RUNTIME_COMBINATION_NOT_CATALOGUED','SOFTWARE_PLAN_AMBIGUOUS','LEGACY_POST_START_MUTATION','IMAGE_BINDING_NOT_IMPLEMENTED','PACKAGE_NOT_LOCKED','VARIANT_PREVIEW','VARIANT_UNSUPPORTED','PROVIDER_CAPABILITY_MISSING','ARTIFACT_INTEGRITY_INCOMPLETE','PACKAGE_LOCK_INTEGRITY_INCOMPLETE'];
  const readiness = ['NONE','READINESS_NOT_REQUESTED','CATALOG_BLOCKED','TOOL_NOT_INSTALLED','TOOL_NATIVE_PATH_REQUIRED','PROVIDER_PROBE_FAILED','PROVIDER_PROBE_TIMEOUT','PROVIDER_OUTPUT_LIMIT','PROVIDER_TERMINATION_UNCONFIRMED','PROVIDER_RESPONSE_INVALID','CGROUP_V2_REQUIRES_SQL2025','LINUX_RUNTIME_REQUIRED','CGROUP_VERSION_UNSUPPORTED','ROOTFUL_STATUS_UNKNOWN','ROOTFUL_PROVIDER_REQUIRED'];
  const identity = v => ['sql-python','sql-r','sql-java'].includes(v.SoftwareId) && ['Python','R','Java'].includes(v.Language) && typeof v.VariantId === 'string' && /^[a-z0-9][a-z0-9_-]{0,127}$/.test(v.VariantId) && typeof v.RuntimeVersion === 'string' && /^\d{1,3}(\.\d{1,3}){0,3}$/.test(v.RuntimeVersion);
  function decision(v) {
    if (!shape(v, ['Contract','Provider','OperatingSystem','Identity','CatalogDecision','CurrentReadiness','HistoricalEvidence','SqlLanguageExecution','TargetAuthorization','ExecutionSupported','MutationAllowed','Actions']) || !shape(v.Contract,['Name','Version','EvidenceBoundary']) || !shape(v.CatalogDecision,['Status','ReasonCode']) || !shape(v.CurrentReadiness,['Status','ReasonCode','RequiredCgroupVersion','LaunchMode']) || !shape(v.HistoricalEvidence,['Status','MappingStatus'])) return false;
    if (v.Contract.Name !== 'SqlServerLab.ExternalRuntimeCapability' || v.Contract.Version !== '1.0' || v.Contract.EvidenceBoundary !== 'PROSPECTIVE_DECLARATION_AND_OPTIONAL_HOST_OBSERVATION' || !['docker','podman'].includes(v.Provider) || v.OperatingSystem !== 'linux' || !['DECLARED_SUPPORTED','BLOCKED'].includes(v.CatalogDecision.Status) || !catalogs.includes(v.CatalogDecision.ReasonCode) || !['NOT_CHECKED','READY','BLOCKED'].includes(v.CurrentReadiness.Status) || !readiness.includes(v.CurrentReadiness.ReasonCode) || v.HistoricalEvidence.Status !== 'NOT_RECORDED' || v.HistoricalEvidence.MappingStatus !== 'NOT_DEFINED' || v.SqlLanguageExecution !== 'NOT_CHECKED' || v.TargetAuthorization !== 'NOT_CHECKED' || v.ExecutionSupported !== false || v.MutationAllowed !== false || !Array.isArray(v.Actions) || v.Actions.length) return false;
    if (![null,'1','2'].includes(v.CurrentReadiness.RequiredCgroupVersion) || ![null,'sql2019-namespace-v1','sql2022-namespace-v1','sql2025-namespace-v1','sql2025-shared-user-v2'].includes(v.CurrentReadiness.LaunchMode)) return false;
    if (v.CatalogDecision.Status === 'BLOCKED') { if (v.Identity !== null || v.CatalogDecision.ReasonCode === 'NONE' || v.CurrentReadiness.Status === 'READY') return false; }
    else if (!shape(v.Identity,['SoftwareId','VariantId','RuntimeVersion','Language','SqlVersion']) || !identity(v.Identity) || typeof v.Identity.SqlVersion !== 'string' || !/^\d{4}$/.test(v.Identity.SqlVersion) || v.CatalogDecision.ReasonCode !== 'NONE' || v.CurrentReadiness.RequiredCgroupVersion === null || v.CurrentReadiness.LaunchMode === null) return false;
    return v.CurrentReadiness.Status === 'READY' ? v.CurrentReadiness.ReasonCode === 'NONE' : v.CurrentReadiness.Status === 'NOT_CHECKED' ? v.CurrentReadiness.ReasonCode === 'READINESS_NOT_REQUESTED' : !['NONE','READINESS_NOT_REQUESTED'].includes(v.CurrentReadiness.ReasonCode);
  }
  let revision = 0, busy = false, options = [];
  const selected = () => /^\d+$/.test(element('choice').value) ? options[Number(element('choice').value)] : undefined;
  function controls() {
    for (const id of ['provider','sql','read','choice']) element(id).disabled = busy;
    for (const id of ['evaluate','host']) element(id).disabled = busy || selected()?.Decision.CatalogDecision.Status !== 'DECLARED_SUPPORTED';
  }
  function clear() {
    revision++; busy = false; options = []; element('choice').replaceChildren(); element('result').textContent = ''; element('status').textContent = 'Host: NOT_CHECKED'; controls();
  }
  async function request(action, check = false) {
    if (busy || !element('dialog').open) return;
    const provider = element('provider').value, sql = element('sql').value, choice = selected();
    if (!['docker','podman'].includes(provider) || !['2019','2022','2025'].includes(sql) || (action === 'Evaluate' && choice?.Decision.CatalogDecision.Status !== 'DECLARED_SUPPORTED')) return;
    const payload = {Action: action, SqlVersion: sql, Provider: provider, OperatingSystem: 'linux'};
    if (action === 'Evaluate') Object.assign(payload,{SoftwareId:choice.SoftwareId,RuntimeVersion:choice.RuntimeVersion,VariantId:choice.VariantId,CheckProviderReadiness:check});
    const current = ++revision; busy = true; element('result').textContent = ''; controls();
    try {
      const response = await sqlServerLabUiFetch('/api/external-runtime-capability',{method:'POST',headers:{'Content-Type':'application/json; charset=utf-8'},body:JSON.stringify(payload)});
      if (current !== revision || !element('dialog').open) return;
      if (!response.ok) throw new Error('INVALID');
      const view = await response.json();
      if (current !== revision || !element('dialog').open) return;
      if (view.ContractVersion !== 'SqlServerLab.ExternalRuntimeCapabilityBrowser/1.0') throw new Error('INVALID');
      if (action === 'ReadOptions') {
        if (!shape(view,['ContractVersion','Status','Options']) || view.Status !== 'OPTIONS' || !Array.isArray(view.Options) || view.Options.length > 128 || view.Options.some(o => !shape(o,['SoftwareId','Language','VariantId','RuntimeVersion','Decision']) || !identity(o) || !decision(o.Decision) || o.Decision.Provider !== provider || o.Decision.CurrentReadiness.Status !== 'NOT_CHECKED' || (o.Decision.Identity && (o.Decision.Identity.VariantId !== o.VariantId || o.Decision.Identity.SoftwareId !== o.SoftwareId || o.Decision.Identity.RuntimeVersion !== o.RuntimeVersion || o.Decision.Identity.SqlVersion !== sql)))) throw new Error('INVALID');
        options = view.Options; element('choice').replaceChildren();
        const placeholder = document.createElement('option'); placeholder.value = ''; placeholder.textContent = 'Variante bewusst auswählen'; element('choice').appendChild(placeholder);
        options.forEach((o,i) => {const item=document.createElement('option');item.value=String(i);item.disabled=o.Decision.CatalogDecision.Status !== 'DECLARED_SUPPORTED';item.textContent=o.Language+' '+o.RuntimeVersion+' · '+o.VariantId+' · '+o.Decision.CatalogDecision.Status+' / '+o.Decision.CatalogDecision.ReasonCode;element('choice').appendChild(item);});
        element('choice').value = ''; element('status').textContent = 'Katalog gelesen · Host: NOT_CHECKED';
      } else {
        if (!shape(view,['ContractVersion','Status','Decision']) || view.Status !== 'DECISION' || !decision(view.Decision) || view.Decision.Provider !== provider || (!check && view.Decision.CurrentReadiness.Status !== 'NOT_CHECKED') || (view.Decision.Identity && (view.Decision.Identity.SoftwareId !== choice.SoftwareId || view.Decision.Identity.VariantId !== choice.VariantId || view.Decision.Identity.RuntimeVersion !== choice.RuntimeVersion || view.Decision.Identity.SqlVersion !== sql))) throw new Error('INVALID');
        const d=view.Decision; element('result').textContent='Katalog: '+d.CatalogDecision.Status+' / '+d.CatalogDecision.ReasonCode+'\nHostvoraussetzungen: '+d.CurrentReadiness.Status+' / '+d.CurrentReadiness.ReasonCode+'\nSQL-Sprachausführung: NOT_CHECKED\nZielautorisierung: NOT_CHECKED\nHistorie: NOT_RECORDED / NOT_DEFINED\nKeine Ausführungsfreigabe.';
        element('status').textContent = 'Entscheidung gelesen.';
      }
    } catch {if(current===revision && element('dialog').open) {clear();element('status').textContent='Entscheidung nicht bestätigt. Eingaben prüfen und bewusst erneut lesen.';}}
    finally {if(current===revision){busy=false;controls();}}
  }
  element('open').addEventListener('click',()=>{clear();element('dialog').showModal();});
  element('read').addEventListener('click',()=>request('ReadOptions'));
  element('evaluate').addEventListener('click',()=>request('Evaluate'));
  element('host').addEventListener('click',()=>request('Evaluate',true));
  for(const id of ['provider','sql']) element(id).addEventListener('change',clear);
  element('choice').addEventListener('change',()=>{revision++;element('result').textContent='';controls();});
  element('close').addEventListener('click',()=>{clear();element('dialog').close();});
  for(const event of ['cancel','close']) element('dialog').addEventListener(event,clear);
  controls();
})();
