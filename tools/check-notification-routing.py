#!/usr/bin/env python3
"""Exercise production notification destination state on both platforms, including cold/rapid taps."""
from pathlib import Path
import os
import re
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
android = root / 'apps/android/app/src/main/java/com/voiid/app'
ios = root / 'apps/ios/Voiid/Voiid'
cache = Path.home() / '.gradle/caches/modules-2/files-2.1'
version = re.search(r'^kotlin = "([^"]+)"', (root / 'apps/android/gradle/libs.versions.toml').read_text(), re.M).group(1)
def jar(group, name, version=None):
    path = cache / group / name
    if version: path /= version
    return str(sorted(path.rglob('*.jar'))[-1])
runtime = [jar('org.jetbrains.kotlin', 'kotlin-stdlib', version), jar('org.jetbrains.kotlinx', 'kotlinx-coroutines-core-jvm', '1.9.0'), jar('org.jetbrains', 'annotations')]
compiler = [jar('org.jetbrains.kotlin', m, version) for m in ['kotlin-compiler-embeddable', 'kotlin-script-runtime', 'kotlin-reflect']] + runtime + [jar('org.jetbrains.intellij.deps', 'trove4j')]
checks = '''
package com.voiid.app.net
class CommunityLink
fun main() {
    DeepLinkRouter.open("chat-a", "message-1")
    val first = DeepLinkRouter.pendingConversation.value!!
    check(first.messageId == "message-1" && DeepLinkRouter.pendingMessage.value == first)
    DeepLinkRouter.consume(first)
    check(DeepLinkRouter.pendingMessage.value == first) // Retained until transcript loads.
    DeepLinkRouter.open("chat-a", "message-2")
    val second = DeepLinkRouter.pendingConversation.value!!
    DeepLinkRouter.consume(first); DeepLinkRouter.consumeMessage(first)
    check(DeepLinkRouter.pendingConversation.value == second && DeepLinkRouter.pendingMessage.value == second)
    DeepLinkRouter.open("chat-b", "message-3")
    check(DeepLinkRouter.pendingConversation.value!!.conversationId == "chat-b")
    DeepLinkRouter.open("chat-b", "message-3")
    val repeated = DeepLinkRouter.pendingConversation.value!!
    DeepLinkRouter.open("chat-b", "message-3")
    check(DeepLinkRouter.pendingConversation.value!!.requestId != repeated.requestId)
    DeepLinkRouter.open("chat-a")
    check(DeepLinkRouter.pendingMessage.value == null)
    check(!IncomingCallPresentation.state.value.showsCall("a", false))
    IncomingCallPresentation.open("a")
    check(IncomingCallPresentation.state.value.showsCall("a", false))
    check(!IncomingCallPresentation.state.value.showsCall("b", false))
    IncomingCallPresentation.clear()
    check(!IncomingCallPresentation.state.value.showsCall("a", false))
    check(IncomingCallPresentation.state.value.showsCall("b", true))
    IncomingCallPresentation.useFallback("b")
    check(IncomingCallPresentation.state.value.showsCall("b", false))
    println("PASS: Android exact-message, delayed transcript, rapid/repeated taps, stale completion, notification-only ring and fallback")
}
'''
preview_source = (android / 'net/VoiidMessagingService.kt').read_text()
preview_start = preview_source.index('        val target = if (messageId != null)')
preview_end = preview_source.index('        // Same precedence', preview_start)
checks += '''
data class PreviewMessage(val id: String, val serverId: String? = null, val isMine: Boolean = false)
fun choosePreview(after: List<PreviewMessage>, before: Set<String>, messageId: String?): PreviewMessage? {
''' + preview_source[preview_start:preview_end] + '    return target\n}\n'
checks = checks.replace('    println("PASS: Android exact-message', '''    val previews = listOf(PreviewMessage("old"), PreviewMessage("local", "server"), PreviewMessage("own", isMine = true))
    check(choosePreview(previews, emptySet(), "missing") == null)
    check(choosePreview(previews, emptySet(), "server")?.id == "local")
    check(choosePreview(previews, emptySet(), "own") == null)
    println("PASS: Android exact-message''')
swift_source = (ios / 'VoiidApp.swift').read_text()
a = swift_source.index('@MainActor\nfinal class NotificationMessageRouter:')
b = swift_source.index('/// AppDelegate forwards', a)
swift_checks = '''
@main struct Check {
    @MainActor static func main() {
        let router = NotificationMessageRouter.shared
        router.open(conversationId: "a", messageId: "1")
        let first = router.pendingConversation!
        precondition(router.pendingMessage == first)
        router.consumeConversation(first)
        precondition(router.pendingMessage == first)
        router.open(conversationId: "a", messageId: "2")
        let second = router.pendingConversation!
        router.consumeConversation(first); router.consumeMessage(first)
        precondition(router.pendingConversation == second && router.pendingMessage == second)
        router.open(conversationId: "b", messageId: "3")
        let third = router.pendingConversation!
        router.open(conversationId: "b", messageId: "3")
        precondition(router.pendingConversation!.id != third.id)
        router.open(conversationId: "a", messageId: nil)
        precondition(router.pendingMessage == nil)
        print("PASS: iOS cold-launch retention, exact-message, repeated taps, stale completion and conversation-only links")
    }
}
'''
ui_source = (ios / 'ContentView.swift').read_text()
ui_start = ui_source.index('    private var incomingCallPresented:')
getter_start = ui_source.index('            get: {', ui_start) + len('            get: {')
getter_end = ui_source.index('            },', getter_start)
swift_checks = '''
enum RingPhase { case incomingRinging, outgoingRinging, connecting, connected, ended }
struct RingCall { var state: RingPhase; var isOutgoing = false }
struct RingModel { var active: RingCall?; var callUIMinimized = false }
struct RingUIHarness {
    var call = RingModel()
    var restoreCallUIRequested = false
    func presented() -> Bool {
''' + ui_source[getter_start:getter_end] + '''
    }
}
''' + swift_checks
swift_checks = swift_checks.replace('        let router = NotificationMessageRouter.shared', '''        var ui = RingUIHarness()
        precondition(!ui.presented())
        ui.call.active = RingCall(state: .incomingRinging)
        precondition(!ui.presented())
        ui.restoreCallUIRequested = true
        precondition(!ui.presented())
        ui.call.active?.state = .connecting
        precondition(ui.presented())
        ui.call.active?.state = .connected
        precondition(ui.presented())
        ui.call.callUIMinimized = true
        precondition(!ui.presented())
        ui.call.callUIMinimized = false
        ui.call.active?.state = .ended
        precondition(!ui.presented())
        print("PASS: iOS CallKit-only ringing, accepted-call presentation, restore, minimized and ended guards")
        let router = NotificationMessageRouter.shared''')

with tempfile.TemporaryDirectory(prefix='voiid-notification-routing-') as directory:
    temp = Path(directory)
    files = [android / 'net/DeepLinkRouter.kt', android / 'net/IncomingCallPresentation.kt']
    fixture = temp / 'Check.kt'; fixture.write_text(checks)
    subprocess.run(['java', '-Xmx512m', '-cp', os.pathsep.join(compiler), 'org.jetbrains.kotlin.cli.jvm.K2JVMCompiler', '-no-stdlib', '-no-reflect', '-classpath', os.pathsep.join(runtime), '-d', str(temp / 'classes'), *map(str, files), str(fixture)], check=True)
    subprocess.run(['java', '-cp', os.pathsep.join([str(temp / 'classes'), *runtime]), 'com.voiid.app.net.CheckKt'], check=True)
    swift = temp / 'Check.swift'; swift.write_text('import Foundation\nimport Combine\n' + swift_source[a:b] + swift_checks)
    subprocess.run(['swiftc', '-parse-as-library', '-module-cache-path', str(temp / 'swift-cache'), str(swift), '-o', str(temp / 'check')], check=True)
    subprocess.run([str(temp / 'check')], check=True)

# Wiring checks supplement the executable state tests: IDs survive every transport/UI boundary.
assert 'putExtra(DeepLinkRouter.EXTRA_MESSAGE_ID, messageId)' in (android / 'net/VoiidMessagingService.kt').read_text()
assert '.appendPath(conversationId).appendPath(messageId' in (android / 'net/VoiidMessagingService.kt').read_text()
assert 'DeepLinkRouter.open(it, messageId)' in (android / 'MainActivity.kt').read_text()
assert 'lifecycleOwner.lifecycle.withResumed' in (android / 'MainActivity.kt').read_text()
assert 'rowIds.indexOf(target.messageId)' in (android / 'main/ChatDetailView.kt').read_text()
assert 'notificationRouter.$pendingConversation' in (ios / 'Main/RootTabView.swift').read_text()
assert 'proxy.scrollTo(messageId, anchor: .center)' in (ios / 'Main/ChatDetailView.swift').read_text()
print('PASS: message-ID transport/UI wiring and resumed-activity answer guard')
