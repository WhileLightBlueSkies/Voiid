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

    private init() {
        sendReadReceipts     = Self.read(Key.sendReadReceipts)
        sendTypingIndicators = Self.read(Key.sendTypingIndicators)
        showOnlineStatus     = Self.read(Key.showOnlineStatus)
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
}
