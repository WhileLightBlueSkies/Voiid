#!/usr/bin/env python3
"""Exercise production iOS session ownership and committed history notifications."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]
def method(source, signature):
    start = source.index(signature)
    end = source.index('{', start) + 1
    depth = 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end] + '\n'

group = (root / 'apps/ios/Voiid/Voiid/Networking/GroupCallService.swift').read_text()
store = (root / 'apps/ios/Voiid/Voiid/Storage/LocalStore.swift').read_text()
fixture = '''import Foundation
final class AVAudioSession {
    static let instance = AVAudioSession()
    static func sharedInstance() -> AVAudioSession { instance }
    enum Category { case playAndRecord }
    enum Mode { case voiceChat }
    enum Option { case defaultToSpeaker, allowBluetooth, notifyOthersOnDeactivation }
    enum Port { case speaker, none }
    var categories = 0, activations = 0, deactivations = 0
    var port = Port.none
    func setCategory(_ category: Category, mode: Mode, options: [Option]) throws { categories += 1 }
    func setActive(_ active: Bool, options: Option? = nil) throws {
        if active { activations += 1 } else { deactivations += 1 }
    }
    func overrideOutputAudioPort(_ port: Port) throws { self.port = port }
}
final class CallService {
    static let shared = CallService()
    var active: Bool? = true
}
final class AudioHarness {
    var speakerOn = false
'''
fixture += method(group, '    private func configureAudioSession()').replace('private func', 'func')
fixture += method(group, '    private func deactivateAudioSession()').replace('private func', 'func')
fixture += '''
}
final class Database {
    func execute(sql: String, arguments: [Any?] = []) throws {}
}
final class DB {
    var fail = false
    func writeCommitted(_ block: (Database) throws -> Void) -> Bool {
        if fail { return false }
        do { try block(Database()); return true } catch { return false }
    }
}
final class TokenStore { static let shared = TokenStore(); var userId: String? = "fixture" }
final class UserDefaults {
    static let standard = UserDefaults()
    var values: [String: Any] = [:]
    func dictionary(forKey key: String) -> [String: Any]? { values[key] as? [String: Any] }
    func set(_ value: Any?, forKey key: String) { values[key] = value }
    func removeObject(forKey key: String) { values.removeValue(forKey: key) }
}
enum History {
    static let db = DB()
    static let callHistoryDidChange = Notification.Name("history")
'''
fixture += store[store.index('    private static let callWriteLock'):store.index('    @MainActor private static var recoveringCalls')]
fixture += method(store, '    static func recordCall(')
fixture += method(store, '    static func clearCallHistory()')
fixture += '''
}
let audio = AudioHarness(), session = AVAudioSession.instance
audio.configureAudioSession()
precondition(session.categories == 0 && session.activations == 0 && session.port == .none)
audio.speakerOn = true; audio.configureAudioSession()
precondition(session.port == .speaker && session.categories == 0)
audio.deactivateAudioSession()
precondition(session.deactivations == 0, "failed upgrade must preserve the original call")
CallService.shared.active = nil
audio.configureAudioSession(); audio.deactivateAudioSession()
precondition(session.categories == 1 && session.activations == 1 && session.deactivations == 1)
var changes = 0
let observer = NotificationCenter.default.addObserver(forName: History.callHistoryDidChange,
    object: nil, queue: nil) { _ in changes += 1 }
func record() -> Bool {
    History.recordCall(id: "call", conversationId: nil, peerUserId: "peer", kind: "voice",
        direction: "incoming", outcome: "missed", startedAt: Date())
}
precondition(record() && changes == 1)
History.db.fail = true
precondition(!record() && changes == 1, "failed write must not publish a committed change")
History.clearCallHistory(); precondition(changes == 1)
History.db.fail = false
History.retryPendingCalls(); precondition(changes == 2, "failed calls must retry and publish only after commit")
History.clearCallHistory(); precondition(changes == 3)
NotificationCenter.default.removeObserver(observer)
print("PASS: CallKit session ownership, standalone audio, and committed history notifications")
'''
with tempfile.TemporaryDirectory(prefix='voiid-call-audit-') as directory:
    temp = Path(directory)
    source = temp / 'Check.swift'
    source.write_text(fixture)
    subprocess.run(['swiftc', '-module-cache-path', str(temp/'cache'), str(source), '-o', str(temp/'check')], check=True)
    subprocess.run([str(temp/'check')], check=True)
