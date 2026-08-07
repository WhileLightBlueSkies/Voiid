//
//  ChatListRows.swift
//  Voiid
//
//  The classic LIST layout for the chat list — the alternative to the icon grid
//  (see ChatLayoutPreference for why both exist).
//
//  A list row's whole job is to answer "does this need me?" without being opened. That means
//  four facts in one glance — who, what they said, when, and whether it is unread — and a
//  visual hierarchy that lets the eye skip the rows that do not matter. Every decision below
//  serves that, and the comments say which.
//

import SwiftUI

struct ChatListRow: View {
    let conversation: VConversation
    var onTap: () -> Void
    var onCall: (() -> Void)?
    var onDelete: (() -> Void)?

    private var isUnread: Bool { conversation.unreadCount > 0 }

    var body: some View {
        Button(action: { Haptics.tap(); onTap() }) {
            HStack(spacing: VoiidSpacing.md) {
                avatar
                    .frame(width: 54, height: 54)

                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline, spacing: VoiidSpacing.sm) {
                        Text(conversation.title)
                            // WEIGHT carries unread, not colour alone. Roughly 1 in 12 men
                            // has a colour-vision deficiency, and a tinted name against a
                            // tinted badge is exactly the pairing that fails for them.
                            .font(VoiidFont.rounded(16, isUnread ? .semibold : .medium))
                            .foregroundStyle(VoiidColor.textPrimary)
                            .lineLimit(1)

                        Spacer(minLength: 0)

                        if let at = conversation.lastMessageAt {
                            Text(VoiidDate.listPreview(at))
                                .font(VoiidFont.rounded(12, .regular))
                                // The timestamp lifts to the brand colour when unread — the
                                // one place colour is doing work the badge does not already
                                // do, and it is never the only signal.
                                .foregroundStyle(isUnread ? VoiidColor.primary : VoiidColor.textSecondary)
                                .monospacedDigit()
                        }
                    }

                    // The badge's animation lives HERE, on the row that outlives it — not on
                    // the badge, which is the thing being inserted and removed. A modifier on
                    // a departing view has nothing left to drive its exit, so the insert
                    // animates and the removal snaps.
                    HStack(alignment: .center, spacing: VoiidSpacing.sm) {
                        Text(conversation.lastMessagePreview ?? "Tap to start the conversation")
                            .font(VoiidFont.rounded(14, isUnread ? .medium : .regular))
                            .foregroundStyle(isUnread ? VoiidColor.textPrimary : VoiidColor.textSecondary)
                            .lineLimit(1)
                            // A preview that is absent reads differently from one that is
                            // empty — the placeholder is dimmer so it never looks like a
                            // message someone actually sent.
                            .opacity(conversation.lastMessagePreview == nil ? 0.7 : 1)

                        Spacer(minLength: 0)

                        if isUnread {
                            // AMBER, matching the grid card. The same signal was drawn in
                            // two different colours depending on which layout you had
                            // chosen — aubergine here, amber there — and the palette
                            // reserves amber for exactly this: "the one thing that must be
                            // seen". Aubergine is also the app's most-used colour, so an
                            // unread badge in it competed with every other primary surface
                            // on screen instead of standing out from them.
                            Text(conversation.unreadCount > 99 ? "99+" : "\(conversation.unreadCount)")
                                .font(VoiidFont.rounded(12, .semibold))
                                .foregroundStyle(VoiidColor.textOnAccent)
                                // The NUMBER rolls when the count changes, rather than being
                                // swapped out. A badge going 2 -> 3 with a hard substitution
                                // is easy to miss entirely; the digit moving is what says
                                // "this just changed" without any extra chrome.
                                .contentTransition(.numericText())
                                .padding(.horizontal, 7)
                                .frame(minWidth: 22, minHeight: 22)
                                .background(VoiidColor.accent)
                                .clipShape(Capsule())
                                // Appearing is the moment that matters — it is the whole
                                // point of the badge. It scales up from the trailing edge it
                                // is anchored to (skill §7: originate from your source), so
                                // it reads as arriving rather than being pasted in.
                                .transition(.scale(scale: 0.5, anchor: .trailing)
                                    .combined(with: .opacity))
                        }
                    }
                    .animation(.spring(response: 0.3, dampingFraction: 0.72),
                               value: conversation.unreadCount)
                }
            }
            .padding(.vertical, 9)
            .padding(.horizontal, VoiidSpacing.md)
            .contentShape(Rectangle())
        }
        .buttonStyle(SoftPressStyle())
        // SWIPE ACTIONS, because a list without them is a list that feels broken on iOS —
        // it is the gesture people try first, and the grid's drag-to-zone equivalent has no
        // meaning in this layout.
        .swipeActions(edge: .trailing, allowsFullSwipe: false) {
            if let onDelete {
                Button(role: .destructive) { Haptics.rigid(); onDelete() } label: {
                    Label("Delete", systemImage: "trash")
                }
            }
            if let onCall, conversation.type == .direct {
                Button { Haptics.tap(); onCall() } label: {
                    Label("Call", systemImage: "phone.fill")
                }
                .tint(VoiidColor.success)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityText)
    }

    /// One spoken sentence rather than four fragments. VoiceOver reads a combined element in
    /// order, so "Priyanshu, 2 unread, Yoooo, 4:12 PM" is the useful phrasing — name first,
    /// urgency second, content last.
    private var accessibilityText: String {
        var parts = [conversation.title]
        if isUnread { parts.append("\(conversation.unreadCount) unread") }
        if let p = conversation.lastMessagePreview { parts.append(p) }
        if let at = conversation.lastMessageAt { parts.append(VoiidDate.listPreview(at)) }
        return parts.joined(separator: ", ")
    }

    @ViewBuilder
    private var avatar: some View {
        ZStack(alignment: .bottomTrailing) {
            if conversation.type == .self {
                // Note to Self gets its mark, not a face — see the grid card for the same
                // reasoning. The two layouts must teach the same vocabulary.
                Circle().fill(VoiidColor.primary.opacity(0.12))
                Image(systemName: "bookmark.fill")
                    .font(.system(size: 20, weight: .medium))
                    .foregroundStyle(VoiidColor.primary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ProfileAvatarButton(photoURL: conversation.photoURL,
                                    name: conversation.title,
                                    size: 54)
            }

            if conversation.isOnline {
                // Ringed in the row's own background so the dot reads as ON the avatar rather
                // than floating beside it — without the ring it disappears against a light
                // photo.
                Circle()
                    .fill(VoiidColor.success)
                    .frame(width: 13, height: 13)
                    .overlay(Circle().strokeBorder(VoiidColor.background, lineWidth: 2.5))
            }
        }
    }
}
