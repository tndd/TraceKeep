const $=id=>document.getElementById(id),invoke=window.__TAURI__?.core?.invoke;
const workerNames={cpu:'CPU',board:'基板',activity:'GPU',evidence:'イベント',extended:'拡張'};
const states={recording:'記録中',disabled:'収集対象外',stopped:'停止中',stale:'更新停止',missing:'未取得',error:'エラー',unknown:'未確認'};
function render(data,control){
  const m=window.MiniModel(data,control);
  $('status-title').textContent=m.recorder.label;
  $('light').className='light '+m.recorder.state;
  $('status-title').title='記録プロセスの状態です。ハードウェアの故障判定ではありません。';
  for(const name of ['cpu','gpu']){const r=m[name];$(name).textContent=r.fresh&&r.value!==null?r.value.toFixed(1):'—';$(name).classList.toggle('old',!r.fresh);$(name).title=r.fresh?'最新の記録値':r.state==='disabled'?'収集対象外':'最新の記録を確認できません';}
  $('workers').replaceChildren(...m.workers.map(w=>{const e=document.createElement('span');e.className='worker '+w.displayState;const dot=document.createElement('span');dot.className='worker-dot';dot.setAttribute('aria-hidden','true');e.append(dot,workerNames[w.name]||w.name);e.title=(workerNames[w.name]||w.name)+': '+(states[w.displayState]||w.displayState);e.setAttribute('aria-label',e.title);e.tabIndex=0;return e;}));
  $('notice').textContent=control.message||'';
}
async function refresh(){try{
  let data,control;
  if(invoke){[data,control]=await Promise.all([invoke('get_snapshot'),invoke('viewer_state')]);}
  else{const response=await fetch('preview.local.json',{cache:'no-store'});if(!response.ok)throw Error('Tauriアプリから開いてください。');data=await response.json();control={};$('preview').hidden=false;}
  render(data,control);
}catch(e){render({recorder:{state:'unknown',label:'取得できません'}},{message:String(e)});}finally{setTimeout(refresh,2000);}}
$('full').onclick=async()=>{try{if(invoke)await invoke('open_view',{view:'full'});else location.href='index.html';}catch(e){$('notice').textContent=String(e);}};
refresh();
