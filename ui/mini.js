const $=id=>document.getElementById(id),invoke=window.__TAURI__?.core?.invoke;
let pending=false,preview=false;
const workerNames={cpu:'CPU',board:'基板',activity:'GPU・負荷',evidence:'イベント',extended:'追加証拠'};
const states={recording:'記録中',disabled:'収集対象外',stopped:'停止中',stale:'更新停止',missing:'未取得',error:'エラー',unknown:'未確認'};
function render(data,control){
  const m=window.MiniModel(data,{...control,busy:control.busy||pending});
  $('status-title').textContent=m.recorder.label;
  $('light').className='light '+m.recorder.state;
  $('status-detail').textContent=m.recorder.state==='recording'?'停止の前後を調べるため、ログを保存しています。':m.recorder.state==='stopped'?'再開するには「記録を開始」を押してください。':'最終保存時刻と記録プロセスの状態を確認してください。';
  $('updated').textContent='最終更新 '+(m.recorder.time?new Date(m.recorder.time).toLocaleTimeString('ja-JP'):'—');
  for(const name of ['cpu','gpu']){const r=m[name];$(name).textContent=r.value===null?'—':r.value.toFixed(1);$(name).classList.toggle('old',!r.fresh);$(name+'-age').textContent=r.state==='disabled'?'収集対象外':r.value===null?'取得できていません':r.fresh?'最新の測定値':'最終値 / '+(typeof r.age==='number'?Math.max(0,Math.round(r.age))+'秒前':'時刻不明');}
  $('load').textContent=m.load.fresh&&m.load.value!==null?Math.round(m.load.value)+'%':'—';$('load-meter').value=m.load.fresh&&m.load.value!==null?m.load.value:0;
  $('worker-count').textContent=m.recorder.state==='recording'?m.recorder.runningWorkers+' / '+m.recorder.enabledWorkers+' 稼働':'状態を確認';
  $('workers').replaceChildren(...m.workers.map(w=>{const e=document.createElement('span');e.className='worker '+w.displayState;e.textContent=workerNames[w.name]||w.name;e.title=states[w.displayState]||w.displayState;e.setAttribute('aria-label',e.textContent+' '+e.title);return e;}));
  $('start').disabled=!m.canStart||preview;$('stop').disabled=!m.canStop||preview;
  $('startup').checked=!!control.startup;$('startup').disabled=m.busy||preview;
  $('notice').textContent=control.message||'';
}
async function refresh(){try{
  let data,control;
  if(invoke){[data,control]=await Promise.all([invoke('get_snapshot'),invoke('viewer_state')]);}
  else{preview=true;const response=await fetch('preview.local.json',{cache:'no-store'});if(!response.ok)throw Error('Tauriアプリから開いてください。');data=await response.json();control={};$('preview').hidden=false;}
  render(data,control);
}catch(e){$('status-title').textContent='状態を取得できません';$('light').className='light';$('notice').textContent=String(e);$('start').disabled=true;$('stop').disabled=true;}finally{setTimeout(refresh,2000);}}
async function action(action){if(pending||!invoke)return;pending=true;$('start').disabled=true;$('stop').disabled=true;$('notice').textContent='Windows の確認画面で操作を許可してください。';try{await invoke('recorder_action',{action});}catch(e){$('notice').textContent=String(e);}finally{pending=false;}}
$('start').onclick=()=>action('start');
$('stop').onclick=()=>$('stop-dialog').showModal();
$('cancel-stop').onclick=()=>$('stop-dialog').close();
$('confirm-stop').onclick=()=>{$('stop-dialog').close();action('stop');};
$('full').onclick=async()=>{try{if(invoke)await invoke('open_view',{view:'full'});else location.href='index.html';}catch(e){$('notice').textContent=String(e);}};
$('startup').onchange=async()=>{const enabled=$('startup').checked;$('startup').disabled=true;try{await invoke('set_viewer_startup',{enabled});}catch(e){$('startup').checked=!enabled;$('notice').textContent=String(e);}finally{$('startup').disabled=false;}};
refresh();
