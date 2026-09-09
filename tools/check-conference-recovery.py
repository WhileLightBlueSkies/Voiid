#!/usr/bin/env python3
"""Run the production Swift encryption recovery handler with controlled room events."""
from pathlib import Path
import subprocess
import tempfile

root = Path(__file__).resolve().parents[1]


def method(source, signature):
    start = source.index(signature)
    opening = source.index('{', start)
    depth = 1
    end = opening + 1
    while depth:
        depth += (source[end] == '{') - (source[end] == '}')
        end += 1
    return source[start:end]


group = (root / 'apps/ios/Voiid/Voiid/Networking/GroupCallService.swift').read_text()
conference = (root / 'apps/ios/Voiid/Voiid/Networking/CallConference.swift').read_text()
handler = method(group, '    private func handleEncryptionState(')
unsubscribe = method(group, '    nonisolated func room(_ room: Room, participant _: RemoteParticipant, didUnsubscribeTrack publication:')
coordinator = method(conference, '    static func keyCoordinator(')
prelude = '''import Foundation
final class Room: @unchecked Sendable {}
final class TrackPublication: @unchecked Sendable {}
typealias RemoteTrackPublication = TrackPublication
final class RemoteParticipant: @unchecked Sendable {}
enum E2EEState: Sendable { case ok, missing_key, decryption_failed, encryption_failed }
struct CallRosterEntry { let userId: String; let state: String; var invitedBy: String? = nil }
@MainActor final class Harness {
    var room: Room? = Room()
    var generation = UUID()
    var failures = 0
    var keyRecoveryTasks: [ObjectIdentifier: Task<Void, Never>] = [:]
    static let keyRecoveryTimeout: Duration = .milliseconds(40)
    func isCurrent(_ session: UUID) -> Bool { generation == session && !Task.isCancelled }
    func refreshParticipants() {}
    func teardown(failure: String?) async { failures += 1; room = nil; generation = UUID() }
    func event(_ room: Room, _ publication: TrackPublication, _ state: E2EEState) {
        handleEncryptionState(room: room, publication: publication, state: state)
    }
'''
checks = '''}
@main struct Check {
    @MainActor static func main() async throws {
        let track = TrackPublication()
        let recovered = Harness(), room = recovered.room!
        recovered.event(room, track, .decryption_failed)
        precondition(recovered.failures == 0, "a rotating key must not immediately hang up")
        recovered.event(room, track, .ok)
        try await Task.sleep(for: .milliseconds(100))
        precondition(recovered.failures == 0 && recovered.keyRecoveryTasks.isEmpty)

        let failed = Harness(), failedRoom = failed.room!
        failed.event(failedRoom, track, .missing_key)
        failed.event(failedRoom, track, .decryption_failed)
        precondition(failed.keyRecoveryTasks.count == 1, "repeated errors cannot reset the deadline")
        try await Task.sleep(for: .milliseconds(100))
        precondition(failed.failures == 1, "a persistent encryption failure must close the room")

        let stale = Harness()
        stale.event(Room(), track, .decryption_failed)
        precondition(stale.keyRecoveryTasks.isEmpty)

        let replacement = Harness()
        replacement.event(replacement.room!, track, .decryption_failed)
        replacement.room = Room(); replacement.generation = UUID()
        try await Task.sleep(for: .milliseconds(100))
        precondition(replacement.failures == 0, "old room's watchdog must not close its replacement")

        let left = Harness(), leftRoom = left.room!
        left.event(leftRoom, track, .decryption_failed)
        left.room(leftRoom, participant: RemoteParticipant(), didUnsubscribeTrack: track)
        try await Task.sleep(for: .milliseconds(100))
        precondition(left.failures == 0 && left.keyRecoveryTasks.isEmpty,
                     "a departing participant's track must not later end the room")

        let roster = [CallRosterEntry(userId: "b", state: "joined"),
                      CallRosterEntry(userId: "a", state: "joined"),
                      CallRosterEntry(userId: "c", state: "invited", invitedBy: "b")]
        precondition(Harness.keyCoordinator(roster) == "b")
        precondition(Harness.keyCoordinator(roster.reversed()) == "b")
        precondition(Harness.keyCoordinator(roster.filter { $0.userId != "b" }) == "a")
        precondition(Harness.keyCoordinator([.init(userId: "a", state: "declined"),
                                            .init(userId: "b", state: "joined")]) == "b")
        precondition(Harness.keyCoordinator([.init(userId: "a", state: "invited")]) == nil)
        print("PASS: 5 production Swift encryption recovery scenarios; 5 coordinator elections")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='voiid-conference-recovery-') as directory:
    temp = Path(directory)
    source = temp / 'Check.swift'
    source.write_text(prelude + handler + '\n' + unsubscribe + '\n' + coordinator + '\n' + checks)
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(source), '-o', str(temp / 'check')], check=True)
    subprocess.run([str(temp / 'check')], check=True)
