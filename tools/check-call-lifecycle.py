#!/usr/bin/env python3
"""Run the production CallKit end handler against stale-event regression scenarios on macOS."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
source = (root / 'apps/ios/Voiid/Voiid/Networking/CallService.swift').read_text()
start = source.index('    func callKitEnd(uuid: UUID) {')
method = source[start:source.index('    /// Tear down the call.', start)]
prelude = '''import Foundation
enum State { case ringing, connected, ended }
struct Call {
    let uuid: UUID
    var state = State.connected
    var isConferenceInvite = false
    var isOutgoing = true
}
enum Reason { case unknown, declined, localHangup }
final class Harness {
    var active: Call?
    var waitingCall: Call?
    var pendingEndReason = Reason.unknown
    var everConnected = false
    var localAnswerGiven = false
    var endedUUID: UUID?
    func clearWaitingCall(sendBusy: Bool, decline: Bool) { waitingCall = nil }
    func decline() { endedUUID = active?.uuid }
    func endActiveCall(notifyPeer: Bool, fromCallKit: Bool) { endedUUID = active?.uuid }
'''
checks = '''}
let current = UUID(), old = UUID()
let stale = Harness(); stale.active = Call(uuid: current)
stale.callKitEnd(uuid: old)
precondition(stale.endedUUID == nil, "A stale UUID must not end a newer call")
let matching = Harness(); matching.active = Call(uuid: current)
matching.callKitEnd(uuid: current)
precondition(matching.endedUUID == current)
let ended = Harness(); ended.active = Call(uuid: current, state: .ended)
ended.callKitEnd(uuid: current)
precondition(ended.endedUUID == nil, "Terminal callbacks are idempotent")
let waiting = Harness(); waiting.active = Call(uuid: current); waiting.waitingCall = Call(uuid: old)
waiting.callKitEnd(uuid: old)
precondition(waiting.waitingCall == nil && waiting.endedUUID == nil)
let declined = Harness(); declined.active = Call(uuid: current, state: .ringing, isOutgoing: false)
declined.callKitEnd(uuid: current)
precondition(declined.pendingEndReason == .declined)
print("PASS: 5 production CallKit handler regressions (stale, matching, ended, waiting, decline)")
'''
with tempfile.TemporaryDirectory(prefix='voiid-call-lifecycle-') as directory:
    temp = Path(directory)
    swift = temp / 'CallKitLifecycle.swift'
    swift.write_text(prelude + method + checks)
    sdk = subprocess.check_output(['xcrun', '--sdk', 'macosx', '--show-sdk-path'], text=True).strip()
    subprocess.run(['xcrun', 'swiftc', '-sdk', sdk, '-module-cache-path', str(temp / 'cache'),
                    str(swift), '-o', str(temp / 'regression')], check=True)
    subprocess.run([str(temp / 'regression')], check=True)
