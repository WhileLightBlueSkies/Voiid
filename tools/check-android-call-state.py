#!/usr/bin/env python3
"""Exercise the production state updater with real StateFlow and deterministic interleavings."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/android/app/src/main/java/com/voiid/app/net/CallService.kt').read_text()
start = source.index('    private inline fun update(')
method = source[start:source.index('    private fun appContextOrNull', start)]
controls_start = source.index('    fun toggleMute() {')
controls = source[controls_start:source.index('    /**', controls_start)]
focus_start = source.index('    private fun applyMicrophoneState(')
focus = source[focus_start:source.index('    private fun applyAudioRoute(', focus_start)]
conference_source = (root / 'apps/android/app/src/main/java/com/voiid/app/net/CallConference.kt').read_text()
coordinator = conference_source[conference_source.index('internal fun conferenceKeyCoordinator('):]

versions = (root / 'apps/android/gradle/libs.versions.toml').read_text()
version = re.search(r'^kotlin = "([^"]+)"', versions, re.MULTILINE).group(1)
cache = Path(os.environ.get('GRADLE_USER_HOME', str(Path.home() / '.gradle'))) / 'caches/modules-2/files-2.1'
def jar(group, module, version=None):
    base = cache / group / module
    if version:
        base /= version
    matches = sorted(base.glob('**/*.jar'))
    if not matches:
        raise SystemExit(f'Missing cached {module}. Run the Android Gradle build first.')
    return str(matches[-1])
stdlib = jar('org.jetbrains.kotlin', 'kotlin-stdlib', version)
coroutines = jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.9.0')
annotations = jar('org.jetbrains', 'annotations')
compiler = [jar('org.jetbrains.kotlin', m, version) for m in
            ['kotlin-compiler-embeddable', 'kotlin-script-runtime', 'kotlin-reflect']]
compiler += [stdlib, coroutines, annotations, jar('org.jetbrains.intellij.deps', 'trove4j')]
prelude = '''import kotlinx.coroutines.flow.MutableStateFlow
enum class Phase { CONNECTED, ENDED }
data class CallState(val callId: String, val phase: Phase = Phase.CONNECTED,
                     val muted: Boolean = false, val speaker: Boolean = false, val onHold: Boolean = false)
data class CallRosterEntry(val user_id: String, val state: String, val invited_by: String? = null)
object ConferenceManager {
    enum class Stage { ESCALATING, CONFERENCE, ENDED }
    data class Conference(val callId: String, val stage: Stage = Stage.CONFERENCE)
    val state = MutableStateFlow<Conference?>(null)
    var muteActions = 0
    fun toggleMute() { muteActions++ }
}
class AudioTrack { var sending = true; fun setEnabled(value: Boolean) { sending = value } }
class Executor {
    var delayed = false
    val pending = ArrayDeque<() -> Unit>()
    fun execute(action: () -> Unit) { if (delayed) pending.addLast(action) else action() }
    fun drain() { while (pending.isNotEmpty()) pending.removeFirst()() }
}
object TelecomBridge { val owned = mutableSetOf<String>(); fun ownsCall(id: String) = id in owned }
object CallAudioFocus { var abandoned = 0; fun abandon(context: Any) { abandoned++ } }
class Handler { fun post(action: () -> Unit) = action() }
class Harness {
    val exec = Executor()
    val mainHandler = Handler()
    val appContext = Any()
    var fallbackFocusInterruptedCallId: String? = null
    var telecomFocusInterruptedCallId: String? = null
    fun isCurrentCall(id: String) = _state.value?.let { it.callId == id && it.phase != Phase.ENDED } == true
    fun fallback(lost: Boolean) = onFallbackAudioFocusChanged("original", lost)
    fun handoff() = handOffAudioFocusToTelecom("original")
    fun reconcile() = applyMicrophoneState("original")
    var localAudioTrack: AudioTrack? = AudioTrack()
    val _state = MutableStateFlow<CallState?>(CallState("original"))
    fun mutate(block: (CallState) -> CallState) = update(block = block)
'''
checks = '''}
fun main() {
    val ended = Harness()
    ended.mutate { old ->
        ended._state.value = old.copy(phase = Phase.ENDED)
        old.copy(muted = true)
    }
    check(ended._state.value?.phase == Phase.ENDED)
    check(ended._state.value?.muted == false)
    val replaced = Harness()
    replaced.mutate { old ->
        replaced._state.value = CallState("replacement")
        old.copy(muted = true)
    }
    check(replaced._state.value == CallState("replacement"))
    val concurrent = Harness()
    var first = true
    concurrent.mutate { old ->
        if (first) { first = false; concurrent._state.value = old.copy(speaker = true) }
        old.copy(muted = true)
    }
    check(concurrent._state.value?.muted == true && concurrent._state.value?.speaker == true)
    println("PASS: 3 production Android state races (hangup, replacement call, concurrent controls)")
    val oneToOne = Harness()
    oneToOne.toggleMute()
    check(oneToOne._state.value?.muted == true && oneToOne.localAudioTrack?.sending == false)
    val conference = Harness()
    ConferenceManager.state.value = ConferenceManager.Conference("original")
    conference.toggleMute()
    check(ConferenceManager.muteActions == 1 && conference.localAudioTrack?.sending == true)
    ConferenceManager.state.value = ConferenceManager.Conference("different-call")
    val unrelated = Harness(); unrelated.toggleMute()
    check(ConferenceManager.muteActions == 1 && unrelated.localAudioTrack?.sending == false)
    ConferenceManager.state.value = null
    TelecomBridge.owned.clear()
    val interrupted = Harness()
    interrupted.fallback(true)
    check(interrupted.localAudioTrack?.sending == false)
    interrupted.toggleMute(); interrupted.toggleMute()
    check(interrupted.localAudioTrack?.sending == false) // Unmute cannot bypass interruption.
    TelecomBridge.owned.add("original")
    interrupted.handoff()
    check(interrupted.localAudioTrack?.sending == true) // Exact device failure recovery.
    interrupted.fallback(true)
    check(interrupted.localAudioTrack?.sending == true) // Late OS callback after handoff.
    val queued = Harness(); queued.exec.delayed = true
    TelecomBridge.owned.clear(); queued.fallback(true)
    TelecomBridge.owned.add("original"); queued.handoff(); queued.exec.drain()
    check(queued.localAudioTrack?.sending == true)
    val held = Harness(); held._state.value = held._state.value!!.copy(onHold = true)
    held.handoff(); check(held.localAudioTrack?.sending == false)
    val muted = Harness(); muted.toggleMute(); muted.handoff()
    check(muted.localAudioTrack?.sending == false)
    var acknowledged = false
    interrupted.onTelecomAudioFocusChanged(setOf("original"), true) { acknowledged = true }
    check(acknowledged && interrupted.localAudioTrack?.sending == false)
    interrupted.handoff(); check(interrupted.localAudioTrack?.sending == false)
    interrupted.toggleMute()
    interrupted.onTelecomAudioFocusChanged(setOf("original"), false)
    check(interrupted.localAudioTrack?.sending == false)
    interrupted.toggleMute(); check(interrupted.localAudioTrack?.sending == true)
    val stale = Harness(); stale.exec.delayed = true
    TelecomBridge.owned.clear(); stale.fallback(true)
    stale._state.value = CallState("replacement"); stale.exec.drain()
    check(stale.localAudioTrack?.sending == true)
    val hangup = Harness(); hangup.exec.delayed = true; hangup.fallback(true)
    hangup._state.value = hangup._state.value!!.copy(phase = Phase.ENDED); hangup.exec.drain()
    check(hangup.localAudioTrack?.sending == true)
    val early = Harness(); early.localAudioTrack = null; early.fallback(true)
    early.localAudioTrack = AudioTrack(); early.reconcile()
    check(early.localAudioTrack?.sending == false)
    early.fallback(false); check(early.localAudioTrack?.sending == true)
    println("PASS: microphone handoff, queued/late loss, real interruption, mute/hold, replacement, hangup, late track")
    val roster = listOf(CallRosterEntry("b", "joined"), CallRosterEntry("a", "joined"),
                        CallRosterEntry("c", "invited", "b"))
    check(conferenceKeyCoordinator(roster) == "b")
    check(conferenceKeyCoordinator(roster.reversed()) == "b")
    check(conferenceKeyCoordinator(roster.filter { it.user_id != "b" }) == "a")
    check(conferenceKeyCoordinator(listOf(CallRosterEntry("a", "declined"), CallRosterEntry("b", "joined"))) == "b")
    check(conferenceKeyCoordinator(listOf(CallRosterEntry("a", "invited"))) == null)
    println("PASS: 3 production Android mute routing scenarios; 5 coordinator elections")
}
'''
with tempfile.TemporaryDirectory(prefix='voiid-android-call-state-') as directory:
    temp = Path(directory)
    kotlin = temp / 'CallStateRace.kt'
    kotlin.write_text(prelude + method + controls + focus + checks + coordinator)
    (temp / 'BuildConfig.kt').write_text('package com.voiid.app\nobject BuildConfig { const val DEBUG = false }')
    (temp / 'Log.kt').write_text('package android.util\nobject Log { fun d(tag: String, message: String) = 0 }')
    runtime = os.pathsep.join([stdlib, coroutines, annotations])
    subprocess.run(['java', '-Xmx512m', '-cp', os.pathsep.join(compiler),
                    'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect',
                    '-classpath', runtime, '-d', str(temp / 'classes'), str(kotlin), str(temp / 'BuildConfig.kt'), str(temp / 'Log.kt')], check=True)
    subprocess.run(['java', '-cp', os.pathsep.join([str(temp / 'classes'), runtime]), 'CallStateRaceKt'], check=True)
