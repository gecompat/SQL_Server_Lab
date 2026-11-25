'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../../..');
const html = fs.readFileSync(path.join(root, 'Ui/index.html'), 'utf8');

class Control {
  constructor() {
    this.listeners = new Map();
    this.children = [];
    this.value = '';
    this.checked = false;
  }
  addEventListener(name, listener) {
    this.listeners.set(name, listener);
  }
  fire(name) {
    return this.listeners.get(name)?.({preventDefault() {}});
  }
  replaceChildren() {
    this.children = [];
    this.value = '';
  }
  appendChild(child) {
    this.children.push(child);
  }
}

const controls = new Map([...html.matchAll(/id="(ovms-gateway-[^"]+)"/g)].map(match => [match[1],new Control()]));
const item = name => controls.get('ovms-gateway-' + name);
const defaults = {
  UpstreamLocation:'http://127.0.0.1:9000/v3/embeddings', RuntimeModel:'fixture-model',
  CertificatePath:'X:/fixture/cert.pem', PrivateKeyPath:'X:/fixture/key.pem', TrustedRootPath:'',
  ApiKeyReference:'SQL_SERVER_LAB_SECRET_FIXTURE', Port:'18443', Dimension:'3', StartTimeoutSeconds:'30', LeaseSeconds:'900'
};
const fields = new Map(Object.keys(defaults).map(name => [name,new Control()]));
const form = item('form');
form.elements = {namedItem: name => fields.get(name)};
form.reportValidity = () => true;
form.reset = () => {
  for (const [name, control] of fields) control.value = defaults[name];
  item('start-confirm').checked = false;
};
item('dialog').showModal = () => { item('dialog').open = true; };
const id = '10000000-1234-4567-890a-100000000001';
const sent = [];
const replies = [];
const source = fs.readFileSync(path.join(root, 'Ui/ai-shared-gateway-plan.js'), 'utf8');
vm.runInNewContext(source, {
  document:{querySelector: selector => controls.get(selector.slice(1)), createElement: () => new Control()},
  async sqlServerLabUiFetch(url, request) {
    sent.push({url, body:request.body && JSON.parse(request.body)});
    assert.match(url, /^\/api\/ai-ovms-gateway\/sessions$/);
    assert.ok(replies.length);
    const reply = replies.shift();
    return {ok:true, async json() { return reply; }};
  }
});

(async () => {
  replies.push({Supported:true,VaultAvailable:false,Items:[]});
  await item('open').fire('click');
  item('start-confirm').checked = true;
  item('start-confirm').fire('change');
  assert.equal(item('start').disabled, true);

  replies.push({Supported:true,VaultAvailable:true,Items:[]});
  await item('read').fire('click');
  fields.get('RuntimeModel').fire('input');
  assert.equal(item('start').disabled, true);
  await form.fire('submit');
  assert.equal(sent.length, 2);

  item('start-confirm').checked = true;
  item('start-confirm').fire('change');
  replies.push({
    Contract:'SqlServerLab.AiOvmsHttpsGateway/1.0', Status:'ENDPOINT_VERIFIED', OperationId:id,
    Location:'https://127.0.0.1:18443/v3/embeddings', RuntimeModel:'fixture-model', Dimension:3, LeaseSeconds:900,
    ServerCertificateSha256:'a'.repeat(64), UpstreamBindingKey:'b'.repeat(64), BindingKey:'c'.repeat(64)
  });
  await form.fire('submit');
  assert.equal(sent.at(-1).body.Port, 18443);
  assert.equal(sent.at(-1).body.Action, 'Start');
  assert.equal(JSON.parse(item('result').value).OperationId,id);
  assert.equal(item('start').disabled,true);

  replies.push({Supported:true,VaultAvailable:false,Items:[{OperationId:id,Port:18443,Status:'OWNED_SESSION'}]});
  await item('read').fire('click');
  const selection = item('selection');
  selection.value = '10000000-1234-4567-890a-100000000002';
  item('stop-confirm').checked = true;
  item('stop-confirm').fire('change');
  await item('stop').fire('click');
  assert.equal(sent.length,4);
  selection.value = id;
  selection.fire('change');
  assert.equal(item('stop').disabled,true);
  item('stop-confirm').checked = true;
  item('stop-confirm').fire('change');
  replies.push({Status:'CLEANUP_SUCCEEDED',OperationId:id});
  await item('stop').fire('click');
  assert.deepEqual(sent.at(-1).body,{Action:'Stop',Confirmed:true,OperationId:id});
  assert.equal(item('stop').disabled,true);
  console.log('GUIDED OVMS GATEWAY UI: PASS');
})().catch(error => {console.error(error);process.exitCode=1;});
