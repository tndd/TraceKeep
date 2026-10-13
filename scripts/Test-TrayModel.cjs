const {test}=require('node:test');const assert=require('node:assert/strict');const model=require('../ui/mini-model.js');
const sample=()=>({recorder:{state:'recording'},coordinator:{configured:true,runtime:{workers:[{name:'cpu',state:'recording',enabled:true,errorCount:0}]}},streams:{cpu:{state:'recording',age:1,history:[{cpuTemp:60}]}}});
test('stopped and stale readings are never shown as live',()=>{const d=sample();assert.equal(model(d).cpu.fresh,true);d.recorder.state='stopped';assert.equal(model(d).cpu.fresh,false);assert.equal(model(d).cpu.value,60);assert.equal(model(d).canStart,true);assert.equal(model(d).canStop,false);assert.equal(model(d).workers[0].displayState,'stopped');});
test('missing values are not zero temperatures',()=>{const d=sample();d.streams.cpu.history=[];assert.equal(model(d).cpu.value,null);assert.equal(model({}).canStart,false);assert.equal(model({}).canStop,false);});
test('busy and intentionally disabled are explicit',()=>{const d=sample();assert.equal(model(d,{busy:true}).canStop,false);d.streams.cpu.state='disabled';assert.equal(model(d).cpu.fresh,false);assert.equal(model(d).cpu.state,'disabled');});
test('stale coordinator overrides old worker green state',()=>{const d=sample();d.recorder.state='unknown';assert.equal(model(d).workers[0].displayState,'unknown');assert.equal(model(d).cpu.fresh,false);});

test('five lamps remain visible when workers disappear',()=>{const m=model({});assert.equal(m.workers.length,5);assert.ok(m.workers.every(w=>w.displayState==='unknown'));});
test('fresh coordinator cannot hide stale sensor logs',()=>{const d=sample();d.streams.cpu.state='stale';assert.equal(model(d).workers[0].displayState,'stale');assert.equal(model(d).cpu.fresh,false);});
