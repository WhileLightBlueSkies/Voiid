//
//  ReportSheet.swift
//  Voiid
//
//  Reporting a clip, a creator, or a person. Twin of Android `ReportSheet.kt`.
//
//  ── WHAT THIS SENDS ──────────────────────────────────────────────────────────────
//  A reason and, optionally, the reporter's own words. NOTHING ELSE. Reporting a person is
//  a report about THEM, not about a message: there is no message id in the payload and no
//  way to attach one, because the server has no key and "fetch the reported message" is a
//  feature that must stay unbuildable.
//
//  The sheet says so on screen rather than letting the user assume either way. Someone
//  reporting harassment deserves to know whether a moderator will be able to read what was
//  said, and the honest answer is no. That sentence is the most important thing on the
//  screen and it is not buried in a footnote.
//
//  ── WHY THE CONFIRMATION IS SEPARATE ─────────────────────────────────────────────
//  The profile's Report row confirms intent first, then presents this. The confirmation
//  cannot submit on its own: a report needs a reason, and a one-tap "Report" that guessed
//  one would file "spam" against someone being reported for something serious.
//

import SwiftUI

struct ReportSheet: View {

    let target: ReportTarget
    /// Called on cancel, on Done after a successful send, and on swipe-dismiss.
    let onDone: () -> Void

    @State private var reason: ReportReason = .spam
    @State private var note = ""
    @State private var busy = false
    @State private var sent = false
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if sent { sentState } else { form }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle(sent ? "" : "Report")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                if !sent {
                    ToolbarItem(placement: .cancellationAction) {
                        Button("Cancel") { onDone() }
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                    ToolbarItem(placement: .confirmationAction) {
                        Button(busy ? "Sending…" : "Send") { send() }
                            .disabled(busy)
                            .foregroundColor(busy ? VoiidColor.textSecondary : VoiidColor.primary)
                    }
                }
            }
        }
    }

    // MARK: states

    private var sentState: some View {
        VStack(spacing: 18) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 42))
                .foregroundColor(VoiidColor.primary)
            Text("Thanks — this has been sent to our moderators.")
                .font(VoiidFont.rounded(16, .regular))
                .foregroundColor(VoiidColor.textPrimary)
                .multilineTextAlignment(.center)
            Button("Done") { onDone() }
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(VoiidColor.primary)
        }
        .padding(32)
    }

    private var form: some View {
        List {
            Section("Why are you reporting this?") {
                ForEach(ReportReason.allCases) { option in
                    Button {
                        Haptics.tap()
                        reason = option
                    } label: {
                        HStack {
                            Text(option.label)
                                .font(VoiidFont.rounded(15, .regular))
                                .foregroundColor(VoiidColor.textPrimary)
                            Spacer()
                            if reason == option {
                                Image(systemName: "checkmark")
                                    .font(.system(size: 14, weight: .semibold))
                                    .foregroundColor(VoiidColor.primary)
                            }
                        }
                    }
                    .buttonStyle(.plain)
                }
            }

            Section {
                // No character counter until it matters: a counter on an empty optional
                // field reads as a requirement.
                TextField("Anything you want to add (optional)", text: $note, axis: .vertical)
                    .lineLimit(3...6)
                    .font(VoiidFont.rounded(15, .regular))
                    .foregroundColor(VoiidColor.textPrimary)
                    .onChange(of: note) { _, new in
                        if new.count > ReportService.maxNoteLength {
                            note = String(new.prefix(ReportService.maxNoteLength))
                        }
                    }
                if note.count > ReportService.maxNoteLength - 100 {
                    Text("\(ReportService.maxNoteLength - note.count) characters left")
                        .font(VoiidFont.rounded(12, .regular))
                        .foregroundColor(VoiidColor.textSecondary)
                }
            } footer: {
                // THE SENTENCE THAT MATTERS MOST ON THIS SCREEN.
                Text(privacyFooter)
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
            }

            if let error {
                Section {
                    Text(error)
                        .font(VoiidFont.rounded(13, .regular))
                        .foregroundColor(VoiidColor.error)
                }
            }
        }
        .scrollContentBackground(.hidden)
    }

    /// Differs by target, because the honest answer differs. A clip is public and the server
    /// can read it; a conversation is not and the server cannot.
    private var privacyFooter: String {
        switch target {
        case .person:
            return "We can see who you are reporting and what you write here. We cannot read "
                + "your messages with them — those are encrypted and we hold no key."
        case .clip, .creator:
            return "We can see the content you are reporting."
        case .communityPost, .community:
            // Deliberately says WHO ELSE sees it, which the other cases do not have to. A
            // community's own owner and admins work its moderation queue (053), so a member
            // reporting a post is handing it to people they are in a room with — and they are
            // entitled to know that before they tap Send rather than to discover it afterwards.
            return "Posts and communities are not end-to-end encrypted, so we can see what you "
                + "are reporting. This community's host and admins can see it too."
        case .event:
            // An event listing is server-readable like a post, but the audience differs and
            // saying so matters: an event report goes to PLATFORM admins, not to the
            // community's own host — who is usually the person being reported. Telling
            // someone their complaint lands with the host they are complaining about, when it
            // does not, would stop reports that ought to be made.
            return "We can see the event listing you are reporting. This goes to Voiid, not "
                + "to the event's host."
        }
    }

    // MARK: send

    private func send() {
        guard !busy else { return }
        Haptics.tap()
        busy = true
        error = nil
        Task {
            do {
                try await ReportService.shared.submit(target: target, reason: reason, note: note)
                sent = true
            } catch {
                // Named plainly and kept on screen. A report that silently failed is worse
                // than no report button at all, because the reporter walks away believing a
                // moderator is looking at it.
                self.error = "Couldn't send this report. Check your connection and try again."
            }
            busy = false
        }
    }
}
