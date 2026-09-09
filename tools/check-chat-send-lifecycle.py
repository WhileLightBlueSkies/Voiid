#!/usr/bin/env python3
"""Run actual Swift send/action/storage methods against deterministic transport + slow disk.
No account, real network request, or substitute implementation of the methods under test.
"""
from pathlib import Path
import subprocess, tempfile
root = Path(__file__).resolve().parents[1]
source = (root/'apps/ios/Voiid/Voiid/Networking/ChatEngine.swift').read_text()

def extract(text, marker):
    start = text.index(marker)
    opening = text.index('{', start)
    depth, end = 1, opening + 1
    while depth:
        depth += (text[end] == '{') - (text[end] == '}')
        end += 1
    return text[start:end]

models = '\n'.join(extract(source, 'struct '+name+':') for name in ['MediaRef', 'DecryptedMessage'])
methods = '\n'.join(extract(source, marker) for marker in [
    'func sendMedia(', 'func sendReaction(', 'func sendDeleteForEveryone(', 'func deleteForMe(',
    'func applyReaction(', 'func applyDeleteForEveryone(', 'func append(', 'func persist()',
    'func persistBatch()', 'func persistSoon()', 'func reloadSharedState(', 'func reloadConversationShard(',
    'func enqueueText(', 'func markSent(', 'func storedMessage(', 'func messages(', 'struct SendBundleBody:', 'struct SendResponse:',
])
methods = methods.replace('func persist() async', '@discardableResult func persist() async')
wire = (root/'apps/ios/Voiid/Voiid/Networking/MessageActionWire.swift').read_text()
lock = extract((root/'apps/ios/Voiid/Voiid/Networking/SharedStore.swift').read_text(), 'enum CrossProcessLock')
preamble = r'''
import Foundation
import Darwin
let directory = URL(fileURLWithPath: CommandLine.arguments[1])
enum AppGroup { static var lockURL: URL? { directory.appendingPathComponent("lock") } }
final class TokenStore { static let shared = TokenStore(); var userId: String? = "me" }
final class E2EManager { static let shared = E2EManager(); let deviceId = "sender-device" }
struct DeviceCiphertext: Codable { let recipient_device_id: String; let ciphertext: String }
struct MediaEnvelope: Encodable { let media: MediaRef; let caption: String }
struct FakeMediaKey { let key = "key"; let nonce = "nonce"; let ciphertextSha256 = "sha" }
func encryptMedia(plaintext: Data) throws -> (ciphertext: Data, mediaKey: FakeMediaKey) { (plaintext, FakeMediaKey()) }
@MainActor final class MediaCache { static let shared = MediaCache(); func setData(_ data: Data, _ key: String) {} }
final class MediaService { static let shared = MediaService(); func upload(body: Data, mime: String) async throws -> String { "media/fixture" } }
enum APIError: Error { case http(status: Int, message: String) }
@MainActor final class Transport {
    var fail = false
    var requests: [[String: Any]] = []
    var accepted: (() -> Void)?
    func request<T: Decodable, B: Encodable>(_ method: String, _ path: String, body: B) async throws -> T {
        if fail { throw APIError.http(status: 503, message: "Offline fixture") }
        requests.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any])
        accepted?()
        return try JSONDecoder().decode(T.self, from: Data("{\"message_id\":\"sent-\(requests.count)\"}".utf8))
    }
}
actor ChatShardStore {
    static let shared = ChatShardStore()
    // Synchronous inside the serial writer, matching production IO. Deliberately slow
    // so a fire-and-forget write cannot accidentally win the race against a reload.
    func write(_ batch: [String: [DecryptedMessage]]) -> Set<String> {
        Thread.sleep(forTimeInterval: 0.04)
        for (key, value) in batch { try! JSONEncoder().encode(value).write(to: directory.appendingPathComponent(key+".json"), options: .atomic) }
        return Set(batch.keys)
    }
}
@MainActor final class ChatEngine {
    let api = Transport()
    var store: [String: [DecryptedMessage]] = [:]
    var storeLoaded = true
    var dirtyConversations: Set<String> = []
    var persistenceTask: Task<Bool, Never>?
    var emptyFanout = false
    var onMessageStateChanged: ((String) -> Void)?
    func ensureLoaded() { storeLoaded = true }
    func loadStore() {}
    func reloadCryptoState() {}
    func markDirty(_ id: String) { dirtyConversations.insert(id) }
    func shardURL(_ id: String) -> URL { directory.appendingPathComponent(id+".json") }
    func parseDate(_ text: String) -> Date { Date() }
    func encryptFanout(_ data: Data, peerUserId: String) async throws -> [DeviceCiphertext] {
        emptyFanout ? [] : [DeviceCiphertext(recipient_device_id: "peer-device", ciphertext: data.base64EncodedString())]
    }
'''
checks = r'''
}
@main struct Check {
    @MainActor static func main() async throws {
        let race = ChatEngine()
        race.store["race"] = []
        race.markDirty("race"); await race.persist()
        let queued = race.enqueueText("Queued while disk is busy", conversationId: "race")
        try await Task.sleep(nanoseconds: 5_000_000)
        await race.reloadSharedState("race")
        precondition(race.storedMessage(id: queued.id, conversationId: "race") != nil, "Reload erased an in-flight queued text")
        await race.persist()
        var acknowledgedImmediately = false
        race.onMessageStateChanged = { cid in
            acknowledgedImmediately = race.storedMessage(id: queued.id, conversationId: cid)?.pending == false
        }
        race.markSent(localId: queued.id, conversationId: "race", serverId: "accepted")
        precondition(acknowledgedImmediately, "The UI must be notified at acceptance without waiting for the queue")
        try await Task.sleep(nanoseconds: 5_000_000)
        await race.reloadSharedState("race")
        precondition(race.storedMessage(id: queued.id, conversationId: "race")?.pending == false, "Reload restored the sending clock after acceptance")
        print("PASS queued text and accepted status survive reload during an in-flight write")
        let engine = ChatEngine()
        let original = DecryptedMessage(id: "local", senderId: "me", text: "Original", createdAt: Date(), isMine: true, serverId: "server")
        engine.store["chat"] = [original]
        engine.markDirty("chat"); await engine.persist()
        var sync: Task<Void, Never>?
        engine.api.accepted = {
            sync = Task { @MainActor in
                await CrossProcessLock.withLock { await engine.reloadSharedState("chat") }
            }
        }
        let sent = try await engine.sendMedia(Data([1,2,3]), mime: "audio/m4a", conversationId: "chat", peerUserId: "peer")
        await sync?.value
        precondition(engine.messages(conversationId: "chat").contains { $0.id == sent.id && $0.media != nil }, "Voice echo was lost to immediate WS sync")
        precondition(engine.api.requests.last?["content_type"] as? String == "media")
        print("PASS voice echo survives immediate post-acceptance sync with a slow shard writer")
        try await engine.sendReaction(targetServerId: "server", emoji: "❤️", conversationId: "chat", peerUserId: "peer")
        await sync?.value
        precondition(engine.storedMessage(id: "server", conversationId: "chat")?.reactions?["me"] == "❤️")
        engine.applyReaction(target: "server", from: "peer", emoji: "❤️", in: "chat", persist: false)
        await engine.persist()
        try await engine.sendReaction(targetServerId: "server", emoji: nil, conversationId: "chat", peerUserId: "peer")
        await sync?.value
        precondition(engine.storedMessage(id: "server", conversationId: "chat")?.reactions == ["peer":"❤️"])
        print("PASS reaction survives reload and removing mine preserves the peer's matching emoji")
        engine.api.fail = true
        do { try await engine.sendReaction(targetServerId: "server", emoji: "🔥", conversationId: "chat", peerUserId: "peer"); preconditionFailure("Expected failure") } catch {}
        precondition(engine.storedMessage(id: "server", conversationId: "chat")?.reactions?["me"] == nil)
        engine.api.fail = false
        let incoming = DecryptedMessage(id: "incoming", senderId: "peer", text: "Peer message", createdAt: Date(), isMine: false)
        engine.append(incoming, to: "chat", persist: false); await engine.persist()
        let beforeUnauthorized = engine.api.requests.count
        do { try await engine.sendDeleteForEveryone(targetServerId: "incoming", conversationId: "chat", peerUserId: "peer"); preconditionFailure("Must reject deleting a peer's message") } catch {}
        precondition(engine.api.requests.count == beforeUnauthorized)
        try await engine.sendDeleteForEveryone(targetServerId: "server", conversationId: "chat", peerUserId: "peer")
        await sync?.value
        precondition(engine.storedMessage(id: "server", conversationId: "chat")?.deletedForEveryone == true)
        engine.applyReaction(target: "server", from: "peer", emoji: "🔥", in: "chat", persist: false)
        precondition(engine.storedMessage(id: "server", conversationId: "chat")?.reactions == nil)
        print("PASS delete-for-everyone persists, rejects peer-message deletion and ignores late reactions")
        let beforeLocalDelete = engine.api.requests.count
        try await engine.deleteForMe(messageIds: ["server", "incoming", sent.id], in: "chat")
        await engine.reloadSharedState("chat")
        precondition(engine.messages(conversationId: "chat").isEmpty)
        precondition(engine.store["chat"]?.count == 3, "Keep ids for decrypt-once dedup")
        precondition(engine.api.requests.count == beforeLocalDelete, "Delete for me must never be transmitted")
        let fresh = ChatEngine(); fresh.storeLoaded = false; await fresh.reloadSharedState("chat")
        precondition(fresh.messages(conversationId: "chat").isEmpty)
        precondition(fresh.storedMessage(id: "server", conversationId: "chat")?.deletedForMe == true)
        print("PASS bulk local deletion survives a fresh engine, retains dedup ids and sends no network action")
        engine.emptyFanout = true
        engine.store["self"] = [original]; engine.markDirty("self"); await engine.persist()
        try await engine.sendReaction(targetServerId: "server", emoji: "👍", conversationId: "self", peerUserId: "me")
        precondition(engine.storedMessage(id: "server", conversationId: "self")?.reactions?["me"] == "👍")
        print("PASS Note to Self applies local reactions without an empty server bundle")
    }
}
'''
with tempfile.TemporaryDirectory(prefix='voiid-send-lifecycle-') as directory:
    folder = Path(directory)
    swift = folder/'check.swift'
    swift.write_text(preamble.replace('@MainActor final class ChatEngine {', models+'\n'+wire+'\n'+lock+'\n@MainActor final class ChatEngine {') + methods + checks)
    subprocess.run(['xcrun','swiftc','-parse-as-library','-module-cache-path',str(folder/'cache'),str(swift),'-o',str(folder/'check')],check=True)
    subprocess.run([str(folder/'check'),str(folder)],check=True)
