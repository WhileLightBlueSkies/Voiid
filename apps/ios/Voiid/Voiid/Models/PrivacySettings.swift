//
//  PrivacySettings.swift
//  Voiid
//
//  The persisted state behind Settings → Privacy. Three booleans, and every one of
//  them has a consumer in the app that genuinely reads it:
//
//      sendReadReceipts      → ChatStore.syncMessages (Models/Stores.swift) guards both
//                              `ChatEngine.markRead(conversationId:)` call sites, which are
//                              the only places this device POSTs `receipts/mark` with
//                              status "read".
//      sendTypingIndicators  → ChatDetailView guards both `WebSocketClient.sendTyping`
//                              call sites (the draft-field onChange and the stop frame
//                              sent on disappear), which are the only places this device
//                              emits a `typing` frame.
//      showOnlineStatus      → ChatDetailView.presenceText, the online / last-seen line
//                              under the chat title. Display-only, on this device.
//
//  If you add a key here, add its consumer in the same change. A toggle whose value
//  nothing reads is a lie the user cannot see, and it is exactly the failure this type
//  exists to prevent.
//
//  Why raw UserDefaults and not @AppStorage
//  ----------------------------------------
//  There are zero occurrences of `@AppStorage` in this app; `BackupManager`, `TokenStore`
//  and `VoIPPushManager` all use explicit `UserDefaults.standard` keys. Introducing a
//  second persistence vocabulary for three booleans is not worth it. This is modelled on
//  `BackupManager`'s pattern: a `@MainActor` `ObservableObject` singleton whose published
//  properties write through to a private, namespaced key on `didSet`.
//
//  Deliberately NOT stored here
//  ---------------------------
//  Nothing about blocking, last-seen visibility, profile-photo visibility, disappearing
//  messages, screenshot blocking, app lock or "who can add me to groups". None of those
//  has a schema, a route or a line of client code in this project, so none of them has a
//  setting.
//

import SwiftUI
import Combine

/// User privacy preferences that are scoped to **this device**.
///
/// None of these are server-side settings — Voiid has no privacy schema on the backend.
/// They change what this iPhone sends and what it draws, which is what the footers on
/// `PrivacySettingsView` say in plain language.
@MainActor
final class PrivacySettings: ObservableObject {

    static let shared = PrivacySettings()

    // MARK: Keys

    private enum Key {
        static let sendReadReceipts     = "voiid.privacy.sendReadReceipts"
        static let sendTypingIndicators = "voiid.privacy.sendTypingIndicators"
        static let showOnlineStatus     = "voiid.privacy.showOnlineStatus"
        static let lastSeenVisibility   = "voiid.privacy.lastSeenVisibility"
        static let photoVisibility      = "voiid.privacy.photoVisibility"
        static let aboutVisibility      = "voiid.privacy.aboutVisibility"
    }

    /// WhatsApp-style "who can see" scope. The rawValue is exactly what the backend stores
    /// and enforces (users.*_privacy) — GET /users/:id and /users/status/:id apply it.
    enum Visibility: String, CaseIterable, Identifiable {
        case everyone, contacts, nobody
        var id: String { rawValue }
        var label: String {
            switch self {
            case .everyone: return "Everyone"
            case .contacts: return "My Contacts"
            case .nobody:   return "Nobody"
            }
        }
    }

    // MARK: Stored preferences

    /// When `false`, this device stops POSTing `receipts/mark` with status `"read"`, so
    /// senders never get the blue tick. Delivery receipts are unaffected: they are a
    /// transport signal the sender needs to know the message arrived at all, and Voiid
    /// has no setting for them.
    @Published var sendReadReceipts: Bool {
        didSet { Self.write(sendReadReceipts, Key.sendReadReceipts) }
    }

    /// When `false`, this device stops emitting `typing` frames over the WebSocket.
    @Published var sendTypingIndicators: Bool {
        didSet { Self.write(sendTypingIndicators, Key.sendTypingIndicators) }
    }

    /// When `false`, the online / last-seen line under a chat title is hidden. Purely a
    /// display choice on this device — it does not change what anyone else can see about
    /// you, because the presence API has no per-user visibility flag.
    @Published var showOnlineStatus: Bool {
        didSet { Self.write(showOnlineStatus, Key.showOnlineStatus) }
    }

    /// "Who can see my last seen & online". Enforced by the backend on /users/status/:id.
    @Published var lastSeenVisibility: Visibility {
        didSet { Self.writeString(lastSeenVisibility.rawValue, Key.lastSeenVisibility); syncToServer() }
    }
    /// "Who can see my profile photo". Enforced by GET /users/:id (photo_url nulled otherwise).
    @Published var photoVisibility: Visibility {
        didSet { Self.writeString(photoVisibility.rawValue, Key.photoVisibility); syncToServer() }
    }
    /// "Who can see my about (bio)". Enforced by GET /users/:id (bio nulled otherwise).
    @Published var aboutVisibility: Visibility {
        didSet { Self.writeString(aboutVisibility.rawValue, Key.aboutVisibility); syncToServer() }
    }

    private init() {
        sendReadReceipts     = Self.read(Key.sendReadReceipts)
        sendTypingIndicators = Self.read(Key.sendTypingIndicators)
        showOnlineStatus     = Self.read(Key.showOnlineStatus)
        lastSeenVisibility   = Self.readVisibility(Key.lastSeenVisibility)
        photoVisibility      = Self.readVisibility(Key.photoVisibility)
        aboutVisibility      = Self.readVisibility(Key.aboutVisibility)
        didLoad = true
    }

    /// Push the three visibility scopes to the server so it can ENFORCE them for other
    /// viewers. Local persistence already happened in the didSet; this is best-effort.
    private var didLoad = false
    private func syncToServer() {
        guard didLoad else { return }   // don't fire during init assignment
        let last = lastSeenVisibility.rawValue, photo = photoVisibility.rawValue, about = aboutVisibility.rawValue
        Task { try? await ProfileService.shared.updateProfile(
            lastSeenPrivacy: last, photoPrivacy: photo, aboutPrivacy: about) }
    }

    // MARK: Storage

    /// All three preferences default to **on**, which means an absent key must read as
    /// `true` — `UserDefaults.bool(forKey:)` alone would return `false` and silently
    /// switch every existing user's receipts off on upgrade.
    private static func read(_ key: String) -> Bool {
        guard UserDefaults.standard.object(forKey: key) != nil else { return true }
        return UserDefaults.standard.bool(forKey: key)
    }

    private static func write(_ value: Bool, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }

    /// Visibility defaults to `.everyone` (matches the server default) when unset.
    private static func readVisibility(_ key: String) -> Visibility {
        guard let raw = UserDefaults.standard.string(forKey: key),
              let v = Visibility(rawValue: raw) else { return .everyone }
        return v
    }
    private static func writeString(_ value: String, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
