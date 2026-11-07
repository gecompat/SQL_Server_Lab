'use strict';
const fs=require('fs'),path=require('path'),vm=require('vm');
const root=path.resolve(__dirname,'../../..');let checks=0;
const check=(value,name)=>{if(!value)throw new Error('ENVIRONMENT_GROUPS_BROWSER_UI_CHECK_FAILED: '+name);checks++;};
function element(tag='div'){
  return {tag,events:{},children:[],textContent:'',className:'',disabled:false,open:false,
    addEventListener(name,handler){this.events[name]=handler;},appendChild(child){this.children.push(child);},replaceChildren(){this.children=[];},
    showModal(){this.open=true;},close(){this.open=false;this.events.close?.();}};
}
const run='33333333-4444-4555-8666-777777777777';
const view=(name='<img src=x onerror=alert(1)>')=>({contractVersion:'SqlServerLab.EnvironmentGroups.BrowserView/1.0',groups:[{groupId:'11111111-2222-4333-8444-555555555555',name,createdAt:'2026-11-07T12:00:00Z',lifecycleState:'ACTIVE',operation:{action:'Start',state:'COMPLETED',startedAt:'2026-11-07T12:00:00Z',updatedAt:'2026-11-07T12:01:00Z'},members:[{runId:run,instanceIds:['MSSQLSERVER'],assignedAt:'2026-11-07T12:00:00Z'}]}]});
function setup(){
  const elements=new Map(['open','dialog','close','dismiss','read','status','list'].map(id=>['environment-groups-'+id,element(id)]));
  const requests=[];
  const document={getElementById:id=>elements.get(id)||null,createElement:tag=>element(tag)};
  vm.runInNewContext(fs.readFileSync(path.join(root,'Ui/environment-groups.js'),'utf8'),{document,sqlServerLabUiFetch:(url,options)=>new Promise((resolve,reject)=>requests.push({url,options,resolve,reject}))});
  const get=id=>elements.get('environment-groups-'+id);
  return {elements,requests,get,click:id=>get(id).events.click(),flush:async()=>{await Promise.resolve();await Promise.resolve();await new Promise(r=>setImmediate(r));}};
}
function textTree(node){return [node.textContent,...(node.children||[]).map(textTree)].join('\n');}
async function answer(f,payload,request=f.requests.at(-1)){request.resolve({ok:true,json:async()=>payload});await f.flush();}
(async()=>{
  let f=setup();f.click('open');check(f.get('dialog').open&&f.requests.length===0,'open is inert until explicit read');
  f.click('read');f.click('read');check(f.requests.length===1&&f.requests[0].url==='/api/environment-groups'&&f.requests[0].options===undefined&&f.get('read').disabled,'single GET only and no duplicate read');
  await answer(f,view());check(f.get('list').children.length===1&&textTree(f.get('list')).includes('<img src=x onerror=alert(1)>'),'group names render as literal text');
  check(f.get('status').textContent.includes('nicht bestätigt')&&f.requests.every(r=>r.url==='/api/environment-groups'),'status is registry-only and sends no mutation');
  f.click('read');await answer(f,{contractVersion:'wrong',groups:[{name:'PRIVATE_CANARY'}]});
  check(f.get('list').children.length===0&&f.get('status').textContent.includes('ENVIRONMENT_GROUPS_READ_UNCONFIRMED')&&!f.get('status').textContent.includes('PRIVATE_CANARY'),'malformed DTO fails closed with fixed status');
  f.click('read');const unexpected=view();unexpected.groups[0].stateRootKey='PRIVATE_STATE_ROOT_CANARY';await answer(f,unexpected);
  check(f.get('list').children.length===0&&f.get('status').textContent.includes('ENVIRONMENT_GROUPS_READ_UNCONFIRMED')&&!f.get('status').textContent.includes('PRIVATE_STATE_ROOT_CANARY'),'unexpected authority fields are rejected');
  f.click('read');f.requests.at(-1).reject(new Error('PRIVATE_ERROR_CANARY'));await f.flush();
  check(!f.get('status').textContent.includes('PRIVATE_ERROR_CANARY'),'transport error is sanitized');
  f.click('read');const pending=f.requests.at(-1);f.click('close');await answer(f,view('late'),pending);
  check(f.get('list').children.length===0,'late response after close is vetoed');
  const html=fs.readFileSync(path.join(root,'Ui/index.html'),'utf8');
  for(const id of ['open','dialog','close','dismiss','read','status','list'])check((html.match(new RegExp('id="environment-groups-'+id+'"','g'))||[]).length===1,'HTML ID unique: '+id);
  check(/src="environment-groups\.js"/.test(html),'dedicated viewer script is loaded');
  console.log('ENVIRONMENT GROUPS BROWSER UI CHECKS: '+checks+' PASS; actual script with synthetic DOM/transport');
})().catch(error=>{console.error(error);process.exitCode=1;});
