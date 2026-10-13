(function(root){
  const palette={green:[67,237,152],yellow:[255,210,85],red:[255,92,104]};
  // Presentation anchors, not thermal protection limits or fault diagnoses.
  const profiles={cpu:{green:70,yellow:85,red:95},gpu:{green:60,yellow:75,red:90}};
  function reading(value,fresh,kind){
    const p=profiles[kind]||profiles.cpu;
    if(!fresh||typeof value!=='number'||!Number.isFinite(value)||value<0||value>150)return {available:false,fraction:0,color:'rgb(86,103,121)',value:null};
    let from=palette.green,to=palette.green,t=0;
    if(value>p.yellow){from=palette.yellow;to=palette.red;t=Math.min(1,(value-p.yellow)/(p.red-p.yellow));}
    else if(value>p.green){to=palette.yellow;t=(value-p.green)/(p.yellow-p.green);}
    return {available:true,value,fraction:Math.min(1,value/100),color:'rgb('+from.map((n,i)=>Math.round(n+(to[i]-n)*t)).join(',')+')'};
  }
  function draw(canvas,r){
    const rect=canvas.getBoundingClientRect(),dpr=Math.min(window.devicePixelRatio||1,3);
    canvas.width=Math.round(rect.width*dpr);canvas.height=Math.round(rect.height*dpr);
    const ctx=canvas.getContext('2d');if(!ctx)return;
    ctx.scale(dpr,dpr);const cx=rect.width/2,cy=54,radius=Math.min(45,rect.width/2-10),start=150*Math.PI/180,sweep=240*Math.PI/180;
    ctx.lineWidth=6.5;ctx.lineCap='round';ctx.strokeStyle='#303e4d';ctx.beginPath();ctx.arc(cx,cy,radius,start,start+sweep);ctx.stroke();
    if(r.available&&r.fraction>0){ctx.strokeStyle=r.color;ctx.beginPath();ctx.arc(cx,cy,radius,start,start+sweep*r.fraction);ctx.stroke();}
  }
  root.TemperatureGauge={reading,draw,profiles};if(typeof module!=='undefined')module.exports={reading,profiles};
})(typeof window==='undefined'?globalThis:window);
