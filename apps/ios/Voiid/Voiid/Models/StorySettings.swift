//
//  StorySettings.swift
//  Voiid
//
//  Per-device Stories preferences. Kept separate from PrivacySettings because that type
//  guarantees "absent key reads as ON" (its three receipts default on), whereas story view
//  receipts are DELIBERATELY OFF by default (§4.1): sending one tells the Voiid server that
//  you opened someone's story, a behavioural fact it otherwise never learns. The
//  privacy-preserving default is that the viewer list starts empty until you opt in.
//
//  Consumer (required, or the toggle would be a lie): StoryEngine reads `sendViewReceipts`
//  before fanning out any receipt AND before reading/showing the local viewer list. When
//  OFF: no receipt is sent, your own viewer list is hidden, and incoming receipts are
//  discarded on decrypt.
//

import SwiftUI
import Combine

@MainActor
final class StorySettings: ObservableObject {
    static let shared = StorySettings()

    private enum Key {
        static let sendViewReceipts = "voiid.stories.sendViewReceipts"
        static let defaultAudience  = "voiid.stories.defaultAudience"   // [user_id] or empty = "My Contacts"
        static let audienceIsCustom = "voiid.stories.audienceIsCustom"
    }

    /// OFF by default. Reciprocal: off means you send no receipts AND see no viewer names.
    @Published var sendViewReceipts: Bool {
        didSet { UserDefaults.standard.set(sendViewReceipts, forKey: Key.sendViewReceipts) }
    }

    private init() {
        // Absent key → false (the privacy-preserving default), so this uses the plain bool
        // read, NOT PrivacySettings' "absent = true" read.
        sendViewReceipts = UserDefaults.standard.bool(forKey: Key.sendViewReceipts)
    }

    // MARK: - Remembered audience (§2.2)

    /// The last-used custom audience, or nil when the last post was "My Contacts" (which
    /// re-expands to include newly-added contacts on the next post).
    var lastCustomAudience: [String]? {
        get {
            guard UserDefaults.standard.bool(forKey: Key.audienceIsCustom) else { return nil }
            return UserDefaults.standard.stringArray(forKey: Key.defaultAudience)
        }
    }

    func rememberAudience(_ userIds: [String], isCustom: Bool) {
        UserDefaults.standard.set(isCustom, forKey: Key.audienceIsCustom)
        UserDefaults.standard.set(isCustom ? userIds : [], forKey: Key.defaultAudience)
    }
}
