#!/usr/bin/env python3
"""Run the production Swift read queue with a persistent fixture store and failing HTTP."""
from pathlib import Path
import subprocess
import tempfile
root = Path(__file__).resolve().parents[1]
s = (root/'apps/ios/Voiid/Voiid/Networking/ChatEngine.swift').read_text()
a = s.index('    private var flushingConversationReads')
b = s.index('    #endif\n    func flushPendingReceipts()', a)
methods = s[a:b].replace('private ', '')
fixture = '''import Foundation
final class UserDefaults {
    static let standard = UserDefaults()
    static var file: URL!
    func all() -> [String: Any] {
        guard let data = try? Data(contentsOf: Self.file) else { return [:] }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:]
    }
    func dictionary(forKey key: String) -> [String: Any]? { all()[key] as? [String: Any] }
    func set(_ value: Any?, forKey key: String) {
        var contents = all(); contents[key] = value
        try! JSONSerialization.data(withJSONObject: contents).write(to: Self.file, options: .atomic)
    }
}
final class TokenStore { static let shared = TokenStore(); var userId: String? = "alice" }
final class E2EManager { static let shared = E2EManager(); var deviceId: String? = "phone" }
enum LocalStore { static var positions: [String:Double] = [:]
    static func rememberReadPosition(_ id: String, through: Double) { positions[id] = through }
}
struct EmptyResponse: Decodable {}
enum Failure: Error { case offline }
@MainActor final class API {
    var fail = false
    var bodies: [[String:Any]] = []
    var duringRequest: (() async -> Void)?
    func request<B: Encodable,T: Decodable>(_ method: String, _ path: String, body: B, as type: T.Type) async throws -> T {
        bodies.append(try! JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String:Any])
        if let callback = duringRequest { duringRequest = nil; await callback() }
        if fail { throw Failure.offline }
        return EmptyResponse() as! T
    }
}
@MainActor final class Harness {
    let api = API()
    var maySendReadReceipts = true
'''+methods+'''
}
@main struct Check {
    @MainActor static func main() async throws {
        UserDefaults.file = URL(fileURLWithPath: CommandLine.arguments[1])
        let original = Harness()
        original.queueConversationRead("chat")
        original.api.fail = true
        await original.flushConversationReads()
        let first = original.api.bodies[0]["read_before"] as! String
        precondition(UserDefaults.standard.dictionary(forKey: original.readQueueKey)?["chat"] != nil)
        // A new engine has only the on-disk queue. It must retry the same boundary.
        let restarted = Harness()
        restarted.maySendReadReceipts = false
        await restarted.flushConversationReads()
        precondition(restarted.api.bodies[0]["read_before"] as? String == first)
        precondition(restarted.api.bodies[0]["send_receipts"] as? Bool == false)
        precondition(UserDefaults.standard.dictionary(forKey: restarted.readQueueKey)?.isEmpty == true)
        restarted.queueConversationRead("chat")
        restarted.api.duringRequest = {
            try? await Task.sleep(for: .milliseconds(5))
            restarted.queueConversationRead("chat")
        }
        await restarted.flushConversationReads()
        precondition(UserDefaults.standard.dictionary(forKey: restarted.readQueueKey)?["chat"] != nil,
            "an older response must not remove a newer read intent")
        await restarted.flushConversationReads()
        precondition(UserDefaults.standard.dictionary(forKey: restarted.readQueueKey)?.isEmpty == true)
        restarted.queueConversationRead("private-chat")
        TokenStore.shared.userId = "bob"
        let otherAccount = Harness()
        await otherAccount.flushConversationReads()
        precondition(otherAccount.api.bodies.isEmpty, "pending reads cannot cross accounts")
        precondition(LocalStore.positions["chat"] != nil)
        print("PASS: durable read retry, fixed boundary, privacy-off clearing, supersession and account isolation")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='voiid-read-intents-') as directory:
    temp=Path(directory); source=temp/'Check.swift'; source.write_text(fixture)
    subprocess.run(['swiftc','-module-cache-path',str(temp/'cache'),'-parse-as-library',str(source),'-o',str(temp/'check')],check=True)
    subprocess.run([str(temp/'check'),str(temp/'store.json')],check=True)
