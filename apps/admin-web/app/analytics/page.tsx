'use client';
import { useEffect, useState } from 'react';
import Shell from '../../components/Shell';
import { PageHeader } from '../../components/ui';
import { AreaChart } from '../../components/Chart';
import { api } from '../../lib/api';

type Data = { collected_since:string; summary:{dau:number;wau:number;mau:number}; platforms:{platform:string;devices:number;registered_users:number;dau:number;mau:number}[];series:{day:string;dau:number|null;ios:number;android:number;web:number;signups:number}[] };
type Stats = Record<string,number>;
const grid = {display:'grid',gridTemplateColumns:'repeat(auto-fit,minmax(210px,1fr))',gap:16};
const names:Record<string,string> = {ios:'iOS',android:'Android',web:'Web',unknown:'Unknown'};
export default function Analytics(){return <Shell>{me=>me.role==='admin'?<Body/>:<p>Analytics is available to platform admins.</p>}</Shell>;}
function Body(){
 const [days,setDays]=useState(30),[revision,setRevision]=useState(0),[data,setData]=useState<Data|null>(null),[stats,setStats]=useState<Stats|null>(null),[error,setError]=useState(''),[loading,setLoading]=useState(true);
 useEffect(()=>{let active=true;setLoading(true);setError('');Promise.all([api<Data>(`/analytics?days=${days}`),api<Stats>('/stats')]).then(([d,s])=>{if(active){setData(d);setStats(s);}}).catch(e=>{if(active)setError(e instanceof Error?e.message:'Unable to load analytics');}).finally(()=>{if(active)setLoading(false);});return()=>{active=false;};},[days,revision]);
 const number=(n:number)=>n.toLocaleString();
 const card=(label:string,value:string,note:string)=><div className="card" key={label}><div className="muted">{label}</div><div style={{fontSize:32,fontWeight:650,letterSpacing:'-.03em',margin:'10px 0'}}>{value}</div><div className="mute" style={{fontSize:12}}>{note}</div></div>;
 const metric=(label:string,key:string)=>card(label,stats&&typeof stats[key]==='number'?number(stats[key]):'Unavailable','Current records');
 return <>
 <PageHeader title="Analytics" subtitle="Usage, audience and growth across Voiid." right={<div style={{display:'flex',gap:8}}><select aria-label="Chart date range" value={days} onChange={e=>setDays(Number(e.target.value))}>{[7,30,90].map(n=><option key={n} value={n}>Last {n} days</option>)}</select><button disabled={loading} onClick={()=>setRevision(v=>v+1)}>{loading?'Loading…':'Refresh'}</button></div>}/>
 {error&&<p className="notice error" role="alert">{error} <button onClick={()=>setRevision(v=>v+1)}>Retry</button></p>}
 {data&&stats&&<div style={{display:'grid',gap:24,opacity:loading?.6:1}}>
 <div className="notice">Activity collection started {new Date(data.collected_since).toLocaleString()}. Today is partial; 7- and 30-day metrics build up from that date. All day boundaries use UTC.</div>
 <section style={grid}>{card('DAU',number(data.summary.dau),'Unique users today (UTC)')}{card('WAU',number(data.summary.wau),'Unique users over 7 calendar days, including today')}{card('MAU',number(data.summary.mau),'Unique users over 30 calendar days, including today')}{card('DAU / MAU',data.summary.mau?`${(100*data.summary.dau/data.summary.mau).toFixed(1)}%`:'—','Provisional while the first 30 days accumulate')}</section>
 <section style={{...grid,gridTemplateColumns:'repeat(auto-fit,minmax(280px,1fr))'}}>
 <div className="card"><h2>Daily active users</h2><AreaChart points={data.series.filter(r=>r.dau!==null).map(r=>({day:r.day,value:r.dau!}))} label="Active users" totalLabel="user-days"/><p className="mute">Dates before collection are excluded, not reported as zero.</p></div>
 <div className="card"><h2>New accounts</h2><AreaChart points={data.series.map(r=>({day:r.day,value:r.signups}))} label="New accounts" color="var(--info)"/><p className="mute">Account creation dates; deleted accounts are excluded.</p></div>
 </section>
 <section className="card"><h2>Platforms</h2><p className="muted">Device counts include non-revoked registered devices. A person with both iOS and Android appears in both rows, but only once in overall DAU, WAU and MAU.</p><div style={{overflowX:'auto'}}><table><thead><tr><th>Platform</th><th>Registered devices</th><th>Users with devices</th><th>DAU</th><th>MAU</th></tr></thead><tbody>{data.platforms.map(p=><tr key={p.platform}><td>{names[p.platform]??p.platform}</td><td>{number(p.devices)}</td><td>{number(p.registered_users)}</td><td>{number(p.dau)}</td><td>{number(p.mau)}</td></tr>)}</tbody></table></div></section>
 <section><h2>Product totals</h2><div style={grid}>{metric('Accounts','users')}{metric('Communities','communities')}{metric('Conversations','conversations')}{metric('Calls','calls')}{metric('Events','events')}{metric('Ticket orders','event_orders')}{metric('Tickets','event_tickets')}{metric('Clips','clips')}</div></section>
 <section className="card"><h2>Daily breakdown</h2><div style={{overflowX:'auto',maxHeight:400}}><table><thead><tr><th>Date (UTC)</th><th>Active users</th><th>iOS</th><th>Android</th><th>Web</th><th>New accounts</th></tr></thead><tbody>{[...data.series].reverse().map(r=><tr key={r.day}><td>{r.day}</td><td>{r.dau===null?'Not collected':number(r.dau)}</td><td>{r.dau===null?'—':number(r.ios)}</td><td>{r.dau===null?'—':number(r.android)}</td><td>{r.dau===null?'—':number(r.web)}</td><td>{number(r.signups)}</td></tr>)}</tbody></table></div></section>
 <section className="card"><h2>What these numbers mean</h2><p>Active means a valid signed-in device made an authenticated API request. Background requests can count; WebSocket-only activity and offline use are not included. These metrics do not measure foreground sessions or screen time.</p><p>Activity stores only account ID, UTC day and platform for up to 90 days. Deleted accounts are excluded. No message content, phone numbers, IP addresses or call recordings are collected for these charts.</p><p className="muted">Retention cohorts, app versions, crash rates, notification conversion and payment settlement analytics need additional instrumentation. They are not available yet.</p></section>
 </div>}
 </>;
}
