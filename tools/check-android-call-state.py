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
class Executor { fun execute(action: () -> Unit) = action() }
class Harness {
    val exec = Executor()
    val localAudioTrack: AudioTrack? = AudioTrack()
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
    kotlin.write_text(prelude + method + controls + checks + coordinator)
    runtime = os.pathsep.join([stdlib, coroutines, annotations])
    subprocess.run(['java', '-Xmx512m', '-cp', os.pathsep.join(compiler),
                    'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect',
                    '-classpath', runtime, '-d', str(temp / 'classes'), str(kotlin)], check=True)
    subprocess.run(['java', '-cp', os.pathsep.join([str(temp / 'classes'), runtime]), 'CallStateRaceKt'], check=True)
