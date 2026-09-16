#!/usr/bin/env python3
"""Production recovery methods, duration models and SQLite history migrations/merges."""
from pathlib import Path
import json, os, re, sqlite3, subprocess, tempfile
root = Path(__file__).resolve().parents[1]
a = root / 'apps/android/app/src/main/java/com/voiid/app'
i = root / 'apps/ios/Voiid/Voiid'
def method(text, start):
    pos=text.index(start); brace=text.index('{',pos); depth=1; end=brace+1
    while depth:
        if text[end]=='{': depth+=1
        elif text[end]=='}': depth-=1
        end+=1
    return text[pos:end]
android_source=(a/'net/CallService.kt').read_text()
ios_source=(i/'Networking/CallService.swift').read_text()
android_recovery=method(android_source,'    private fun reconcileRecoveredConnection(').replace('private fun','fun',1)
ios_recovery=method(ios_source,'    private func reconcileRecoveredConnection(').replace('private func','func',1)
android_model=method((a/'model/Models.kt').read_text(),'data class VCallLog(')
ios_model=method((i/'Models/Models.swift').read_text(),'struct VCallLog:')

# Use the shipped v4 table and the actual migration/merge statements, not a new test schema.
schema=json.loads((root/'apps/android/app/schemas/com.voiid.app.store.VoiidDatabase/4.json').read_text())
create=next(e['createSql'] for e in schema['database']['entities'] if e['tableName']=='call_history').replace('${TABLE_NAME}','call_history')
android_merge=re.search(r'@Query\("(UPDATE call_history SET.*?)"\)',(a/'store/VoiidDatabase.kt').read_text()).group(1)
swift_store=(i/'Storage/LocalStore.swift').read_text()
swift_upsert=re.search(r'INSERT INTO call_history\s+.*?(?=\s+""", arguments:)',swift_store,re.S).group(0)
for platform in ['Android','iOS']:
    db=sqlite3.connect(':memory:'); db.execute(create)
    db.execute("INSERT INTO call_history(id,kind,direction,outcome,started_at,ended_at) VALUES('old','voice','incoming','answered',100,160)")
    src=(a/'store/Migrations.kt').read_text() if platform=='Android' else (i/'Storage/VoiidDatabase.swift').read_text()
    migration=re.search(r'ALTER TABLE `?call_history`? ADD COLUMN `?connected_at`? INTEGER',src).group(0)
    db.execute(migration)
    assert db.execute("SELECT started_at, ended_at, connected_at FROM call_history WHERE id='old'").fetchone()==(100,160,None)
    def record(start,connected,end,outcome):
        values=('call','chat','peer','voice','incoming',outcome,start,end,connected)
        if platform=='iOS': db.execute(swift_upsert,values)
        else:
            db.execute('INSERT OR IGNORE INTO call_history(id,conversation_id,peer_user_id,kind,direction,outcome,started_at,ended_at,connected_at) VALUES(?,?,?,?,?,?,?,?,?)',values)
            db.execute(android_merge,dict(id='call',conversationId='chat',peerUserId='peer',outcome=outcome,startedAt=start,endedAt=end,connectedAt=connected))
    record(1000,None,None,'missed'); record(1000,1020,None,'answered'); record(1000,1020,1085,'answered')
    record(1000,None,None,'missed') # queued initial write arrives after teardown
    record(1085,1050,None,'answered') # duplicate report must not move start/connection time
    assert db.execute("SELECT started_at, connected_at, ended_at, outcome FROM call_history WHERE id='call'").fetchone()==(1000,1020,1085,'answered')
    assert db.execute("SELECT ended_at-connected_at FROM call_history WHERE id='call'").fetchone()[0]==65
    assert db.execute('SELECT count(*) FROM call_history').fetchone()[0]==2
    print(f'PASS: {platform} migration preserves rows; start and connected times survive late/duplicate writes; duration excludes ringing')

cache=Path.home()/'.gradle/caches/modules-2/files-2.1'
version=re.search(r'^kotlin = "([^"]+)"',(root/'apps/android/gradle/libs.versions.toml').read_text(),re.M).group(1)
def jar(group,name,v=None):
    path=cache/group/name
    if v:path/=v
    return str(sorted(p for p in path.rglob('*.jar') if not p.name.endswith(('-sources.jar', '-javadoc.jar')))[-1])
runtime=[jar('org.jetbrains.kotlin','kotlin-stdlib',version),jar('org.jetbrains','annotations')]
compiler=[jar('org.jetbrains.kotlin',m,version) for m in ['kotlin-compiler-embeddable','kotlin-script-runtime','kotlin-reflect']]+runtime+[jar('org.jetbrains.intellij.deps','trove4j'),jar('org.jetbrains.kotlinx','kotlinx-coroutines-core-jvm','1.9.0')]
kotlin='''
class PeerConnection {
    enum class IceConnectionState { CONNECTED, COMPLETED, DISCONNECTED, CHECKING, FAILED }
    enum class SignalingState { STABLE, HAVE_LOCAL_OFFER }
    var ice = IceConnectionState.DISCONNECTED
    var signaling = SignalingState.STABLE
    fun iceConnectionState() = ice
    fun signalingState() = signaling
}
class Harness {
    var currentId = "call"
    var ended = false
    var pc: PeerConnection? = PeerConnection()
    var restartInFlight = true
    var iceRestartAttempts = 2
    var reconnecting = true
    var cancelled = 0
    var connectedAt = 1020L
    fun isCurrentCall(id: String) = currentId == id && !ended
    fun cancelDisconnectGrace() { cancelled++ }
    fun cancelRestartWatchdog() { cancelled++ }
    fun markReconnecting(on: Boolean) { reconnecting = on }
'''+android_recovery+'''
}
'''+android_model+'''
fun main() {
    val h=Harness()
    check(!h.reconcileRecoveredConnection("call") && h.reconnecting)
    h.pc!!.ice=PeerConnection.IceConnectionState.CONNECTED
    h.pc!!.signaling=PeerConnection.SignalingState.HAVE_LOCAL_OFFER
    check(h.reconcileRecoveredConnection("call") && !h.reconnecting && h.restartInFlight)
    h.pc!!.signaling=PeerConnection.SignalingState.STABLE
    check(h.reconcileRecoveredConnection("call") && !h.reconnecting && !h.restartInFlight && h.iceRestartAttempts==0)
    check(h.connectedAt==1020L && h.cancelled==2)
    val stale=Harness(); stale.pc!!.ice=PeerConnection.IceConnectionState.COMPLETED
    check(!stale.reconcileRecoveredConnection("old") && stale.reconnecting)
    stale.ended=true; check(!stale.reconcileRecoveredConnection("call"))
    val model=VCallLog("call",false,true,"answered",1000000L,1085000L,1020000L)
    check(model.durationSeconds==65L && model.startedAt==1000000L)
    check(model.copy(outcome="missed").durationSeconds==null)
    check(model.copy(endedAt=1010000L).durationSeconds==0L)
    check(model.copy(connectedAt=null).durationSeconds==85L)
    println("PASS: Android production recovery (stable, pending offer, stale, ended), unchanged timer, and duration model")
}
'''
swift='''import Foundation
class Peer { enum Ice { case connected, completed, disconnected }; enum Signal { case stable, haveLocalOffer }
    var iceConnectionState = Ice.disconnected; var signalingState = Signal.stable }
enum Phase { case connecting, connected, ended }
struct Call { var state = Phase.connected }
class Harness {
    var active: Call? = Call()
    var pc: Peer? = Peer()
    var recovered = false
    var isReconnecting = true
    func handleIceRecovered() { recovered = true }
'''+ios_recovery+'''
}
'''+ios_model+'''
let h=Harness(); h.reconcileRecoveredConnection(); precondition(!h.recovered)
h.pc!.iceConnectionState = .connected; h.pc!.signalingState = .haveLocalOffer
h.reconcileRecoveredConnection(); precondition(!h.recovered && !h.isReconnecting)
h.pc!.signalingState = .stable; h.reconcileRecoveredConnection(); precondition(h.recovered)
let ended=Harness(); ended.active?.state = .ended; ended.pc!.iceConnectionState = .completed
ended.reconcileRecoveredConnection(); precondition(!ended.recovered)
var model=VCallLog(callId:"call",isVideo:false,incoming:true,outcome:"answered",startedAt:Date(timeIntervalSince1970:1000),endedAt:Date(timeIntervalSince1970:1085),connectedAt:Date(timeIntervalSince1970:1020))
precondition(model.durationSeconds==65 && model.startedAt.timeIntervalSince1970==1000)
model.outcome="missed"; precondition(model.durationSeconds==nil)
model.outcome="answered"; model.endedAt=Date(timeIntervalSince1970:1010); precondition(model.durationSeconds==0)
print("PASS: iOS production recovery (stable, pending offer, ended) and connected-duration model")
'''
with tempfile.TemporaryDirectory(prefix='voiid-recovery-history-') as directory:
    temp=Path(directory); k=temp/'Check.kt';k.write_text(kotlin)
    subprocess.run(['java','-Xmx512m','-cp',os.pathsep.join(compiler),'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler','-no-stdlib','-no-reflect','-classpath',os.pathsep.join(runtime),'-d',str(temp/'classes'),str(k)],check=True)
    subprocess.run(['java','-cp',os.pathsep.join([str(temp/'classes'),*runtime]),'CheckKt'],check=True)
    f=temp/'Check.swift';f.write_text(swift)
    subprocess.run(['swiftc','-module-cache-path',str(temp/'swift-cache'),str(f),'-o',str(temp/'check')],check=True)
    subprocess.run([str(temp/'check')],check=True)
