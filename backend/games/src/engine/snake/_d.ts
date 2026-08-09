import { snake, TUNING } from './index';
let s = snake.create(['u1','u2'],{bots:4,seed:999}).serialize();
let tot=0,n=0,peak=0,full=0;
const big:number[]=[];
for(let i=0;i<TUNING.TICK_HZ*30;i++){
  const e=snake.restore(s); e.tick!(); s=e.serialize();
  const w:any=(e as any).serializeForWire(); const b=JSON.stringify(w).length;
  tot+=b;n++; if(b>peak)peak=b; if(w.foodFull)full++;
  if(b>4000) big.push(Math.round(b/1024));
}
console.log('avg',(tot/n/1024).toFixed(2),'peak',(peak/1024).toFixed(1),'full',full);
console.log('frames >4KB:',big.length,'sizes:',big.slice(0,12).join(','));
