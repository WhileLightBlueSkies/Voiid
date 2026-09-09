import fs from "node:fs/promises";
import { Presentation, PresentationFile } from "@oai/artifact-tool";

const OUT = "/Users/devacc/Voiid/Voiid_PreSeed_Investor_Deck_Full.pptx";
const PREVIEW = "/Users/devacc/Voiid/.codex-tmp/investor-deck/rendered";
const W=1280,H=720;
const C={bg:"#F6F8F8",white:"#FFFFFF",ink:"#101617",muted:"#5D696C",primary:"#13828C",lav:"#68B8BD",lav2:"#D9EFF0",amber:"#A16207",line:"#D7DEDF",green:"#238A58",blue:"#1D4ED8",rose:"#7E22CE"};
const FONT="SF Pro Rounded";
const APP_ICON_PNG=await fs.readFile("/Users/devacc/Voiid/apps/ios/Voiid/Voiid/Assets.xcassets/AppIcon.appiconset/AppIcon-1024.png");
const p=Presentation.create({slideSize:{width:W,height:H}});

function box(s,x,y,w,h,fill=C.white,r=16,line="none") {return s.shapes.add({geometry:r?"roundRect":"rect",position:{left:x,top:y,width:w,height:h},fill,line:{style:"solid",fill:line,width:line==="none"?0:1},borderRadius:r});}
function text(s,t,x,y,w,h,size=24,color=C.ink,bold=false,align="left") {const q=s.shapes.add({geometry:"textbox",position:{left:x,top:y,width:w,height:h},fill:"none",line:{style:"solid",fill:"none",width:0}});q.text=t;q.text.style={fontFamily:FONT,fontSize:size,color,bold,alignment:align};return q;}
function base(title,kicker="VOIID • PRE-SEED") {const s=p.slides.add();s.background.fill=C.bg;text(s,kicker,72,42,500,26,14,C.primary,true);text(s,title,72,82,1136,76,40,C.ink,true);box(s,72,169,1136,2,C.primary,0);return s;}
function footer(s,n){text(s,String(n).padStart(2,"0"),1150,674,58,20,13,C.muted,true,"right");}
function notes(s,src){s.speakerNotes.textFrame.setText(`[Sources]\n${src}`);}
function pill(s,label,x,y,w,fill=C.lav2,color=C.primary){box(s,x,y,w,42,fill,21);text(s,label,x+12,y+9,w-24,23,16,color,true,"center");}

// 1 — cover
{
 const s=p.slides.add();s.background.fill=C.bg;
 box(s,790,0,490,720,C.primary,0);
 s.images.add({blob:APP_ICON_PNG,contentType:"image/png",alt:"Voiid iOS app icon",fit:"cover",position:{left:900,top:155,width:270,height:270},geometry:"roundRect",borderRadius:58});
 text(s,"Voiid",72,56,180,44,27,C.primary,true);
 text(s,"Built in India.\nFor the world.",72,158,650,190,60,C.ink,true);
 text(s,"The private social stack for communication, community, content and commerce.",72,380,610,84,25,C.muted,false);
 pill(s,"PRE-SEED",72,520,138,C.primary,C.white);pill(s,"PILOT TESTING",226,520,184,C.lav2,C.primary);
 text(s,"Sampath Kumar  •  Founder & CEO",72,626,510,28,18,C.ink,true);
 notes(s,"Product positioning and brand assets: Voiid repository README.md and docs/LANDING_PAGE_BRIEF.md.");
}

// 2 problem
{
 const s=base("Digital life is fragmented—and trust is the casualty.");
 text(s,"People switch between apps to message, call, share moments, meet communities and play. Each handoff adds friction; each platform asks for more data.",72,202,710,86,25,C.muted);
 const items=[["FRAGMENTATION","Too many apps for one social life."],["SURVEILLANCE","Convenience often trades against privacy."],["WEAK CONTEXT","Chats, communities and shared experiences live apart."]];
 items.forEach((a,i)=>{const y=330+i*96;text(s,`0${i+1}`,72,y,54,40,24,C.amber,true);text(s,a[0],142,y,220,28,18,C.primary,true);text(s,a[1],365,y,760,34,22,C.ink);});footer(s,2);
 notes(s,"Problem framing: founder-provided positioning and product scope in docs/LANDING_PAGE_BRIEF.md.");
}

// 3 solution
{
 const s=base("Voiid brings the social stack into one private home.");
 text(s,"One identity. One trusted graph. Multiple ways to connect.",72,196,780,46,27,C.muted);
 const items=[[/TabChats/,"MESSAGING","Encrypted chats & groups"],[/TabStories/,"MOMENTS","Share with the people who matter"],[/TabClips/,"CLIPS","Discover creators and culture"],[/game_snake/,"GAMES","Play inside the conversation"]];
 const glyphs=["C","M","▶","G"];
 items.forEach((a,i)=>{const x=72+i*284;box(s,x,294,252,300,C.white,16,C.line);box(s,x+76,326,100,100,[C.lav2,"#F1E7FA","#E6EDFC","#F3F5F5"][i],16);text(s,glyphs[i],x+76,348,100,52,34,[C.primary,C.rose,C.blue,C.ink][i],true,"center");text(s,a[1],x+20,455,212,28,19,C.primary,true,"center");text(s,a[2],x+22,500,208,58,18,C.muted,false,"center");});footer(s,3);
 notes(s,"Feature scope: docs/LANDING_PAGE_BRIEF.md and product assets in apps/ios/Voiid/Voiid/Assets.xcassets.");
}

// full social stack
{
 const s=base("One social graph powers the entire stack.");
 const features=[["CHAT","Messages & groups","LIVE"],["CALLS","Voice & video","LIVE"],["STORIES","Private moments","LIVE"],["MAP","Encrypted location","LIVE"],["CLIPS","Creator discovery","PILOT"],["GAMES","Play together","LIVE"],["COMMUNITIES","Belong & organise","BUILDING"],["PAYMENTS","Events & commerce","ROADMAP"]];
 features.forEach((a,i)=>{const col=i%4,row=Math.floor(i/4),x=72+col*284,y=216+row*190;box(s,x,y,252,154,a[2]==="LIVE"?C.white:"#EDF1F1",16,C.line);text(s,a[0],x+20,y+22,210,26,18,[C.primary,C.green,C.rose,C.blue][col],true);text(s,a[1],x+20,y+61,210,34,20,C.ink,true);text(s,a[2],x+20,y+112,210,18,13,a[2]==="LIVE"?C.green:C.muted,true);});
 text(s,"Private communication is the wedge; communities and transactions expand lifetime value.",72,620,1080,34,22,C.primary,true);footer(s,4);notes(s,"Feature status synthesised from the Voiid iOS/backend repository and docs/COMMUNITY_COMMERCE_PLAN.md. Payments and commerce are roadmap, not live claims.");
}

// 4 why win
{
 const s=base("Privacy is the architecture—not a setting.");
 box(s,72,214,490,386,C.primary,28);text(s,"THE SERVER\nNEVER SEES\nPLAINTEXT",112,266,410,174,42,C.white,true);text(s,"Private keys stay on-device. Critical dependencies remain swappable.",112,480,380,72,20,C.lav2);
 const ys=[["End-to-end encrypted core","Messages and sensitive connection data are designed around ciphertext-only infrastructure."],["Honest privacy boundaries","Public clips, creator profiles and games are identified as public—not hidden behind vague claims."],["Built for resilience","Plain Postgres and replaceable interfaces reduce platform lock-in."]];
 ys.forEach((a,i)=>{const y=222+i*126;text(s,a[0],620,y,520,32,24,C.ink,true);text(s,a[1],620,y+42,520,66,18,C.muted);});footer(s,5);
 notes(s,"Architecture claims: README.md Golden rules; privacy boundaries: docs/LANDING_PAGE_BRIEF.md.");
}

// 5 wedge
{
 const s=base("Trusted communication unlocks shared experiences.");
 const stages=[["01","CONNECT","Encrypted messaging & calls",C.primary],["02","ENGAGE","Moments, clips & games",C.rose],["03","BELONG","Communities & events",C.blue],["04","MONETISE","Tickets and creator commerce",C.amber]];
 stages.forEach((a,i)=>{const x=72+i*284;box(s,x,238,252,326,C.white,22,C.line);text(s,a[0],x+22,260,56,40,24,a[3],true);text(s,a[1],x+22,330,208,28,20,C.ink,true);text(s,a[2],x+22,382,208,84,20,C.muted);box(s,x+22,512,208,6,a[3],3);});
 text(s,"The same trusted identity compounds across every surface.",72,620,900,32,23,C.primary,true);footer(s,6);notes(s,"Product sequence: repository feature set and docs/COMMUNITY_COMMERCE_PLAN.md.");
}

// 6 market
{
 const s=base("India is the launchpad; the need is global.");
 text(s,"Voiid targets a universal tension: people want richer digital connection without surrendering control of their private lives.",72,202,870,86,25,C.muted);
 const claims=[["MOBILE-FIRST","Designed around the phone as the primary social layer."],["INDIA-BUILT","Local product intuition with global product ambition."],["GENERATIONAL","Privacy expectations are rising as social behaviour keeps expanding."]];
 claims.forEach((a,i)=>{const x=72+i*378;box(s,x,352,346,214,i===1?C.primary:C.white,24,i===1?C.primary:C.line);text(s,a[0],x+24,382,298,28,18,i===1?C.lav2:C.primary,true);text(s,a[1],x+24,432,298,82,22,i===1?C.white:C.ink,true);});footer(s,7);
 notes(s,"No external market-size claim used. Geographic positioning: founder line in docs/LANDING_PAGE_BRIEF.md.");
}

// quantified market
{
 const s=base("A massive audience already lives across fragmented platforms.");
 const nums=[["969M","Internet subscriptions in India","TRAI • Mar 2025"],["491M","Indian social-media identities","DataReportal • Jan 2025"],["5.66B","Global social-media identities","DataReportal • 2026"]];
 nums.forEach((a,i)=>{const x=72+i*378;box(s,x,226,346,220,i===1?C.primary:C.white,16,i===1?C.primary:C.line);text(s,a[0],x+24,256,298,66,45,i===1?C.white:C.primary,true);text(s,a[1],x+24,332,298,54,20,i===1?C.white:C.ink,true);text(s,a[2],x+24,402,298,20,14,i===1?C.lav2:C.muted,true);});
 box(s,72,490,1136,96,C.lav2,16);text(s,"CREATOR COMMERCE",96,514,260,24,16,C.primary,true);text(s,"2–2.5M active Indian creators influence $350B+ in annual consumer spending.",350,510,820,52,23,C.ink,true);text(s,"Voiid enters through trusted communication, then monetises community activity.",72,622,1040,28,21,C.primary,true);footer(s,8);
 notes(s,"TRAI: https://trai.gov.in/sites/default/files/2025-07/YIR_08072025_0.pdf\nDataReportal India: https://datareportal.com/reports/digital-2025-india\nDataReportal global: https://datareportal.com/reports/digital-2026-two-in-three-people-use-social-media\nPIB/BCG creator economy: https://www.pib.gov.in/PressReleaseIframePage.aspx?PRID=2126106&lang=2&reg=48");
}

// 7 business model
{
 const s=base("Monetisation grows with community activity.");
 text(s,"Voiid can earn when hosts and creators earn—without putting core private communication behind a paywall.",72,202,930,68,25,C.muted);
 const rows=[["PAID EVENTS","Commission on tickets and passes","Near-term wedge"],["COMMUNITY COMMERCE","Transaction fee on products and experiences","Expansion"],["CREATOR ECONOMY","Tips, subscriptions and services","Longer-term"]];
 rows.forEach((a,i)=>{const y=314+i*92;box(s,72,y,1136,72,i===0?C.white:"#EDF1F1",14,C.line);text(s,a[0],96,y+23,255,26,18,C.primary,true);text(s,a[1],386,y+20,490,30,21,C.ink);text(s,a[2],960,y+23,210,26,17,i===0?C.amber:C.muted,true,"right");});footer(s,9);
 notes(s,"Business-model roadmap: docs/COMMUNITY_COMMERCE_PLAN.md. Paid payment provider is not yet live.");
}

// competitive position
{
 const s=base("The advantage is an integrated, private social stack.");
 const headers=["CATEGORY","PRIVATE CORE","CONTENT","COMMUNITY","COMMERCE"];headers.forEach((h,i)=>text(s,h,72+i*220,222,i===0?220:205,24,14,C.muted,true));
 const rows=[["Messaging apps","Strong","Limited","Groups","Limited"],["Social networks","Weak","Strong","Followers","Ads / shops"],["Community tools","Mixed","Limited","Strong","Subscriptions"],["VOIID","Strong","Strong","Strong","Events → commerce"]];
 rows.forEach((r,ri)=>{const y=270+ri*76;box(s,72,y,1136,60,ri===3?C.primary:(ri%2?"#EDF1F1":C.white),12,ri===3?C.primary:C.line);r.forEach((v,i)=>text(s,v,92+i*220,y+18,i===0?200:205,25,17,ri===3?C.white:(i===0?C.ink:C.muted),ri===3||i===0));});
 text(s,"A shared identity, graph and privacy architecture compound across every surface.",72,614,1080,36,22,C.primary,true);footer(s,10);notes(s,"Category-level competitive framing; no unsupported competitor-specific claim is used.");
}

// 8 traction
{
 const s=base("The product is in pilot; the learning loop is active.");
 const stages=[["NOW","Pilot testing","Validate reliability, privacy flows and core engagement."],["NEXT","Waitlist launch","Build an owned audience and measure intent by cohort."],["THEN","Focused rollout","Convert early communities into repeat usage and referrals."]];
 stages.forEach((a,i)=>{const x=72+i*378;box(s,x,238,346,292,i===0?C.primary:C.white,24,i===0?C.primary:C.line);text(s,a[0],x+26,268,294,24,16,i===0?C.lav2:C.amber,true);text(s,a[1],x+26,318,294,42,27,i===0?C.white:C.ink,true);text(s,a[2],x+26,388,286,84,19,i===0?C.lav2:C.muted);});
 text(s,"Next investor update: waitlist conversion, activation, retention and referral.",72,592,1000,34,23,C.primary,true);footer(s,11);notes(s,"Stage and traction provided directly by founder: pre-seed, pilot testing, waitlist starting soon.");
}

// go to market
{
 const s=base("Go to market through dense communities, not broad downloads.");
 const steps=[["01","SEED","Recruit pilot communities with an existing reason to interact."],["02","ACTIVATE","Win week one through chat, calls, games and shared moments."],["03","EXPAND","Add creators, events and local discovery to deepen the graph."],["04","MONETISE","Introduce paid events and commerce after engagement is proven."]];
 steps.forEach((a,i)=>{const x=72+i*284;box(s,x,238,252,312,i===0?C.primary:C.white,16,i===0?C.primary:C.line);text(s,a[0],x+22,262,55,34,22,i===0?C.white:C.primary,true);text(s,a[1],x+22,324,208,26,18,i===0?C.white:C.ink,true);text(s,a[2],x+22,378,208,110,18,i===0?C.lav2:C.muted);});text(s,"Initial proof: activation → week-4 retention → invites per active user.",72,610,1000,32,22,C.primary,true);footer(s,12);notes(s,"Proposed pre-seed GTM based on the pilot and upcoming waitlist; metrics are targets to instrument, not reported traction.");
}

// 9 roadmap
{
 const s=base("An 18-month path to repeatable growth.");
 const rows=[["0–3 MONTHS","Complete pilot hardening • open waitlist • instrument activation"],["3–9 MONTHS","Launch focused cohorts • strengthen calls, clips and games • prove retention"],["9–18 MONTHS","Scale communities • activate paid events • prepare creator monetisation"]];
 rows.forEach((a,i)=>{const y=230+i*124;text(s,a[0],72,y,230,28,18,[C.primary,C.rose,C.amber][i],true);box(s,320,y-5,888,78,C.white,18,C.line);text(s,a[1],350,y+17,824,38,21,C.ink);});
 pill(s,"NORTH STAR: WEEKLY TRUSTED CONNECTIONS",72,612,430,C.primary,C.white);footer(s,13);notes(s,"Roadmap synthesis based on current pilot stage and repository plans; timing is a planning assumption for discussion.");
}

// 10 team
{
 const s=base("Founder-led, product-first execution.");
 box(s,72,222,230,230,C.primary,115);text(s,"SK",72,296,230,78,54,C.white,true,"center");
 text(s,"Sampath Kumar",354,236,650,48,34,C.ink,true);text(s,"Founder & CEO",354,296,650,34,23,C.primary,true);text(s,"Leading Voiid from product vision through pilot execution—with a clear ambition to build in India for the world.",354,370,730,108,24,C.muted);
 box(s,354,520,650,2,C.line,0);text(s,"Pre-seed priorities: product • growth • engineering",354,548,650,32,19,C.amber,true);footer(s,14);notes(s,"Founder name and role supplied directly by the user. No unverified biography claims added.");
}

// 15 why now
{
 const s=base("Why now: social and commerce are converging.");
 const signals=[["SOCIAL SCALE","491M social-media identities in India","The audience already exists."],["PAYMENT HABIT","22B+ monthly UPI transactions","Transactions are native digital behaviour."],["CREATOR SUPPLY","2–2.5M active Indian creators","Only 8–10% monetise effectively."],["PLATFORM SHIFT","Messaging apps are adding payments and business tools","The market is moving toward integrated utility."]];
 signals.forEach((a,i)=>{const x=72+(i%2)*568,y=220+Math.floor(i/2)*182;box(s,x,y,536,146,i===0?C.primary:C.white,16,i===0?C.primary:C.line);text(s,a[0],x+24,y+20,488,22,15,i===0?C.lav2:C.primary,true);text(s,a[1],x+24,y+52,488,34,22,i===0?C.white:C.ink,true);text(s,a[2],x+24,y+98,488,26,17,i===0?C.lav2:C.muted);});footer(s,15);
 notes(s,"DataReportal India: https://datareportal.com/reports/digital-2025-india\nNPCI UPI statistics: https://www.npci.org.in/product/upi/product-statistics\nPIB/BCG creator economy: https://www.pib.gov.in/PressReleaseIframePage.aspx?PRID=2126106&lang=2&reg=48\nMeta India payment integration: https://about.fb.com/news/2026/04/bringing-prepaid-mobile-recharges-to-whatsapp-users-in-india/");
}

// 16 beachhead
{
 const s=base("Win one dense network first.");
 box(s,72,220,500,360,C.primary,20);text(s,"BEACHHEAD",108,254,420,24,16,C.lav2,true);text(s,"Private, mobile-first\ncommunities with\n50–500 members",108,304,420,128,34,C.white,true);text(s,"They already coordinate across messaging, content, events and payment links.",108,474,410,64,19,C.lav2);
 const items=[["PAIN","Fragmented tools and weak context"],["ENTRY","Community leaders invite the network"],["ACTIVATION","Chat + calls + games in week one"],["EXPANSION","Events, creators and commerce"]];items.forEach((a,i)=>{const y=220+i*92;text(s,a[0],630,y,150,24,16,C.primary,true);text(s,a[1],800,y,370,52,21,C.ink,true);box(s,630,y+64,540,1,C.line,0);});footer(s,16);notes(s,"Beachhead is a recommended ICP hypothesis derived from Voiid's community-led product and GTM. Validate through the pilot before presenting it as proven.");
}

// 17 pilot proof
{
 const s=base("The pilot is designed to produce investable proof.");
 text(s,"Current stage: product in pilot • waitlist opening next",72,198,820,34,23,C.primary,true);
 const metrics=[["ACTIVATION","% completing a trusted interaction in 24 hours"],["RETENTION","Week-1 and week-4 active-user retention"],["DENSITY","Active relationships per community"],["VIRALITY","Invites accepted per active user"],["ENGAGEMENT","Weekly trusted connections per user"],["RELIABILITY","Message, call and session success rate"]];metrics.forEach((a,i)=>{const x=72+(i%3)*378,y=270+Math.floor(i/3)*142;box(s,x,y,346,112,C.white,16,C.line);text(s,a[0],x+20,y+18,306,22,15,[C.primary,C.rose,C.blue][i%3],true);text(s,a[1],x+20,y+50,306,44,18,C.ink,true);});
 box(s,72,576,1136,54,C.lav2,16);text(s,"BASELINE BEING ESTABLISHED — report cohort size, dates and raw counts alongside percentages.",96,591,1088,24,17,C.primary,true);footer(s,17);notes(s,"Metric framework follows Stripe Atlas guidance to demonstrate understanding of stage-appropriate metrics when instrumentation is still being established: https://stripe.com/in/guides/atlas/pitching");
}

// 18 market model
{
 const s=base("From audience scale to a revenue model.");
 const bands=[["TAM","5.66B","Global social-media identities","Global social layer"],["SAM","491M","Indian social-media identities","India launch market"],["SOM","To validate","Active users × paid activity × take rate","Five-year operating target"]];bands.forEach((a,i)=>{const y=220+i*116;box(s,72,y,1136,92,i===2?C.primary:C.white,16,i===2?C.primary:C.line);text(s,a[0],96,y+24,94,30,18,i===2?C.lav2:C.primary,true);text(s,a[1],208,y+18,190,42,i===2?24:30,i===2?C.white:C.ink,true);text(s,a[2],422,y+18,470,28,19,i===2?C.white:C.ink,true);text(s,a[3],422,y+50,470,22,16,i===2?C.lav2:C.muted);});
 text(s,"SOM formula",72,594,160,24,16,C.primary,true);text(s,"Retained communities × active members × annual GMV × Voiid take rate",238,589,930,34,22,C.ink,true);footer(s,18);notes(s,"TAM source: https://datareportal.com/reports/digital-2026-two-in-three-people-use-social-media\nSAM source: https://datareportal.com/reports/digital-2025-india\nSOM intentionally remains formula-based until pilot retention, pricing and transaction data exist.");
}

// 19 revenue mechanics
{
 const s=base("Trust first. Transactions follow.");
 const engines=[["1","EVENTS","Ticketing commission","First revenue wedge"],["2","COMMUNITY COMMERCE","Transaction take rate","After payment rails"],["3","CREATOR TOOLS","Tips, subscriptions and services","After creator pilots"]];engines.forEach((a,i)=>{const y=222+i*112;text(s,a[0],72,y,50,34,24,[C.primary,C.blue,C.amber][i],true);text(s,a[1],144,y,260,26,18,C.primary,true);text(s,a[2],432,y,410,30,23,C.ink,true);text(s,a[3],900,y,260,28,17,C.muted,true,"right");box(s,144,y+58,1016,1,C.line,0);});
 box(s,72,574,1136,66,C.lav2,16);text(s,"PRICING VALIDATION",96,594,224,22,15,C.primary,true);text(s,"Test willingness to pay, take rate and repeat GMV during controlled community pilots.",326,590,840,30,20,C.ink,true);footer(s,19);notes(s,"Revenue mechanics reflect docs/COMMUNITY_COMMERCE_PLAN.md. Payments and commerce remain roadmap; do not report GMV as revenue. Metric treatment reference: https://stripe.com/in/guides/atlas/pitching");
}

// 20 round milestones
{
 const s=base("This round turns the pilot into repeatable evidence.");
 const ms=[["01","LAUNCH","Reliable public product across iOS and Android","Product risk reduced"],["02","PROVE","Measured activation, retention and community density","Engagement proven"],["03","REPEAT","Waitlist conversion and a repeatable community playbook","Distribution proven"],["04","MONETISE","First paid-event pilots and transaction revenue","Economics validated"]];ms.forEach((a,i)=>{const y=214+i*92;text(s,a[0],72,y,70,32,24,[C.primary,C.blue,C.green,C.amber][i],true);text(s,a[1],164,y,160,24,17,C.primary,true);text(s,a[2],350,y,570,44,20,C.ink,true);text(s,a[3],954,y,214,30,16,C.muted,true,"right");box(s,164,y+62,1004,1,C.line,0);});
 box(s,72,592,1136,58,C.lav2,16);text(s,"NEXT-ROUND READY",96,610,230,22,15,C.primary,true);text(s,"Retention + repeatable acquisition + first revenue",332,605,830,30,21,C.ink,true);footer(s,20);notes(s,"Milestone framework for the pre-seed round. Numeric thresholds and dates should be finalised after the pilot baseline and raise amount are confirmed.");
}

// final ask
{
 const s=p.slides.add();s.background.fill=C.primary;
 text(s,"THE PRE-SEED ROUND",72,60,520,26,15,C.lav2,true);text(s,"Built in India.\nFor the world.",72,132,720,230,58,C.white,true);
 box(s,770,58,438,592,C.white,28);text(s,"USE OF FUNDS",806,94,366,28,18,C.primary,true);
 const funds=[["60%","PRODUCT + INFRA","Development, reliability and infrastructure",C.primary],["25%","USER GROWTH","Waitlist conversion and community acquisition",C.blue],["10%","OPERATIONS","Legal, compliance, finance and support",C.green],["5%","CREATOR ECOSYSTEM","Creator pilots, tools and partnerships",C.amber]];
 funds.forEach((a,i)=>{const y=148+i*100;text(s,a[0],806,y,74,36,24,a[3],true);text(s,a[1],892,y,280,24,15,C.ink,true);text(s,a[2],892,y+31,280,36,15,C.muted);box(s,806,y+78,366,4,C.line,2);box(s,806,y+78,366*(Number(a[0].replace("%",""))/60),4,a[3],2);});
 box(s,806,558,366,1,C.line,0);text(s,"100% allocated",806,578,170,24,16,C.primary,true);text(s,"Raise amount\nto be finalised",986,573,186,42,14,C.muted,true,"right");text(s,"Sampath Kumar  •  Founder & CEO",72,606,610,30,19,C.lav2,true);text(s,"VOIID",72,656,220,24,16,C.white,true);footer(s,21);notes(s,"Round stage provided by founder. Allocation supplied by founder: 60% development and infrastructure, 25% user growth, 10% operations, 5% creator ecosystem. Total verified at 100%. Raise amount remains to be finalised.");
}

await fs.mkdir(PREVIEW,{recursive:true});
for (let i=0;i<p.slides.items.length;i++) {const b=await p.export({slide:p.slides.items[i],format:"png",scale:1});await fs.writeFile(`${PREVIEW}/slide-${i+1}.png`,new Uint8Array(await b.arrayBuffer()));}
const pptx=await PresentationFile.exportPptx(p);await pptx.save(OUT);
console.log(OUT);
