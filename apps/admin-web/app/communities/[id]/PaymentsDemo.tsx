'use client';
import {useState} from 'react';
export default function PaymentsDemo(){
 const [rate,setRate]=useState(25),[quantity,setQuantity]=useState(1),[bank,setBank]=useState(false),[stage,setStage]=useState('Ready');
 if(process.env.NODE_ENV!=='development')return null;
 const gross=quantity*100000,fee=Math.floor(gross*rate/100);
 const money=(n:number)=>`₹${(n/100).toFixed(2)}`;
 return <section className="card" style={{marginBottom:24}}><h2>Event payments demo</h2><p><strong>DEMO · No money moves.</strong> This preview uses no payment API and creates no real tickets or bank accounts.</p>
 <h3>Recipient onboarding</h3><p>Demo Restaurant · Account ending 6789 · {bank?'Verified (simulated)':'Not verified'}</p><button disabled={bank} onClick={()=>setBank(true)}>Simulate bank verification</button>
 <h3>Checkout and commission</h3><label>Ticket quantity<input type="number" min="1" max="10" disabled={stage!=='Ready'} value={quantity} onChange={e=>setQuantity(Math.max(1,Math.min(10,Math.trunc(Number(e.target.value)||1))))}/></label><label>Commission override (%)<input type="number" min="0" max="100" step="1" disabled={stage!=='Ready'} value={rate} onChange={e=>setRate(Math.max(0,Math.min(100,Math.trunc(Number(e.target.value)||0))))}/></label>
 <p>Guest total {money(gross)} · Voiid commission {money(fee)} · Organiser share {money(gross-fee)}</p><p>Processing fees and taxes are excluded; their allocation is not final.</p>
 <p role="status">{stage}</p>{stage==='Ready'&&<><button disabled={!bank} onClick={()=>setStage('Paid · settlement pending')}>Simulate payment success</button><button onClick={()=>setStage('Payment failed · no charge')}>Simulate failure</button></>}
 {stage==='Paid · settlement pending'&&<button onClick={()=>setStage('Settled to demo bank')}>Simulate settlement</button>}
 {(stage==='Paid · settlement pending'||stage==='Settled to demo bank')&&<button onClick={()=>setStage('Refund pending')}>Simulate refund request</button>}
 {stage==='Refund pending'&&<button onClick={()=>setStage('Refunded · demo transfer reversed')}>Complete demo refund</button>}
 <button onClick={()=>{setStage('Ready');setBank(false);setRate(25);setQuantity(1)}}>Reset demo</button></section>;
}
