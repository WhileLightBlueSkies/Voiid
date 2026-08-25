//
//  MapNotificationsView.swift
//  Voiid
//
//  The Map's bell, and what is honestly behind it.
//
//  ── WHAT WAS LOOKED FOR, AND WHAT WAS FOUND ─────────────────────────────────────
//  Before building anything, the codebase was searched for a map notification feed:
//
//   * `UNUserNotificationCenter` — used, but only by `MissedCallNotifier` (a local
//     notification for a missed call) and by the permission prompt. Nothing map-related is
//     ever scheduled, and the app has no push payload type for the Map.
//   * `.voiidMapControlReceived` — real, and posted by the ratchet decode path when a
//     `map_key` / `map_off` arrives. But it is TRANSIENT: `MapPresenceEngine` observes it,
//     applies the effect, and the notification is gone. Nothing writes it to a log.
//   * `MapPresenceStore` — deliberately keeps only the LATEST fix per contact. "No trail,
//     no history — by design" (docs/MAP_STATUS.md). There is nowhere a feed could be read
//     from even if one were wanted.
//
//  So there is NO EVENT FEED, and this screen does not pretend to be one. There is no
//  "Priya started sharing 10 minutes ago", because the app does not know when she started —
//  it knows only that she is sharing NOW. Inventing a timestamp for an event we never
//  recorded is exactly the fabrication this screen exists to avoid.
//
//  ── WHAT THIS SCREEN IS INSTEAD ─────────────────────────────────────────────────
//  A statement of current Map activity, built entirely from state the engine actually holds:
//
//   * who is sharing with me right now, and how fresh their last fix is (`presences`);
//   * who has given me a key but whose first fix has not landed (`inboundSenders` minus
//     those with a presence) — genuinely "waiting", not a guess;
//   * my own outbound share and when it lapses (`outboundExpiresAt`) — the one thing on the
//     Map that will change on its own without anybody touching it, and therefore the closest
//     thing to a notification this app truthfully has.
//
//  The bell's "3" badge was removed from `FriendsMapScreen` in the same change. A count with
//  nothing behind it is worse than no count.
//

import SwiftUI
import Combine

struct MapNotificationsView: View {
    @ObservedObject private var engine = MapPresenceEngine.shared
    @ObservedObject private var directory = UserDirectory.shared

    /// Drives the two countdowns (each person's fix age, and my own share's expiry). Both are
    /// measured against absolute instants, so without a tick this screen would read the same
    /// thing five minutes later — the silent-drift problem the audience sheet's clock exists
    /// to solve, and the same 30s beat is used here for the same reason.
    @State private var now = Date()
    private let clock = Timer.publish(every: 30, on: .main, in: .common).autoconnect()

    /// People with a live-enough fix. Same freshness verdict the map's pins use, so the two
    /// surfaces can never disagree about who is on the map.
    private var sharing: [MapPresence] {
        engine.presences
            .filter {
                let s = MapPresenceState.forFix(at: $0.fixedAt, now: now)
                return s == .live || s == .stale
            }
            .sorted { directory.displayName($0.senderUserId)
                .localizedCaseInsensitiveCompare(directory.displayName($1.senderUserId)) == .orderedAscending }
    }

    /// People who have handed us a map key but whose first fix has not arrived — or whose
    /// last one aged out. Not an error and not an absence: the key is real, the position is
    /// not here yet.
    private var waiting: [String] {
        let drawable = Set(sharing.map(\.senderUserId))
        return engine.inboundSenders.filter { !drawable.contains($0) }.sorted {
            directory.displayName($0).localizedCaseInsensitiveCompare(directory.displayName($1)) == .orderedAscending
        }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                VoiidSettingsHeader(
                    "Map activity",
                    subtitle: "What the Map knows right now.",
                    badge: ("lock.fill", "End-to-end encrypted"))

                // THREE DISTINGUISHABLE STATES, in the same priority order the map itself
                // uses. A fault must never be dressed as "nobody is sharing with you" — that
                // tells the user something false about their friends.
                if let error = engine.lastError {
                    failedCard(error)
                } else if sharing.isEmpty && waiting.isEmpty {
                    emptyCard
                } else {
                    if !sharing.isEmpty { sharingCard }
                    if !waiting.isEmpty { waitingCard }
                }

                outboundCard

                // The honest footer. This screen's whole reason for existing is that the
                // thing the bell implies does not exist, so it says so plainly.
                Text("""
                    Voiid keeps no history of who shared with you or when. The Map holds only \
                    each person’s latest position, so this screen shows what’s true now rather \
                    than a list of past events.
                    """)
                    .font(.footnote)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .padding(.horizontal, 4)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(VoiidSpacing.md)
        }
        .font(.body)
        .foregroundStyle(VoiidColor.textPrimary)
        .fontDesign(.rounded)
        .voiidSettingsPage()
        .onReceive(clock) { now = $0 }
        .onAppear { now = Date() }
    }

    // MARK: - Cards

    private var sharingCard: some View {
        VoiidCardSection(
            "Sharing with you",
            footer: "Their position updates about every five minutes while they’re visible to you."
        ) {
            ForEach(Array(sharing.enumerated()), id: \.element.senderUserId) { index, p in
                if index > 0 { VoiidRowDivider() }
                VoiidSettingsRow(
                    icon: "dot.radiowaves.left.and.right",
                    title: directory.displayName(p.senderUserId),
                    detail: "Updated \(MapFormatters.relativeAge(p.fixedAt))")
            }
        }
    }

    private var waitingCard: some View {
        VoiidCardSection(
            "Waiting for a position",
            footer: """
                These people have shared with you, but their first update hasn’t arrived yet — \
                or their last one is old enough that showing it would be a guess about where \
                they are.
                """
        ) {
            ForEach(Array(waiting.enumerated()), id: \.element) { index, uid in
                if index > 0 { VoiidRowDivider() }
                VoiidSettingsRow(icon: "hourglass",
                                 title: directory.displayName(uid),
                                 detail: "No position yet")
            }
        }
    }

    /// My own share. Shown ONLY when a server row genuinely exists — `outboundShareId`, not
    /// `isVisible`, for the same reason the audience sheet gates on it: while ghosted there
    /// is no share to describe.
    @ViewBuilder
    private var outboundCard: some View {
        if engine.outboundShareId != nil {
            VoiidCardSection(
                "Your share",
                footer: "A Map share always ends on its own, so you can’t be left sharing forever."
            ) {
                VoiidSettingsRow(icon: "clock",
                                 title: "Sharing ends",
                                 detail: expiryDetail)
                VoiidRowDivider()
                VoiidSettingsRow(
                    icon: "person.2",
                    title: engine.audience.count == 1
                        ? "1 person can see you"
                        : "\(engine.audience.count) people can see you")
            }
        }
    }

    private var emptyCard: some View {
        VoiidCardSection(footer: "You’ll see people here as soon as someone shares with you.") {
            VoiidSettingsRow(icon: "bell.slash",
                             title: "Nothing to show",
                             detail: "No one is sharing their location with you right now.")
        }
    }

    private func failedCard(_ message: String) -> some View {
        VoiidCardSection(footer: "This is a fault, not an empty Map — it doesn’t mean nobody is sharing with you.") {
            VoiidSettingsRow(icon: "exclamationmark.triangle",
                             title: "Couldn’t load the Map",
                             detail: message,
                             destructive: true)
        }
    }

    /// Time left on my own share, phrased the way the audience sheet phrases it so the two
    /// surfaces read identically.
    private var expiryDetail: String {
        guard let exp = engine.outboundExpiresAt else {
            return "Time remaining unknown — add time on the Map to set it."
        }
        let left = exp.timeIntervalSince(now)
        guard left > 0 else { return "Expired — add time to keep sharing." }
        let mins = Int(left / 60)
        if mins < 60 { return "Ends in \(max(1, mins))m" }
        let hours = mins / 60
        let rem = mins % 60
        return rem == 0 ? "Ends in \(hours)h" : "Ends in \(hours)h \(rem)m"
    }
}
