#!/usr/bin/env python3
"""Run the production Android Telecom routing methods against platform callback fixtures."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/android/app/src/main/java/com/voiid/app/net/VoiidConnection.kt').read_text()
start = source.index('    fun applyRoutePreference(')
end = source.index('    /**\n     * Report the final outcome', start)
methods = source[start:end]
call_source = (root / 'apps/android/app/src/main/java/com/voiid/app/net/CallService.kt').read_text()
a = call_source.index('    sealed class AudioRoute(')
routes = call_source[a:call_source.index('    /**', a)]
cache = Path(os.environ.get('GRADLE_USER_HOME', str(Path.home() / '.gradle'))) / 'caches/modules-2/files-2.1'
version = re.search(r'^kotlin = "([^"]+)"', (root / 'apps/android/gradle/libs.versions.toml').read_text(), re.M).group(1)
def jar(group, module, version=None):
    path = cache / group / module
    if version: path /= version
    return str(sorted(path.rglob('*.jar'))[-1])
stdlib = jar('org.jetbrains.kotlin', 'kotlin-stdlib', version)
runtime = [stdlib, jar('org.jetbrains', 'annotations')]
compiler = [jar('org.jetbrains.kotlin', name, version) for name in ['kotlin-compiler-embeddable', 'kotlin-script-runtime', 'kotlin-reflect']]
compiler += runtime + [jar('org.jetbrains.intellij.deps', 'trove4j'), jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.9.0')]
fixture = '''
annotation class RequiresApi(val value: Int)
object Build { object VERSION { var SDK_INT = 34 } }
interface OutcomeReceiver<R, E> { fun onResult(result: R?); fun onError(error: E) }
class CallEndpointException(val code: Int)
data class CallEndpoint(val identifier: String, val endpointType: Int, val endpointName: String) {
    companion object { const val TYPE_EARPIECE=1; const val TYPE_SPEAKER=2; const val TYPE_BLUETOOTH=3; const val TYPE_WIRED_HEADSET=4 }
}
class CallAudioState(var route: Int = 1, val supportedRouteMask: Int = 15) {
    companion object { const val ROUTE_EARPIECE=1; const val ROUTE_SPEAKER=2; const val ROUTE_BLUETOOTH=4; const val ROUTE_WIRED_HEADSET=8 }
}
class Context { val mainExecutor = java.util.concurrent.Executor { it.run() } }
open class Connection {
    var callAudioState: CallAudioState? = CallAudioState()
    var currentCallEndpoint: CallEndpoint? = null
    val requests = mutableListOf<CallEndpoint>()
    val legacyRequests = mutableListOf<Int>()
    fun setAudioRoute(route: Int) { legacyRequests += route }
    fun requestCallEndpointChange(target: CallEndpoint, executor: java.util.concurrent.Executor, receiver: OutcomeReceiver<Void, CallEndpointException>) { requests += target }
    open fun onAvailableCallEndpointsChanged(availableEndpoints: MutableList<CallEndpoint>) {}
    open fun onCallEndpointChanged(callEndpoint: CallEndpoint) {}
    open fun onMuteStateChanged(isMuted: Boolean) {}
}
object CallManager {
''' + routes + '''
    data class CallState(val callId: String = "call", val muted: Boolean = false)
    object state { var value: CallState? = CallState() }
    var speaker = false
    fun onSystemAudioRouteChanged(value: Boolean) { speaker = value }
    fun toggleMute() { state.value = state.value?.copy(muted = !state.value!!.muted) }
}
class Harness: Connection() {
    var terminated = false
    val callId = "call"
    val appContext = Context()
    var pendingSpeaker: Boolean? = null
    var pendingExplicitRoute: CallManager.AudioRoute? = null
    var endpoints: List<CallEndpoint> = emptyList()
''' + methods + '''
}
fun main() {
    val phone = CallEndpoint("phone", 1, "Phone")
    val speaker = CallEndpoint("speaker", 2, "Speaker")
    val headset = CallEndpoint("headset", 3, "Test headset")
    val other = CallEndpoint("other", 3, "Other headset")
    val all = mutableListOf(phone, speaker, headset, other)
    val automatic = Harness(); automatic.onAvailableCallEndpointsChanged(all)
    automatic.applyRoutePreference(false)
    check(automatic.requests.last() == headset)
    automatic.applyExplicitRoute(CallManager.AudioRoute.Speaker)
    check(automatic.requests.last() == speaker)
    automatic.applyExplicitRoute(CallManager.AudioRoute.Earpiece)
    check(automatic.requests.last() == phone)
    automatic.applyExplicitRoute(CallManager.AudioRoute.Bluetooth(other.identifier.hashCode(), other.endpointName))
    check(automatic.requests.last() == other)
    val pending = Harness(); pending.applyExplicitRoute(CallManager.AudioRoute.Speaker)
    check(pending.requests.isEmpty())
    pending.onAvailableCallEndpointsChanged(all)
    check(pending.requests.single() == speaker)
    pending.onCallEndpointChanged(speaker); check(CallManager.speaker)
    pending.onCallEndpointChanged(phone); check(!CallManager.speaker)
    pending.terminated = true; pending.onCallEndpointChanged(speaker); check(!CallManager.speaker)
    val old = Harness(); Build.VERSION.SDK_INT = 33
    old.applyExplicitRoute(CallManager.AudioRoute.Speaker)
    check(old.legacyRequests.last() == CallAudioState.ROUTE_SPEAKER)
    old.applyExplicitRoute(CallManager.AudioRoute.Earpiece)
    check(old.legacyRequests.last() == CallAudioState.ROUTE_EARPIECE)
    println("PASS: modern and legacy explicit routes beat headset defaults; exact headset, deferred endpoints, confirmed UI state, stale callback")
}
'''
with tempfile.TemporaryDirectory(prefix='voiid-audio-routing-') as directory:
    folder = Path(directory)
    main = folder / 'Routes.kt'; main.write_text(fixture)
    log = folder / 'Log.kt'; log.write_text('package android.util\nobject Log { fun i(tag: String, message: String) {}\nfun w(tag: String, message: String) {} }')
    subprocess.run(['java', '-Xmx512m', '-cp', os.pathsep.join(compiler), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler',
                    '-no-stdlib', '-no-reflect', '-classpath', os.pathsep.join(runtime), '-d', str(folder / 'classes'), str(main), str(log)], check=True)
    subprocess.run(['java', '-cp', os.pathsep.join([str(folder / 'classes')] + runtime), 'RoutesKt'], check=True)
