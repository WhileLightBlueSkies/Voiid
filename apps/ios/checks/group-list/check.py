"""Run the production iOS list reconciliation against isolated service/storage fixtures."""
from pathlib import Path
import subprocess, tempfile
source = (Path(__file__).resolve().parents[2] / 'Voiid/Voiid/Models/Stores.swift').read_text()
start = source.index('    private var standaloneGroupIDs:')
end = source.index('    /// One-time backfill', start)
logic = source[start:end]
fixture = r'''
import Foundation
struct VConversation { let id: String; let type: Kind; var title = ""; var peerUserId: String? = nil; var photoURL: String? = nil }
enum Kind { case direct, group, `self` }
struct APIError: Error { var errorDescription: String? = "offline" }
@MainActor final class TokenStore { static let shared = TokenStore(); var userId: String? = UUID().uuidString }
@MainActor enum LocalStore {
 static var rows: [VConversation] = []
 static func importLegacyMessageBlobIfNeeded() {}
 static func conversations() -> [VConversation] { rows }
 static func saveConversations(_ incoming: [VConversation]) {
   for c in incoming { rows.removeAll { $0.id == c.id }; rows.append(c) }
 }
}
@MainActor final class UserDirectory {
 static let shared = UserDirectory()
 func upsertManyFromServer(_ rows: [(userId: String, fullName: String, username: String?, photoURL: String?)]) {}
}
@MainActor final class ChatService {
 static let shared = ChatService()
 var rows: [VConversation] = []
 var duringFetch: (() -> Void)?
 var holdFetch = false
 var fetchStarted = false
 func createSelfChat() async throws {}
 func fetchConversations() async throws -> [VConversation] { fetchStarted = true; while holdFetch { await Task.yield() }; duringFetch?(); return rows }
}
@MainActor final class CommunityService {
 struct Card { let id: String; var isMember = true; var owner_id: String? = nil }
 struct Channel { let conversation_id: String }
 static let shared = CommunityService()
 var cards: [Card] = []; var channelIDs: [String] = []; var fails = false
 func mine() async throws -> [Card] { cards }
 func channels(communityId: String) async throws -> [Channel] {
   if fails { throw APIError() }
   precondition(communityId != "pending", "Pending applicants cannot list channels")
   return channelIDs.map { Channel(conversation_id: $0) }
 }
}
@MainActor final class ChatStore {
 var directConversations: [VConversation] = []; var groupConversations: [VConversation] = []
 var loadError: String?; var didLoadConversations = false
 func startRealtime() {}; func backfillPreviewsIfNeeded() {}
__LOGIC__
 var internalChannelIDs: Set<String> { Set(communityConversations.map(\.id)) }
 func created(_ id: String) { standaloneGroupIDs.insert(id); LocalStore.rows.append(VConversation(id: id, type: .group)) }
}
@main struct Check {
 @MainActor static func main() async {
   let account = TokenStore.shared.userId!
   defer { for key in UserDefaults.standard.dictionaryRepresentation().keys where key.hasPrefix("voiid.standalone-groups.v1.") && key.contains(account) { UserDefaults.standard.removeObject(forKey: key) } }
   let channels = (0..<10).map { VConversation(id: "channel-\($0)", type: .group) }
   let old = (0..<4).map { VConversation(id: "deleted-\($0)", type: .group) }
   LocalStore.rows = channels + old
   ChatService.shared.rows = channels
   CommunityService.shared.cards = [.init(id: "community"), .init(id: "pending", isMember: false)]
   CommunityService.shared.channelIDs = channels.map(\.id)
   let store = ChatStore()
   await store.loadConversations()
   precondition(store.groupConversations.isEmpty, "Channels/deleted groups leaked into Groups")
   precondition(store.internalChannelIDs == Set(channels.map(\.id)), "Community messaging lost its internal channels")
   precondition(LocalStore.rows.count == 14, "List reconciliation must preserve transcripts")
   store.created("new")
   CommunityService.shared.fails = true
   await store.loadConversations()
   precondition(store.groupConversations.map(\.id) == ["new"], "Failure erased known group")
   let reopened = ChatStore()
   await reopened.loadConversations()
   precondition(reopened.groupConversations.map(\.id) == ["new"], "Offline cold launch lost classification")
   CommunityService.shared.fails = false
   ChatService.shared.duringFetch = { reopened.created("during-sync") }
   await reopened.loadConversations()
   precondition(reopened.groupConversations.map(\.id) == ["during-sync"], "Older snapshot erased newly created group or retained deleted group")
   ChatService.shared.duringFetch = nil
   ChatService.shared.rows = []
   CommunityService.shared.cards = []
   await reopened.loadConversations()
   precondition(reopened.groupConversations.isEmpty, "Empty snapshot failed to clear Groups")
   // A capped response must not turn missing community channels into standalone groups.
   CommunityService.shared.cards = (0..<200).map { .init(id: "community-\($0)") }
   ChatService.shared.rows = channels
   await reopened.loadConversations()
   precondition(reopened.groupConversations.isEmpty, "Truncated community response leaked channels")
   CommunityService.shared.cards = []
   ChatService.shared.rows = []
   ChatService.shared.fetchStarted = false
   ChatService.shared.holdFetch = true
   let first = Task { await reopened.loadConversations() }
   while !ChatService.shared.fetchStarted { await Task.yield() }
   var secondFinished = false
   let second = Task { await reopened.loadConversations(); secondFinished = true }
   for _ in 0..<20 { await Task.yield() }
   precondition(!secondFinished, "Concurrent caller returned before reconciliation")
   ChatService.shared.holdFetch = false
   await first.value; await second.value
   precondition(secondFinished)
   print("PASS: refresh waiters, truncated responses, channel routing,  community separation, stale groups, pending memberships, failed refresh, offline restart, concurrent creation, empty snapshot")
 }
}
'''
with tempfile.TemporaryDirectory(prefix='voiid-group-list-') as d:
    path = Path(d) / 'Check.swift'
    path.write_text(fixture.replace('__LOGIC__', logic))
    subprocess.run(['xcrun', 'swiftc', '-parse-as-library', str(path), '-o', str(Path(d)/'check')], check=True)
    subprocess.run([str(Path(d)/'check')], check=True)
