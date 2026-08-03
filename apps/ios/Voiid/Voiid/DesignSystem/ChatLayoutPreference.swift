//
//  ChatLayoutPreference.swift
//  Voiid
//
//  How the chat list is drawn: the icon GRID, or a classic LIST.
//
//  WHY BOTH EXIST
//  --------------
//  The grid is Voiid's own idea — chats as home-screen tiles you can drag to reorder, or
//  onto Call / Delete zones. It is distinctive, and it is genuinely better for the handful
//  of people you actually message.
//
//  It is worse for everyone else. A grid shows a photo and a name; a list row shows the
//  photo, the name, the last message, the time and the unread count in one glance. Past
//  twenty conversations the grid becomes a wall of faces you have to read one at a time,
//  and there is nowhere to put the message preview that tells you whether a chat needs
//  attention. Every mainstream messenger is a list for exactly that reason.
//
//  So this is a real preference, not a novelty toggle: the grid stays the default because
//  it is what makes the app feel like itself, and the list is one tap away in Settings for
//  people whose chat list has outgrown it.
//
//  Deliberately NOT synced to the server. It describes this device's screen — a phone and a
//  tablet can reasonably want different answers — and syncing it would mean a settings write
//  on a screen that must stay instant.
//

import SwiftUI
import Combine

@MainActor
final class ChatLayoutPreference: ObservableObject {
    static let shared = ChatLayoutPreference()

    enum Layout: String, CaseIterable, Identifiable {
        case grid, list
        var id: String { rawValue }

        var label: String {
            switch self {
            case .grid: return "Grid"
            case .list: return "List"
            }
        }

        /// The SF Symbol shown beside each option, so the choice is legible before you make
        /// it — the words "grid" and "list" describe a layout you cannot see until you pick.
        var icon: String {
            switch self {
            case .grid: return "square.grid.2x2"
            case .list: return "list.bullet"
            }
        }
    }

    private static let key = "voiid.chatlist.layout"

    @Published var layout: Layout {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: Self.key) }
    }

    private init() {
        // GRID is the default: it is the app's signature, and a first-time user should meet
        // it rather than a list they have seen a dozen times elsewhere.
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? Layout.grid.rawValue
        layout = Layout(rawValue: raw) ?? .grid
    }
}
