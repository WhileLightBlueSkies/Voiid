import Foundation
import Combine

/// Device-only messaging preferences plus server-confirmed profile/presence audiences.
@MainActor
final class PrivacySettings: ObservableObject {
    static let shared = PrivacySettings(
        accountID: { TokenStore.shared.userId },
        fetch: { try await ProfileService.shared.privacySettings(userID: $0) },
        save: { field, value in try await ProfileService.shared.updatePrivacy(field: field, value: value) }
    )

    enum Visibility: String, CaseIterable, Identifiable, Codable {
        case everyone, contacts, nobody
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everyone: "Everyone"
            case .contacts: "My Contacts"
            case .nobody: "Nobody"
            }
        }
    }

    enum Field: String {
        case lastSeen = "last_seen_privacy"
        case photo = "photo_privacy"
        case about = "about_privacy"
    }

    struct Snapshot: Decodable, Equatable {
        var lastSeen: Visibility
        var photo: Visibility
        var about: Visibility
        enum CodingKeys: String, CodingKey {
            case lastSeen = "last_seen_privacy", photo = "photo_privacy", about = "about_privacy"
        }
        subscript(field: Field) -> Visibility {
            get {
                switch field {
                case .lastSeen: lastSeen
                case .photo: photo
                case .about: about
                }
            }
            set {
                switch field {
                case .lastSeen: lastSeen = newValue
                case .photo: photo = newValue
                case .about: about = newValue
                }
            }
        }
    }

    @Published var sendReadReceipts: Bool {
        didSet {
            // Preserve private reads before enabling again, including reads made by older
            // app versions that only persisted the local unread position.
            if !oldValue || !sendReadReceipts { preservePrivateReads() }
            defaults.set(sendReadReceipts, forKey: "voiid.privacy.sendReadReceipts")
        }
    }
    @Published var sendTypingIndicators: Bool {
        didSet { defaults.set(sendTypingIndicators, forKey: "voiid.privacy.sendTypingIndicators") }
    }
    /// Only controls whether this device displays other people's activity.
    @Published var showOnlineStatus: Bool {
        didSet { defaults.set(showOnlineStatus, forKey: "voiid.privacy.showOnlineStatus") }
    }

    @Published private(set) var snapshot: Snapshot?
    @Published private(set) var isLoading = false
    @Published private(set) var isSaving = false
    @Published private(set) var syncError: String?
    private var loadedAccountID: String?
    private var generation = UUID()
    private let defaults: UserDefaults
    private let accountID: () -> String?
    private let fetch: (String) async throws -> Snapshot
    private let save: (Field, Visibility) async throws -> Void

    var hasLoadedVisibility: Bool { snapshot != nil && loadedAccountID == accountID() }
    var canEditVisibility: Bool { hasLoadedVisibility && !isLoading && !isSaving && syncError == nil }

    // Dependencies are injectable so failed saves and account switches can be checked
    // without live credentials or a running app.
    init(defaults: UserDefaults = .standard, accountID: @escaping () -> String?,
         fetch: @escaping (String) async throws -> Snapshot,
         save: @escaping (Field, Visibility) async throws -> Void) {
        self.defaults = defaults
        self.accountID = accountID
        self.fetch = fetch
        self.save = save
        sendReadReceipts = defaults.object(forKey: "voiid.privacy.sendReadReceipts") as? Bool ?? true
        sendTypingIndicators = defaults.object(forKey: "voiid.privacy.sendTypingIndicators") as? Bool ?? true
        showOnlineStatus = defaults.object(forKey: "voiid.privacy.showOnlineStatus") as? Bool ?? true
    }

    private func preservePrivateReads() {
        guard let account = accountID() else { return }
        let queueKey = "voiid.read-intents.\(account)"
        var queue = defaults.dictionary(forKey: queueKey) ?? [:]
        for (id, raw) in queue {
            guard var intent = raw as? [String: Any], let through = intent["through"] as? Double else { continue }
            rememberPrivateRead(id, through: through)
            intent["disclose"] = false
            queue[id] = intent
        }
        defaults.set(queue, forKey: queueKey)
        if !oldReadReceiptsEnabled {
            for (id, raw) in defaults.dictionary(forKey: "voiid.read-position.\(account)") ?? [:] {
                if let through = raw as? Double { rememberPrivateRead(id, through: through) }
            }
        }
    }

    private var oldReadReceiptsEnabled: Bool {
        defaults.object(forKey: "voiid.privacy.sendReadReceipts") as? Bool ?? true
    }

    func rememberPrivateRead(_ id: String, through: Double) {
        guard let account = accountID() else { return }
        let key = "voiid.private-read-position.\(account)"
        var positions = defaults.dictionary(forKey: key) ?? [:]
        positions[id] = max(positions[id] as? Double ?? 0, through)
        defaults.set(positions, forKey: key)
    }

    func privateReadPosition(_ id: String) -> Double? {
        guard let account = accountID() else { return nil }
        return defaults.dictionary(forKey: "voiid.private-read-position.\(account)")?[id] as? Double
    }

    /// No device-global audience cache: a newly signed-in account must load its own values.
    func resetVisibility() {
        generation = UUID()
        loadedAccountID = nil
        snapshot = nil
        isLoading = false
        isSaving = false
        syncError = nil
    }

    func refreshVisibility() async {
        guard let userID = accountID() else { resetVisibility(); return }
        if loadedAccountID != userID {
            resetVisibility()
            loadedAccountID = userID
        }
        guard !isLoading && !isSaving else { return }
        let requestGeneration = generation
        isLoading = true
        syncError = nil
        defer { if generation == requestGeneration { isLoading = false } }
        do {
            let values = try await fetch(userID)
            guard generation == requestGeneration, accountID() == userID else { return }
            snapshot = values
        } catch {
            guard generation == requestGeneration, accountID() == userID else { return }
            syncError = "Couldn’t load your saved privacy settings. Try again before making changes."
        }
    }

    /// Save only the changed field; stale photo/about values cannot overwrite another
    /// device's edits. Keep showing the last confirmed selection until the save succeeds.
    func setVisibility(_ value: Visibility, for field: Field) async {
        guard canEditVisibility, let userID = accountID(), snapshot?[field] != value else { return }
        let requestGeneration = generation
        isSaving = true
        syncError = nil
        defer { if generation == requestGeneration { isSaving = false } }
        do {
            try await save(field, value)
            guard generation == requestGeneration, accountID() == userID else { return }
            snapshot?[field] = value
        } catch {
            guard generation == requestGeneration, accountID() == userID else { return }
            // A response can be lost after the server commits. Refresh before another edit
            // rather than claiming the previous setting is definitely still in force.
            syncError = "Couldn’t confirm this privacy change. Refresh to check what’s saved, then try again."
        }
    }
}

/// Typing reflects recent edits, never merely the existence of an unsent draft.
struct TypingActivity {
    private(set) var active = false
    private var lastSent: TimeInterval = -.infinity
    private var expiresAt: TimeInterval = -.infinity

    mutating func edited(at now: TimeInterval, allowed: Bool, hasText: Bool) -> Bool? {
        guard allowed && hasText else { return stop() }
        expiresAt = now + 3
        guard !active || now - lastSent >= 2 else { return nil }
        active = true
        lastSent = now
        return true
    }

    mutating func expire(at now: TimeInterval) -> Bool? {
        guard now >= expiresAt else { return nil }
        return stop()
    }

    mutating func stop() -> Bool? {
        guard active else { return nil }
        active = false
        return false
    }
}
