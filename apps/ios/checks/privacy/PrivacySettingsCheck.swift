import Foundation

// Only the transport dependencies are stubbed; PrivacySettings.swift is compiled unchanged.
@MainActor final class TokenStore {
    static let shared = TokenStore()
    var userId: String?
}
enum AvailabilityStatus: String { case available, busy, away, dnd }
@MainActor final class APIClient {
    static var response = Data()
    static var bodies: [[String: Any]] = []
    static var paths: [String] = []
    func request<T: Decodable>(_ method: String, _ path: String) async throws -> T {
        Self.paths.append(path)
        return try JSONDecoder().decode(T.self, from: Self.response)
    }
    func request<T: Decodable, Body: Encodable>(_ method: String, _ path: String, body: Body) async throws -> T {
        Self.bodies.append(try JSONSerialization.jsonObject(with: JSONEncoder().encode(body)) as! [String: Any])
        return try await request(method, path)
    }
}
enum CheckError: Error { case offline }

@main struct PrivacySettingsCheck {
    @MainActor static func main() async {
        var count = 0
        func check(_ condition: @autoclosure () -> Bool, _ description: String) {
            precondition(condition(), description)
            count += 1
        }
        let suite = "voiid.privacy.check.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set("everyone", forKey: "voiid.privacy.lastSeenVisibility")
        var account: String? = "alice"
        var server = PrivacySettings.Snapshot(lastSeen: .nobody, photo: .contacts, about: .everyone)
        var failLoad = false
        var failSave = false
        var requests: [(PrivacySettings.Field, PrivacySettings.Visibility)] = []
        let store = PrivacySettings(defaults: defaults, accountID: { account }, fetch: { _ in
            if failLoad { throw CheckError.offline }
            return server
        }, save: { field, value in
            requests.append((field, value))
            if failSave { throw CheckError.offline }
            server[field] = value
        })
        check(!store.canEditVisibility, "No edits before server settings load")
        await store.refreshVisibility()
        check(store.snapshot == server && store.canEditVisibility, "Uses server audience, not old global defaults")
        await store.setVisibility(.contacts, for: .lastSeen)
        check(requests.count == 1 && requests[0].0 == .lastSeen, "Writes only edited field")
        check(store.snapshot?.lastSeen == .contacts && store.snapshot?.photo == .contacts, "Confirmed save updates selection")
        await store.setVisibility(.contacts, for: .lastSeen)
        check(requests.count == 1, "No redundant write for unchanged selection")
        failSave = true
        await store.setVisibility(.nobody, for: .photo)
        check(store.snapshot?.photo == .contacts, "Failed save does not falsely confirm new audience")
        check(store.syncError != nil && !store.canEditVisibility && !store.isSaving, "Save error visible and edits paused until reconciliation")
        // Server may have committed a request whose response was lost.
        server.photo = .nobody
        await store.refreshVisibility()
        check(store.snapshot?.photo == .nobody && store.canEditVisibility, "Refresh reconciles ambiguous save")
        failLoad = true
        await store.refreshVisibility()
        check(store.syncError != nil && !store.canEditVisibility && !store.isLoading, "Failed refresh cannot silently use stale settings")
        failLoad = false
        server.about = .contacts
        await store.refreshVisibility()
        check(store.snapshot?.about == .contacts && store.syncError == nil, "Reload picks up another device's changes")
        account = nil
        await store.refreshVisibility()
        check(store.snapshot == nil && !store.hasLoadedVisibility, "Sign-out clears account preferences")
        check(store.sendTypingIndicators && store.sendReadReceipts && store.showOnlineStatus, "Device-only defaults retained")
        store.showOnlineStatus = false
        check(defaults.bool(forKey: "voiid.privacy.showOnlineStatus") == false, "Local activity display setting still persists")

        var currentUser: String? = "alice"
        var pendingSave: CheckedContinuation<Void, Error>?
        var saves = 0
        let alice = PrivacySettings.Snapshot(lastSeen: .everyone, photo: .contacts, about: .nobody)
        let bob = PrivacySettings.Snapshot(lastSeen: .nobody, photo: .nobody, about: .contacts)
        let delayed = PrivacySettings(defaults: defaults, accountID: { currentUser }, fetch: { $0 == "alice" ? alice : bob }, save: { _, _ in
            saves += 1
            try await withCheckedThrowingContinuation { pendingSave = $0 }
        })
        await delayed.refreshVisibility()
        let firstSave = Task { await delayed.setVisibility(.nobody, for: .lastSeen) }
        while pendingSave == nil { await Task.yield() }
        check(delayed.isSaving && delayed.snapshot == alice, "Keeps confirmed values while saving")
        await delayed.setVisibility(.everyone, for: .photo)
        check(saves == 1, "Overlapping selections cannot race")
        currentUser = "bob"
        await delayed.refreshVisibility()
        check(delayed.snapshot == bob && delayed.canEditVisibility, "Account switch loads independent settings")
        pendingSave!.resume()
        await firstSave.value
        check(delayed.snapshot == bob && !delayed.isSaving, "Late save cannot alter another account")

        var pendingLoad: CheckedContinuation<PrivacySettings.Snapshot, Error>?
        currentUser = "alice"
        let loading = PrivacySettings(defaults: defaults, accountID: { currentUser }, fetch: { user in
            if user == "bob" { return bob }
            return try await withCheckedThrowingContinuation { pendingLoad = $0 }
        }, save: { _, _ in })
        let firstLoad = Task { await loading.refreshVisibility() }
        while pendingLoad == nil { await Task.yield() }
        currentUser = "bob"
        await loading.refreshVisibility()
        pendingLoad!.resume(returning: alice)
        await firstLoad.value
        check(loading.snapshot == bob, "Late fetch cannot overwrite new account")

        let invalid = Data("{\"last_seen_privacy\":\"bogus\",\"photo_privacy\":\"everyone\",\"about_privacy\":\"everyone\"}".utf8)
        check((try? JSONDecoder().decode(PrivacySettings.Snapshot.self, from: invalid)) == nil, "Unknown audiences fail decoding instead of defaulting to everyone")
        check((try? JSONDecoder().decode(PrivacySettings.Snapshot.self, from: Data("{}".utf8))) == nil, "Missing server fields cannot imply permissive defaults")
        do {
            APIClient.response = Data("{\"user\":{\"last_seen_privacy\":\"nobody\",\"photo_privacy\":\"contacts\",\"about_privacy\":\"everyone\"}}".utf8)
            let fetched = try await ProfileService.shared.privacySettings(userID: "alice")
            check(fetched.lastSeen == .nobody && APIClient.paths.last == "users/alice", "Service reads owner privacy from real profile envelope")
            APIClient.response = Data("{\"user\":{\"id\":\"alice\"}}".utf8)
            try await ProfileService.shared.updatePrivacy(field: .lastSeen, value: .nobody)
            check(APIClient.bodies.last?.count == 1 && APIClient.bodies.last?["last_seen_privacy"] as? String == "nobody", "Service sends only edited privacy field")
            _ = try await ProfileService.shared.updateStatus(nil)
            check(APIClient.bodies.last?["status_text"] is NSNull, "Clearing status explicitly sends JSON null")
            _ = try await ProfileService.shared.updateStatus(.busy)
            check(APIClient.bodies.last?["status_text"] as? String == "busy", "Setting status still sends selected value")
        } catch { preconditionFailure("Service serialization failed: \(error)") }
        account = "alice"
        store.rememberPrivateRead("chat", through: 100)
        store.rememberPrivateRead("chat", through: 90)
        check(store.privateReadPosition("chat") == 100, "Private watermark never moves backwards")
        defaults.set(["chat": ["through": 120.0, "disclose": true]], forKey: "voiid.read-intents.alice")
        store.sendReadReceipts = false
        check(store.privateReadPosition("chat") == 120, "Disabling suppresses pending retries")
        let intent = defaults.dictionary(forKey: "voiid.read-intents.alice")?["chat"] as? [String: Any]
        check(intent?["disclose"] as? Bool == false, "Queued reads cannot regain disclosure after toggle")
        defaults.set(["chat": 150.0], forKey: "voiid.read-position.alice")
        store.sendReadReceipts = true
        check(store.privateReadPosition("chat") == 150, "Enabling preserves legacy private read positions")
        let restarted = PrivacySettings(defaults: defaults, accountID: { account }, fetch: { _ in server }, save: { _, _ in })
        check(restarted.privateReadPosition("chat") == 150, "Private reads survive process restart")
        account = "bob"
        check(restarted.privateReadPosition("chat") == nil, "Private watermark is account scoped")
        restarted.rememberPrivateRead("chat", through: 200)
        account = "alice"
        check(restarted.privateReadPosition("chat") == 150, "Other account cannot overwrite watermark")

        var typing = TypingActivity()
        check(typing.edited(at: 0, allowed: true, hasText: true) == true, "First edit starts typing")
        check(typing.edited(at: 1, allowed: true, hasText: true) == nil, "Keystrokes are throttled")
        check(typing.expire(at: 3) == nil, "Old timeout cannot cancel more recent activity")
        check(typing.edited(at: 3, allowed: true, hasText: true) == true, "Continued edits refresh typing")
        check(typing.expire(at: 6) == false && !typing.active, "Untouched draft expires after three seconds")
        check(typing.expire(at: 9) == nil, "Stopped typing is idempotent")
        check(typing.edited(at: 10, allowed: false, hasText: true) == nil, "Privacy-off never starts typing")
        check(typing.edited(at: 11, allowed: true, hasText: true) == true, "New editing restarts typing")
        check(typing.edited(at: 12, allowed: false, hasText: true) == false, "Disabling stops active typing")
        _ = typing.edited(at: 13, allowed: true, hasText: true)
        check(typing.edited(at: 14, allowed: true, hasText: false) == false, "Clearing or sending stops typing")
        _ = typing.edited(at: 15, allowed: true, hasText: true)
        check(typing.stop() == false && typing.stop() == nil, "Leaving or backgrounding stops exactly once")
        print("Passed \(count) privacy load/save, failure, serialization and account-isolation checks.")
    }
}
