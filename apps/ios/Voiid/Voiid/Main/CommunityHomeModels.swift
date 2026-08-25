//
//  CommunityHomeModels.swift
//  Voiid
//
//  Placeholder data behind the community Home tab, ported from the reference.
//
//  ── WHAT IS LEFT HERE IS STILL MOCK; WHAT WENT LIVE HAS LEFT ────────────────────
//  Posts, the pinned announcement and the About links are now served (047_community_home.sql)
//  and their types live on the wire, in CommunityService — `CommunityPost`,
//  `CommunityAnnouncement` and `CommunityAboutLink` are deleted rather than kept as a second
//  shape to hold in step with the server.
//
//  WHAT REMAINS MOCK, AND WHY:
//    AdminStat / AdminTask ....... NO BACKEND AT ALL. There is no stats endpoint, no aggregate
//                                  of members/active/posts/reports, and no unified moderation
//                                  queue. The numbers are invented and identical for every
//                                  community. Deliberately NOT derived from whatever data is
//                                  in hand: a dashboard reporting "1,204 posts" because it
//                                  counted one page of the feed is a mock that lies, which is
//                                  worse than one that visibly does not.
//    CommunitySpace decoration ... purpose/unread/member-count; the channels endpoint has no
//                                  such columns (047 adds purpose/posting/pinned_at to
//                                  community_channels, but no route reads them yet).
//    CommunityDirectoryMember .... display names and online state; the roster returns ids.
//    CommunityRule ............... 046 has the table; no route serves it.
//
//  Each of those goes the same way these did: the view already reads the type, not the
//  samples, so wiring one is a service call and a deletion.
//

import SwiftUI

// MARK: - Avatars

/// The palette avoids lime. Lime is the brand's ACTION colour — unread badges, the compose
/// button — and an avatar wearing it competes with the controls the user is meant to press.
enum AvatarPalette {
    private static let colors: [Color] = [
        Color(hex: 0x7862A6),   // aubergine
        Color(hex: 0x3B82F6),   // blue
        Color(hex: 0xA855F7),   // violet
        Color(hex: 0xE8A33D),   // amber
        Color(hex: 0x22C55E),   // green
        Color(hex: 0xEF4444),   // red
        Color(hex: 0x14B8A6),   // teal
        Color(hex: 0xEC4899),   // pink
    ]

    static func color(for name: String) -> Color {
        // A simple deterministic hash. `hashValue` is NOT used: Swift seeds it per process, so
        // the colour would change every launch.
        let sum = name.unicodeScalars.reduce(0) { $0 &+ Int($1.value) }
        return colors[abs(sum) % colors.count]
    }

    /// One or two initials, skipping anything that is not a letter so "🌱 Plant" does not
    /// produce an emoji initial.
    static func initials(for name: String) -> String {
        let words = name.split(separator: " ")
            .compactMap { $0.first(where: \.isLetter) }
            .prefix(2)
        return words.isEmpty ? "?" : String(words).uppercased()
    }
}

/// A name-derived avatar. Used wherever the roster has a display name to work with.
struct CommunityAvatar: View {
    let name: String
    var size: CGFloat = 64

    var body: some View {
        Circle()
            .fill(
                LinearGradient(
                    colors: [
                        AvatarPalette.color(for: name),
                        AvatarPalette.color(for: name).opacity(0.72),
                    ],
                    startPoint: .topLeading, endPoint: .bottomTrailing
                )
            )
            .frame(width: size, height: size)
            .overlay {
                Text(AvatarPalette.initials(for: name))
                    // Scales with the circle so it reads at 26pt in a face pile and 64pt in a card.
                    .font(.system(size: size * 0.38, weight: .semibold, design: .rounded))
                    .foregroundColor(.white)
            }
            .accessibilityHidden(true)
    }
}

// MARK: - Feed
//
// The feed's types are GONE from this file. A post and the pinned announcement are served by
// GET /communities/:id/posts and /announcements, and are decoded as `CommunityService.Post`
// and `CommunityService.Announcement` — see CommunityHomeTab.

// MARK: - Admin

/// A number on the admin dashboard.
struct AdminStat: Identifiable, Hashable {
    let id: String
    let label: String
    let value: String
    let delta: String
    let icon: String
    /// Whether the change is good news. Drives the arrow's colour — never the hue alone, the
    /// arrow direction carries it too.
    var isPositive: Bool = true

    static let samples: [AdminStat] = [
        .init(id: "members", label: "Members", value: "48.2K", delta: "+312 this week",
              icon: "person.2.fill"),
        .init(id: "active", label: "Active today", value: "6,140", delta: "+8%",
              icon: "bolt.fill"),
        .init(id: "posts", label: "Posts", value: "1,204", delta: "+96 this week",
              icon: "square.and.pencil"),
        .init(id: "reports", label: "Open reports", value: "3", delta: "2 new today",
              icon: "exclamationmark.triangle.fill", isPositive: false),
    ]
}

/// Something waiting on an admin. Deliberately one type for join requests, reported posts and
/// pending events — the dashboard's job is a single queue of "what needs me", and three
/// separate lists would hide the smallest one.
struct AdminTask: Identifiable, Hashable {
    enum Kind: String, Hashable {
        case joinRequest = "Join request"
        case report = "Reported post"
        case eventApproval = "Event approval"

        var icon: String {
            switch self {
            case .joinRequest:   "person.badge.plus"
            case .report:        "flag.fill"
            case .eventApproval: "calendar.badge.clock"
            }
        }
    }

    let id: String
    let kind: Kind
    let subject: String
    let detail: String
    let age: String

    static let samples: [AdminTask] = [
        .init(id: "t1", kind: .joinRequest, subject: "Sana Malik",
              detail: "Wants to join · @sana.m", age: "12m ago"),
        .init(id: "t2", kind: .report, subject: "Post by Dev Anand",
              detail: "Reported as spam by 3 members", age: "1h ago"),
        .init(id: "t3", kind: .eventApproval, subject: "Type Crit Night",
              detail: "Submitted by Nova Rao · 18 Sep", age: "3h ago"),
        .init(id: "t4", kind: .joinRequest, subject: "Imran Q",
              detail: "Wants to join · @imranq", age: "5h ago"),
    ]
}

// MARK: - Spaces
//
// A Space is a room inside the community. Members join the ones they care about; admins create
// them and decide who may post. `posting` is the whole reason a Space is not just a group chat:
// an announcements Space where only admins write is a different thing from a lounge.

struct CommunitySpace: Identifiable, Hashable {
    /// Who may post here. Read access is governed by the community, not the Space.
    enum Posting: String, Hashable {
        case everyone = "Everyone"
        case adminsOnly = "Admins only"
    }

    let id: String
    let name: String
    let purpose: String
    let icon: String
    var members: Int = 0
    var unread: Int = 0
    var posting: Posting = .everyone
    var isJoined: Bool = true
    /// Pinned Spaces sort to the top for everyone in the community.
    var isPinned: Bool = false
    var lastActivity: String = "2h ago"

    var membersText: String {
        members >= 1_000 ? String(format: "%.1fK", Double(members) / 1_000) : "\(members)"
    }

    static let samples: [CommunitySpace] = [
        .init(id: "announce", name: "Announcements",
              purpose: "Official updates from the admin team.",
              icon: "megaphone.fill", members: 48_200, unread: 2,
              posting: .adminsOnly, isPinned: true, lastActivity: "2d ago"),
        .init(id: "general", name: "General",
              purpose: "Everything that doesn't fit anywhere else.",
              icon: "bubble.left.and.bubble.right.fill", members: 31_400, unread: 12,
              lastActivity: "4m ago"),
        .init(id: "critique", name: "Design Critique",
              purpose: "Post work. Get honest feedback.",
              icon: "eye.fill", members: 8_900, unread: 5, lastActivity: "22m ago"),
        .init(id: "jobs", name: "Jobs & Gigs",
              purpose: "Hiring, freelance and collaboration posts.",
              icon: "briefcase.fill", members: 12_100, lastActivity: "1h ago"),
        .init(id: "resources", name: "Resources",
              purpose: "Files, kits and links worth keeping.",
              icon: "folder.fill", members: 15_600, posting: .adminsOnly,
              lastActivity: "3d ago"),
        .init(id: "offtopic", name: "Off Topic",
              purpose: "Anything but design.",
              icon: "sparkles", members: 6_200, isJoined: false, lastActivity: "8m ago"),
    ]
}

// MARK: - Members

/// Someone in the community, from the directory's point of view.
struct CommunityDirectoryMember: Identifiable, Hashable {
    let id: String
    let name: String
    let handle: String
    /// Admins and owners share every permission in this build.
    var isManager: Bool = false
    var roleLabel: String = "Member"
    var joined: String = "May 2024"
    var isOnline: Bool = false
    /// Admin-only signal, so a moderator can spot a new account before it posts.
    var isNew: Bool = false

    static let samples: [CommunityDirectoryMember] = [
        .init(id: "m1", name: "Arjun Dev", handle: "arjundev", isManager: true,
              roleLabel: "Owner", joined: "Jan 2023", isOnline: true),
        .init(id: "m2", name: "Nova Rao", handle: "novarao", isManager: true,
              roleLabel: "Admin", joined: "Feb 2023", isOnline: true),
        .init(id: "m3", name: "Kiran S", handle: "kiran.s", isManager: true,
              roleLabel: "Admin", joined: "Apr 2023"),
        .init(id: "m4", name: "Rohit Sharma", handle: "rohit.s",
              joined: "12 May 2024", isOnline: true, isNew: true),
        .init(id: "m5", name: "Ananya Mehta", handle: "ananya.m",
              joined: "3 Jun 2024", isNew: true),
        .init(id: "m6", name: "Meera P", handle: "meera.p", joined: "Aug 2023"),
        .init(id: "m7", name: "Karan Malhotra", handle: "karan.m",
              joined: "Nov 2023", isOnline: true),
        .init(id: "m8", name: "Neha Iyer", handle: "neha.i", joined: "Dec 2023"),
        .init(id: "m9", name: "Vishal Patil", handle: "vishal.p", joined: "Jan 2024"),
    ]
}

/// The Members tab's filter.
enum MemberFilter: String, CaseIterable, Identifiable {
    case all = "All"
    case admins = "Admins"
    case online = "Online"
    case newest = "New"

    var id: String { rawValue }

    func matches(_ member: CommunityDirectoryMember) -> Bool {
        switch self {
        case .all:    true
        case .admins: member.isManager
        case .online: member.isOnline
        case .newest: member.isNew
        }
    }
}

// MARK: - About

/// One community rule. Numbered in the view rather than the model, so reordering is a list
/// operation and not a renumbering chore.
struct CommunityRule: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String

    static let samples: [CommunityRule] = [
        .init(id: "r1", title: "Be useful, not loud",
              detail: "Critique the work, never the person. Say what you would want said to you."),
        .init(id: "r2", title: "No unsolicited promotion",
              detail: "Sharing your own work is welcome in the right Space. Ads are not."),
        .init(id: "r3", title: "Credit sources",
              detail: "If you post someone else's work, name them and link it."),
        .init(id: "r4", title: "Keep it in the right Space",
              detail: "Jobs in Jobs & Gigs, feedback in Design Critique. It keeps search useful."),
    ]
}

// A link on the About tab is now `CommunityService.AboutLink`, served by
// GET /communities/:id/links. The local `CommunityAboutLink` is deleted: 047 makes `value`
// free text (a contact address and a "read the handbook" label both live there, so it is not
// a URL) and `icon` a client-chosen SF Symbol name, and a second local copy of that shape
// would only be somewhere for the two to disagree.

