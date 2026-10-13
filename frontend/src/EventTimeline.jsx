import React from 'react';
import * as d3 from 'd3';
import {Chart,txt} from './Charts';

const levelColor=n=>n>0&&n<=2?'#ff8895':n===3?'#e8b76d':'#69b5dc';

export function EventTimeline({compact=false,onPick,events=[]}){
 const {E}=useData();const time=t=>clock(E.start,t); const providers=[...new Set(events.map(e=>e.provider))];
 return <><Chart height={Math.max(115,providers.length*(compact?32:39)+45)} label="発生元別イベントタイムライン" draw={(s,w,h)=>{
  if(!providers.length){txt(s,w/2,h/2,'この期間のイベント記録はありません','middle');return;} const left=w<500?112:compact?146:196,right=12,bottom=h-30,step=(bottom-8)/Math.max(1,providers.length);
  const x=d3.scaleLinear().domain([0,120]).range([left,w-right]);
  providers.forEach((p,i)=>{
   const top=7+i*step,label=p.replace('Microsoft-Windows-','');
   txt(s,0,top+step/2+4,label.slice(0,w<500?16:compact?22:30));
   for(let b=0;b<24;b++){
    const bucket=events.filter(e=>e.provider===p&&e.t>=b*5&&e.t<(b+1)*5),n=d3.sum(bucket,e=>e.count);
    const lead=[...bucket].sort((a,b)=>(a.level||4)-(b.level||4)||a.t-b.t)[0];
    const width=Math.max(1,x((b+1)*5)-x(b*5)-2),height=Math.max(10,step-7);
    const cell=s.append('rect').attr('x',x(b*5)+1).attr('y',top).attr('width',width).attr('height',height).attr('rx',2)
     .attr('fill',lead?levelColor(lead.level):'#142832').attr('stroke',lead?levelColor(lead.level):'#243b47').attr('stroke-opacity',.75).attr('fill-opacity',lead?.78:1);
    if(lead){
     const title=`${label} / ${time(b*5)}–${time((b+1)*5)} / ${n}件`;
     const open=()=>onPick({...lead,bucketStart:b*5,bucketEnd:(b+1)*5,bucketCount:n,bucketEvents:bucket});
     cell.style('cursor','pointer').attr('role','button').attr('tabindex',0).attr('aria-label',title)
      .on('click',open).on('keydown',ev=>{if(ev.key==='Enter'||ev.key===' '){ev.preventDefault();open()}})
      .on('pointerenter',function(){d3.select(this).attr('fill-opacity',1).attr('stroke','#ecf7ff')})
      .on('pointerleave',function(){d3.select(this).attr('fill-opacity',.78).attr('stroke',levelColor(lead.level))});
     cell.append('title').text(title+' · クリックで区間内の記録を表示');
     if(width>=20)txt(s,x(b*5)+1+width/2,top+height/2+4,n>999?'1k+':n,'middle','#08202b').attr('pointer-events','none');
    }
   }
  });
  s.append('g').attr('class','axis').attr('transform',`translate(0,${bottom})`).call(d3.axisBottom(x).tickValues([0,20,40,60,80,100,120]).tickFormat(time));
 }}/><p className="event-grid-note">1マス＝5分の集計区間（イベントの継続時間ではありません）。暗いマス＝この保存データに該当記録なし。</p></>
}

import {useData,clock} from './DataContext';
