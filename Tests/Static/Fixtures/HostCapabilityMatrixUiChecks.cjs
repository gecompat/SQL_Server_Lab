'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../../..');
let passed=0;
function check(condition,name){assert.ok(condition,name);passed++;console.log('PASS: '+name);}
const unknown=['SQL_BUILD','GUEST_OPERATING_SYSTEM','KERNEL_AND_CGROUP_CONTROLLERS','WSL_SHARED_KERNEL','ROOTLESS_AND_LAUNCH_MODE','RESOURCES','TARGET_AUTHORIZATION','HISTORICAL_EVIDENCE','SQL_LANGUAGE_EXECUTION'];
function node(){return {value:'',textContent:'',disabled:false,open:false,children:[],events:{},attributes:{},
  addEventListener(name,fn){this.events[name]=fn;},appendChild(value){this.children.push(value);},replaceChildren(...values){this.children=values;},
  setAttribute(name,value){this.attributes[name]=value;},showModal(){this.open=true;},close(){this.open=false;this.events.close?.();},
  set innerHTML(value){throw new Error('HTML_SINK_FORBIDDEN');}};}
function setup(){
  const elements=Object.fromEntries(['open','dialog','sql','provider','versions','read','probe','status','scope','providers','rows','unassessed','close'].map(id=>[id,node()]));
  elements.provider.value='all';const requests=[];
  const fixture={elements,requests,click:id=>elements[id].events.click(),change:(id,value)=>{elements[id].value=value;elements[id].events.change();},flush:()=>new Promise(resolve=>setImmediate(resolve))};
  const forbidden=()=>{throw new Error('PERSISTENCE_OR_LOOP_FORBIDDEN');};
  const context={document:{querySelector:selector=>elements[selector.replace('#host-matrix-','')],createElement:node},
    sqlServerLabUiFetch:(url,options)=>new Promise((resolve,reject)=>requests.push({url,options,resolve,reject})),
    localStorage:{getItem:forbidden,setItem:forbidden},sessionStorage:{getItem:forbidden,setItem:forbidden},setInterval:forbidden,setTimeout:forbidden,console};
  vm.runInNewContext(fs.readFileSync(path.join(root,'Ui/host-capability-matrix.js'),'utf8'),context);
  return fixture;
}
function matrix(provider='all',probe=false){
  const names=provider==='all'?['docker','podman','hyperv']:[provider];
  const value={Contract:{Name:'SqlServerLab.HostCapabilityMatrix',Version:'1.0',EvidenceBoundary:'CATALOG_AND_OPTIONAL_PROVIDER_BOOTSTRAP_ONLY'},Feature:'SqlExternalRuntime',SqlVersion:'2022',HostOperatingSystem:'windows',GeneratedAtUtc:'2026-01-01T00:00:00.0000000Z',CatalogFingerprint:'a'.repeat(64),ProviderProfile:provider==='all'?'NOT_CHECKED':'PARTIAL_SELECTION',Providers:[],Capabilities:[],Unassessed:unknown,ManufacturerSupport:'NOT_ASSESSED',ProjectAcceptance:'NOT_ASSESSED',ExecutionSupported:false,MutationAllowed:false,Actions:[]};
  for(const name of names){
    value.Providers.push({Provider:name,Presence:probe?'PRESENT':'UNKNOWN',Readiness:probe?'READY':'NOT_CHECKED',ReasonCode:probe?'PROVIDER_REACHABLE':'PROVIDER_NOT_CHECKED',Source:'SqlServerLab.DiagnosticProviderReadiness/1.0',ObservedAtUtc:probe?value.GeneratedAtUtc:null});
    for(const [language,id,version] of [['Python','sql-python','3.10'],['R','sql-r','4.2.3'],['Java','sql-java','11']])value.Capabilities.push({Provider:name,TargetOperatingSystem:name==='hyperv'?'windows':'linux',Language:language,SoftwareId:id,VariantId:id+'-synthetic',RuntimeVersion:version,CatalogStatus:'DECLARED_SUPPORTED',CatalogReasonCode:'NONE',Availability:probe?'INCOMPLETE':'NOT_CHECKED',ReasonCode:probe?'HOST_REQUIREMENTS_NOT_CHECKED':'PROVIDER_NOT_CHECKED',NextStep:probe?'ASSESS_LAUNCH_REQUIREMENTS':'CHECK_PROVIDER_READINESS',RequiredCapabilities:[],ExplicitSelectionRequired:false});
    value.Capabilities.push({Provider:name,TargetOperatingSystem:name==='hyperv'?'windows':'linux',Language:'C#',SoftwareId:null,VariantId:null,RuntimeVersion:null,CatalogStatus:'NOT_EVALUATED',CatalogReasonCode:'LANGUAGE_USER_DEFERRED',Availability:'USER_DEFERRED',ReasonCode:'LANGUAGE_USER_DEFERRED',NextStep:'USER_DECISION_REQUIRED',RequiredCapabilities:[],ExplicitSelectionRequired:false});
  }
  return {ContractVersion:'SqlServerLab.HostCapabilityMatrixBrowser/1.0',Status:'MATRIX',Matrix:value};
}
const versions=()=>({ContractVersion:'SqlServerLab.HostCapabilityMatrixBrowser/1.0',Status:'VERSIONS',Versions:['2016','2017','2019','2022','2025']});
async function answer(fixture,view,request=fixture.requests.at(-1)){request.resolve({ok:true,json:async()=>view});await fixture.flush();}
async function load(fixture){fixture.click('open');await answer(fixture,versions());fixture.change('sql','2022');}
const text=value=>value.textContent+' '+value.children.map(text).join(' ');
(async()=>{
  const fixture=setup();check(fixture.requests.length===0&&fixture.elements.read.disabled&&fixture.elements.probe.disabled,'Initial load has no requests or enabled host probe');
  fixture.click('open');check(fixture.requests.length===1&&JSON.parse(fixture.requests[0].options.body).Action==='ReadVersions','Opening reads only SQL metadata');
  await answer(fixture,versions());check(fixture.elements.sql.children.length===6&&fixture.elements.sql.value==='','Version choices come from validated metadata and require selection');
  fixture.change('sql','2022');check(fixture.requests.length===1&&fixture.elements.probe.disabled&&!fixture.elements.read.disabled,'Selection does not probe; all-provider probe stays disabled');
  fixture.click('read');const request=JSON.parse(fixture.requests.at(-1).options.body);
  check(fixture.requests.at(-1).url==='/api/host-capability-matrix'&&request.Provider==='all'&&request.CheckProviderReadiness===false&&fixture.elements.read.disabled,'Default read is explicitly non-probing and busy controls are disabled');
  await answer(fixture,matrix());check(fixture.elements.rows.children.length===12&&fixture.elements.providers.children.length===3,'All providers and languages remain visible');
  check(text(fixture.elements.rows).includes('C#')&&text(fixture.elements.rows).includes('Zurückgestellt')&&fixture.elements.rows.children.every(row=>row.attributes['aria-disabled']==='true'),'Deferred options remain visible without selectable execution');
  check(fixture.elements.scope.textContent.includes('NOT_CHECKED')&&fixture.elements.scope.textContent.includes('a'.repeat(64))&&fixture.elements.unassessed.textContent.includes('WSL'),'Scope, catalog binding and unassessed requirements remain visible');
  const before=fixture.requests.length;fixture.change('provider','docker');check(fixture.requests.length===before&&fixture.elements.rows.children.length===0&&!fixture.elements.probe.disabled,'Provider change clears previous facts and enables only an explicit single-provider probe');
  fixture.click('probe');check(JSON.parse(fixture.requests.at(-1).options.body).CheckProviderReadiness===true,'Host query requires its dedicated explicit action');
  await answer(fixture,matrix('docker',true));check(fixture.elements.rows.children.length===4&&text(fixture.elements.rows).includes('Launchanforderungen ungeprüft')&&fixture.elements.scope.textContent.includes('PARTIAL_SELECTION'),'Reachable provider remains incomplete for language execution');
  for(const [name,mutate] of [
    ['authority',value=>{value.Matrix.MutationAllowed=true;}],['boolean-string',value=>{value.Matrix.ExecutionSupported='false';}],
    ['action',value=>{value.Matrix.Actions=['PRIVATE_HOST_CANARY'];}],['identity',value=>{value.Matrix.SqlVersion='2019';}],
    ['provider',value=>{value.Matrix.Providers[0].Provider='podman';}],['version',value=>{value.Matrix.Contract.Version='1.1';}],
    ['extra',value=>{value.Matrix.Raw='PRIVATE_HOST_CANARY';}],['row-extra',value=>{value.Matrix.Capabilities[0].Explanation='PRIVATE_HOST_CANARY';}],
    ['raw-reason',value=>{value.Matrix.Capabilities[0].ReasonCode='PRIVATE_HOST_CANARY';}],['raw-variant',value=>{value.Matrix.Capabilities[0].VariantId='<img src=x>'; }],
    ['deferred-identity',value=>{value.Matrix.Capabilities.at(-1).SoftwareId='sql-csharp';}],['unassessed',value=>{value.Matrix.Unassessed=[];}],
    ['profile',value=>{value.Matrix.ProviderProfile='ALL_PROVIDERS';}],['date',value=>{value.Matrix.GeneratedAtUtc='PRIVATE_HOST_CANARY';}],
    ['required',value=>{value.Matrix.Capabilities[0].RequiredCapabilities=['/PRIVATE_HOST_CANARY'];}],['null',value=>{value.Matrix=null;}],
    ['row-relation',value=>{Object.assign(value.Matrix.Capabilities[0],{Availability:'INCOMPLETE',ReasonCode:'HOST_REQUIREMENTS_NOT_CHECKED',NextStep:'ASSESS_LAUNCH_REQUIREMENTS'});}],
    ['next-relation',value=>{value.Matrix.Capabilities[0].NextStep='ASSESS_LAUNCH_REQUIREMENTS';}],
    ['catalog-relation',value=>{Object.assign(value.Matrix.Capabilities[0],{CatalogStatus:'BLOCKED',CatalogReasonCode:'RUNTIME_COMBINATION_NOT_CATALOGUED'});}],
    ['deferred-requirements',value=>{value.Matrix.Capabilities.at(-1).RequiredCapabilities=['synthetic'];}],
    ['deferred-selection',value=>{value.Matrix.Capabilities.at(-1).ExplicitSelectionRequired=true;}]
  ]){
    const local=setup();await load(local);local.change('provider','docker');local.click('read');await answer(local,matrix('docker'));
    local.click('read');const value=matrix('docker');mutate(value);await answer(local,value);
    check(local.elements.rows.children.length===0&&local.elements.scope.textContent===''&&local.elements.status.textContent.includes('nicht bestätigt')&&!text(local.elements.status).includes('PRIVATE_HOST_CANARY'),'Malformed response removes prior success without raw output: '+name);
  }
  for(const [name,mutate] of [['presence',value=>{value.Matrix.Providers[0].Presence='MISSING';}],['reason',value=>{value.Matrix.Providers[0].ReasonCode='PROVIDER_UNREACHABLE';}]]){
    const local=setup();await load(local);local.change('provider','docker');local.click('probe');const value=matrix('docker',true);mutate(value);await answer(local,value);
    check(local.elements.rows.children.length===0&&local.elements.status.textContent.includes('nicht bestätigt'),'Contradictory explicit provider observation is rejected: '+name);
  }
  for(const [presence,readiness,code] of [['MISSING','NOT_READY','TOOL_NOT_INSTALLED'],['PRESENT','NOT_READY','PROVIDER_ACCESS_DENIED'],['UNKNOWN','UNKNOWN','DIAGNOSTIC_READINESS_TIMEOUT']]){
    const local=setup();await load(local);local.change('provider','docker');local.click('probe');const value=matrix('docker',true);
    Object.assign(value.Matrix.Providers[0],{Presence:presence,Readiness:readiness,ReasonCode:code});
    for(const row of value.Matrix.Capabilities.filter(item=>item.Language!=='C#'))Object.assign(row,{Availability:readiness==='UNKNOWN'?'UNKNOWN':'PRECONDITION_MISSING',ReasonCode:code,NextStep:readiness==='UNKNOWN'?'RECHECK_PROVIDER_READINESS':'REVIEW_PROVIDER_READINESS'});
    await answer(local,value);check(local.elements.rows.children.length===4,'Consistent incomplete/unknown observation remains visible: '+code);
  }
  const stale=setup();await load(stale);stale.change('provider','podman');stale.click('probe');const pending=stale.requests.at(-1);
  stale.click('close');stale.click('open');check(stale.requests.length===2&&stale.elements.read.disabled&&stale.elements.versions.disabled,'Close/reopen does not multiply an active bounded host request');
  await answer(stale,matrix('podman',true),pending);check(stale.elements.rows.children.length===0&&stale.elements.scope.textContent===''&&!stale.elements.versions.disabled,'Late response cannot populate the reopened dialog');
  stale.click('versions');await answer(stale,versions());stale.change('sql','2022');stale.click('read');const old=stale.requests.at(-1);stale.change('sql','2019');await answer(stale,matrix(),old);
  check(stale.elements.rows.children.length===0&&stale.elements.scope.textContent==='','Changed SQL selection invalidates a pending response');
  const error=setup();await load(error);error.click('read');await answer(error,matrix());error.click('read');error.requests.at(-1).reject(new Error('PRIVATE_HOST_CANARY'));await error.flush();
  check(error.elements.rows.children.length===0&&!error.elements.status.textContent.includes('PRIVATE_HOST_CANARY'),'Transport errors clear success and hide raw error text');
  error.click('versions');await answer(error,{...versions(),Versions:['2022','2022']});check(error.elements.sql.children.length===0&&error.elements.read.disabled,'Invalid metadata cannot retain older SQL choices');
  check(fixture.requests.every(item=>JSON.parse(item.options.body).Action.startsWith('Read')),'Only read actions are sent; no persistence or timers were accessed');
  console.log(`Host matrix UI: ${passed} PASS; synthetic DOM/transport only.`);
})().catch(error=>{console.error(error);process.exitCode=1;});
