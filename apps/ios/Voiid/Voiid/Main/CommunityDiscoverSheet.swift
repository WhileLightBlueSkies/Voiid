//
//  CommunityDiscoverSheet.swift
//  Voiid
//
//  Browsing communities you are NOT in — a different job from the list behind it, which is
//  the ones you already belong to. It gets its own surface for that reason: a filter over
//  your own communities can never show you a new one.
//
//  Opens on TRENDING rather than an empty box. `GET /communities/search` answers an empty
//  query with communities ranked by recent joins, so the sheet has something in it before
//  anyone types — a discover screen that waits for input is a search box wearing a browse
//  screen's clothes.
//

import SwiftUI

struct CommunityDiscoverSheet: View {
    /// Handed back to the parent, which owns the navigation stack. The sheet does not push
    /// its own destination: a community opened from here should land in the same place as one
    /// opened from the list, not on a stack that disappears when the sheet closes.
    let onOpen: (String) -> Void

    @Environment(\.dismiss) private var dismiss

    @State private var cards: [CommunityService.CommunityCard] = []
    @State private var search = ""
    @State private var loading = true
    @State private var error: String?
    /// The last query actually sent, so a result landing out of order cannot overwrite a
    /// newer one — typing quickly otherwise leaves the list showing an earlier term's answer.
    @State private var inFlight = ""

    private var isSearching: Bool {
        search.trimmingCharacters(in: .whitespacesAndNewlines).count >= 2
    }

    var body: some View {
        NavigationStack {
            ZStack {
                VoiidColor.background.ignoresSafeArea()

                ScrollView {
                    LazyVStack(spacing: 10) {
                        if !isSearching && !cards.isEmpty {
                            // Labelled honestly. Calling a trending list "results" implies the
                            // user asked for it.
                            Text("Trending")
                                .font(VoiidFont.rounded(13, .semibold))
                                .foregroundColor(VoiidColor.textSecondary)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.top, VoiidSpacing.xs)
                        }

                        ForEach(cards, id: \.id) { card in
                            Button {
                                Haptics.tap()
                                // Dismiss first, then hand the handle up. Pushing behind a
                                // sheet that is still on screen shows the destination sliding
                                // in underneath it.
                                dismiss()
                                onOpen(card.handle)
                            } label: {
                                CommunityCardRow(card: card, isHost: false)
                            }
                            .buttonStyle(.plain)
                        }

                        if cards.isEmpty && !loading {
                            emptyState
                        }

                        Color.clear.frame(height: 24)
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                }
                .scrollDismissesKeyboard(.immediately)

                if loading && cards.isEmpty {
                    ProgressView().tint(VoiidColor.accent)
                }
            }
            .navigationTitle("Discover")
            .navigationBarTitleDisplayMode(.inline)
            .searchable(text: $search, prompt: "Search communities")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                        .foregroundColor(VoiidColor.textSecondary)
                }
            }
            .task { await load() }
            .onChange(of: search) { _, _ in Task { await load() } }
        }
        // A browse surface wants room. `.large` opens tall enough to show several cards, and
        // the medium detent exists so someone who only wanted a quick look can shrink it.
        .presentationDetents([.large, .medium])
        .presentationDragIndicator(.visible)
    }

    @ViewBuilder private var emptyState: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: error == nil ? "safari" : "exclamationmark.triangle")
                .font(.system(size: 30))
                .foregroundColor(VoiidColor.textSecondary)
            // Error beats empty: "nothing matches" for a failed request is a lie the user
            // cannot act on, and it hides the retry that would fix it.
            Text(error ?? (isSearching ? "No communities match that."
                                       : "Nothing to discover yet."))
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
            if error != nil {
                Button("Try again") { Task { await load() } }
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(VoiidColor.primary)
            }
        }
        .padding(.top, VoiidSpacing.xl)
    }

    private func load() async {
        let q = search.trimmingCharacters(in: .whitespacesAndNewlines)
        // A one-character term would fall back to trending server-side, which reads as the
        // list jumping back to the start mid-word. Hold the previous results instead.
        if q.count == 1 { return }

        inFlight = q
        loading = true
        defer { if inFlight == q { loading = false } }
        do {
            let found = try await CommunityService.shared.search(q)
            // Discarded if the term moved on while this was in flight.
            guard inFlight == q else { return }
            cards = found
            error = nil
        } catch {
            guard inFlight == q else { return }
            self.error = (error as? APIError)?.errorDescription ?? "Couldn’t load communities."
        }
    }
}
