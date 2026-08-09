import { snake, TUNING } from './index';
let s = snake.create(['u1','u2'],{bots:4,seed:999}).serialize();
for(let i=0;i<TUNING.TICK_HZ*30;i++){ const e=snake.restore(s); e.tick!(); s=e.serialize(); }
const e=snake.restore(s); e.tick!();
const w:any=(e as any).serializeForWire();
console.log('total',(JSON.stringify(w).length/1024).toFixed(2),'KB');
for(const k of Object.keys(w)){ const v=JSON.stringify(w[k]).length; if(v>150) console.log('  ',k,(v/1024).toFixed(2),'KB'); }
console.log('snake breakdown:');
for(const sn of w.snakes){ console.log('   m',sn.m,'pathPts',(sn.p.length-2)/2,'bytes',JSON.stringify(sn).length); }
