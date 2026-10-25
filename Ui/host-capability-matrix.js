'use strict';
(() => {
  const element = id => document.querySelector('#host-matrix-' + id);
  const shape = (value, names) => value !== null && typeof value === 'object' && !Array.isArray(value) && Object.keys(value).length === names.length && Object.keys(value).every(key => names.includes(key));
  const providers = ['docker','podman','hyperv'];
  const unknown = ['SQL_BUILD','GUEST_OPERATING_SYSTEM','KERNEL_AND_CGROUP_CONTROLLERS','WSL_SHARED_KERNEL','ROOTLESS_AND_LAUNCH_MODE','RESOURCES','TARGET_AUTHORIZATION','HISTORICAL_EVIDENCE','SQL_LANGUAGE_EXECUTION'];
  const providerCodes = ['PROVIDER_NOT_CHECKED','PROVIDER_OBSERVATION_INVALID','DIAGNOSTIC_READINESS_FAILED','DIAGNOSTIC_READINESS_TIMEOUT','DIAGNOSTIC_READINESS_OUTPUT_LIMIT','DIAGNOSTIC_READINESS_TERMINATION_UNCONFIRMED','DIAGNOSTIC_READINESS_RESPONSE_INVALID','PROVIDER_REACHABLE','PROVIDER_OS_UNSUPPORTED','TOOL_NOT_INSTALLED','PROVIDER_NOT_INSTALLED','PROVIDER_INSTALLATION_INCOMPLETE','TOOL_RESOLUTION_FAILED','TOOL_NATIVE_PATH_REQUIRED','PROVIDER_ACCESS_DENIED','TOOL_EXECUTION_DENIED','PROVIDER_UNREACHABLE','PROVIDER_PROBE_TIMEOUT','PROVIDER_PROBE_FAILED','PROVIDER_RESPONSE_INVALID'];
  const catalogCodes = ['NONE','CATALOG_DECISION_UNAVAILABLE','SOFTWARE_NOT_CATALOGUED','SQL_VERSION_UNKNOWN','RUNTIME_COMBINATION_NOT_CATALOGUED','SOFTWARE_PLAN_AMBIGUOUS','LEGACY_POST_START_MUTATION','IMAGE_BINDING_NOT_IMPLEMENTED','PACKAGE_NOT_LOCKED','VARIANT_PREVIEW','VARIANT_UNSUPPORTED','PROVIDER_CAPABILITY_MISSING','ARTIFACT_INTEGRITY_INCOMPLETE','PACKAGE_LOCK_INTEGRITY_INCOMPLETE','LANGUAGE_USER_DEFERRED'];
  const steps = {RECHECK_CATALOG:'Katalog erneut prüfen',REVIEW_CATALOG_SCOPE:'Katalogzuordnung prüfen',CHECK_PROVIDER_READINESS:'Provider bewusst lesend prüfen',REVIEW_PROVIDER_READINESS:'Fehlende Providervoraussetzung prüfen',ASSESS_LAUNCH_REQUIREMENTS:'Konkrete Launchanforderungen noch prüfen',RECHECK_PROVIDER_READINESS:'Providerentscheidung erneut prüfen',USER_DECISION_REQUIRED:'Durch Benutzerentscheidung zurückgestellt'};
  const states = {UNKNOWN:'Ungeklärt',CATALOG_BLOCKED:'Kataloganforderung nicht aufgelöst',NOT_CHECKED:'Provider nicht geprüft',PRECONDITION_MISSING:'Providervoraussetzung fehlt',INCOMPLETE:'Provider erreichbar; Launchanforderungen ungeprüft',USER_DEFERRED:'Zurückgestellt'};
  const presence = {UNKNOWN:'Ungeklärt',PRESENT:'Werkzeug vorhanden',MISSING:'Nicht installiert',INCOMPLETE:'Installation unvollständig',HOST_UNSUPPORTED:'Hostsystem nicht unterstützt'};
  const readiness = {NOT_CHECKED:'Nicht geprüft',UNKNOWN:'Ungeklärt',READY:'Erreichbar',NOT_READY:'Nicht bereit'};
  const reasons = {PROVIDER_NOT_CHECKED:'Provider wurde noch nicht abgefragt.',PROVIDER_REACHABLE:'Die Verwaltungsschnittstelle ist erreichbar.',TOOL_NOT_INSTALLED:'Das Providerwerkzeug fehlt.',PROVIDER_NOT_INSTALLED:'Das Providermodul fehlt.',PROVIDER_OS_UNSUPPORTED:'Der Provider benötigt ein anderes Hostbetriebssystem.',PROVIDER_INSTALLATION_INCOMPLETE:'Benötigte Verwaltungswerkzeuge fehlen.',PROVIDER_ACCESS_DENIED:'Verwaltungsrechte fehlen.',TOOL_EXECUTION_DENIED:'Die Werkzeugausführung wurde verweigert.',PROVIDER_UNREACHABLE:'Die Runtime ist nicht erreichbar.',PROVIDER_PROBE_TIMEOUT:'Die Runtimeantwort wurde nicht rechtzeitig bestätigt.',PROVIDER_RESPONSE_INVALID:'Die Runtimeantwort ist nicht auswertbar.',RUNTIME_COMBINATION_NOT_CATALOGUED:'Für dieses SQL-/Provider-/Gastziel ist keine passende Variante katalogisiert.',HOST_REQUIREMENTS_NOT_CHECKED:'Die konkreten Launchanforderungen sind noch ungeprüft.',LANGUAGE_USER_DEFERRED:'C# bleibt durch Benutzerentscheidung zurückgestellt.'};
  const reasonText = code => `${reasons[code] ?? 'Eine verlässliche Entscheidung ist noch offen.'} (${code})`;
  const timestamp = value => typeof value === 'string' && /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{7}Z$/.test(value) && Number.isFinite(Date.parse(value));
  let revision = 0, busy = false, active = null;
  function controls() {
    element('sql').disabled = busy; element('provider').disabled = busy; element('versions').disabled = busy;
    element('read').disabled = busy || !/^\d{4}$/.test(element('sql').value);
    element('probe').disabled = element('read').disabled || !providers.includes(element('provider').value);
  }
  function clearResult() {
    revision++; element('providers').replaceChildren(); element('rows').replaceChildren();
    element('scope').textContent = ''; element('unassessed').textContent = ''; element('status').textContent = 'Host: NOT_CHECKED'; controls();
  }
  function validMatrix(matrix, sql, selected, probe) {
    if (!shape(matrix,['Contract','Feature','SqlVersion','HostOperatingSystem','GeneratedAtUtc','CatalogFingerprint','ProviderProfile','Providers','Capabilities','Unassessed','ManufacturerSupport','ProjectAcceptance','ExecutionSupported','MutationAllowed','Actions']) ||
        !shape(matrix.Contract,['Name','Version','EvidenceBoundary']) || matrix.Contract.Name !== 'SqlServerLab.HostCapabilityMatrix' || matrix.Contract.Version !== '1.0' || matrix.Contract.EvidenceBoundary !== 'CATALOG_AND_OPTIONAL_PROVIDER_BOOTSTRAP_ONLY' || matrix.Feature !== 'SqlExternalRuntime' || matrix.SqlVersion !== sql ||
        !['windows','linux','unknown'].includes(matrix.HostOperatingSystem) || !timestamp(matrix.GeneratedAtUtc) || typeof matrix.CatalogFingerprint !== 'string' || !/^[a-f0-9]{64}$/.test(matrix.CatalogFingerprint) || matrix.ManufacturerSupport !== 'NOT_ASSESSED' || matrix.ProjectAcceptance !== 'NOT_ASSESSED' || matrix.ExecutionSupported !== false || matrix.MutationAllowed !== false || !Array.isArray(matrix.Actions) || matrix.Actions.length !== 0 ||
        !Array.isArray(matrix.Unassessed) || matrix.Unassessed.join(',') !== unknown.join(',') || !Array.isArray(matrix.Providers) || matrix.Providers.map(item => item?.Provider).join(',') !== selected.join(',')) return false;
    if (!['NO_PROVIDER','DOCKER_ONLY','PODMAN_ONLY','HYPERV_ONLY','DOCKER_PODMAN','DOCKER_HYPERV','PODMAN_HYPERV','ALL_PROVIDERS','NOT_CHECKED','UNKNOWN','PARTIAL_SELECTION'].includes(matrix.ProviderProfile) || (selected.length === 1 && matrix.ProviderProfile !== 'PARTIAL_SELECTION')) return false;
    for (const item of matrix.Providers) {
      if (!shape(item,['Provider','Presence','Readiness','ReasonCode','Source','ObservedAtUtc']) || !['UNKNOWN','PRESENT','MISSING','INCOMPLETE','HOST_UNSUPPORTED'].includes(item.Presence) || !['NOT_CHECKED','UNKNOWN','READY','NOT_READY'].includes(item.Readiness) || !providerCodes.includes(item.ReasonCode) || item.Source !== 'SqlServerLab.DiagnosticProviderReadiness/1.0') return false;
      if (probe ? item.Readiness === 'NOT_CHECKED' || !timestamp(item.ObservedAtUtc) : item.Readiness !== 'NOT_CHECKED' || item.Presence !== 'UNKNOWN' || item.ReasonCode !== 'PROVIDER_NOT_CHECKED' || item.ObservedAtUtc !== null) return false;
      const relation = ({PROVIDER_NOT_CHECKED:['UNKNOWN','NOT_CHECKED'],PROVIDER_REACHABLE:['PRESENT','READY'],TOOL_NOT_INSTALLED:['MISSING','NOT_READY'],PROVIDER_NOT_INSTALLED:['MISSING','NOT_READY'],PROVIDER_OS_UNSUPPORTED:['HOST_UNSUPPORTED','NOT_READY'],PROVIDER_INSTALLATION_INCOMPLETE:['INCOMPLETE','NOT_READY'],PROVIDER_ACCESS_DENIED:['PRESENT','NOT_READY'],TOOL_EXECUTION_DENIED:['PRESENT','NOT_READY'],PROVIDER_UNREACHABLE:['PRESENT','NOT_READY'],PROVIDER_PROBE_TIMEOUT:['PRESENT','NOT_READY'],PROVIDER_PROBE_FAILED:['PRESENT','NOT_READY'],PROVIDER_RESPONSE_INVALID:['PRESENT','UNKNOWN']})[item.ReasonCode] ?? ['UNKNOWN','UNKNOWN'];
      if (item.Presence !== relation[0] || item.Readiness !== relation[1]) return false;
      if (item.ReasonCode === 'PROVIDER_OS_UNSUPPORTED' && (item.Provider !== 'hyperv' || matrix.HostOperatingSystem === 'windows')) return false;
      if (item.Provider === 'hyperv' && matrix.HostOperatingSystem !== 'windows' && ['PROVIDER_REACHABLE','TOOL_NOT_INSTALLED','PROVIDER_NOT_INSTALLED','PROVIDER_INSTALLATION_INCOMPLETE','TOOL_RESOLUTION_FAILED','TOOL_NATIVE_PATH_REQUIRED','PROVIDER_ACCESS_DENIED','TOOL_EXECUTION_DENIED','PROVIDER_UNREACHABLE','PROVIDER_PROBE_TIMEOUT','PROVIDER_PROBE_FAILED','PROVIDER_RESPONSE_INVALID'].includes(item.ReasonCode)) return false;
    }
    if (selected.length === 3) {
      const profile = matrix.Providers.every(item => item.Readiness === 'NOT_CHECKED') ? 'NOT_CHECKED' : matrix.Providers.some(item => !['PRESENT','MISSING','HOST_UNSUPPORTED'].includes(item.Presence)) ? 'UNKNOWN' : ({'':'NO_PROVIDER',docker:'DOCKER_ONLY',podman:'PODMAN_ONLY',hyperv:'HYPERV_ONLY','docker+podman':'DOCKER_PODMAN','docker+hyperv':'DOCKER_HYPERV','podman+hyperv':'PODMAN_HYPERV','docker+podman+hyperv':'ALL_PROVIDERS'})[matrix.Providers.filter(item => item.Presence === 'PRESENT').map(item => item.Provider).join('+')];
      if (matrix.ProviderProfile !== profile) return false;
    }
    if (!Array.isArray(matrix.Capabilities) || matrix.Capabilities.length < 4 || matrix.Capabilities.length > 131) return false;
    for (const row of matrix.Capabilities) {
      if (!shape(row,['Provider','TargetOperatingSystem','Language','SoftwareId','VariantId','RuntimeVersion','CatalogStatus','CatalogReasonCode','Availability','ReasonCode','NextStep','RequiredCapabilities','ExplicitSelectionRequired']) || !selected.includes(row.Provider) || row.TargetOperatingSystem !== (row.Provider === 'hyperv' ? 'windows' : 'linux') || !['Python','R','Java','C#'].includes(row.Language) || !['DECLARED_SUPPORTED','BLOCKED','UNKNOWN','NOT_EVALUATED'].includes(row.CatalogStatus) || !catalogCodes.includes(row.CatalogReasonCode) || !Object.hasOwn(states,row.Availability) || ![...catalogCodes,...providerCodes,'HOST_REQUIREMENTS_NOT_CHECKED'].includes(row.ReasonCode) || !Object.hasOwn(steps,row.NextStep) || typeof row.ExplicitSelectionRequired !== 'boolean' || !Array.isArray(row.RequiredCapabilities) || row.RequiredCapabilities.length > 16 || row.RequiredCapabilities.some(value => typeof value !== 'string' || !/^[a-zA-Z][a-zA-Z0-9._-]{0,127}$/.test(value))) return false;
      if (row.Language === 'C#') {
        if (row.SoftwareId !== null || row.VariantId !== null || row.RuntimeVersion !== null || row.CatalogStatus !== 'NOT_EVALUATED' || row.CatalogReasonCode !== 'LANGUAGE_USER_DEFERRED' || row.Availability !== 'USER_DEFERRED' || row.ReasonCode !== 'LANGUAGE_USER_DEFERRED' || row.NextStep !== 'USER_DECISION_REQUIRED' || row.RequiredCapabilities.length !== 0 || row.ExplicitSelectionRequired) return false;
      } else {
        if (row.SoftwareId !== ({Python:'sql-python',R:'sql-r',Java:'sql-java'})[row.Language] || row.Availability === 'USER_DEFERRED' || row.CatalogStatus === 'NOT_EVALUATED' || (row.VariantId !== null && (typeof row.VariantId !== 'string' || !/^[a-z0-9][a-z0-9_-]{0,127}$/.test(row.VariantId))) || (row.RuntimeVersion !== null && (typeof row.RuntimeVersion !== 'string' || !/^\d{1,3}(\.\d{1,3}){0,3}$/.test(row.RuntimeVersion))) || (row.CatalogStatus === 'DECLARED_SUPPORTED' && (row.CatalogReasonCode !== 'NONE' || row.VariantId === null || row.RuntimeVersion === null))) return false;
        if ((row.VariantId === null) !== (row.RuntimeVersion === null) || (row.VariantId === null && (row.RequiredCapabilities.length !== 0 || row.ExplicitSelectionRequired))) return false;
        const observed = matrix.Providers.find(item => item.Provider === row.Provider);
        const expected = row.CatalogStatus === 'DECLARED_SUPPORTED' ? ({NOT_CHECKED:['NOT_CHECKED',observed.ReasonCode,'CHECK_PROVIDER_READINESS'],NOT_READY:['PRECONDITION_MISSING',observed.ReasonCode,'REVIEW_PROVIDER_READINESS'],READY:['INCOMPLETE','HOST_REQUIREMENTS_NOT_CHECKED','ASSESS_LAUNCH_REQUIREMENTS'],UNKNOWN:['UNKNOWN',observed.ReasonCode,'RECHECK_PROVIDER_READINESS']})[observed.Readiness] : row.CatalogStatus === 'BLOCKED' ? ['CATALOG_BLOCKED',row.CatalogReasonCode,'REVIEW_CATALOG_SCOPE'] : ['UNKNOWN','CATALOG_DECISION_UNAVAILABLE','RECHECK_CATALOG'];
        if ((row.CatalogStatus === 'BLOCKED' && ['NONE','LANGUAGE_USER_DEFERRED'].includes(row.CatalogReasonCode)) || (row.CatalogStatus === 'UNKNOWN' && row.CatalogReasonCode !== 'CATALOG_DECISION_UNAVAILABLE') || row.Availability !== expected[0] || row.ReasonCode !== expected[1] || row.NextStep !== expected[2]) return false;
      }
    }
    return true;
  }
  function cell(row, text) { const value = document.createElement('td'); value.textContent = text; row.appendChild(value); }
  function render(matrix) {
    element('scope').textContent = `SQL ${matrix.SqlVersion} · Hostsystem ${matrix.HostOperatingSystem} · Profil ${matrix.ProviderProfile}\nAbfrage: ${matrix.GeneratedAtUtc}\nGeladener Katalog: ${matrix.CatalogFingerprint}`;
    for (const item of matrix.Providers) {
      const row = document.createElement('tr');
      for (const text of [item.Provider,presence[item.Presence],readiness[item.Readiness],reasonText(item.ReasonCode),item.ObservedAtUtc ?? 'Nicht geprüft']) cell(row,text);
      element('providers').appendChild(row);
    }
    for (const item of matrix.Capabilities) {
      const row = document.createElement('tr');
      const canInspect = item.CatalogStatus === 'DECLARED_SUPPORTED' && ['docker','podman'].includes(item.Provider) && ['2019','2022','2025'].includes(matrix.SqlVersion);
      row.setAttribute('aria-disabled',canInspect ? 'false' : 'true');
      cell(row,`${item.Provider} / ${item.TargetOperatingSystem}`);
      cell(row,`${item.Language} ${item.RuntimeVersion ?? ''}\n${item.VariantId ?? 'Keine passende Katalogvariante'}${item.ExplicitSelectionRequired ? '\nNur bewusste Variantenwahl' : ''}`);
      cell(row,`${item.CatalogStatus} / ${item.CatalogReasonCode}\nBenötigt: ${item.RequiredCapabilities.join(', ') || 'Nicht zugeordnet'}`);
      cell(row,`${states[item.Availability]}\n${reasonText(item.ReasonCode)}`); cell(row,steps[item.NextStep]); element('rows').appendChild(row);
      const detail = document.createElement('td'), button = document.createElement('button');
      button.type = 'button'; button.className = 'button secondary'; button.disabled = !canInspect;
      button.textContent = canInspect ? 'Varianten- und Launchdetails öffnen' : item.Language === 'C#' ? 'Zurückgestellt' : 'Detailprüfung noch nicht verfügbar';
      if (canInspect) button.addEventListener('click',() => {
        const tuple = {SqlVersion:matrix.SqlVersion,Provider:item.Provider,SoftwareId:item.SoftwareId,RuntimeVersion:item.RuntimeVersion,VariantId:item.VariantId};
        element('dialog').close(); clearResult();
        document.dispatchEvent(new CustomEvent('sqlserverlab:external-runtime-request',{detail:tuple}));
      });
      detail.appendChild(button); row.appendChild(detail);
    }
    element('unassessed').textContent = 'Noch ungeprüft: SQL-Build, tatsächliches Gastbetriebssystem, Kernel/cgroup-Controller, gemeinsamer WSL-Kernel, Rootless/Launchmodus, Ressourcen, Zielrechte, historische Nachweise und SQL-Sprachausführung.';
    element('status').textContent = 'Übersicht gelesen. Keine Ausführungsfreigabe.';
  }
  async function request(action, probe = false) {
    if (busy || !element('dialog').open) return;
    const sql = element('sql').value, provider = element('provider').value;
    if (action === 'ReadMatrix' && (!/^\d{4}$/.test(sql) || !['all',...providers].includes(provider) || (probe && provider === 'all'))) return;
    clearResult(); const current = revision, token = {}; active = token; busy = true; controls();
    element('status').textContent = probe ? 'Provider wird bewusst lesend geprüft …' : 'Katalog wird gelesen; Host: NOT_CHECKED';
    const payload = action === 'ReadVersions' ? {Action:action} : {Action:action,SqlVersion:sql,Provider:provider,CheckProviderReadiness:probe};
    try {
      const response = await sqlServerLabUiFetch('/api/host-capability-matrix',{method:'POST',headers:{'Content-Type':'application/json; charset=utf-8'},body:JSON.stringify(payload)});
      if (current !== revision || !element('dialog').open) return;
      if (!response.ok) throw new Error('INVALID');
      const view = await response.json();
      if (current !== revision || !element('dialog').open) return;
      if (view.ContractVersion !== 'SqlServerLab.HostCapabilityMatrixBrowser/1.0') throw new Error('INVALID');
      if (action === 'ReadVersions') {
        if (!shape(view,['ContractVersion','Status','Versions']) || view.Status !== 'VERSIONS' || !Array.isArray(view.Versions) || !view.Versions.length || view.Versions.length > 32 || new Set(view.Versions).size !== view.Versions.length || view.Versions.some(value => typeof value !== 'string' || !/^\d{4}$/.test(value))) throw new Error('INVALID');
        element('sql').replaceChildren(); const placeholder = document.createElement('option'); placeholder.value = ''; placeholder.textContent = 'SQL-Version wählen'; element('sql').appendChild(placeholder);
        for (const version of view.Versions) { const option = document.createElement('option'); option.value = version; option.textContent = version; element('sql').appendChild(option); }
        element('sql').value = ''; element('status').textContent = 'SQL-Version wählen. Host: NOT_CHECKED';
      } else {
        if (!shape(view,['ContractVersion','Status','Matrix']) || view.Status !== 'MATRIX' || !validMatrix(view.Matrix,sql,provider === 'all' ? providers : [provider],probe)) throw new Error('INVALID');
        render(view.Matrix);
      }
    } catch {
      if (current === revision && element('dialog').open) { clearResult(); if (action === 'ReadVersions') { element('sql').replaceChildren(); element('sql').value = ''; } element('status').textContent = 'Übersicht nicht bestätigt. Eingaben prüfen und bewusst erneut lesen.'; }
    } finally { if (active === token) { active = null; busy = false; controls(); } }
  }
  element('open').addEventListener('click',() => { clearResult(); element('sql').replaceChildren(); element('sql').value = ''; element('dialog').showModal(); request('ReadVersions'); });
  element('versions').addEventListener('click',() => request('ReadVersions'));
  element('read').addEventListener('click',() => request('ReadMatrix'));
  element('probe').addEventListener('click',() => request('ReadMatrix',true));
  for (const id of ['sql','provider']) element(id).addEventListener('change',clearResult);
  element('close').addEventListener('click',() => { element('dialog').close(); clearResult(); });
  element('dialog').addEventListener('cancel',clearResult); element('dialog').addEventListener('close',clearResult);
  controls();
})();
