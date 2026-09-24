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
/// Who your memories go to. One setting, chosen in Memories privacy (MemoriesPrivacyView) and
/// shown on every new memory — not re-picked per post.
enum MomentAudience: String, CaseIterable, Identifiable {
    /// Phone contacts on Voiid, and everyone you chat with.
    case connections
    /// Only people saved in your phone's contacts.
    case contacts
    /// Only people you have messaged with.
    case chats
    /// Only the people you pick.
    case selected
    /// Nobody: kept on this phone only.
    case nobody

    var id: String { rawValue }

    var title: String {
        switch self {
        case .connections: "All my connections"
        case .contacts: "My contacts"
        case .chats: "People I chat with"
        case .selected: "Only selected people"
        case .nobody: "Nobody"
        }
    }

    var detail: String {
        switch self {
        case .connections: "Your contacts on Voiid and everyone you chat with"
        case .contacts: "People saved in your phone who use Voiid"
        case .chats: "Only people you've messaged with"
        case .selected: "Only the people you choose"
        case .nobody: "Only you. Kept on this phone, never sent."
        }
    }

    var icon: String {
        switch self {
        case .connections: "person.3.fill"
        case .contacts: "person.crop.circle.fill"
        case .chats: "bubble.left.and.bubble.right.fill"
        case .selected: "checklist"
        case .nobody: "lock.fill"
        }
    }

    /// Whether "Hide from" applies on top of this choice.
    var allowsHiding: Bool { self == .connections || self == .contacts || self == .chats }
}

final class StorySettings: ObservableObject {
    static let shared = StorySettings()

    private enum Key {
        static let sendViewReceipts = "voiid.stories.sendViewReceipts"
        static let defaultAudience  = "voiid.stories.defaultAudience"   // [user_id] or empty = "My Contacts"
        static let audienceIsCustom = "voiid.stories.audienceIsCustom"
        static let archiveByDefault = "voiid.stories.archiveByDefault"
        static let audienceMode = "voiid.stories.audienceMode"
        static let selectedPeople = "voiid.stories.selectedPeople"
        static let hiddenFrom = "voiid.stories.hiddenFrom"
    }

    @Published var audienceMode: MomentAudience {
        didSet { UserDefaults.standard.set(audienceMode.rawValue, forKey: Key.audienceMode) }
    }
    /// The people for `.selected`.
    @Published var selectedPeople: Set<String> {
        didSet { UserDefaults.standard.set(Array(selectedPeople), forKey: Key.selectedPeople) }
    }
    /// Left out of `.connections`, `.contacts` and `.chats`.
    @Published var hiddenFrom: Set<String> {
        didSet { UserDefaults.standard.set(Array(hiddenFrom), forKey: Key.hiddenFrom) }
    }

    /// OFF by default. Reciprocal: off means you send no receipts AND see no viewer names.
    @Published var sendViewReceipts: Bool {
        didSet { UserDefaults.standard.set(sendViewReceipts, forKey: Key.sendViewReceipts) }
    }

    /// ON by default. This keeps only YOUR OWN copy of YOUR OWN moment past its expiry,
    /// on this device — it is not a change to who can see it, and a viewer's copy still
    /// expires either way. Defaulting it on is safe for that reason: the only person who
    /// gains access to anything is the author, to their own content. Every post can still
    /// override it from the composer, and anything kept can be deleted from the archive.
    @Published var archiveByDefault: Bool {
        didSet { UserDefaults.standard.set(archiveByDefault, forKey: Key.archiveByDefault) }
    }

    private init() {
        // Absent key → false (the privacy-preserving default), so this uses the plain bool
        // read, NOT PrivacySettings' "absent = true" read.
        sendViewReceipts = UserDefaults.standard.bool(forKey: Key.sendViewReceipts)
        // Absent key → true, so an upgrading user starts keeping their own moments rather
        // than silently losing them. Uses object(forKey:) because plain `bool` reads a
        // missing key as false, which would be the wrong default here.
        archiveByDefault = (UserDefaults.standard.object(forKey: Key.archiveByDefault) as? Bool) ?? true

        let defaults = UserDefaults.standard
        selectedPeople = Set(defaults.stringArray(forKey: Key.selectedPeople) ?? [])
        hiddenFrom = Set(defaults.stringArray(forKey: Key.hiddenFrom) ?? [])
        if let raw = defaults.string(forKey: Key.audienceMode), let mode = MomentAudience(rawValue: raw) {
            audienceMode = mode
        } else if defaults.bool(forKey: Key.audienceIsCustom),
                  let last = defaults.stringArray(forKey: Key.defaultAudience), !last.isEmpty {
            // Carried over from the per-post picker: a custom list becomes "Only selected people".
            audienceMode = .selected
            selectedPeople = Set(last)
        } else {
            audienceMode = .connections
        }
    }

    /// Everyone `mode` covers right now, before "Hide from".
    func people(for mode: MomentAudience) -> Set<String> {
        let directory = UserDirectory.shared
        switch mode {
        case .connections: return directory.storyReachableUserIds()
        case .contacts: return directory.phoneContactIds()
        case .chats: return directory.chatPeerIds()
        case .selected: return selectedPeople.intersection(directory.storyReachableUserIds())
        case .nobody: return []
        }
    }

    /// Who a new memory is sent to under the current setting.
    func resolvedAudience() -> [String] {
        var ids = people(for: audienceMode)
        if audienceMode.allowsHiding { ids.subtract(hiddenFrom) }
        return Array(ids)
    }

    func resetForSignOut() {
        sendViewReceipts = false
        archiveByDefault = true
        audienceMode = .connections
        selectedPeople = []
        hiddenFrom = []
        for key in [Key.sendViewReceipts, Key.defaultAudience, Key.audienceIsCustom, Key.archiveByDefault,
                    Key.audienceMode, Key.selectedPeople, Key.hiddenFrom] {
            UserDefaults.standard.removeObject(forKey: key)
        }
    }

}
