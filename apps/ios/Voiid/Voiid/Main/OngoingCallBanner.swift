//
//  OngoingCallBanner.swift
//  Voiid
//
//  "Ongoing call — Join", pinned at the top of a group chat (plan item 3.15, part 3).
//
//  ── THE PROBLEM THIS SOLVES ──────────────────────────────────────────────────────
//  A group call used to be discoverable ONLY by catching the ring push. Miss the
//  notification — phone face-down, Do Not Disturb, app killed, notification swiped — and the
//  call became invisible even while everyone else sat in it. There was no state in the chat
//  saying a call was happening, so the only recovery was independently guessing to tap the
//  call button, which then started a SECOND call rather than joining the first.
//
//  ── WHY POLLING, AND WHY IT IS CHEAP ─────────────────────────────────────────────
//  The server holds a short-TTL Redis marker per conversation that connected clients re-arm
//  (see `touchGroupCallPresence` in calls.ts). There is deliberately no "call ended" event to
//  deliver: a call ends when everyone stops heartbeating, and a TTL expresses that without
//  anything having to notice or announce it. So this polls, and only while the chat is
//  actually on screen — `.task(id:)` starts it on appear and cancels it on disappear.
//
//  Nothing here is encrypted, and nothing here needs to be: "a call is happening in this
//  room" is routing metadata the server already holds in order to route the call at all. No
//  media, no keys, and no participant names cross this endpoint — only a count.
//

import SwiftUI

struct OngoingCallBanner: View {
    let conversationId: String
    /// Tapping Join runs the chat's normal call-start path rather than a second one of its
    /// own. Joining an existing call and starting a new one are the same operation on the
    /// server — the room is derived from the conversation id — so they must not diverge here.
    let onJoin: () -> Void

    /// Observed directly rather than through `@EnvironmentObject` — `GroupCallService` is a
    /// singleton that is never injected into the environment, and an absent environment object
    /// is a RUNTIME crash rather than a compile error.
    @ObservedObject private var groupCall = GroupCallService.shared

    @State private var active = false
    @State private var participantCount = 0

    /// Reduce Motion asks for a gentler equivalent, not for no feedback. The banner still
    /// appears and still says the same thing — it cross-fades instead of sliding a
    /// full-width row down over the transcript.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// Long enough that an idle chat is not chatty, short enough that a call started while
    /// you are reading appears within a few seconds.
    private static let pollSeconds: TimeInterval = 8

    /// Whether the banner should currently be on screen. Suppressed while WE are on the
    /// call: the call screen already covers the chat, and offering to "join" something you
    /// are in reads as a bug. `self_present` from the server would lag by a poll interval,
    /// so local state is what decides.
    private var visible: Bool {
        active && groupCall.conversationId != conversationId
    }

    var body: some View {
        Group {
            if visible { banner }
        }
        // THE ANIMATION BELONGS ON THE CONTAINER, NOT ON THE BANNER.
        //
        // It used to sit on `banner` itself — but `banner` is the view being inserted and
        // removed, so at removal time it is already leaving the hierarchy and has no
        // animation to drive its own exit. The insert animated and the exit snapped. Moving
        // the modifier to the enclosing Group means both halves are animated by a view that
        // outlives the change.
        //
        // Spring, not a fixed ease: the banner can flip back and forth as people join and
        // leave a call, and a spring retargets from wherever the row currently is rather than
        // restarting from a stale value and jumping. Critically damped — this is chrome
        // appearing, not something the user threw, so it has not earned any overshoot.
        // Reduce Motion keeps the feedback and drops the travel: a short opacity fade rather
        // than nothing at all, since the banner appearing IS the information.
        .animation(reduceMotion ? .easeOut(duration: 0.18)
                                : .spring(response: 0.32, dampingFraction: 1.0),
                   value: visible)
        .task(id: conversationId) { await pollLoop() }
    }

    private var banner: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "phone.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(VoiidColor.textOnPrimary)
                .frame(width: 26, height: 26)
                .background(VoiidColor.primary)
                .clipShape(Circle())

            VStack(alignment: .leading, spacing: 1) {
                Text("Ongoing call")
                    .font(VoiidFont.rounded(14, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                if participantCount > 0 {
                    Text("\(participantCount) on the call")
                        .font(VoiidFont.rounded(11, .regular))
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }

            Spacer(minLength: 0)

            // Press feedback comes from SoftPressStyle below (on press-DOWN, with its own
            // haptic), so there is none here — a second one on action is two buzzes for one
            // press.
            Button(action: onJoin) {
                Text("Join")
                    .font(VoiidFont.rounded(13, .semibold))
                    .foregroundColor(VoiidColor.textOnPrimary)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 6)
                    .background(VoiidColor.primary)
                    .clipShape(Capsule())
            }
            .buttonStyle(SoftPressStyle())
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.sm)
        .background(VoiidColor.surfaceCard)
        // Symmetric path: it arrives from the top of the chat and leaves the same way, so the
        // banner reads as one object coming and going rather than two unrelated effects.
        // Under Reduce Motion the travel is dropped and only the opacity remains — a
        // full-width row sliding down over the transcript is exactly the vestibular motion
        // that setting exists to suppress.
        .transition(reduceMotion
                    ? .opacity
                    : .move(edge: .top).combined(with: .opacity))
        .accessibilityElement(children: .combine)
        .accessibilityLabel(participantCount > 0
                            ? "Ongoing call, \(participantCount) on the call"
                            : "Ongoing call")
    }

    private func pollLoop() async {
        while !Task.isCancelled {
            await refresh()
            try? await Task.sleep(nanoseconds: UInt64(Self.pollSeconds * 1_000_000_000))
        }
    }

    private func refresh() async {
        struct Response: Decodable {
            // Optional so one added server field cannot break decoding — Swift's Codable
            // throws `keyNotFound` on an absent key, which has bitten this codebase before.
            let active: Bool?
            let participant_count: Int?
        }
        // A failed poll leaves the banner as it was rather than hiding it. Flapping a Join
        // button on a transient network blip is worse than a banner that is a few seconds
        // stale, and a 403 (not a member) simply never turns it on in the first place.
        guard let r = try? await APIClient().request(
            "GET", "calls/group/active?conversation_id=\(conversationId)",
            as: Response.self) else { return }

        active = r.active ?? false
        participantCount = r.participant_count ?? 0
    }
}
