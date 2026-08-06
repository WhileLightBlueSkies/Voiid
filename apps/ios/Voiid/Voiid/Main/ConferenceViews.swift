//
//  ConferenceViews.swift
//  Voiid
//
//  The UI for turning a 1:1 call into a small conference: who to add, and who is on the
//  call once they are.
//
//  ── A SHARED CALL IS NOT AN INTRODUCTION ─────────────────────────────────────────
//  Nothing in this file may create or imply a conversation. The backend guarantees it
//  structurally (32 guard tests in callConference.test.ts assert that no write to
//  `conversations` or `conversation_members` happens anywhere in the call path), and the
//  UI has to hold the same line: the roster below offers no "message" affordance, and the
//  picker asks the server who is invitable rather than deciding locally.
//
//  ── WHAT AN UNKNOWN PARTICIPANT MAY SEE ──────────────────────────────────────────
//  If you do not already know someone, you get their @username and nothing else — no full
//  name, no photo, no number — and reaching them afterwards still takes their contact PIN.
//  That rule lives in `CallIdentity` and is applied through `CallConference.displayName`;
//  these views never resolve a name themselves, precisely so there is one place it can be
//  got wrong.
//

import SwiftUI

// MARK: - Invite picker

/// Choose someone to add to the current call.
///
/// Sourced from EXISTING CONVERSATIONS rather than the address book. Adding someone to a
/// call is a reachability action, and the people you can already reach are exactly the
/// people you already have a conversation with — the same set `POST /calls/ring` will
/// accept. Offering the whole address book would produce a list where most taps fail.
struct ConferenceInviteSheet: View {
    let onPick: (String) -> Void
    let onCancel: () -> Void

    // ChatStore is injected, not a singleton — matching every other view in this app.
    @EnvironmentObject private var chat: ChatStore
    @State private var search = ""

    private var candidates: [VConversation] {
        let live = CallService.shared.active?.peerUserId
        return chat.directConversations
            // Not the person already on the call, and not a self chat.
            .filter { $0.peerUserId != nil && $0.peerUserId != live && $0.type != .self }
            .filter {
                search.isEmpty
                    || $0.title.localizedCaseInsensitiveContains(search)
            }
    }

    var body: some View {
        NavigationStack {
            Group {
                if candidates.isEmpty {
                    VStack(spacing: VoiidSpacing.sm) {
                        Image(systemName: "person.2")
                            .font(.system(size: 30))
                            .foregroundColor(VoiidColor.textSecondary)
                        Text(search.isEmpty ? "No one to add yet" : "No matches")
                            .font(VoiidFont.headline)
                            .foregroundColor(VoiidColor.textPrimary)
                        Text("You can add people you already have a chat with.")
                            .font(VoiidFont.subhead)
                            .foregroundColor(VoiidColor.textSecondary)
                            .multilineTextAlignment(.center)
                    }
                    .padding(VoiidSpacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(candidates) { conv in
                        Button {
                            if let uid = conv.peerUserId { onPick(uid) }
                        } label: {
                            HStack(spacing: VoiidSpacing.sm) {
                                // ClipThumbnail already resolves a remote URL with a
                                // placeholder and a cross-fade; a second avatar component
                                // would be a second thing to keep in sync.
                                ClipThumbnail(url: conv.photoURL)
                                    .frame(width: 40, height: 40)
                                    .clipShape(Circle())
                                Text(conv.title)
                                    .font(VoiidFont.body)
                                    .foregroundColor(VoiidColor.textPrimary)
                                Spacer()
                                Image(systemName: "plus.circle.fill")
                                    .foregroundColor(VoiidColor.primary)
                            }
                            // The whole row is the target, not just the label.
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .listRowBackground(VoiidColor.background)
                    }
                    .listStyle(.plain)
                    .searchable(text: $search, prompt: "Search")
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Add to call")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
            }
        }
        .task { if chat.directConversations.isEmpty { await chat.loadConversations() } }
    }
}

// MARK: - Roster

/// Who is on the call. Shown once a call has more than the two original participants.
///
/// Deliberately spare: a name, whether they are still ringing, and nothing else. There is
/// no tap target here — no profile, no message, no add-contact — because every one of those
/// would be a path from "we were briefly on a call" to "I can now reach you", which is the
/// exact thing the conference design refuses.
struct ConferenceRoster: View {
    @ObservedObject private var conference = CallConferenceService.shared

    var body: some View {
        if conference.roster.count > 1 {
            VStack(alignment: .leading, spacing: 6) {
                Text("On this call")
                    .font(VoiidFont.rounded(11, .semibold))
                    .foregroundColor(.white.opacity(0.6))
                    .textCase(.uppercase)

                ForEach(conference.roster) { entry in
                    HStack(spacing: 8) {
                        Circle()
                            .fill(entry.isRinging ? VoiidColor.accent : Color.green)
                            .frame(width: 6, height: 6)
                        // Resolved by the engine, never here — see the header. An unknown
                        // participant renders as @username and nothing more.
                        Text(CallIdentity.label(for: entry))
                            .font(VoiidFont.rounded(13, .medium))
                            .foregroundColor(.white)
                            .lineLimit(1)
                        if entry.isRinging {
                            Text("ringing")
                                .font(VoiidFont.rounded(11, .regular))
                                .foregroundColor(.white.opacity(0.6))
                        }
                        Spacer(minLength: 0)
                    }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, VoiidSpacing.sm)
            .background(Color.black.opacity(0.35))
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        }
    }
}

// MARK: - Incoming conference invite

/// The banner shown while this device is ringing for a conference invite.
///
/// Separate from the 1:1 incoming screen because the decision is different: you are not
/// being called by one person, you are being pulled into a call that already exists. The
/// inviter is named; the people already on it are not, because you may not know them and
/// listing them would leak exactly what the identity rule protects.
struct ConferenceInviteBanner: View {
    @ObservedObject private var conference = CallConferenceService.shared

    var body: some View {
        if conference.phase == .invited {
            VStack(spacing: VoiidSpacing.md) {
                Text("Call invitation")
                    .font(VoiidFont.rounded(12, .semibold))
                    .foregroundColor(VoiidColor.textSecondary)
                    .textCase(.uppercase)

                Text(inviterLabel)
                    .font(VoiidFont.rounded(20, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)

                HStack(spacing: VoiidSpacing.xl) {
                    Button {
                        Haptics.rigid()
                        Task { await conference.declineInvite() }
                    } label: {
                        Image(systemName: "phone.down.fill")
                            .font(.system(size: 22)).foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(VoiidColor.error).clipShape(Circle())
                    }
                    Button {
                        Haptics.tap()
                        Task { _ = await conference.acceptInvite() }
                    } label: {
                        Image(systemName: "phone.fill")
                            .font(.system(size: 22)).foregroundColor(.white)
                            .frame(width: 56, height: 56)
                            .background(Color.green).clipShape(Circle())
                    }
                }
            }
            .padding(VoiidSpacing.lg)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .shadow(radius: 12)
        }
    }

    /// The inviter, under the same rule as everyone else: a stranger is an @username.
    private var inviterLabel: String {
        guard let id = conference.inviterUserId else { return "Someone" }
        if let entry = conference.roster.first(where: { $0.userId == id }) {
            return CallIdentity.label(for: entry)
        }
        return CallIdentity.label(userId: id, username: nil)
    }
}
