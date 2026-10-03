'use strict';
const fs=require('node:fs'),path=require('node:path'),vm=require('node:vm'),assert=require('node:assert/strict');
const root=path.resolve(__dirname,'../../..');let passed=0;
function check(condition,name){assert.ok(condition,name);passed++;console.log('PASS: '+name);}
function setup(){
  const elements=Object.fromEntries(['open','dialog','sql','query','search','results','status','close'].map(id=>[id,{value:'',textContent:'',disabled:false,open:false,children:[],events:{},addEventListener(name,fn){this.events[name]=fn;},replaceChildren(){this.children=[];},appendChild(v){this.children.push(v);},showModal(){this.open=true;},close(){this.open=false;this.events.close?.();}}]));
  const requests=[];const context={document:{querySelector:s=>elements[s.replace('#collation-','')],createElement:()=>({})},fetch:(url,options)=>new Promise((resolve,reject)=>requests.push({url,options,resolve,reject})),TextEncoder};
  vm.runInNewContext(fs.readFileSync(path.join(root,'Ui/collation-catalog.js'),'utf8'),context);
  return {elements,requests,click:id=>elements[id].events.click(),flush:()=>new Promise(r=>setImmediate(r))};
}
const row=()=>({Name:'SQL_Latin1_General_CP1_CI_AS',Locale:'Latin',CodePage:1252,Lcid:1033,CaseSensitivity:'CI',AccentSensitivity:'AS',Utf8:false,Status:'DEPRECATED',SqlVersion:'2025'});
const dto=(rows=[row()])=>({Contract:{Name:'SqlServerLab.CollationCatalogueSearch',Version:'1.0'},SqlVersion:'2025',Status:rows.length?'MATCHES':'NO_MATCHES',Results:rows,ReturnedCount:rows.length,Truncated:false,SqlValidation:'NOT_CHECKED',ExecutionSupported:false,MutationAllowed:false,Actions:[]});
async function answer(f,v,r=f.requests.at(-1)){r.resolve({ok:true,json:async()=>v});await f.flush();}
(async()=>{
  let f=setup();f.click('open');check(f.requests.length===0 && f.elements.sql.value==='2025' && f.elements.query.value==='','Opening uses RAM defaults, zero request');
  f.elements.query.value='Latin1';f.elements.query.events.input();f.elements.sql.events.change();check(f.requests.length===0,'Editing does not search');
  f.click('search');const request=f.requests[0];check(request.url==='/api/collations/search' && request.options.method==='POST' && Object.keys(JSON.parse(request.options.body)).length===2 && JSON.parse(request.options.body).Query==='Latin1','Conscious search has exactly two fields');
  f.click('search');check(f.requests.length===1 && f.elements.search.disabled,'Busy denies duplicate request');
  await answer(f,dto());check(f.elements.results.children[0].textContent.includes('DEPRECATED') && f.elements.status.textContent.includes('NOT_CHECKED') && f.elements.status.textContent.includes('Keine Auswahl übernommen'),'Deprecated remains visible with warning, no takeover');
  f.click('search');await answer(f,dto([]));check(f.elements.status.textContent.includes('Keine Katalogtreffer') && f.elements.results.children.length===0,'Empty results are useful');
  f.click('search');const hundred=dto(Array.from({length:100},row));hundred.Truncated=true;await answer(f,hundred);check(f.elements.results.children.length===100 && f.elements.status.textContent.includes('eingrenzen'),'Actual truncation displayed');
  f.click('search');const late=f.requests.at(-1);f.click('close');await answer(f,dto(),late);check(!f.elements.dialog.open && f.elements.query.value==='' && f.elements.results.children.length===0,'Cancel clears RAM and vetoes late success');
  f=setup();f.click('open');f.click('search');const failed=f.requests.at(-1);f.elements.dialog.events.cancel();f.elements.dialog.open=false;failed.reject(new Error('PRIVATE_CANARY'));await f.flush();check(!f.elements.status.textContent.includes('PRIVATE_CANARY') && f.elements.results.children.length===0,'Escape vetoes late failure');
  for(const edit of ['query','sql']){f=setup();f.click('open');f.click('search');const old=f.requests[0];f.elements[edit].value=edit==='sql'?'2022':'new';f.elements[edit].events[edit==='sql'?'change':'input']();await answer(f,dto(),old);check(f.elements.results.children.length===0 && f.elements.status.textContent==='SQL-Prüfung: NOT_CHECKED','Edit invalidates late response '+edit);}
  for(const change of [v=>v.Extra='PRIVATE_CANARY',v=>v.Contract.Version='2.0',v=>v.Results={},v=>v.ReturnedCount=2,v=>v.Truncated='false',v=>v.Truncated=true,v=>v.SqlValidation='PASS',v=>v.ExecutionSupported=true,v=>v.MutationAllowed='false',v=>v.Actions=['START'],v=>v.SqlVersion='2022',v=>v.Results[0].Name='<img src=x>',v=>v.Results[0].CodePage='1252',v=>v.Results[0].Lcid=-1,v=>v.Results[0].Utf8='false',v=>v.Results[0].Locale='PRIVATE_CANARY\n',v=>v.Results[0].Locale='',v=>v.Results[0].Status='UNKNOWN',v=>v.Results[0].SqlVersion='2022',v=>v.Results[0].Extra='PRIVATE_CANARY']){
    f=setup();f.click('open');f.click('search');const view=dto();change(view);await answer(f,view);check(f.elements.results.children.length===0 && f.elements.status.textContent.includes('nicht bestätigt') && !f.elements.status.textContent.includes('PRIVATE_CANARY'),'Malformed DTO fails closed '+passed);
  }
  f=setup();f.click('open');f.click('search');const text=dto();text.Results[0].Locale='<img src=x onerror=alert(1)>';await answer(f,text);check(f.elements.results.children[0].textContent.includes('<img') && !('innerHTML' in f.elements.results.children[0]),'Metadata rendered only as text');
  f=setup();f.click('open');f.click('search');f.requests[0].reject(new Error('PRIVATE_CANARY'));await f.flush();check(!f.elements.status.textContent.includes('PRIVATE_CANARY'),'Raw transport error never reflected');
  for(const query of ['x'.repeat(257),'bad\n']){f=setup();f.click('open');f.elements.query.value=query;f.click('search');check(f.requests.length===0,'Invalid query zero dispatch '+passed);}
  f=setup();f.click('open');f.elements.sql.value='PRIVATE_CANARY';f.click('search');check(f.requests.length===0,'Forged SQL option zero dispatch');
  f=setup();f.click('search');f.click('close');check(f.requests.length===0,'Closed dialog and back never dispatch');
  console.log('JS TOTAL: '+passed+' PASS; actual module handlers/fake DOM; real browser/network/provider: 0');
})().catch(e=>{console.error(e);process.exitCode=1;});
