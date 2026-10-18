import {test} from 'node:test';
import assert from 'node:assert/strict';
import {createReadClient} from '../../ui/native-requests.mjs';
const ticks=async()=>{for(let i=0;i<5;i++)await Promise.resolve()};
function clock(){let id=0;const timers=new Map();return {setTimeout(fn){timers.set(++id,fn);return id},clearTimeout(i){timers.delete(i)},expire(){for(const [i,fn] of [...timers]){timers.delete(i);fn()}},size:()=>timers.size}};
test('an unresponsive native reader times out without accumulating refreshes, then recovers',async()=>{
  const c=clock();let calls=0,finish;
  const read=createReadClient(()=>{calls++;return new Promise(r=>finish=r)},c);
  const first=assert.rejects(read('get_snapshot'),/時間内/);await ticks();c.expire();await first;
  const second=assert.rejects(read('get_snapshot'),/時間内/);await ticks();assert.equal(calls,1);c.expire();await second;
  const recovered=read('get_snapshot');finish({recorder:{state:'stopped'}});
  assert.deepEqual(await recovered,{recorder:{state:'stopped'}});assert.equal(c.size(),0);
  const fresh=read('get_snapshot');await ticks();assert.equal(calls,2);finish('fresh');assert.equal(await fresh,'fresh');
});
test('history rejects a different range while pending and releases its slot on failure',async()=>{
  const c=clock();let fail;
  const read=createReadClient(()=>new Promise((_,reject)=>fail=reject),c);
  const first=assert.rejects(read('query_history',{start:'a'}),/disk unavailable/);await ticks();
  await assert.rejects(read('query_history',{start:'b'}),/前の記録読み取り/);
  fail(Error('disk unavailable'));await first;assert.equal(c.size(),0);
  const retry=assert.rejects(read('query_history',{start:'b'}),/保存ログ/);await ticks();c.expire();await retry;
});
test('stopped recording remains a valid read result and does not request elevation',async()=>{
  const commands=[];const read=createReadClient(command=>{commands.push(command);return {recorder:{state:'stopped'},streams:{}}});
  assert.equal((await read('get_snapshot')).recorder.state,'stopped');assert.deepEqual(commands,['get_snapshot']);
});
