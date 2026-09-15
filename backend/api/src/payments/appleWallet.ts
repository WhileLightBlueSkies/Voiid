import { createHash, X509Certificate } from 'node:crypto';
import { mkdtemp, readFile, writeFile, rm } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join, resolve } from 'node:path';
import { execFile } from 'node:child_process';
import { promisify } from 'node:util';
const run = promisify(execFile);
const PASS_ID = 'pass.in.voiid.events';
const TEAM_ID = 'ZX246KFTQD';
export function appleWalletConfigured() {
  return !!(process.env.VOIID_WALLET_CERT_PATH && process.env.VOIID_WALLET_KEY_PATH && process.env.VOIID_WALLET_WWDR_PATH);
}
export function ticketPass(ticket: {id:string; title:string; starts_at:string|Date; location_text:string|null; people?:number}) {
  if (!/^[0-9a-f-]{36}$/i.test(ticket.id)) throw Error('invalid ticket id');
  // Allow only origins declared in the app's associated-domains entitlement.
  const origin = process.env.VOIID_TICKET_LINK_ORIGIN === 'https://api-dev.voiid.app'
    ? 'https://api-dev.voiid.app' : 'https://voiid.app';
  const link = `${origin}/tickets/${ticket.id}`;
  return {
    formatVersion:1, passTypeIdentifier:PASS_ID, teamIdentifier:TEAM_ID,
    serialNumber:ticket.id, organizationName:'Voiid', description:'Voiid event ticket',
    logoText:'Voiid', foregroundColor:'rgb(255,255,255)', backgroundColor:'rgb(24,32,40)',labelColor:'rgb(161,222,209)',
    relevantDate:new Date(ticket.starts_at).toISOString(),
    eventTicket:{
      primaryFields:[{key:'event',label:'EVENT',value:ticket.title}],
      secondaryFields:[{key:'start',label:'STARTS',value:new Date(ticket.starts_at).toISOString(),dateStyle:'PKDateStyleMedium',timeStyle:'PKDateStyleShort'}],
      auxiliaryFields:[{key:'venue',label:'VENUE',value:ticket.location_text||'See event details'},
        {key:'people',label:'ADMITS',value:String(ticket.people ?? 1)}],
      backFields:[{key:'secure_ticket',label:'OPEN SECURE TICKET',value:link},
        {key:'admission',label:'AT THE DOOR',value:'Open the link above and sign in to Voiid to display your current entry QR. This saved pass is not an admission code.'},
        {key:'updates',label:'CURRENT EVENT STATUS',value:'Check Voiid for cancellations, schedule changes and ticket status. Details on this saved pass may become outdated.'}],
    },
    // No persistent admission barcode, personal identity or signing token is embedded.
  };
}
export async function createApplePass(ticket: Parameters<typeof ticketPass>[0]): Promise<Buffer> {
  if(!appleWalletConfigured()) throw Error('wallet not configured');
  const certPath=process.env.VOIID_WALLET_CERT_PATH!;
  const cert=new X509Certificate(await readFile(certPath));
  if(Date.parse(cert.validFrom)>Date.now() || Date.parse(cert.validTo)<=Date.now()) throw Error('wallet certificate not valid');
  if(!cert.subject.split('\n').includes(`UID=${PASS_ID}`) || !cert.subject.split('\n').includes(`OU=${TEAM_ID}`)) throw Error('wallet certificate identity mismatch');
  const directory=await mkdtemp(join(tmpdir(),'voiid-pass-'));
  try {
    const assets=process.env.VOIID_WALLET_ASSETS_PATH || resolve(__dirname,'../../assets/wallet');
    const files:Record<string,Buffer>={'pass.json':Buffer.from(JSON.stringify(ticketPass(ticket))),
      'icon.png':await readFile(join(assets,'icon.png')),'icon@2x.png':await readFile(join(assets,'icon@2x.png'))};
    const manifest:Record<string,string>={};
    for(const [name,bytes] of Object.entries(files)){await writeFile(join(directory,name),bytes,{mode:0o600});manifest[name]=createHash('sha1').update(bytes).digest('hex');}
    await writeFile(join(directory,'manifest.json'),JSON.stringify(manifest),{mode:0o600});
    await run('openssl',['smime','-binary','-sign','-signer',certPath,'-inkey',process.env.VOIID_WALLET_KEY_PATH!,
      '-certfile',process.env.VOIID_WALLET_WWDR_PATH!,'-in',join(directory,'manifest.json'),'-out',join(directory,'signature'),'-outform','DER'],{timeout:15000});
    await run('zip',['-q','-X','ticket.pkpass',...Object.keys(files),'manifest.json','signature'],{cwd:directory,timeout:15000});
    return await readFile(join(directory,'ticket.pkpass'));
  } finally { await rm(directory,{recursive:true,force:true}); }
}
