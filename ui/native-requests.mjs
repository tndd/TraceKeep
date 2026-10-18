// Deadlines affect only reads. A timed-out native operation is not cancelled;
// reuse its promise so periodic refreshes cannot queue more work behind it.
export function createReadClient(invoke, clock=globalThis) {
  const pending=new Map();
  return function read(command,args,timeoutMs=10000) {
    const key=JSON.stringify(args??null);
    let flight=pending.get(command);
    if(flight&&flight.key!==key)return Promise.reject(Error('前の記録読み取りがまだ終了していません。しばらくしてから再試行してください。'));
    if(!flight){
      flight={key,promise:Promise.resolve().then(()=>invoke(command,args))};
      pending.set(command,flight);
      const clear=()=>{if(pending.get(command)===flight)pending.delete(command)};
      flight.promise.then(clear,clear);
    }
    return new Promise((resolve,reject)=>{
      const timer=clock.setTimeout(()=>reject(Error(command==='query_history'
        ?'保存ログの読み取りが時間内に完了しませんでした。再試行できます。記録処理は継続します。'
        :'最新状態の読み取りが時間内に完了しませんでした。再接続を試みています。')),timeoutMs);
      flight.promise.then(value=>{clock.clearTimeout(timer);resolve(value)},error=>{clock.clearTimeout(timer);reject(error)});
    });
  };
}
