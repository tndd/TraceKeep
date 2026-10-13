import React,{useEffect,useState} from 'react';
import {createRoot} from 'react-dom/client';
import {App} from './App';
import {buildModel} from './model.mjs';
import {DataContext} from './DataContext';
import './styles.css';
import './production.css';
const invoke=window.__TAURI__?.core?.invoke;
const localInput=d=>new Date(d.getTime()-d.getTimezoneOffset()*60000).toISOString().slice(0,16);
class Boundary extends React.Component{componentDidCatch(error){invoke?.('report_workspace_state',{ready:false,message:String(error)}).catch(()=>{})}state={error:null};static getDerivedStateFromError(error){return{error:String(error)}}render(){return this.state.error?<div className="load-screen"><h1>画面を表示できません</h1><p>{this.state.error}</p><button onClick={()=>location.reload()}>再読み込み</button></div>:this.props.children}}
function Root(){
 const [model,setModel]=useState(null),[end,setEnd]=useState(localInput(new Date())),[loading,setLoading]=useState(false),[error,setError]=useState(''),[status,setStatus]=useState(null),[viewer,setViewer]=useState(null),[busy,setBusy]=useState(false),[notice,setNotice]=useState('');
 async function load(at=end){setLoading(true);setError('');try{let raw;if(invoke){const b=new Date(at),a=new Date(b-7200000);raw=await invoke('query_history',{start:a.toISOString(),end:b.toISOString()});}else{const r=await fetch('./history.local.json',{cache:'no-store'});if(!r.ok)throw Error('TraceKeepアプリから開いてください。ブラウザでは保存されたCUI出力のみ閲覧できます。');raw=await r.json();setEnd(localInput(new Date(raw.end)));}setModel(buildModel(raw));}catch(e){setError(String(e));invoke?.('report_workspace_state',{ready:false,message:String(e)}).catch(()=>{})}finally{setLoading(false)}}
 useEffect(()=>{load();let cancelled=false,timer;async function state(){try{if(invoke){const [s,v]=await Promise.all([invoke('get_snapshot'),invoke('viewer_state')]);if(!cancelled){setStatus(old=>old?.recorder?.state===s.recorder?.state&&old?.recorder?.label===s.recorder?.label?old:{recorder:s.recorder});setViewer(old=>JSON.stringify(old)===JSON.stringify(v)?old:v)}}}catch(e){if(!cancelled)setStatus({recorder:{state:'unknown',label:'状態取得失敗'}})}finally{if(!cancelled)timer=setTimeout(state,5000)}}state();return()=>{cancelled=true;clearTimeout(timer)}},[]);
 async function action(fn){if(busy)return;setBusy(true);setNotice('操作の完了を待っています…');try{const result=await fn();setNotice(typeof result==='string'?result:'操作が完了しました。');if(invoke){setStatus(await invoke('get_snapshot'));setViewer(await invoke('viewer_state'));}}catch(e){setNotice(String(e))}finally{setBusy(false)}}
 const runtime={status,viewer,busy:busy||viewer?.busy,native:!!invoke,
 openMini:()=>invoke?action(()=>invoke('open_view',{view:'mini'})):setNotice('簡易モニターはデスクトップアプリで開けます。'),
 close:()=>invoke?window.__TAURI__.window.getCurrentWindow().close():setNotice('ブラウザ表示です。記録処理に影響しません。'),
 exportData:value=>action(async()=>'保存先: '+await invoke('export_history_view',{value})),
 control:mode=>{if(mode==='stop'&&!confirm('記録を停止します。停止中の診断情報は収集されません。続けますか？'))return;action(()=>invoke('recorder_action',{action:mode}))},
 startup:enabled=>action(()=>invoke('set_viewer_startup',{enabled})),
 configure:(module,enabled)=>{if(!confirm(`${module}を${enabled?'有効':'無効'}にします。動作中の記録が短時間中断し、管理者確認が表示されます。続けますか？`))return;action(async()=>{await invoke('configure_module',{module,enabled});await load()})}
 };
 useEffect(()=>{if(model&&invoke)invoke('report_workspace_state',{ready:true,message:'Device workspace rendered from saved records'}).catch(()=>{})},[model]);
 const warnings=model?Object.entries(model.raw.streams).filter(([,v])=>v.truncated||v.issues?.length||v.unresolvedReferences||v.invalidLines).map(([k])=>k):[];
 return <><div className="history-toolbar"><strong>記録期間</strong><label>終了時刻<input type="datetime-local" aria-label="記録期間の終了時刻" value={end} disabled={!invoke||loading} onChange={e=>setEnd(e.target.value)}/></label><span>までの2時間</span><button disabled={loading} onClick={()=>load()}>{loading?'読み込み中…':'期間を読み込む'}</button><button disabled={loading||!invoke} onClick={()=>{const n=localInput(new Date());setEnd(n);load(n)}}>直近2時間</button><span>保存ログを手動更新</span></div>{error&&<div className="runtime-notice" role="alert">{error}</div>}{notice&&<div className="runtime-notice" role="status">{notice}<button onClick={()=>setNotice('')}>閉じる</button></div>}{warnings.length>0&&<div className="runtime-notice">読み取り制限・欠損あり：{warnings.join(' / ')}。詳細は収集設定へ。表示範囲の完全性は保証されません。</div>}{model?<DataContext.Provider value={model}><App key={model.raw.queriedAt} runtime={runtime}/></DataContext.Provider>:<div className="load-screen"><h1>TraceKeep</h1><p>{loading?'保存済みの診断記録を読み込んでいます…':'表示する記録を読み込んでください。'}</p></div>}</>
}
createRoot(document.getElementById('root')).render(<Boundary><Root/></Boundary>);
