//
//  CommunitiesHomeView.swift
//  Voiid
//
//  The Communities tab. Replaces the "coming soon" placeholder this tab has shown since it
//  was added.
//
//  ── WHAT IS AND IS NOT ENCRYPTED HERE ────────────────────────────────────────────
//  A community's CHANNELS are ordinary MLS group conversations and stay end-to-end
//  encrypted. The container around them — the name, the handle, the member roster, search
//  and invites — is server-readable, exactly as declared in the header of
//  030_communities.sql. This screen shows only the container, so nothing on it is
//  encrypted, and the copy does not imply otherwise.
//
//  ── JOINING IS NOT A MESSAGING RIGHT ─────────────────────────────────────────────
//  Being in a community lets you into its channels and grants exactly one private line —
//  to the OWNER, and only the owner. Reaching any other member still takes one of the three
//  paths in 020_reachability.sql. There is deliberately no "message" affordance on a member
//  row anywhere in this file.
//

import SwiftUI

struct CommunitiesHomeView: View {
    @EnvironmentObject var session: AppSession

    @State private var mine: [CommunityService.CommunityCard] = []
    @State private var results: [CommunityService.CommunityCard] = []
    @State private var search = ""
    @State private var loading = false
    @State private var loadError: String?
    @State private var showCreate = false
    /// The community opened from a card. Held by id so a refresh cannot swap it underneath.
    @State private var openHandle: String?

    /// Searching replaces the list entirely rather than filtering `mine` — discovery is a
    /// different SOURCE (its own endpoint, its own results), not a filter over what you have.
    private var isSearching: Bool {
        search.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var body: some View {
        NavigationStack {
            content
                .background(VoiidColor.background.ignoresSafeArea())
                .navigationTitle("Communities")
                .navigationBarTitleDisplayMode(.inline)
                .searchable(text: $search, prompt: "Find a community")
                .toolbar {
                    ToolbarItem(placement: .primaryAction) {
                        Button { Haptics.tap(); showCreate = true } label: {
                            Image(systemName: "plus")
                        }
                        .accessibilityLabel("Create a community")
                    }
                }
                .sheet(isPresented: $showCreate) {
                    CommunityCreateSheet { created in
                        showCreate = false
                        mine.insert(created, at: 0)
                    } onCancel: { showCreate = false }
                }
                .navigationDestination(item: $openHandle) { handle in
                    CommunityDetailView(handle: handle)
                }
                .task { await loadMine() }
                .onChange(of: search) { _, _ in Task { await runSearch() } }
                .refreshable { await loadMine() }
        }
        .onAppear { session.hideTabBar = false }
    }

    @ViewBuilder private var content: some View {
        // Error beats empty. Rendering "you're not in any communities" for a failed request
        // is a lie the user cannot act on — the same rule the Clips feed follows.
        if let loadError, mine.isEmpty, !isSearching {
            ScrollView {
                VStack(spacing: VoiidSpacing.sm) {
                    Image(systemName: "exclamationmark.triangle")
                        .font(.system(size: 30)).foregroundColor(VoiidColor.textSecondary)
                    Text(loadError).font(VoiidFont.subhead)
                        .foregroundColor(VoiidColor.textSecondary)
                        .multilineTextAlignment(.center)
                    Button("Try again") { Task { await loadMine() } }
                        .font(VoiidFont.rounded(15, .semibold))
                        .foregroundColor(VoiidColor.primary)
                }
                .padding(VoiidSpacing.xl)
            }
        } else if isSearching {
            list(results, empty: "No communities match that.")
        } else if mine.isEmpty && !loading {
            emptyState
        } else {
            list(mine, empty: "")
        }
    }

    private func list(_ cards: [CommunityService.CommunityCard], empty: String) -> some View {
        ScrollView {
            LazyVStack(spacing: 10) {
                ForEach(cards, id: \.id) { card in
                    Button {
                        Haptics.tap()
                        openHandle = card.handle
                    } label: {
                        CommunityCardRow(card: card)
                    }
                    .buttonStyle(.plain)
                }
                if cards.isEmpty && !loading {
                    Text(empty)
                        .font(VoiidFont.subhead)
                        .foregroundColor(VoiidColor.textSecondary)
                        .padding(.top, VoiidSpacing.xl)
                }
                Color.clear.frame(height: 100)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.top, VoiidSpacing.sm)
            // Had NO bottom clearance at all, so the last card sat under the tab bar — the bar
            // is painted over this page, not inserted into its safe area. See bottomInset.
            .padding(.bottom, session.bottomInset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "person.3")
                .font(.system(size: 34))
                .foregroundColor(VoiidColor.primary)
            Text("No communities yet")
                .font(VoiidFont.rounded(20, .semibold))
                .foregroundColor(VoiidColor.textPrimary)
            Text("Search for one above, open an invite link, or start your own.")
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
            Button("Create a community") { Haptics.tap(); showCreate = true }
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundColor(VoiidColor.textOnPrimary)
                .padding(.horizontal, VoiidSpacing.lg)
                .padding(.vertical, 10)
                .background(VoiidColor.primary)
                .clipShape(Capsule())
                .padding(.top, VoiidSpacing.sm)
        }
        .padding(VoiidSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func loadMine() async {
        loading = true; loadError = nil
        defer { loading = false }
        do { mine = try await CommunityService.shared.mine() }
        catch { loadError = (error as? APIError)?.errorDescription ?? "Couldn't load your communities." }
    }

    private func runSearch() async {
        guard isSearching else { results = []; return }
        // Failures here are deliberately silent: a search that returns nothing and a search
        // that failed look the same to the user, and an error banner over a live-typing
        // field flickers on every keystroke.
        results = (try? await CommunityService.shared.search(search)) ?? []
    }
}

// MARK: - Card

private struct CommunityCardRow: View {
    let card: CommunityService.CommunityCard

    var body: some View {
        HStack(spacing: VoiidSpacing.md) {
            ClipThumbnail(url: card.avatar_url)
                .frame(width: 52, height: 52)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(card.name ?? "@\(card.handle)")
                        .font(VoiidFont.rounded(16, .semibold))
                        .foregroundColor(VoiidColor.textPrimary)
                        .lineLimit(1)
                    if card.isMember {
                        Text("joined")
                            .font(VoiidFont.rounded(10, .semibold))
                            .foregroundColor(VoiidColor.primary)
                            .padding(.horizontal, 6).padding(.vertical, 2)
                            .background(VoiidColor.accent.opacity(0.35))
                            .clipShape(Capsule())
                    } else if card.isPending {
                        Text("requested")
                            .font(VoiidFont.rounded(10, .semibold))
                            .foregroundColor(VoiidColor.textSecondary)
                    }
                }
                if let d = card.description, !d.isEmpty {
                    Text(d)
                        .font(VoiidFont.footnote)
                        .foregroundColor(VoiidColor.textSecondary)
                        .lineLimit(2)
                }
                Text("\(card.members) member\(card.members == 1 ? "" : "s")")
                    .font(VoiidFont.rounded(11, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right")
                .font(.system(size: 12, weight: .semibold))
                .foregroundColor(VoiidColor.textSecondary)
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
    }
}

// MARK: - Create

private struct CommunityCreateSheet: View {
    let onCreated: (CommunityService.CommunityCard) -> Void
    let onCancel: () -> Void

    @State private var handle = ""
    @State private var name = ""
    @State private var blurb = ""
    @State private var busy = false
    @State private var error: String?

    /// Matches the server's grammar exactly (030_communities.sql) so a name the client
    /// accepts is one the server will too — a mismatch here reads as a random rejection.
    private var handleValid: Bool {
        handle.range(of: "^[a-z][a-z0-9_]{2,19}$", options: .regularExpression) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("handle", text: $handle)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .onChange(of: handle) { _, v in handle = v.lowercased() }
                    TextField("Name", text: $name)
                    TextField("What it's for (optional)", text: $blurb, axis: .vertical)
                        .lineLimit(2...4)
                } footer: {
                    Text("Handles share one namespace with usernames and creator handles, so "
                         + "@\(handle.isEmpty ? "yourname" : handle) can only mean one thing across Voiid.")
                }
                if let error {
                    Text(error).foregroundColor(VoiidColor.error).font(VoiidFont.footnote)
                }
            }
            .navigationTitle("New community")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Create") { Task { await create() } }
                        .disabled(!handleValid || name.isEmpty || busy)
                }
            }
        }
    }

    private func create() async {
        busy = true; error = nil
        defer { busy = false }
        do {
            let card = try await CommunityService.shared.create(
                handle: handle, name: name,
                description: blurb.isEmpty ? nil : blurb)
            onCreated(card)
        } catch {
            // The handle race can only be settled by the database, so its refusal is shown
            // verbatim rather than pre-checked into a promise this client cannot keep.
            self.error = (error as? APIError)?.errorDescription ?? "Couldn't create that community."
        }
    }
}
