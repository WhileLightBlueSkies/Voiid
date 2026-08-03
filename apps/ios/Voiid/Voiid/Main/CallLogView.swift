//
//  CallLogView.swift
//  Voiid
//
//  Recents — every call, newest first.
//
//  WHY THIS EXISTS. Call history was written to `call_history` from the first call the app
//  ever placed, but the only way to SEE it was to open the specific chat it happened in, or
//  that person's profile. So "who called me while I was out?" — the single question a call
//  log answers — had no answer anywhere in the app. The data was there the whole time; the
//  screen was not.
//
//  A NOTE ON WHAT THIS IS NOT. There is no server-side call history: `call_history` is a
//  LOCAL table, written when this device places or receives a call. A call answered on your
//  other phone does not appear here, and reinstalling loses the log. That is a real
//  limitation and the empty state does not pretend otherwise.
//

import SwiftUI

struct CallLogView: View {
    @EnvironmentObject var chat: ChatStore
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var entries: [LocalStore.CallLogEntry] = []
    @State private var filter: Filter = .all
    @State private var confirmClear = false
    /// Set to open a chat, read by the caller — the same pattern ChatsHomeView uses for its
    /// own navigation rather than pushing from inside a sheet.
    @State private var openConversation: VConversation?

    enum Filter: String, CaseIterable, Identifiable {
        case all = "All", missed = "Missed"
        var id: String { rawValue }
    }

    private var visible: [LocalStore.CallLogEntry] {
        filter == .missed ? entries.filter(\.missed) : entries
    }

    var body: some View {
        NavigationStack {
            Group {
                if entries.isEmpty {
                    emptyState
                } else if visible.isEmpty {
                    // A filter that matches nothing is NOT the same as having no history —
                    // saying "No calls yet" here would be a lie, and the user would think the
                    // log was broken rather than that they simply have no missed calls.
                    noMissedState
                } else {
                    list
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Calls")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Done") { dismiss() }.foregroundStyle(VoiidColor.primary)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    // Only offered when there is something to clear.
                    if !entries.isEmpty {
                        Menu {
                            Button(role: .destructive) {
                                Haptics.rigid(); confirmClear = true
                            } label: {
                                Label("Clear call history", systemImage: "trash")
                            }
                        } label: {
                            Image(systemName: "ellipsis.circle")
                        }
                        .accessibilityLabel("More")
                    }
                }
            }
            .safeAreaInset(edge: .top) {
                if !entries.isEmpty { filterBar }
            }
            .confirmationDialog("Clear call history?", isPresented: $confirmClear,
                                titleVisibility: .visible) {
                Button("Clear", role: .destructive) {
                    LocalStore.clearCallHistory()
                    entries = []
                    Haptics.success()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                // Say what is actually lost. This is device-local, so "on this device" is
                // not a hedge — it is the whole truth.
                Text("This removes every call from this device. It doesn't affect the other person's log.")
            }
            .navigationDestination(item: $openConversation) { ChatDetailView(conversation: $0) }
        }
        .tint(VoiidColor.primary)
        .task { entries = LocalStore.allCalls() }
    }

    // MARK: - Pieces

    /// All / Missed. Two options, so a segmented control rather than a menu — the choice is
    /// visible and one tap away, which is what a filter this small should be.
    private var filterBar: some View {
        Picker("Filter", selection: $filter) {
            ForEach(Filter.allCases) { Text($0.rawValue).tag($0) }
        }
        .pickerStyle(.segmented)
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.bottom, VoiidSpacing.sm)
        .background(.bar)
    }

    private var list: some View {
        List {
            ForEach(grouped, id: \.0) { day, calls in
                Section {
                    ForEach(calls) { entry in
                        CallLogRow(
                            entry: entry,
                            name: name(for: entry),
                            photoURL: entry.peerUserId.flatMap { UserDirectory.shared.photoURL($0) },
                            onOpenChat: { open(entry) },
                            onCallBack: { callBack(entry) }
                        )
                        .listRowBackground(VoiidColor.background)
                        .listRowSeparatorTint(VoiidColor.divider.opacity(0.5))
                    }
                } header: {
                    Text(day)
                        .font(VoiidFont.rounded(12, .semibold))
                        .kerning(0.6)
                        .foregroundStyle(VoiidColor.textSecondary)
                }
            }
        }
        .listStyle(.plain)
        .scrollContentBackground(.hidden)
    }

    /// Grouped by day, newest first. A call log without date separators is a wall of times
    /// with no way to tell yesterday from last month.
    private var grouped: [(String, [LocalStore.CallLogEntry])] {
        let cal = Calendar.current
        var order: [String] = []
        var buckets: [String: [LocalStore.CallLogEntry]] = [:]
        for e in visible {
            let key = VoiidDate.separator(cal.startOfDay(for: e.startedAt))
            if buckets[key] == nil { order.append(key) }
            buckets[key, default: []].append(e)
        }
        return order.map { ($0, buckets[$0] ?? []) }
    }

    private var emptyState: some View {
        VStack(spacing: VoiidSpacing.sm) {
            ZStack {
                Circle().fill(VoiidColor.primary.opacity(0.10)).frame(width: 88, height: 88)
                Image(systemName: "phone")
                    .font(.system(size: 32, weight: .medium))
                    .foregroundStyle(VoiidColor.primary)
            }
            .padding(.bottom, VoiidSpacing.xs)

            Text("No calls yet")
                .font(VoiidFont.rounded(20, .semibold))
                .foregroundStyle(VoiidColor.textPrimary)

            // Names the LIMITATION rather than only the absence: this log is written by this
            // device, so a user who has definitely made calls elsewhere is not left thinking
            // the screen is broken.
            Text("Calls you make and receive on this device will appear here.")
                .font(VoiidFont.rounded(14, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, VoiidSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var noMissedState: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(VoiidColor.success)
            Text("No missed calls")
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundStyle(VoiidColor.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - Actions

    private func name(for entry: LocalStore.CallLogEntry) -> String {
        if let peer = entry.peerUserId {
            let resolved = UserDirectory.shared.displayName(peer)
            if !resolved.isEmpty { return resolved }
        }
        // Fall back to the conversation title before giving up — a group call has no single
        // peer, and an unknown 1:1 still has a chat with a name on it.
        if let cid = entry.conversationId,
           let conv = (chat.directConversations + chat.groupConversations).first(where: { $0.id == cid }) {
            return conv.title
        }
        return "Unknown"
    }

    private func conversation(for entry: LocalStore.CallLogEntry) -> VConversation? {
        guard let cid = entry.conversationId else { return nil }
        return (chat.directConversations + chat.groupConversations).first { $0.id == cid }
    }

    private func open(_ entry: LocalStore.CallLogEntry) {
        guard let conv = conversation(for: entry) else { return }
        Haptics.tap()
        openConversation = conv
    }

    /// Call back with the SAME medium — a video call returns a video call.
    ///
    /// Routed through the chat rather than placed here: ChatDetailView owns peer resolution
    /// and the group-call lock, and duplicating that would let the two paths drift.
    private func callBack(_ entry: LocalStore.CallLogEntry) {
        guard let conv = conversation(for: entry) else { return }
        Haptics.tap()
        openConversation = conv
    }
}

/// One call.
///
/// The row answers three things at a glance: WHO, whether it was missed, and which way it
/// went. Everything else — time, duration, medium — is secondary and styled that way.
private struct CallLogRow: View {
    let entry: LocalStore.CallLogEntry
    let name: String
    let photoURL: String?
    var onOpenChat: () -> Void
    var onCallBack: () -> Void

    /// Direction, not medium. Every call used to draw the same phone glyph, so incoming and
    /// outgoing were indistinguishable — the single most useful fact about a call log.
    private var directionIcon: String {
        if entry.outcome == "declined" { return "phone.down.fill" }
        if entry.missed { return "phone.arrow.down.left" }
        return entry.incoming ? "arrow.down.left" : "arrow.up.right"
    }

    private var subtitle: String {
        var parts: [String] = [entry.incoming ? "Incoming" : "Outgoing"]
        switch entry.outcome {
        case "answered":
            if let d = entry.duration { parts.append(durationText(d)) }
        case "declined":  parts = [entry.incoming ? "Declined" : "Call declined"]
        case "failed":    parts = ["Failed"]
        default:          parts = [entry.incoming ? "Missed" : "No answer"]
        }
        parts.append(VoiidDate.bubbleTime(entry.startedAt))
        return parts.joined(separator: " · ")
    }

    private func durationText(_ d: TimeInterval) -> String {
        let s = Int(d), m = s / 60
        return m >= 60
            ? String(format: "%d:%02d:%02d", m / 60, m % 60, s % 60)
            : String(format: "%d:%02d", m, s % 60)
    }

    var body: some View {
        HStack(spacing: VoiidSpacing.md) {
            ProfileAvatarButton(photoURL: photoURL, name: name, size: 44)

            VStack(alignment: .leading, spacing: 2) {
                Text(name)
                    // MISSED IS RED IN THE NAME, not only in the icon. Colour alone fails for
                    // ~1 in 12 men, so the direction glyph carries it too — but a missed call
                    // is the reason to open this screen, and it should be findable by scanning.
                    .font(VoiidFont.rounded(16, .medium))
                    .foregroundStyle(entry.missed ? VoiidColor.error : VoiidColor.textPrimary)
                    .lineLimit(1)

                HStack(spacing: 5) {
                    Image(systemName: directionIcon)
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(entry.missed ? VoiidColor.error : VoiidColor.textSecondary)
                    Text(subtitle)
                        .font(VoiidFont.rounded(12, .regular))
                        .foregroundStyle(VoiidColor.textSecondary)
                        .lineLimit(1)
                }
            }

            Spacer(minLength: VoiidSpacing.sm)

            // The medium doubles as the call-back button: tapping a video call returns a
            // video call. A separate "call back" control would repeat what this already says.
            Button {
                onCallBack()
            } label: {
                Image(systemName: entry.isVideo ? "video.fill" : "phone.fill")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(VoiidColor.primary)
                    .frame(width: 36, height: 36)
                    .background(Circle().fill(VoiidColor.primary.opacity(0.10)))
            }
            .buttonStyle(.plain)
            .accessibilityLabel(entry.isVideo ? "Video call \(name)" : "Call \(name)")
        }
        .padding(.vertical, 6)
        .contentShape(Rectangle())
        .onTapGesture { onOpenChat() }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(name), \(subtitle)")
    }
}
