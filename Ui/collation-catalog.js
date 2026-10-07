'use strict';
(() => {
  const el = id => document.querySelector('#collation-' + id);
  const shape = (v,k) => v !== null && typeof v === 'object' && !Array.isArray(v) && Object.keys(v).length === k.length && Object.keys(v).every(n => k.includes(n));
  const clean = v => typeof v === 'string' && !/[\u0000-\u001f\u007f-\u009f]/.test(v);
  function valid(v, sql) {
    return shape(v,['Contract','SqlVersion','Status','Results','ReturnedCount','Truncated','SqlValidation','ExecutionSupported','MutationAllowed','Actions']) &&
      shape(v.Contract,['Name','Version']) && v.Contract.Name === 'SqlServerLab.CollationCatalogueSearch' && v.Contract.Version === '1.0' && v.SqlVersion === sql &&
      Array.isArray(v.Results) && v.Results.length <= 100 && Number.isInteger(v.ReturnedCount) && v.ReturnedCount === v.Results.length && typeof v.Truncated === 'boolean' &&
      (!v.Truncated || v.Results.length === 100) && v.Status === (v.Results.length ? 'MATCHES' : 'NO_MATCHES') && v.SqlValidation === 'NOT_CHECKED' &&
      v.ExecutionSupported === false && v.MutationAllowed === false && Array.isArray(v.Actions) && !v.Actions.length &&
      v.Results.every(r => shape(r,['Name','Locale','CodePage','Lcid','CaseSensitivity','AccentSensitivity','Utf8','Status','SqlVersion']) &&
        clean(r.Name) && /^[A-Za-z0-9_]{1,128}$/.test(r.Name) && clean(r.Locale) && r.Locale.trim().length > 0 && r.Locale.length <= 256 &&
        Number.isInteger(r.CodePage) && r.CodePage >= 0 && r.CodePage <= 2147483647 && Number.isInteger(r.Lcid) && r.Lcid >= 0 && r.Lcid <= 2147483647 &&
        ['CI','CS','BIN','BIN2'].includes(r.CaseSensitivity) && ['AI','AS','NOT_APPLICABLE'].includes(r.AccentSensitivity) &&
        typeof r.Utf8 === 'boolean' && ['SUPPORTED','DEPRECATED'].includes(r.Status) && r.SqlVersion === sql);
  }
  let revision = 0, busy = false;
  function clear() {revision++; busy=false; el('search').disabled=false; el('results').replaceChildren(); el('status').textContent='SQL-Prüfung: NOT_CHECKED';}
  async function search() {
    if(busy || !el('dialog').open) return;
    const sql=el('sql').value, query=el('query').value;
    if(!['2019','2022','2025'].includes(sql) || !clean(query) || query.length>256){clear();el('status').textContent='Suchangaben prüfen.';return;}
    const current=++revision; busy=true;el('search').disabled=true;el('results').replaceChildren();el('status').textContent='Katalog wird gelesen.';
    try {
      const response=await sqlServerLabUiFetch('/api/collations/search',{method:'POST',headers:{'Content-Type':'application/json; charset=utf-8'},body:JSON.stringify({SqlVersion:sql,Query:query})});
      if(current!==revision || !el('dialog').open)return;
      if(!response.ok)throw new Error('INVALID');
      const view=await response.json();
      if(current!==revision || !el('dialog').open)return;
      if(!valid(view,sql) || new TextEncoder().encode(JSON.stringify(view)).length>65536)throw new Error('INVALID');
      for(const r of view.Results){
        const item=document.createElement('li');
        item.textContent=r.Name+' · '+r.Locale+' · Codepage '+r.CodePage+' · LCID '+r.Lcid+' · '+r.CaseSensitivity+'/'+r.AccentSensitivity+' · UTF-8: '+(r.Utf8?'ja':'nein')+(r.Status==='DEPRECATED'?' · DEPRECATED: weiterhin zulässig, veralteter Default':' · SUPPORTED');
        el('results').appendChild(item);
      }
      el('status').textContent=(view.Results.length?view.ReturnedCount+' Katalogtreffer.':'Keine Katalogtreffer.')+(view.Truncated?' Weitere Treffer vorhanden; Suche eingrenzen.':'')+' SQL-Prüfung: NOT_CHECKED. Keine Auswahl übernommen.';
    }catch{if(current===revision && el('dialog').open){clear();el('status').textContent='Katalogsuche nicht bestätigt. Suchangaben prüfen.';}}
    finally{if(current===revision){busy=false;el('search').disabled=false;}}
  }
  el('open').addEventListener('click',()=>{clear();el('sql').value='2025';el('query').value='';el('dialog').showModal();});
  el('search').addEventListener('click',search);
  el('query').addEventListener('input',clear);el('sql').addEventListener('change',clear);
  function cancel(){clear();el('query').value='';el('sql').value='2025';}
  el('close').addEventListener('click',()=>{cancel();el('dialog').close();});
  for(const event of ['cancel','close'])el('dialog').addEventListener(event,cancel);
})();
