(function(root){
  function model(data,control={}){
    const recorder=data?.recorder||{state:'unknown',label:'記録状態を確認できません'};
    const stream=(name)=>data?.streams?.[name]||{};
    const reading=(name,key)=>{const s=stream(name),value=s.history?.at(-1)?.[key];return {value:typeof value==='number'&&Number.isFinite(value)?value:null,age:s.age,state:s.state,fresh:s.state==='recording'&&recorder.state==='recording'};};
    const workers=['cpu','board','activity','evidence','extended'].map(name=>(data?.coordinator?.runtime?.workers||[]).find(w=>w.name===name)||{name,state:'unknown'}).map(w=>({...w,displayState:['unknown','unconfigured'].includes(recorder.state)?'unknown':['stopped','stopping'].includes(recorder.state)?'stopped':w.state==='recording'&&w.errorCount!==0?'error':w.state==='recording'&&['cpu','board','activity'].includes(w.name)&&stream(w.name).state!=='recording'?'stale':w.state}));
    return {recorder,workers,cpu:reading('cpu','cpuTemp'),gpu:reading('activity','gpuTemp'),load:reading('activity','cpuLoad'),busy:!!control.busy,
      canStart:!control.busy&&recorder.state==='stopped',canStop:!control.busy&&['recording','attention','unknown'].includes(recorder.state)&&data?.coordinator?.configured===true};
  }
  root.MiniModel=model;if(typeof module!=='undefined')module.exports=model;
})(typeof window==='undefined'?globalThis:window);
