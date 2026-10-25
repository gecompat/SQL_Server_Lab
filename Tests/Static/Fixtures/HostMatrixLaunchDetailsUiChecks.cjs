'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../../..');let passed=0;
function check(condition,name){assert.ok(condition,name);passed++;console.log('PASS: '+name);}
function node(){return {value:'',textContent:'',disabled:false,open:false,children:[],events:{},attributes:{},addEventListener(name,handler){this.events[name]=handler;},appendChild(value){this.children.push(value);},replaceChildren(...values){this.children=values;},setAttribute(name,value){this.attributes[name]=value;},showModal(){this.open=true;},close(){this.open=false;this.events.close?.();},set innerHTML(value){throw new Error('HTML_FORBIDDEN');}};}
const tuple={SqlVersion:'2022',Provider:'docker',SoftwareId:'sql-python',RuntimeVersion:'3.10',VariantId:'sql2022-python310-ubuntu2204-derived'};
function setup(){
  const host=Object.fromEntries(['open','dialog','sql','provider','versions','read','probe','status','scope','providers','rows','unassessed','close'].map(id=>[id,node()]));
  const detail=Object.fromEntries(['open','dialog','provider','sql','read','choice','status','result','history-result','evaluate','host','history','close'].map(id=>[id,node()]));
  host.provider.value='all';detail.provider.value='docker';detail.sql.value='2022';const requests=[],events={};
  const document={querySelector:selector=>selector.startsWith('#host-matrix-')?host[selector.slice(13)]:detail[selector.replace('#external-runtime-','')],createElement:node,addEventListener(name,handler){events[name]=handler;},dispatchEvent(event){events[event.type]?.(event);}};
  const context={document,CustomEvent:class{constructor(type,options){this.type=type;this.detail=options.detail;}},sqlServerLabUiFetch:(url,options)=>new Promise((resolve,reject)=>requests.push({url,options,resolve,reject})),console};
  for(const source of ['external-runtime-capability.js','host-capability-matrix.js'])vm.runInNewContext(fs.readFileSync(path.join(root,'Ui',source),'utf8'),context);
  return {host,detail,requests,document,flush:()=>new Promise(resolve=>setImmediate(resolve))};
}
function matrix(){
  const value={Contract:{Name:'SqlServerLab.HostCapabilityMatrix',Version:'1.0',EvidenceBoundary:'CATALOG_AND_OPTIONAL_PROVIDER_BOOTSTRAP_ONLY'},Feature:'SqlExternalRuntime',SqlVersion:'2022',HostOperatingSystem:'windows',GeneratedAtUtc:'2026-01-01T00:00:00.0000000Z',CatalogFingerprint:'a'.repeat(64),ProviderProfile:'NOT_CHECKED',Providers:[],Capabilities:[],Unassessed:['SQL_BUILD','GUEST_OPERATING_SYSTEM','KERNEL_AND_CGROUP_CONTROLLERS','WSL_SHARED_KERNEL','ROOTLESS_AND_LAUNCH_MODE','RESOURCES','TARGET_AUTHORIZATION','HISTORICAL_EVIDENCE','SQL_LANGUAGE_EXECUTION'],ManufacturerSupport:'NOT_ASSESSED',ProjectAcceptance:'NOT_ASSESSED',ExecutionSupported:false,MutationAllowed:false,Actions:[]};
  for(const provider of ['docker','podman','hyperv']){
    value.Providers.push({Provider:provider,Presence:'UNKNOWN',Readiness:'NOT_CHECKED',ReasonCode:'PROVIDER_NOT_CHECKED',Source:'SqlServerLab.DiagnosticProviderReadiness/1.0',ObservedAtUtc:null});
    value.Capabilities.push({Provider:provider,TargetOperatingSystem:provider==='hyperv'?'windows':'linux',Language:'Python',SoftwareId:tuple.SoftwareId,RuntimeVersion:tuple.RuntimeVersion,VariantId:tuple.VariantId,CatalogStatus:'DECLARED_SUPPORTED',CatalogReasonCode:'NONE',Availability:'NOT_CHECKED',ReasonCode:'PROVIDER_NOT_CHECKED',NextStep:'CHECK_PROVIDER_READINESS',RequiredCapabilities:[],ExplicitSelectionRequired:false});
    value.Capabilities.push({Provider:provider,TargetOperatingSystem:provider==='hyperv'?'windows':'linux',Language:'C#',SoftwareId:null,RuntimeVersion:null,VariantId:null,CatalogStatus:'NOT_EVALUATED',CatalogReasonCode:'LANGUAGE_USER_DEFERRED',Availability:'USER_DEFERRED',ReasonCode:'LANGUAGE_USER_DEFERRED',NextStep:'USER_DECISION_REQUIRED',RequiredCapabilities:[],ExplicitSelectionRequired:false});
  }
  return {ContractVersion:'SqlServerLab.HostCapabilityMatrixBrowser/1.0',Status:'MATRIX',Matrix:value};
}
function decision(software='sql-python'){
  const r=software==='sql-r';return {Contract:{Name:'SqlServerLab.ExternalRuntimeCapability',Version:'1.0',EvidenceBoundary:'PROSPECTIVE_DECLARATION_AND_OPTIONAL_HOST_OBSERVATION'},Provider:'docker',OperatingSystem:'linux',Identity:{SoftwareId:software,VariantId:r?'sql2022-r42-ubuntu2204-derived':tuple.VariantId,RuntimeVersion:r?'4.2.3':'3.10',Language:r?'R':'Python',SqlVersion:'2022'},CatalogDecision:{Status:'DECLARED_SUPPORTED',ReasonCode:'NONE'},CurrentReadiness:{Status:'NOT_CHECKED',ReasonCode:'READINESS_NOT_REQUESTED',RequiredCgroupVersion:'1',LaunchMode:'sql2022-namespace-v1'},HistoricalEvidence:{Status:'NOT_RECORDED',MappingStatus:'NOT_DEFINED'},SqlLanguageExecution:'NOT_CHECKED',TargetAuthorization:'NOT_CHECKED',ExecutionSupported:false,MutationAllowed:false,Actions:[]};
}
function options(includeTarget=true){const entries=[decision('sql-r'),...(includeTarget?[decision()]:[])];return {ContractVersion:'SqlServerLab.ExternalRuntimeCapabilityBrowser/1.0',Status:'OPTIONS',Options:entries.map(value=>({SoftwareId:value.Identity.SoftwareId,Language:value.Identity.Language,RuntimeVersion:value.Identity.RuntimeVersion,VariantId:value.Identity.VariantId,Decision:value}))};}
async function answer(fixture,value,request=fixture.requests.at(-1)){request.resolve({ok:true,json:async()=>value});await fixture.flush();}
async function openMatrix(fixture){fixture.host.open.events.click();await answer(fixture,{ContractVersion:'SqlServerLab.HostCapabilityMatrixBrowser/1.0',Status:'VERSIONS',Versions:['2022']});fixture.host.sql.value='2022';fixture.host.sql.events.change();fixture.host.read.events.click();await answer(fixture,matrix());}
const detailButton=fixture=>fixture.host.rows.children[0].children.at(-1).children[0];
(async()=>{
  const fixture=setup();await openMatrix(fixture);
  check(fixture.host.rows.children.length===6,'Actual controllers compose on a single document');
  const buttons=fixture.host.rows.children.map(row=>row.children.at(-1).children[0]);
  check(buttons.filter(button=>!button.disabled).length===2&&buttons.filter(button=>button.disabled).every(button=>!button.events.click),'Only catalogued Docker/Podman variants have a read-only continuation');
  detailButton(fixture).events.click();const read=JSON.parse(fixture.requests.at(-1).options.body);
  check(!fixture.host.dialog.open&&fixture.host.rows.children.length===0&&fixture.detail.dialog.open,'Continuation closes and clears matrix before opening existing detail view');
  check(fixture.requests.at(-1).url==='/api/external-runtime-capability'&&read.Action==='ReadOptions'&&read.SqlVersion===tuple.SqlVersion&&read.Provider===tuple.Provider&&!Object.hasOwn(read,'CheckProviderReadiness'),'Opening details reads only existing catalogue options with exact provider/SQL scope');
  await answer(fixture,options());
  check(fixture.detail.choice.value==='1'&&!fixture.detail.host.disabled&&fixture.detail.status.textContent.includes('Host: NOT_CHECKED'),'Exact variant is selected after fresh resolution, independent of option order');
  check(fixture.requests.length===3,'No evaluation, history or native host request is automatic');
  fixture.detail.host.events.click();const probe=JSON.parse(fixture.requests.at(-1).options.body);
  check(probe.CheckProviderReadiness===true&&probe.SoftwareId===tuple.SoftwareId&&probe.VariantId===tuple.VariantId&&probe.RuntimeVersion===tuple.RuntimeVersion&&probe.Provider===tuple.Provider,'Only explicit existing host action probes the exact transferred tuple');
  const blocked=decision();blocked.CurrentReadiness.Status='BLOCKED';blocked.CurrentReadiness.ReasonCode='CGROUP_VERSION_UNSUPPORTED';
  await answer(fixture,{ContractVersion:'SqlServerLab.ExternalRuntimeCapabilityBrowser/1.0',Status:'DECISION',Decision:blocked});
  check(fixture.detail.result.textContent.includes('CGROUP_VERSION_UNSUPPORTED')&&fixture.detail.result.textContent.includes('SQL-Sprachausführung: NOT_CHECKED')&&fixture.detail.result.textContent.includes('Keine Ausführungsfreigabe'),'Existing cgroup decision stays scoped and does not become SQL execution authority');
  const drift=setup();await openMatrix(drift);detailButton(drift).events.click();await answer(drift,options(false));
  check(drift.detail.choice.value===''&&drift.detail.host.disabled&&drift.detail.status.textContent.includes('nicht bestätigt'),'Unavailable or changed variant is never replaced by a different supported option');
  for(const change of ['close','provider']){
    const stale=setup();await openMatrix(stale);detailButton(stale).events.click();const pending=stale.requests.at(-1);
    if(change==='close')stale.detail.close.events.click();else{stale.detail.provider.value='podman';stale.detail.provider.events.change();}
    await answer(stale,options(),pending);
    check(stale.detail.choice.value===''&&stale.detail.host.disabled,'Late option response cannot restore a transferred selection after '+change);
  }
  for(const invalid of [{...tuple,Provider:'hyperv'},{...tuple,CheckProviderReadiness:true},{...tuple,SqlVersion:2022},{...tuple,VariantId:'../PRIVATE_HOST_CANARY'}]){
    const local=setup();local.document.dispatchEvent({type:'sqlserverlab:external-runtime-request',detail:invalid});await local.flush();
    check(local.requests.length===0&&!local.detail.dialog.open,'Malformed/unsupported event does not open or query details');
  }
  console.log(`Host matrix launch bridge UI: ${passed} PASS; actual controllers, synthetic DOM/transport.`);
})().catch(error=>{console.error(error);process.exitCode=1;});
