import {test} from 'node:test';
import assert from 'node:assert/strict';
import {build} from 'esbuild';
import {JSDOM} from 'jsdom';
import {mkdir,writeFile,unlink} from 'node:fs/promises';
import {pathToFileURL,fileURLToPath} from 'node:url';
import React,{act} from 'react';
import {createRoot} from 'react-dom/client';
import {buildModel} from '../src/model.mjs';

test('CPU/GPU comparison modes render real bins and empty data without crashing',async()=>{
 const cache=new URL('../node_modules/.cache/',import.meta.url);await mkdir(cache,{recursive:true});
 const file=new URL(`workspace-test-${process.pid}.mjs`,cache);
 const bundle=await build({stdin:{contents:"export {App} from './src/App.jsx';export {DataContext} from './src/DataContext.jsx';",resolveDir:fileURLToPath(new URL('../',import.meta.url)),loader:'jsx'},bundle:true,platform:'node',format:'esm',packages:'external',loader:{'.css':'empty'},write:false});
 await writeFile(file,bundle.outputFiles[0].text);
 const dom=new JSDOM('<div id="root"></div>',{url:'http://localhost'});
 const originals=new Map();
 for(const [key,value] of Object.entries({window:dom.window,document:dom.window.document,navigator:dom.window.navigator,DOMParser:dom.window.DOMParser,SVGElement:dom.window.SVGElement,ResizeObserver:class{observe(){}disconnect(){}},IS_REACT_ACT_ENVIRONMENT:true})){
  originals.set(key,Object.getOwnPropertyDescriptor(globalThis,key));Object.defineProperty(globalThis,key,{value,configurable:true,writable:true});
 }
 dom.window.scrollTo=()=>{};dom.window.SVGElement.prototype.getBoundingClientRect=()=>({width:800,height:400});
 let root;
 try{
  const {App,DataContext}=await import(pathToFileURL(fileURLToPath(file)));
  const fixture={start:'2026-01-01T00:00:00Z',end:'2026-01-01T02:00:00Z',streams:{}};
  for(const key of ['cpu','activity'])fixture.streams[key]={rows:[21,81].map((m,i)=>({time:new Date(Date.parse(fixture.start)+m*60000).toISOString(),session:'synthetic',sensors:[{name:'CPU Total',type:'Load',value:20+i*30},{name:'Core (Tctl/Tdie)',type:'Temperature',value:55+i*10}],gpu:[{temperatureC:55+i*10,powerW:40+i*30}]}))};
  const runtime={status:{recorder:{state:'recording',label:'synthetic'}},openMini(){},close(){}};
  const click=async text=>{const el=[...document.querySelectorAll('button')].find(x=>x.textContent===text);assert.ok(el,`missing ${text}`);await act(()=>el.click());};
  for(const populated of [true,false]){
   root=createRoot(document.getElementById('root'));
   const model=buildModel(populated?fixture:{...fixture,streams:{}});
   await act(()=>root.render(React.createElement(DataContext.Provider,{value:model},React.createElement(App,{runtime}))));
   for(const device of ['CPU','GPU']){
    await click(device);
    const button=[...document.querySelectorAll('button')].find(x=>x.textContent.includes('分布')&&x.textContent.includes('比較'));
    assert.ok(button);await act(()=>button.click());
    const chart=document.querySelector('svg[aria-label="2期間の実測分布"]');assert.ok(chart);
    if(populated){assert.ok(chart.querySelector('rect[fill="#50ded2"]'));assert.ok(chart.querySelector('rect[fill="#efb968"]'));}
    else assert.match(chart.textContent,/未取得/);
    await click('負荷・電圧との関係');assert.ok(document.querySelector('svg[aria-label="負荷と温度の関係・周辺分布"]'));
    await click('分布の推移');assert.ok(document.querySelector('svg[aria-label="20分ごとの分布推移"]'));
   }
   await act(()=>root.unmount());root=null;
  }
 }finally{
  if(root)await act(()=>root.unmount());
  dom.window.close();
  for(const [key,descriptor]of originals){if(descriptor)Object.defineProperty(globalThis,key,descriptor);else delete globalThis[key];}
  await unlink(file);
 }
});

test('workspace transport preserves sensors and process coverage',()=>{
 const base={start:'2026-01-01T00:00:00Z',end:'2026-01-01T02:00:00Z',streams:{cpu:{rows:[{time:'2026-01-01T00:01:00Z',sensors:[{name:'CPU Total',type:'Load',value:42,hardware:'synthetic CPU'},{name:'Core (Tctl/Tdie)',type:'Temperature',value:60}]}]},processes:{rows:[]}}};
 const packed=structuredClone(base);
 packed.streams.cpu.sensorCatalog=base.streams.cpu.rows[0].sensors.map(({value,...metadata})=>metadata);
 packed.streams.cpu.sensorEncoding='catalog-v1';packed.streams.cpu.rows[0].sensors=[[0,42],[1,60]];
 assert.equal(JSON.stringify(buildModel(packed).E),JSON.stringify(buildModel(base).E));
 packed.streams.processes.sampleSummary={count:100,first:'first',last:'last',maxGap:30};
 assert.deepEqual(buildModel(packed).D.sources.find(s=>s.name==='プロセス'),{name:'プロセス',...packed.streams.processes.sampleSummary});
});
