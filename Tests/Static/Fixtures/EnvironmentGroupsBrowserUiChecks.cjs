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
const groupId='11111111-2222-4333-8444-555555555555';
const view=(name='<img src=x onerror=alert(1)>')=>({contractVersion:'SqlServerLab.EnvironmentGroups.BrowserView/1.0',groups:[{groupId,name,createdAt:'2026-11-07T12:00:00Z',lifecycleState:'ACTIVE',operation:{action:'Start',state:'COMPLETED',startedAt:'2026-11-07T12:00:00Z',updatedAt:'2026-11-07T12:01:00Z'},members:[{runId:run,instanceIds:['MSSQLSERVER'],assignedAt:'2026-11-07T12:00:00Z'}]}]});
function setup(){
  const elements=new Map(['open','dialog','close','dismiss','read','status','list'].map(id=>['environment-groups-'+id,element(id)]));
  const requests=[],events=[];
  const document={getElementById:id=>elements.get(id)||null,createElement:tag=>element(tag)};
  class CustomEventFixture{constructor(type,options){this.type=type;this.detail=options?.detail;}}
  vm.runInNewContext(fs.readFileSync(path.join(root,'Ui/environment-groups.js'),'utf8'),{document,window:{dispatchEvent:event=>events.push(event)},CustomEvent:CustomEventFixture,sqlServerLabUiFetch:(url,options)=>new Promise((resolve,reject)=>requests.push({url,options,resolve,reject}))});
  const get=id=>elements.get('environment-groups-'+id);
  return {elements,requests,events,get,click:id=>get(id).events.click(),flush:async()=>{await Promise.resolve();await Promise.resolve();await new Promise(r=>setImmediate(r));}};
}
function textTree(node){return [node.textContent,...(node.children||[]).map(textTree)].join('\n');}
function findButton(node,label){for(const child of node.children||[]){if(child.tag==='button'&&child.textContent===label)return child;const nested=findButton(child,label);if(nested)return nested;}return null;}
function actualFunction(source,name){const match=new RegExp('^(?:async )?function '+name+'\\(','m').exec(source);check(!!match,'actual app handler exists: '+name);const rest=source.slice(match.index),next=/\n(?:async )?function \w+\(/.exec(rest);return next?rest.slice(0,next.index):rest;}
async function answer(f,payload,request=f.requests.at(-1)){request.resolve({ok:true,json:async()=>payload});await f.flush();}
(async()=>{
  let f=setup();f.click('open');check(f.get('dialog').open&&f.requests.length===0,'open is inert until explicit read');
  f.click('read');f.click('read');check(f.requests.length===1&&f.requests[0].url==='/api/environment-groups'&&f.requests[0].options===undefined&&f.get('read').disabled,'single GET only and no duplicate read');
  await answer(f,view());check(f.get('list').children.length===1&&textTree(f.get('list')).includes('<img src=x onerror=alert(1)>'),'group names render as literal text');
  const stopButton=findButton(f.get('list').children[0],'Gruppe stoppen');check(!!stopButton,'active group exposes stop action');stopButton.events.click();
  check(f.events.length===1&&f.events[0].type==='sqlserverlab:environment-group-lifecycle-request'&&f.events[0].detail.action==='Stop'&&f.events[0].detail.groupId===groupId,'stop dispatches only the typed group action and stable ID');
  check(!f.get('dialog').open&&f.requests.length===1,'lifecycle action closes stale view and performs no direct network mutation');
  check(f.get('status').textContent.includes('nicht bestätigt')&&f.requests.every(r=>r.url==='/api/environment-groups'),'stored status is not presented as runtime confirmation');

  f=setup();f.click('open');f.click('read');const stopped=view();stopped.groups[0].lifecycleState='STOPPED';stopped.groups[0].operation=null;await answer(f,stopped);
  const startButton=findButton(f.get('list').children[0],'Gruppe starten');check(!!startButton,'stopped group exposes start action');startButton.events.click();
  check(f.events.length===1&&f.events[0].detail.action==='Start','start dispatches explicit start action');

  f=setup();f.click('open');f.click('read');const inProgress=view();inProgress.groups[0].operation.state='IN_PROGRESS';await answer(f,inProgress);
  check(!findButton(f.get('list').children[0],'Gruppe starten')&&!findButton(f.get('list').children[0],'Gruppe stoppen'),'in-progress operation offers no duplicate lifecycle action');
  f=setup();f.click('open');f.click('read');const emptyStopped=view();emptyStopped.groups[0].lifecycleState='STOPPED';emptyStopped.groups[0].members=[];emptyStopped.groups[0].operation=null;await answer(f,emptyStopped);
  check(findButton(f.get('list').children[0],'Gruppe starten')?.disabled===true,'empty stopped group cannot start');

  f=setup();f.click('open');f.click('read');
  await answer(f,{contractVersion:'wrong',groups:[{name:'PRIVATE_CANARY'}]});
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
  const appSource=fs.readFileSync(path.join(root,'Ui/app.js'),'utf8');
  check(/if \(typeof window !== 'undefined' && typeof window\.addEventListener === 'function'\)\s*\{\s*window\.addEventListener\('sqlserverlab:environment-group-lifecycle-request', handleEnvironmentGroupLifecycleRequest\);\s*\}/.test(appSource),'app listens for lifecycle action event when browser listener is available');
  const confirmations=[],errors=[];
  const appContext=vm.createContext({publicCommandCatalog:[],window:{addEventListener(){}},showError:error=>errors.push(error.message),openConfirmation:(...args)=>confirmations.push(args)});
  vm.runInContext(actualFunction(appSource,'handleEnvironmentGroupLifecycleRequest'),appContext);
  const lifecycleSet={Name:'Default',IsDefault:true,MandatoryNames:['GroupId'],Parameters:[{Name:'GroupId',TypeName:'System.String',Mandatory:true,Sensitive:false,IsCredential:false},{Name:'WhatIf',TypeName:'System.Management.Automation.SwitchParameter',Mandatory:false,Sensitive:false,IsCredential:false}]};
  for(const action of ['Start','Stop']){
    const command={Name:action==='Start'?'Start-SqlServerLabEnvironmentGroup':'Stop-SqlServerLabEnvironmentGroup',RequiresConfirmation:true,ParameterSets:[lifecycleSet]};
    appContext.publicCommandCatalog=[command];appContext.handleEnvironmentGroupLifecycleRequest({detail:{action,groupId,groupName:'Linked Server Demo'}});
    const confirmation=confirmations.at(-1);
    check(confirmation?.[2]==='__PublicCommand'&&confirmation?.[3]?.command===command,'actual app handler uses catalogued public command for '+action);
    check(confirmation[3].parameterSet===lifecycleSet&&Object.keys(confirmation[3].parameters).join(',')==='GroupId'&&confirmation[3].parameters.GroupId===groupId,'actual app handler submits only GroupId using default parameter set for '+action);
    check(confirmation[1].includes('nicht blind wiederholen')&&confirmation[4]===('Gruppe '+(action==='Start'?'starten':'stoppen')),'confirmation explains lifecycle and lost-response handling for '+action);
  }
  const confirmationCount=confirmations.length;
  appContext.handleEnvironmentGroupLifecycleRequest({detail:{action:'Start',groupId:'bad-id',groupName:'Demo'}});
  check(confirmations.length===confirmationCount&&errors.at(-1)==='ENVIRONMENT_GROUP_ACTION_INVALID','invalid event is rejected with fixed error');
  appContext.publicCommandCatalog=[{Name:'Stop-SqlServerLabEnvironmentGroup',RequiresConfirmation:true,ParameterSets:[{...lifecycleSet,MandatoryNames:['GroupId','Force'],Parameters:[...lifecycleSet.Parameters,{Name:'Force',TypeName:'System.Management.Automation.SwitchParameter',Mandatory:true,Sensitive:false,IsCredential:false}]}]}];
  appContext.handleEnvironmentGroupLifecycleRequest({detail:{action:'Stop',groupId,groupName:'Demo'}});
  check(confirmations.length===confirmationCount&&errors.at(-1)==='ENVIRONMENT_GROUP_COMMAND_UNAVAILABLE','changed command contract fails closed');
  console.log('ENVIRONMENT GROUPS BROWSER UI CHECKS: '+checks+' PASS; actual component and app handler with synthetic DOM/catalog');
})().catch(error=>{console.error(error);process.exitCode=1;});
