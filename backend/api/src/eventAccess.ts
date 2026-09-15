import {query} from './db';
import {communityAccess} from './communityRoles';
export async function eventAccess(eventId:string,communityId:string,userId:string,permission:'view'|'manage'|'checkin') {
 const base=await communityAccess(communityId,userId,false);
 if(!base.ok)return base;
 if(base.isOrganiser)return {ok:true as const,isOrganiser:true};
 const staff=(await query(`select role from event_staff where event_id=$1 and user_id=$2 and state='active' and expires_at>now()`,[eventId,userId]))[0];
 const manager=staff?.role==='manager';
 if(permission==='manage'&&!manager || permission==='checkin'&&!staff)
  return {ok:false as const,status:403,error:'event permission required'};
 return {ok:true as const,isOrganiser:manager};
}
