import React from 'react';
import {ArrowUpRightIcon,ChevronRightIcon,InformationCircleIcon} from '@heroicons/react/24/outline';
import * as d3 from 'd3';
import {Panel,Chord,Cap,Boxes,Clocks,Pack,Chart,txt,fmt,Tag} from './Charts';
import {useData,clock,precise} from './DataContext';


function BoardDistribution({onPick}){const {E}=useData();
 const values=E.board.map(r=>r.v12).filter(v=>Number.isFinite(v));
 const groups=[...d3.rollup(values,v=>v.length,v=>v)].sort((a,b)=>a[0]-b[0]);
 return <Chart height={210} label="基板12Vの実測度数" draw={(s,w,h)=>{
  if(!values.length){txt(s,w/2,h/2,'この期間の基板電圧は未取得','middle');return;} const x=d3.scaleLinear().domain([d3.min(values)-.012,d3.max(values)+.012]).range([40,w-12]);
  const y=d3.scaleLinear().domain([0,100]).range([h-35,22]);
  [0,25,50,75,100].forEach(v=>{s.append('line').attr('x1',40).attr('x2',w-12).attr('y1',y(v)).attr('y2',y(v)).attr('stroke','#263d48');txt(s,32,y(v)+4,v,'end')});
  groups.forEach(([v,n])=>{s.append('rect').attr('x',x(v)-5).attr('y',y(n/values.length*100)).attr('width',10).attr('height',h-35-y(n/values.length*100)).attr('rx',2).attr('fill','#bca0f4').style('cursor','pointer').on('click',()=>onPick(`基板 +12V / ${fmt(v,3)} V · ${n}標本`)).append('title').text(`${fmt(v,3)} V · ${n}標本`)});
  s.append('g').attr('class','axis').attr('transform',`translate(0,${h-35})`).call(d3.axisBottom(x).ticks(4).tickFormat(v=>fmt(v,2)));
  txt(s,40,12,'標本の割合 (%)');txt(s,w-12,h-2,'基板センサー +12V (V)','end');
 }}/>
}

export function DiagnosticSummary({onGo,onEvent,onInspect,onPick,eventChart,cpuChart}){const {D,E}=useData();const first=E.storage.find(s=>s.nvme.status==='ok')?.nvme.health?.counters||{},last=E.storage.filter(s=>s.nvme.status==='ok').at(-1)?.nvme.health?.counters||{},errors=E.events.filter(e=>e.level>0&&e.level<=2),delta=k=>E.nvmeDelta(k)===null?'—':'+'+E.nvmeDelta(k),time=t=>t?new Date(t).toLocaleTimeString():'—';
 return <div className="diagnostic-summary">
  <div className="diagnostic-strip">
   <button onClick={()=>onGo('settings')}><span>保存済みの時系列</span><strong>{D.sources.filter(s=>s.count>0).length}<small>系統</small></strong><em>CPU・基板・GPU・性能・プロセス</em><ArrowUpRightIcon/></button>
   <button onClick={()=>onGo('events')}><span>Windowsエラー</span><strong className="amber-text">{errors.reduce((n,e)=>n+e.count,0)}<small>件</small></strong><em>選択期間 / 内容を確認</em><ArrowUpRightIcon/></button>
   <button onClick={()=>onGo('disk')}><span>NVMe異常終了カウンター</span><strong>{delta('unsafeShutdowns')}<small>回</small></strong><em>期間内の増分 · 累積 {last.unsafeShutdowns??'—'}回</em><ArrowUpRightIcon/></button>
   <button onClick={()=>onInspect('NVMeカウンターの比較',{period:E.period,firstMinute:E.storage[0]?.t,lastMinute:E.storage.at(-1)?.t,first,last,note:'標本間の増分。故障の有無を保証するものではありません。'})}><span>NVMeメディアエラー</span><strong>{delta('mediaErrors')}<small>件</small></strong><em>期間内の増分 · 累積 {last.mediaErrors??'—'}件</em><ArrowUpRightIcon/></button>
  </div>

  <div className="three-grid diagnostic-plots">
   <Panel title="CPU負荷と温度の分布" eyebrow="CPU / LOAD × TEMPERATURE" action={<button className="text-button" onClick={()=>onGo('cpu')}>CPU <ArrowUpRightIcon/></button>}>
    <div className="panel-stat">{E.cpu.filter(r=>Number.isFinite(r.temp)&&Number.isFinite(r.load)).length}<small>標本 / 同時測定の負荷と温度</small></div>
    {cpuChart}
    <p className="diagnostic-caption">横軸：CPU負荷、縦軸：温度。周辺の棒は実測分布。</p>
   </Panel>
   <Panel title="GPUの動作状態" eyebrow="STATE TRANSITIONS" action={<button className="text-button" onClick={()=>onGo('gpu')}>GPU <ArrowUpRightIcon/></button>}>
    <div className="panel-stat">{D.transitions}<small>回 / 観測した状態遷移</small></div>
    <Chord compact onPick={onPick}/>
    <p className="diagnostic-caption">P-state間の移動を俯瞰。帯幅は遷移回数。</p>
   </Panel>
   <Panel title="SSD応答時間のばらつき" eyebrow="LATENCY DISTRIBUTION" action={<button className="text-button" onClick={()=>onGo('disk')}>ディスク <ArrowUpRightIcon/></button>}>
    <div className="panel-stat">{D.disk.length}<small>区間 / 読込・書込</small></div>
    <Boxes compact onPick={onPick}/>
    <p className="diagnostic-caption">区間平均の分布。箱は四分位、ひげは最小〜最大。</p>
   </Panel>
   <Panel title="基板電圧の分布" eyebrow="BOARD / VOLTAGE" action={<button className="text-button" onClick={()=>onGo('board')}>基板 <ArrowUpRightIcon/></button>}>
    <div className="panel-stat">{fmt(d3.min(E.board,r=>r.v12),3)}<small>— {fmt(d3.max(E.board,r=>r.v12),3)} V / 観測範囲</small></div>
    <BoardDistribution onPick={onPick}/>
    <p className="diagnostic-caption">+12Vの実測度数。基板の表示名は未検証。AC入力やPSU内部の直接測定ではありません。</p>
   </Panel>
   <Panel title="プロセス群のメモリ構成" eyebrow="MEMORY / PROCESS FAMILY" action={<button className="text-button" onClick={()=>onGo('memory')}>メモリ <ArrowUpRightIcon/></button>}>
    <div className="panel-stat">{D.processTree.id==null?0:D.processTree.children.length+1}<small>プロセス / {D.processTree.name} · {time(D.processTime)}</small></div>
    <Pack compact onPick={onPick}/>
    <p className="diagnostic-caption">面積＝Working Set、濃さ＝CPU秒。選択した親子群のみ、共有メモリの重複を含みます。</p>
   </Panel>
   <Panel title="GPU電力制限の記録" eyebrow="LIMIT COUNTER" action={<button className="text-button" onClick={()=>onGo('gpu')}>GPU <ArrowUpRightIcon/></button>}>
    <div className="panel-stat">{fmt(D.capTotal,2)}<small>秒 / 累積カウンターの有効増分</small></div>
    <Cap compact onPick={onPick}/>
    <p className="diagnostic-caption">瞬間フラグでは見えない制限の履歴。PSU故障を示す値ではありません。</p>
   </Panel>
  </div>

  <div className="wide-aside">
   <Panel title="イベントと調査の入口" eyebrow="EVIDENCE TIMELINE" action={<button className="text-button" onClick={()=>onGo('events')}>全イベント <ArrowUpRightIcon/></button>}>
    {eventChart}
    <div className="legend"><span><i style={{background:'#ff8895'}}/>エラー</span><span><i style={{background:'#e8b76d'}}/>警告</span><span><i style={{background:'#69b5dc'}}/>情報・詳細</span><span>1マス＝5分 · 色＝区間内の最重大レベル</span></div>
    <div className="evidence-entry-list">{errors.slice(0,10).map(e=><button key={e.recordId} onClick={()=>onEvent(e)}><time>{time(e.time)}</time><span className="dot red-dot"/><span><b>{e.provider.replace("Microsoft-Windows-","")} · {e.id}</b><small>{e.fields.find(f=>f.name==='MiniportName')?.value||e.provider} / 記録内容と前後のセンサー</small></span><ChevronRightIcon/></button>)}</div>
    <div className="data-note"><InformationCircleIcon/>PowerShellの反復記録は全イベントで表示。イベントの重大度だけで原因を判定しません。</div>
   </Panel>
   <Panel title="記録の取得状況" eyebrow="RECORDING COVERAGE" action={<Tag>期間内の実測</Tag>}>
    <div className="coverage-table"><div className="coverage-heading"><span>ソース / 標本数</span><span>最大記録間隔</span></div>{D.sources.map(s=><button key={s.name} onClick={()=>onInspect(s.name+'の取得状況',{period:E.period,samples:s.count,first:s.first,last:s.last,maxIntervalSeconds:s.maxGap,note:'保存ログ内の実測間隔。現在の稼働状態ではありません。'})}><span><b>{s.name}</b><small>{s.count.toLocaleString()}件 · 最終 {time(s.last)}</small></span><strong>{fmt(s.maxGap,2)}<small> 秒</small></strong></button>)}</div>
    <div className="coverage-foot"><InformationCircleIcon/><span>設定間隔と実測間隔を区別<small>プロセス群は直近2標本を保持</small></span></div>
    <button className="text-button" onClick={()=>onGo('settings')}>収集設定・ソースの詳細 <ArrowUpRightIcon/></button>
   </Panel>
  </div>
 </div>
}
