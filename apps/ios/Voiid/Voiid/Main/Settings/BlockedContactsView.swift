//
//  BlockedContactsView.swift
//  Voiid
//
//  Settings → Privacy → Blocked contacts.
//
//  The list of people this account has blocked, and the only place to unblock them. Blocking
//  happens on a person's profile; unblocking needs a home that does not require finding the
//  person you have been avoiding, which is the entire reason this screen exists.
//
//  THE FOOTER IS LOAD-BEARING
//  --------------------------
//  Blocking is SYMMETRIC on the server: neither party can message or call the other. A user
//  who assumes Block is a one-way mute will read their own failed sends as a bug in the app,
//  so the screen says it plainly rather than leaving them to discover it.
//
//  It also says what blocking does NOT do. Blocking is not deletion — history stays, shared
//  groups stay, and nothing is announced to the other person. Each of those is a reasonable
//  and wrong assumption, and the cost of getting one wrong is someone believing a
//  conversation is gone when it is not.
//

import SwiftUI

struct BlockedContactsView: View {

    @ObservedObject private var service = BlockService.shared
    @State private var confirmUnblock: BlockedUser?
    @State private var failureMessage: String?

    var body: some View {
        List {
            SettingsSection(
                service.blocked.isEmpty ? nil : "Blocked",
                footer: "Blocked people can't message or call you — and you can't message or "
                    + "call them. They're never told. Your past messages and any groups you "
                    + "share stay where they are."
            ) {
                if !service.didLoad {
                    // Distinct from the empty state on purpose: "you have blocked nobody" is a
                    // claim, and making it before the list has loaded is making it up.
                    HStack(spacing: 12) {
                        ProgressView().tint(VoiidColor.textSecondary)
                        Text("Loading…")
                            .font(VoiidFont.rounded(15, .regular))
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                    .padding(.vertical, 6)
                } else if service.blocked.isEmpty {
                    Text("You haven't blocked anyone.")
                        .font(VoiidFont.rounded(15, .regular))
                        .foregroundColor(VoiidColor.textSecondary)
                        .padding(.vertical, 6)
                } else {
                    ForEach(service.blocked) { user in
                        row(for: user)
                    }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Blocked contacts")
        .navigationBarTitleDisplayMode(.inline)
        .task { await service.loadIfNeeded() }
        .refreshable { await service.refresh() }
        .confirmationDialog(
            confirmUnblock.map { "Unblock \($0.displayName)?" } ?? "",
            isPresented: Binding(get: { confirmUnblock != nil },
                                 set: { if !$0 { confirmUnblock = nil } }),
            titleVisibility: .visible
        ) {
            Button("Unblock") {
                if let user = confirmUnblock { unblock(user) }
                confirmUnblock = nil
            }
            Button("Cancel", role: .cancel) { confirmUnblock = nil }
        } message: {
            Text("They'll be able to message and call you again.")
        }
        .alert("Couldn't unblock",
               isPresented: Binding(get: { failureMessage != nil },
                                    set: { if !$0 { failureMessage = nil } })) {
            Button("OK", role: .cancel) { failureMessage = nil }
        } message: {
            Text(failureMessage ?? "")
        }
    }

    private func row(for user: BlockedUser) -> some View {
        HStack(spacing: 12) {
            avatar(for: user)

            VStack(alignment: .leading, spacing: 2) {
                Text(user.displayName)
                    .font(VoiidFont.rounded(16, .medium))
                    .foregroundColor(VoiidColor.textPrimary)
                // Only when it adds something — repeating the display name as "@name"
                // underneath itself is noise.
                if let username = user.username, !username.isEmpty,
                   user.displayName != "@\(username)" {
                    Text("@\(username)")
                        .font(VoiidFont.rounded(13, .regular))
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }

            Spacer()

            Button {
                Haptics.tap()
                confirmUnblock = user
            } label: {
                if service.pending.contains(user.id) {
                    ProgressView().tint(VoiidColor.textSecondary)
                } else {
                    Text("Unblock")
                        .font(VoiidFont.rounded(15, .medium))
                        .foregroundColor(VoiidColor.primary)
                }
            }
            .buttonStyle(.plain)
            .disabled(service.pending.contains(user.id))
        }
        .padding(.vertical, 4)
    }

    /// Remote photo with an initials fallback.
    ///
    /// `VoiidAvatar` takes a BUNDLED image name, not a URL, so it cannot render a profile
    /// photo fetched from the server. This follows the AsyncImage pattern already used by
    /// SettingsSheet's profile row rather than widening that component for one screen.
    @ViewBuilder
    private func avatar(for user: BlockedUser) -> some View {
        let side: CGFloat = 38
        ZStack {
            Circle().fill(VoiidColor.fieldFill)
            if let raw = user.photo_url, let url = URL(string: raw) {
                AsyncImage(url: url) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    initials(for: user)
                }
            } else {
                initials(for: user)
            }
        }
        .frame(width: side, height: side)
        .clipShape(Circle())
    }

    private func initials(for user: BlockedUser) -> some View {
        Text(String(user.displayName.trimmingCharacters(in: .punctuationCharacters).prefix(1)).uppercased())
            .font(VoiidFont.rounded(16, .semibold))
            .foregroundColor(VoiidColor.textSecondary)
    }

    private func unblock(_ user: BlockedUser) {
        Task {
            let ok = await service.unblock(userId: user.id)
            if !ok {
                failureMessage = "Check your connection and try again. \(user.displayName) "
                    + "is still blocked."
            }
        }
    }
}
