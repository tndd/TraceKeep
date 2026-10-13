// Fixed count thresholds keep heatmap shades comparable across sources and filters.
export const eventCountStops=[1,3,10,100,1000];
export const eventTone=count=>count<=0?0:1+eventCountStops.slice(1).filter(n=>count>=n).length;
export function voltageOccupancy(rows,minutes=120){
 const valid=rows.filter(r=>Number.isFinite(r.t)&&r.t>=0&&r.t<minutes&&Number.isFinite(r.v12));
 const values=[...new Set(valid.map(r=>r.v12))].sort((a,b)=>a-b),count=24,step=minutes/count;
 if(!values.length)return {bands:[],totals:Array(count).fill(0),sampleCount:0,step};
 const min=values[0],max=values.at(-1),binned=values.length>12,width=(max-min)/12;
 const bands=(binned?Array.from({length:12},(_,i)=>({lo:min+i*width,hi:i===11?max:min+(i+1)*width})):values.map(v=>({lo:v,hi:v}))).map(b=>({...b,counts:Array(count).fill(0),total:0}));
 const totals=Array(count).fill(0);
 for(const r of valid){const column=Math.min(count-1,Math.floor(r.t/step)),band=binned?Math.min(11,Math.floor((r.v12-min)/width)):values.indexOf(r.v12);bands[band].counts[column]++;bands[band].total++;totals[column]++;}
 return {bands,totals,sampleCount:valid.length,step,binned};
}
