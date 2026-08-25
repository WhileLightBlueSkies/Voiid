import { readFileSync } from 'node:fs';
import { resolve } from 'node:path';
import { ludo, FIRST_TURN_MS, ROLL_SETTLE_MS, TRANSITION_MS, TURN_WINDOW_MS } from './index';
import { buildBoardCells } from './cells';
import { destination, FINISHED, HOME_LANE_BASE, isSafe, path, START_INDICES, YARD } from './board';
import { blockedSquares, legalMoves, pickAutoMove, resolveCapture } from './rules';
import { pickTimeoutMove } from './autoplay';
import { selectBotMove } from './bot/policy';
import { botDelay, BOT_TURN_BUDGET_MS } from './bot/scheduler';
import { botName } from './bot/names';
import { DiceRng } from './rng';
import type { GameEngine } from '../GameEngine';
import type { LudoStateV3 } from './types';

let failed = 0; let passed = 0;
function check(name: string, value: boolean): void {
    if (value) { passed++; console.log(`  PASS  ${name}`); }
    else { failed++; console.error(`  FAIL  ${name}`); }
}
function state(overrides: Partial<LudoStateV3> = {}): LudoStateV3 {
    return {
        schemaVersion: 3, rulesVersion: 'ludo-classic-2', mode: 'four', status: 'active', started: true,
        assigned: [true,true,true,true], controller: ['human','human','human','human'],
        humanUserIds: ['u0','u1','u2','u3'], formerControllerUserIds: [null,null,null,null],
        botDifficulty: [null,null,null,null], botNames: [null,null,null,null],
        botPolicyVersion: [null,null,null,null], accepted: [true,true,true,true],
        participation: ['active','active','active','active'], timeoutStreak: [0,0,0,0], captures: [0,0,0,0],
        tokens: Array.from({length:4}, () => [YARD,YARD,YARD,YARD]), activeSeat: 0, turnSerial: 1,
        phase: 'awaitingRoll', opensAt: Date.now()-1, deadlineAt: Date.now()+TURN_WINDOW_MS,
        botActionAt: null, sixStreak: 0, rollId: null, rollValue: null, legalTokenIds: [],
        automated: false, turnHadAutoAction: false, actionCounter: 0, lastAction: null,
        winnerSeat: null, winnerController: null, winnerUserId: null, endReason: null,
        startedAt: Date.now(), ...overrides,
    };
}
function restored(s: LudoStateV3, seed = 'ab'.repeat(32)): GameEngine {
    return ludo.restore({ludo: structuredClone(s)}, {ludo:{rng:{seed,counter:0},pacingCounter:0}});
}
function serialized(e: GameEngine): LudoStateV3 { return (e.serialize() as {ludo:LudoStateV3}).ludo; }

console.log('\nLudo v3 board and rules');
let formulaOkay = true;
for (let seat=0;seat<4;seat++) for (let at=0;at<52;at++) for (let die=1;die<=6;die++) {
    const progress=(at-START_INDICES[seat]+52)%52, next=progress+die;
    const expected=next<52?(START_INDICES[seat]+next)%52:next===57?FINISHED:next<57?HOME_LANE_BASE+next-52:null;
    if (destination(at,die,seat)!==expected) formulaOkay=false;
}
check('52 cells × 4 seats × 6 dice obey the closed form', formulaOkay);
check('yard entry requires exactly six', [1,2,3,4,5].every(d=>destination(YARD,d,2)===null)&&destination(YARD,6,2)===26);
check('home-lane exact finish and overshoot', destination(104,1,0)===FINISHED&&destination(104,2,0)===null);
check('all eight safe cells are exact', [0,8,13,21,26,34,39,47].every(isSafe)&&!isSafe(50));
const cells=buildBoardCells();
check('generated board has 225 uniquely keyed addressable cells', cells.length===225&&new Set(cells.map(c=>c.id)).size===225);
// Start cells are safe, so they carry a star like the other four safe squares, AND they carry
// their seat so the client can ink them in that seat's colour. They used to be inked but
// unmarked, which read as ordinary coloured track rather than as a safe square.
check('start cells carry their seat, a star, and safety', [0,13,26,39].every((i,seat)=>{
    const c=cells.find(x=>x.trackIndex===i);
    return c?.decoration==='star'&&c?.isEntry===true&&c?.isSafe===true&&c?.seat===seat;
}));
check('every safe cell is starred and approach chevrons are untouched', cells.filter(c=>c.decoration==='star').length===8&&cells.filter(c=>c.decoration==='approachChevron').length===4);
check('only start cells are flagged as entries', cells.filter(c=>c.isEntry).length===4);
const fixture=JSON.parse(readFileSync(resolve(process.cwd(),'../../packages/design-tokens/fixtures/ludo_board_v3.json'),'utf8'));
check('shared v3 fixture matches generated cells', JSON.stringify(fixture.cells)===JSON.stringify(cells));

const captureState=state({tokens:[[21,YARD,YARD,YARD],[27,YARD,YARD,YARD],[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD]]});
check('single opponent on non-safe destination captures', resolveCapture(captureState,0,27)?.seat===1);
captureState.tokens[1]=[27,27,YARD,YARD];
check('opponent block cannot be crossed or landed on', blockedSquares(captureState,0).has(27)&&!legalMoves(captureState,0,6).includes(0));
const ownBlock=state({tokens:[[0,0,YARD,YARD],[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD]]});
check('third pawn cannot enter its own two-pawn start block', !legalMoves(ownBlock,0,6).includes(2));
check('path returns every traversed cell in order', JSON.stringify(path(0,6,0))===JSON.stringify([1,2,3,4,5,6]));

console.log('\nLudo v3 deterministic authority');
const seed='12'.repeat(32), a=DiceRng.fromState({seed,counter:0})!, b=DiceRng.fromState({seed,counter:0})!;
check('dice sequence is deterministic after restore', Array.from({length:128},()=>a.next()).join()===Array.from({length:128},()=>b.next()).join());
check('dice values remain in 1...6', Array.from({length:1000},()=>a.next()).every(v=>v>=1&&v<=6));
check('commitment does not disclose seed', !a.commitment().includes(seed));
const auto=state({tokens:[[50,40,YARD,YARD],[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD]]});
const legal=legalMoves(auto,0,1);
check('timeout adapter is exactly Balanced selection', pickTimeoutMove(auto,0,1,legal)===selectBotMove(auto,0,1,legal,'balanced'));
check('deterministic auto-pick ties remain stable', pickAutoMove(auto,0,1,legal)===pickAutoMove(auto,0,1,legal));
// Rolling carries no decision, so its pacing is short; choosing a token does, so it is longer.
// The gap between the two is the point: a bot that pauses the same length before both reads as
// stalled on the roll, which is what a table of bots felt like early on when nobody can leave
// home and every turn is roll-and-pass.
check('bot names are deterministic', botName(seed,2,new Set())===botName(seed,2,new Set()));
check('bot roll pacing is short and bounded', botDelay(seed,3,'balanced','awaitingRoll')>=300&&botDelay(seed,3,'balanced','awaitingRoll')<=520);
// The move delay is measured from the OPEN of the move window, which is already ROLL_SETTLE_MS
// past the roll — so it is a short beat, not a second pause. A whole bot turn, both legs plus
// the roll animation between them, has to fit the budget; otherwise a table of bots eats the
// time between two of your own turns.
check('a whole bot turn fits the budget', (() => {
    const tiers = ['relaxed','balanced','sharp'] as const;
    return tiers.every((tier) => {
        let worst = 0;
        for (let c = 0; c < 200; c++) {
            const turn = botDelay(seed, c, tier, 'awaitingRoll')
                + ROLL_SETTLE_MS
                + botDelay(seed, c, tier, 'awaitingMove');
            if (turn > worst) worst = turn;
        }
        return worst <= BOT_TURN_BUDGET_MS;
    });
})());

console.log('\nLudo v3 lifecycle, projection, recovery');
const e=ludo.create(['u0'],{mode:'duel',rngSeed:seed,roster:[{kind:'human',userId:'u0'},{kind:'bot',difficulty:'sharp'}]}) as GameEngine&{accept(id:string):boolean;startAll(now:number):void;setFrameContext(c:unknown):void};
e.accept('u0'); const start=Date.now(); e.startAll(start); let s=serialized(e);
check('duel assigns opposite physical seats and four pawns each', s.assigned.filter(Boolean).length===2&&s.assigned[0]===s.assigned[2]&&s.tokens.filter(r=>r.length===4).length===2);
check('first decision opens at +120ms', s.opensAt===start+FIRST_TURN_MS);

// A 3-player table is a real configuration; the roster used to be truncated to the mode's
// seat count, silently dropping the third player.
const three=ludo.create(['u0'],{rngSeed:seed,roster:[{kind:'human',userId:'u0'},{kind:'bot',difficulty:'balanced'},{kind:'bot',difficulty:'relaxed'}]}) as GameEngine&{accept(id:string):boolean;startAll(now:number):void};
three.accept('u0'); three.startAll(Date.now()); const s3=serialized(three);
check('three-player table seats all three players', s3.assigned.filter(Boolean).length===3&&s3.tokens.filter(r=>r.length===4).length===3);
check('three-player table is not duel mode', s3.mode==='four');
const four=ludo.create(['u0'],{rngSeed:seed,roster:[{kind:'human',userId:'u0'},{kind:'bot',difficulty:'balanced'},{kind:'bot',difficulty:'relaxed'},{kind:'bot',difficulty:'sharp'}]}) as GameEngine&{accept(id:string):boolean;startAll(now:number):void};
four.accept('u0'); four.startAll(Date.now());
check('four-player table still seats four', serialized(four).assigned.filter(Boolean).length===4);
check('human gets deadline; bot gets botActionAt only', s.controller[s.activeSeat]==='human'?s.deadlineAt===s.opensAt!+TURN_WINDOW_MS&&s.botActionAt===null:s.deadlineAt===null&&s.botActionAt!==null);
e.setFrameContext({serverNow:start,seq:9,connections:{u0:'connected'},names:{u0:'Alice'}});
const projected=e.serializeForPlayer!('u0') as any;
e.setFrameContext({serverNow:start,seq:9,connections:{u0:'connected'},names:{u0:'Player 1'}});
const outsider=e.serializeForPlayer!('intruder') as any;
check('wire is schema v3 with recipient role and sequence', projected.ludoV3.schemaVersion===3&&projected.ludoV3.seq===9&&projected.ludoV3.viewerRole==='controller');
check('unauthorized projection contains no raw identity', !JSON.stringify(outsider).includes('u0')&&!JSON.stringify(outsider).includes('Alice'));
check('server bots expose BOT marker but no human identity', projected.ludoV3.seats.some((x:any)=>x.controller==='bot'&&x.botMarker==='BOT'));
check('server secret never appears in public state', !JSON.stringify(projected).includes(seed));
const roundTrip=ludo.restore(e.serialize(),e.serializeSecret!());
check('serialize/restore preserves authoritative state', JSON.stringify(roundTrip.serialize())===JSON.stringify(e.serialize()));
const lostSecret=ludo.restore(e.serialize());
check('missing RNG secret abandons match safely', serialized(lostSecret).status==='abandoned'&&serialized(lostSecret).endReason==='serverIntegrityError');
check('schema-v2 restore is terminal, never parallel rules', ludo.restore({ludo:{schemaVersion:2}}).isFinished!());
const former=state({controller:['bot','human','human','human'],humanUserIds:[null,'u1','u2','u3'],formerControllerUserIds:['u0',null,null,null],activeSeat:0});
check('former controller cannot submit intent after takeover', restored(former).applyInput('u0',{turnSerial:1,roll:true}).rejection==='NOT_SEAT_CONTROLLER');
const duel=state({mode:'duel',assigned:[true,false,true,false],humanUserIds:['u0',null,'u2',null],participation:['active','waiting','active','waiting'],tokens:[[YARD,YARD,YARD,YARD],[],[YARD,YARD,YARD,YARD],[]]});
const duelEngine=restored(duel), forfeited=duelEngine.applyInput('u0',{forfeit:true});
check('duel forfeit is immediately terminal', forfeited.accepted&&serialized(duelEngine).status==='finished'&&serialized(duelEngine).endReason==='duelForfeit');
check('transition timing remains literal', TRANSITION_MS===480&&FIRST_TURN_MS===120);

function counterFor(target: number, reject?: number): number {
    for (let counter=0; counter<500; counter++) {
        const r=DiceRng.fromState({seed,counter})!;
        const value=r.next();
        if (value===target && value!==reject) return counter;
    }
    throw new Error('no deterministic die counter');
}
const thirdSix=state({sixStreak:2,tokens:[[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD]]});
const thirdSixEngine=ludo.restore({ludo:thirdSix},{ludo:{rng:{seed,counter:counterFor(6)},pacingCounter:0}});
const thirdResult=thirdSixEngine.applyInput('u0',{turnSerial:1,roll:true});
check('third consecutive six is discarded and passes', thirdResult.accepted&&serialized(thirdSixEngine).activeSeat===1&&serialized(thirdSixEngine).sixStreak===0);
const noLegal=state({tokens:[[0,0,FINISHED,FINISHED],[6,6,YARD,YARD],[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD]]});
const noLegalEngine=ludo.restore({ludo:noLegal},{ludo:{rng:{seed,counter:counterFor(6)},pacingCounter:0}});
noLegalEngine.applyInput('u0',{turnSerial:1,roll:true});
check('a six with no legal move grants another roll to the same seat', serialized(noLegalEngine).activeSeat===0&&serialized(noLegalEngine).phase==='awaitingRoll'&&serialized(noLegalEngine).sixStreak===1);
for (const tier of ['relaxed','balanced','sharp'] as const) {
    check(`${tier} bot policy is deterministic and proposes only a legal token`,
        selectBotMove(auto,0,1,legal,tier)===selectBotMove(auto,0,1,legal,tier)&&
        legal.includes(selectBotMove(auto,0,1,legal,tier)!));
}
const takeoverTokens=[[40,YARD,YARD,YARD],[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD]];
const takeover=state({timeoutStreak:[2,0,0,0],deadlineAt:Date.now()-1,tokens:takeoverTokens});
const takeoverEngine=ludo.restore({ludo:takeover},{ludo:{rng:{seed,counter:counterFor(1)},pacingCounter:0}});
takeoverEngine.onTimeout!();
const takeoverAfter=serialized(takeoverEngine);
check('third timed-out human turn installs irreversible Balanced server bot', takeoverAfter.controller[0]==='bot'&&takeoverAfter.botDifficulty[0]==='balanced'&&takeoverAfter.formerControllerUserIds[0]==='u0');
check('takeover preserves every pawn exactly', JSON.stringify(takeoverAfter.tokens[0])===JSON.stringify(takeoverTokens[0]));
const restoredMove=restored(state({phase:'awaitingMove',rollId:'r',rollValue:6,legalTokenIds:[0],tokens:[[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD],[YARD,YARD,YARD,YARD]]}));
check('restore while awaiting move retains roll and legal set', serialized(restoredMove).phase==='awaitingMove'&&serialized(restoredMove).rollId==='r'&&serialized(restoredMove).legalTokenIds[0]===0);

console.log(`\n${passed} passed, ${failed} failed`);
if (failed) process.exit(1);
