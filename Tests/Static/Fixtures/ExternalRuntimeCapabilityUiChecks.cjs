'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../../..');
const ids=['open','dialog','provider','sql','read','choice','status','result','history-result','evaluate','host','history','close'];
let passed=0;
function check(condition,name){assert.ok(condition,name);passed++;console.log('PASS: '+name);}
function setup(){
  const elements=Object.fromEntries(ids.map(id=>[id,{value:'',textContent:'',disabled:false,open:false,children:[],events:{},addEventListener(name,fn){this.events[name]=fn;},replaceChildren(){this.children=[];this.value='';},appendChild(v){this.children.push(v);},showModal(){this.open=true;},close(){this.open=false;this.events.close?.();}}]));
  elements.provider.value='docker';elements.sql.value='2022';
  const requests=[];
  const context={document:{querySelector:selector=>elements[selector.replace('#external-runtime-','')],createElement:()=>({}),addEventListener(){}},sqlServerLabUiFetch:(url,options)=>new Promise((resolve,reject)=>requests.push({url,options,resolve,reject})),console};
  vm.runInNewContext(fs.readFileSync(path.join(root,'Ui/external-runtime-capability.js'),'utf8'),context);
  const click=id=>elements[id].events.click();
  const flush=()=>new Promise(resolve=>setImmediate(resolve));
  return {elements,requests,click,flush};
}
const decision=()=>({Contract:{Name:'SqlServerLab.ExternalRuntimeCapability',Version:'1.0',EvidenceBoundary:'PROSPECTIVE_DECLARATION_AND_OPTIONAL_HOST_OBSERVATION'},Provider:'docker',OperatingSystem:'linux',Identity:{SoftwareId:'sql-python',VariantId:'sql2022-python310-ubuntu2204-derived',RuntimeVersion:'3.10',Language:'Python',SqlVersion:'2022'},CatalogDecision:{Status:'DECLARED_SUPPORTED',ReasonCode:'NONE'},CurrentReadiness:{Status:'NOT_CHECKED',ReasonCode:'READINESS_NOT_REQUESTED',RequiredCgroupVersion:'1',LaunchMode:'sql2022-namespace-v1'},HistoricalEvidence:{Status:'NOT_RECORDED',MappingStatus:'NOT_DEFINED'},SqlLanguageExecution:'NOT_CHECKED',TargetAuthorization:'NOT_CHECKED',ExecutionSupported:false,MutationAllowed:false,Actions:[]});
const option=()=>({SoftwareId:'sql-python',Language:'Python',RuntimeVersion:'3.10',VariantId:'sql2022-python310-ubuntu2204-derived',Decision:decision()});
const options=()=>({ContractVersion:'SqlServerLab.ExternalRuntimeCapabilityBrowser/1.0',Status:'OPTIONS',Options:[option()]});
const result=d=>({ContractVersion:'SqlServerLab.ExternalRuntimeCapabilityBrowser/1.0',Status:'DECISION',Decision:d});
const history=()=>({ContractVersion:'SqlServerLab.ExternalRuntimeCapabilityBrowser/1.1',Status:'HISTORY',Provider:'docker',OperatingSystem:'linux',Identity:decision().Identity,HistoricalEvidence:{Status:'RECORDED_HISTORY_ONLY',MappingStatus:'DEFINED',ReasonCode:'INDEX_MATCH_RECORDED',RecordCount:2,ReferenceVerificationStatus:'NOT_VERIFIED',EvidenceBoundary:'RECORDED_HISTORY_ONLY'},CurrentReadinessStatus:'NOT_CHECKED',SqlLanguageExecution:'NOT_CHECKED',TargetAuthorization:'NOT_CHECKED',ExecutionSupported:false,MutationAllowed:false,Actions:[]});
async function answer(fixture,view,request=fixture.requests.at(-1)){request.resolve({ok:true,json:async()=>view});await fixture.flush();}
async function load(fixture){fixture.click('open');fixture.click('read');await answer(fixture,options());fixture.elements.choice.value='0';fixture.elements.choice.events.change();}
(async()=>{
  let f=setup();f.click('open');check(f.requests.length===0,'Opening dialog makes no request');
  f.elements.sql.events.change();check(f.requests.length===0,'Changing tuple does not observe host');
  f.click('evaluate');f.click('host');f.click('history');check(f.requests.length===0,'No catalog choice means zero dispatch');
  f.click('read');check(f.requests.length===1 && f.elements.read.disabled,'Metadata request enters busy state');
  check(JSON.parse(f.requests[0].options.body).Action==='ReadOptions' && !('CheckProviderReadiness' in JSON.parse(f.requests[0].options.body)),'Metadata never requests readiness');
  await answer(f,options());check(f.elements.evaluate.disabled,'Placeholder does not silently select first option');
  f.elements.choice.value='0';f.elements.choice.events.change();f.click('evaluate');check(JSON.parse(f.requests.at(-1).options.body).CheckProviderReadiness===false,'Ordinary evaluate explicitly opts out');
  f.click('host');check(f.requests.length===2,'Busy prevents double dispatch');
  await answer(f,result(decision()));check(f.elements.result.textContent.includes('NOT_CHECKED') && f.elements.result.textContent.includes('Keine Ausführungsfreigabe'),'Fixed decision output separates authority');
  f.click('host');check(JSON.parse(f.requests.at(-1).options.body).CheckProviderReadiness===true,'Only deliberate host action opts in');
  const ready=decision();ready.CurrentReadiness.Status='READY';ready.CurrentReadiness.ReasonCode='NONE';await answer(f,result(ready));check(f.elements.result.textContent.includes('Hostvoraussetzungen: READY') && f.elements.result.textContent.includes('Zielautorisierung: NOT_CHECKED'),'READY cannot grant target rights');
  f.click('host');const unknown=decision();unknown.CurrentReadiness.Status='BLOCKED';unknown.CurrentReadiness.ReasonCode='PROVIDER_RESPONSE_INVALID';await answer(f,result(unknown));check(f.elements.result.textContent.includes('Hostvoraussetzungen: BLOCKED / PROVIDER_RESPONSE_INVALID') && f.elements.result.textContent.includes('Keine Ausführungsfreigabe'),'Unknown facts display fixed shared reason without authority');
  check(f.requests.length===4 && f.requests.every(r=>r.url==='/api/external-runtime-capability'),'Unknown host response causes no extra request or action');
  f.click('read');const late=f.requests.at(-1);f.click('close');await answer(f,options(),late);check(!f.elements.dialog.open && f.elements.choice.children.length===0 && f.elements.result.textContent==='','Cancel vetoes late success');
  f=setup();await load(f);f.click('host');const failure=f.requests.at(-1);f.elements.dialog.events.cancel();f.elements.dialog.open=false;failure.reject(new Error('PRIVATE_CANARY'));await f.flush();check(!f.elements.status.textContent.includes('PRIVATE_CANARY') && f.elements.result.textContent==='','Escape vetoes late failure');
  f=setup();await load(f);f.click('host');const old=f.requests.at(-1);f.elements.sql.value='2025';f.elements.sql.events.change();await answer(f,result(ready),old);check(f.elements.result.textContent==='' && f.elements.choice.children.length===0,'Tuple change invalidates late response');
  const changes=[v=>v.Extra='PRIVATE_CANARY',v=>v.Decision.Contract.Extra='PRIVATE_CANARY',v=>v.Decision.Identity.VariantId='<img src=x>',v=>v.Decision.ExecutionSupported=true,v=>v.Decision.MutationAllowed='false',v=>v.Decision.Actions=['START'],v=>v.Decision.CurrentReadiness.ReasonCode='PRIVATE_CANARY',v=>v.Decision.HistoricalEvidence.Status='PASS',v=>v.Decision.Identity.SqlVersion='2025',v=>v.Decision.CurrentReadiness.RequiredCgroupVersion=1];
  for(const change of changes){f=setup();await load(f);f.click('evaluate');const view=result(decision());change(view);await answer(f,view);check(f.elements.result.textContent==='' && !f.elements.status.textContent.includes('PRIVATE_CANARY'),'Malformed/foreign/private response fails closed '+passed);}
  f=setup();f.click('open');f.click('read');const blocked=option();blocked.Decision.Identity=null;blocked.Decision.CatalogDecision={Status:'BLOCKED',ReasonCode:'VARIANT_UNSUPPORTED'};await answer(f,{...options(),Options:[blocked]});check(f.elements.choice.children[1].disabled && f.elements.choice.children[1].textContent.includes('VARIANT_UNSUPPORTED'),'Blocked option remains visible with safe reason');
  f.elements.choice.value='0';f.elements.choice.events.change();f.click('evaluate');f.click('host');check(f.requests.length===1,'Forged blocked selection cannot dispatch');
  f=setup();await load(f);f.elements.provider.value='PRIVATE_CANARY';f.click('host');check(f.requests.length===1,'Arbitrary menu values cannot request host');
  f=setup();await load(f);f.click('history');const payload=JSON.parse(f.requests.at(-1).options.body);
  check(payload.Action==='ReadRecordedEvidence' && Object.keys(payload).length===7 && !('CheckProviderReadiness' in payload),'Deliberate history action has no host-readiness flag');
  f.click('history');f.click('host');check(f.requests.length===2,'Busy history prevents duplicate or host dispatch');
  await answer(f,history());check(f.elements['history-result'].textContent.includes('RECORDED_HISTORY_ONLY') && f.elements['history-result'].textContent.includes('NOT_VERIFIED') && f.elements['history-result'].textContent.includes('Aktuelle Hostbereitschaft: NOT_CHECKED') && f.elements['history-result'].textContent.includes('Keine Ausführungsfreigabe'),'Historical match remains separate from current readiness and authority');
  f.elements.choice.events.change();check(f.elements['history-result'].textContent==='','Changing selection clears historical result');
  for(const reason of ['INDEX_LEGACY_IDENTITY_UNKNOWN','INDEX_NO_MATCH','INDEX_NOT_PRESENT','INDEX_INVALID','EVIDENCE_OUTPUT_LIMIT']){
    f=setup();await load(f);f.click('history');const view=history();view.HistoricalEvidence.ReasonCode=reason;view.HistoricalEvidence.RecordCount=0;
    view.HistoricalEvidence.Status=reason==='INDEX_LEGACY_IDENTITY_UNKNOWN'||reason==='INDEX_NO_MATCH'?'NOT_RECORDED':'UNAVAILABLE';view.HistoricalEvidence.MappingStatus=reason==='INDEX_LEGACY_IDENTITY_UNKNOWN'?'NOT_DEFINED':reason==='INDEX_NO_MATCH'?'DEFINED':'UNAVAILABLE';
    await answer(f,view);check(f.elements['history-result'].textContent.includes(reason),'Missing/legacy/unavailable history remains explicit '+reason);
  }
  const historyChanges=[v=>v.Extra='PRIVATE_CANARY',v=>v.HistoricalEvidence.Cells=['PRIVATE_CANARY'],v=>v.HistoricalEvidence.RecordCount=0,v=>v.HistoricalEvidence.RecordCount=129,v=>v.HistoricalEvidence.RecordCount='2',v=>v.HistoricalEvidence.ReasonCode=['INDEX_MATCH_RECORDED'],v=>v.HistoricalEvidence.ReferenceVerificationStatus='VERIFIED',v=>v.Identity.Provider='podman',v=>v.Identity.Language='Java',v=>v.Identity.SqlVersion='2025',v=>v.Provider='podman',v=>v.CurrentReadinessStatus='READY',v=>v.MutationAllowed=true,v=>v.Actions=['START'],v=>v.Identity=null];
  for(const change of historyChanges){f=setup();await load(f);f.click('history');const view=history();change(view);await answer(f,view);check(f.elements['history-result'].textContent==='' && !f.elements.status.textContent.includes('PRIVATE_CANARY'),'Foreign/malformed/history authority response fails closed '+passed);}
  f=setup();await load(f);f.click('history');const lateHistory=f.requests.at(-1);f.click('close');await answer(f,history(),lateHistory);check(f.elements['history-result'].textContent==='' && !f.elements.dialog.open,'Cancel vetoes late historical success');
  f=setup();await load(f);f.click('history');const oldHistory=f.requests.at(-1);f.elements.provider.value='podman';f.elements.provider.events.change();await answer(f,history(),oldHistory);check(f.elements['history-result'].textContent==='' && f.elements.choice.children.length===0,'Provider change invalidates historical response');
  console.log('JS TOTAL: '+passed+' PASS; real DOM/network/provider: 0');
})().catch(error=>{console.error(error);process.exitCode=1;});
