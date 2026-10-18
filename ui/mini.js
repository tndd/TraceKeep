import {createReadClient} from './native-requests.mjs';
const $=id=>document.getElementById(id),invoke=window.__TAURI__?.core?.invoke;
const read=invoke?createReadClient(invoke):null;
let reported='';
function notice(message=''){$('notice-message').textContent=message;$('notice').hidden=!message;}
const workerNames={cpu:'CPU',board:'基板',activity:'GPU',evidence:'イベント',extended:'拡張'};
const states={recording:'記録中',disabled:'収集対象外',stopped:'停止中',stale:'更新停止',missing:'未取得',error:'エラー',unknown:'未確認'};
function render(data,control){
  const m=window.MiniModel(data,control);
  for(const name of ['cpu','gpu']){
    const r=m[name],g=TemperatureGauge.reading(r.value,r.fresh,name),node=$(name+'-gauge');
    $(name).textContent=g.available?Math.round(g.value):'—';$(name).classList.toggle('old',!g.available);
    const anchors=TemperatureGauge.profiles[name];
    node.title=g.available?`${name.toUpperCase()} ${g.value.toFixed(1)} °C / 色の目安: 緑 ${anchors.green}°C以下・黄 ${anchors.yellow}°C・赤 ${anchors.red}°C以上（故障判定ではありません）`:r.state==='disabled'?'収集対象外':'最新の記録を確認できません';
    node.setAttribute('role',g.available?'meter':'img');node.setAttribute('aria-label',name.toUpperCase()+'温度');
    if(g.available){node.setAttribute('aria-valuemin','0');node.setAttribute('aria-valuemax',String(Math.max(100,g.value)));node.setAttribute('aria-valuenow',String(g.value));node.setAttribute('aria-valuetext',g.value.toFixed(1)+' °C');}
    else {for(const a of ['aria-valuemin','aria-valuemax','aria-valuenow','aria-valuetext'])node.removeAttribute(a);node.setAttribute('aria-label',name.toUpperCase()+'温度: 最新値を確認できません');}
    TemperatureGauge.draw($(name+'-arc'),g);
  }
  $('workers').replaceChildren(...m.workers.map(w=>{const e=document.createElement('span');e.className='worker '+w.displayState;const dot=document.createElement('span');dot.className='worker-dot';dot.setAttribute('aria-hidden','true');e.append(dot,workerNames[w.name]||w.name);e.title=(workerNames[w.name]||w.name)+': '+(states[w.displayState]||w.displayState);e.setAttribute('aria-label',e.title);e.tabIndex=0;return e;}));
  notice(control.message||(data.recorder?.state==='stopped'?'記録は停止中です。再開には管理者の確認が必要です。':''));
  $('resume').hidden=!invoke||data.recorder?.state!=='stopped';$('resume').disabled=!!control.busy;
  const health=JSON.stringify({recorder:data.recorder?.state||'unknown',launchChecked:!!control.launchChecked,cpuFresh:!!m.cpu.fresh,gpuFresh:!!m.gpu.fresh,workers:m.workers.map(w=>w.displayState)});
  if(invoke&&health!==reported){reported=health;invoke('report_workspace_state',{ready:true,message:health,view:'mini'}).catch(()=>{});}
}
async function refresh(){try{
  let data,control;
  if(invoke){[data,control]=await Promise.all([read('get_snapshot'),read('viewer_state')]);}
  else{const response=await fetch('preview.local.json',{cache:'no-store'});if(!response.ok)throw Error('Tauriアプリから開いてください。');data=await response.json();control={};$('preview').hidden=false;}
  render(data,control);
}catch(e){render({recorder:{state:'unknown',label:'取得できません'}},{message:String(e)});}finally{setTimeout(refresh,2000);}}
$('resume').onclick=async()=>{$('resume').disabled=true;notice('管理者権限の確認と記録の開始を待っています…');try{await invoke('recorder_action',{action:'start'});}catch(e){notice(String(e));}finally{$('resume').disabled=false;}};
$('full').onclick=async()=>{try{if(invoke)await invoke('open_view',{view:'full'});else location.href='index.html';}catch(e){notice(String(e));}};
$('close').onclick=async()=>{try{if(invoke)await window.__TAURI__.window.getCurrentWindow().close();else notice('アプリではトレイに戻ります。記録は継続します。');}catch(e){notice(String(e));}};
document.querySelector('header').addEventListener('mousedown',async e=>{
  if(e.button!==0||e.target.closest('button')||!invoke)return;
  try{await window.__TAURI__.window.getCurrentWindow().startDragging();}catch(e){notice(String(e));}
});
refresh();
