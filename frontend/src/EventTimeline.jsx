import React from 'react';
import * as d3 from 'd3';
import {Chart,txt} from './Charts';
import {useData,clock} from './DataContext';
import {eventTone} from './summary-data.mjs';

const levelColor=n=>n>0&&n<=2?'#ff8895':n===3?'#e8b76d':'#69b5dc';
const intensity=[0,.32,.48,.65,.82,1];
const fillFor=(n,level)=>n?d3.interpolateRgb('#101e28',levelColor(level))(intensity[eventTone(n)]):'#11202a';
export function EventTimeline({compact=false,onPick,events=[]}){
 const {E}=useData(),time=t=>clock(E.start,t),providers=[...new Set(events.map(e=>e.provider))];
 const grouped=d3.group(events,e=>e.provider,e=>Math.floor(e.t/5));
 return <><Chart height={Math.max(115,providers.length*(compact?28:34)+45)} label="発生元別イベントヒートマップ・色は重大度、濃淡は件数" draw={(s,w,h)=>{
  if(!providers.length){txt(s,w/2,h/2,'この期間のイベント記録はありません','middle');return;}
  const left=w<500?112:compact?146:196,right=12,bottom=h-30,step=(bottom-8)/providers.length;
  const x=d3.scaleLinear().domain([0,120]).range([left,w-right]);
  providers.forEach((p,i)=>{
   const top=7+i*step,label=p.replace('Microsoft-Windows-','');
   txt(s,0,top+step/2+3,label.slice(0,w<500?16:compact?22:30));
   for(let b=0;b<24;b++){
    const bucket=grouped.get(p)?.get(b)||[],n=d3.sum(bucket,e=>e.count);
    const lead=[...bucket].sort((a,b)=>(a.level||4)-(b.level||4)||a.t-b.t)[0];
    const width=Math.max(1,x((b+1)*5)-x(b*5)-3),height=Math.max(8,step-5),fill=fillFor(n,lead?.level);
    const title=`${label} / ${time(b*5)}–${time((b+1)*5)} / ${n}件`;
    const cell=s.append('rect').attr('x',x(b*5)+1.5).attr('y',top).attr('width',width).attr('height',height).attr('rx',2).attr('fill',fill).attr('stroke','none');
    cell.append('title').text(title+(lead?' · クリックで記録を表示':' · 保存データ内に記録なし'));
    if(lead){
     const open=()=>onPick({...lead,bucketStart:b*5,bucketEnd:(b+1)*5,bucketCount:n,bucketEvents:bucket});
     const enter=function(){d3.select(this).attr('stroke','#dae9f0').attr('stroke-width',1)},leave=function(){d3.select(this).attr('stroke','none')};
     cell.style('cursor','pointer').attr('role','button').attr('tabindex',0).attr('aria-label',title)
      .on('click',open).on('keydown',ev=>{if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();open()}})
      .on('pointerenter',enter).on('pointerleave',leave).on('focus',enter).on('blur',leave);
    }
   }
  });
  s.append('g').attr('class','axis').attr('transform',`translate(0,${bottom})`).call(d3.axisBottom(x).tickValues([0,20,40,60,80,100,120]).tickFormat(time));
 }}/><div className="heat-scale event-heat-scale"><span>件数 / 5分</span>{[[0,'0'],[1,'1–2'],[3,'3–9'],[10,'10–99'],[100,'100–999'],[1000,'1000+']].map(([n,label])=><span className="heat-key" key={n}><span className="heat-key-colors">{[4,3,2].map(level=><i key={level} style={{background:fillFor(n,level)}}/>)}</span>{label}</span>)}</div><p className="event-grid-note">色＝区間内の最重大レベル、濃淡＝全レベルの合計件数。暗い空欄は保存データ内に記録なし。欠測の有無は取得状況で確認。</p></>
}
