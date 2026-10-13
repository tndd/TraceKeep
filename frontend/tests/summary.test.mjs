import {test} from 'node:test';
import assert from 'node:assert/strict';
import {eventTone,voltageOccupancy} from '../src/summary-data.mjs';
test('event intensity is stable across filtered populations',()=>{assert.deepEqual([0,1,2,3,9,10,99,100,999,1000,9999].map(eventTone),[0,1,1,2,2,3,3,4,4,5,5])});
test('voltage occupancy preserves discrete steps and separates absence from zero share',()=>{const d=voltageOccupancy([{t:0,v12:12.1},{t:1,v12:12.1},{t:2,v12:12.12},{t:5,v12:12.12},{t:10,v12:null},{t:120,v12:12.1}]);assert.equal(d.sampleCount,4);assert.deepEqual(d.totals.slice(0,3),[3,1,0]);assert.equal(d.bands.length,2);assert.deepEqual(d.bands[0].counts.slice(0,3),[2,0,0]);assert.equal(d.bands.reduce((n,b)=>n+b.total,0),4)});
test('voltage banding retains min and max observations without smoothing',()=>{const d=voltageOccupancy(Array.from({length:25},(_,i)=>({t:i,v12:12+i/1000})));assert.equal(d.bands.length,12);assert.equal(d.bands.reduce((n,b)=>n+b.total,0),25);assert.equal(d.bands.at(-1).hi,12.024);assert.equal(voltageOccupancy([]).bands.length,0)});
