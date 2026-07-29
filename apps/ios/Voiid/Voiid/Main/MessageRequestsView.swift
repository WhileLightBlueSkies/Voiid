//
//  MessageRequestsView.swift
//  Voiid
//
//  Inbound message requests — people who reached you by @username and are waiting to be
//  accepted (see 020_reachability.sql).
//
//  These are deliberately NOT in your chat list. `GET /conversations` filters to
//  `request_state = 'accepted'`, so a stranger's first message cannot appear among your real
//  conversations — that separation is the entire point of the Accept/Decline gate, and this
//  screen is where the held-back ones live.
//
//  DECLINE TELLS THE SENDER NOTHING. If "declined" were distinguishable from "not opened yet",
//  a request would become a presence oracle: send one, learn whether an account is live and
//  attended. From their side both look identical — message shows Sent, forever.
//

import SwiftUI

struct MessageRequestsView: View {
    /// Called after Accept, so the caller can open the now-real conversation.
    var onAccepted: (String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var requests: [ContactPinService.PendingRequest] = []
    @State private var loading = true
    @State private var busy: Set<String> = []
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Group {
                if loading {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if requests.isEmpty {
                    emptyState
                } else {
                    list
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Message requests")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.foregroundStyle(VoiidColor.textSecondary)
                }
            }
            .task { await load() }
        }
        .tint(VoiidColor.primary)
    }

    private var list: some View {
        List {
            ForEach(requests) { r in
                VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    HStack(spacing: VoiidSpacing.md) {
                        ProfileAvatarButton(photoURL: r.photo_url,
                                            name: r.full_name ?? r.username ?? "?",
                                            size: 44)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.full_name?.isEmpty == false ? r.full_name! : (r.username ?? "Unknown"))
                                .font(VoiidFont.rounded(16, .semibold))
                                .foregroundStyle(VoiidColor.textPrimary)
                            // How they reached you is load-bearing context: "found you by
                            // @username" is a different trust signal from "has your number".
                            Text(r.opened_via == "username"
                                 ? "Found you by @\(r.username ?? "username")"
                                 : "Has your number")
                                .font(VoiidFont.rounded(12, .regular))
                                .foregroundStyle(VoiidColor.textSecondary)
                        }
                        Spacer()
                        if busy.contains(r.conversation_id) { ProgressView() }
                    }

                    HStack(spacing: VoiidSpacing.sm) {
                        Button {
                            Haptics.tap()
                            act(r, accept: true)
                        } label: {
                            Text("Accept")
                                .font(VoiidFont.rounded(14, .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(VoiidColor.primary)
                                .foregroundStyle(VoiidColor.textOnPrimary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)

                        Button {
                            Haptics.tap()
                            act(r, accept: false)
                        } label: {
                            Text("Decline")
                                .font(VoiidFont.rounded(14, .semibold))
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 9)
                                .background(VoiidColor.fieldFill)
                                .foregroundStyle(VoiidColor.textSecondary)
                                .clipShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                    .disabled(busy.contains(r.conversation_id))
                }
                .padding(.vertical, 6)
                .listRowBackground(VoiidColor.surfaceCard)
            }

            if let error {
                Text(error).font(.footnote).foregroundStyle(VoiidColor.error)
                    .listRowBackground(VoiidColor.surfaceCard)
            }
        }
        .voiidSettingsList()
    }

    private var emptyState: some View {
        VStack(spacing: VoiidSpacing.sm) {
            ZStack {
                Circle().fill(VoiidColor.primary.opacity(0.08)).frame(width: 64, height: 64)
                Image(systemName: "tray")
                    .font(.system(size: 26))
                    .foregroundStyle(VoiidColor.primary.opacity(0.65))
            }
            Text("No requests")
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundStyle(VoiidColor.textPrimary)
            Text("When someone finds you by your username, their first message waits here until you accept it.")
                .font(VoiidFont.rounded(13, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal, VoiidSpacing.xl)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load() async {
        loading = true
        requests = (try? await ContactPinService.shared.pending()) ?? []
        loading = false
    }

    private func act(_ r: ContactPinService.PendingRequest, accept: Bool) {
        busy.insert(r.conversation_id)
        error = nil
        Task {
            do {
                if accept {
                    try await ContactPinService.shared.accept(conversationId: r.conversation_id)
                } else {
                    try await ContactPinService.shared.decline(conversationId: r.conversation_id)
                }
                // Remove locally rather than re-fetching: the row is gone either way, and a
                // round-trip would make the list flicker.
                requests.removeAll { $0.conversation_id == r.conversation_id }
                if accept { onAccepted(r.conversation_id) }
            } catch {
                self.error = accept ? "Couldn’t accept that request." : "Couldn’t decline that request."
            }
            busy.remove(r.conversation_id)
        }
    }
}
