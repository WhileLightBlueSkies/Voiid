//
//  GifPickerSheet.swift
//  Voiid
//
//  GIF search, backed by our own /gifs proxy in front of Tenor.
//
//  THE PRIVACY SHAPE, which is the whole reason this is not a two-line SDK drop-in:
//    - Search goes through OUR backend, so the API key never ships in the binary and users'
//      searches don't reach Google carrying their IP.
//    - Picking a GIF DOWNLOADS it here, then hands the bytes to the normal `sendMedia` path —
//      encrypted on-device, ciphertext to R2. The recipient never touches Tenor at all.
//
//  That second point is the important one. Every other messenger sends a GIPHY/Tenor URL and
//  lets each recipient fetch it, which tells a third party who received what and when, and
//  breaks the GIF permanently if the provider removes it. Sending it as ordinary E2EE media
//  costs us bandwidth once and buys both properties back.
//

import SwiftUI

struct GifPickerSheet: View {
    /// Handed the downloaded GIF bytes. The caller encrypts and sends via the media path.
    var onPick: (Data) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""
    @State private var gifs: [GifService.Gif] = []
    @State private var loading = true
    @State private var configured = true
    @State private var downloading: String?
    @State private var searchTask: Task<Void, Never>?
    @FocusState private var searchFocused: Bool

    private let columns = [GridItem(.flexible(), spacing: 6), GridItem(.flexible(), spacing: 6)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchField
                if !configured {
                    unavailable
                } else if loading && gifs.isEmpty {
                    ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if gifs.isEmpty {
                    empty
                } else {
                    grid
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("GIFs")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    Button("Close") { dismiss() }.foregroundStyle(VoiidColor.textSecondary)
                }
            }
            .task { await load(nil) }
        }
        .tint(VoiidColor.primary)
    }

    private var searchField: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 14))
                .foregroundStyle(VoiidColor.textSecondary)
            TextField("Search GIFs", text: $query)
                .font(VoiidFont.rounded(15, .regular))
                .focused($searchFocused)
                .autocorrectionDisabled()
                .onChange(of: query) { _, q in
                    // Debounced: a fast typist should produce one request per pause, not one
                    // per keystroke — this costs us Tenor quota on every call.
                    searchTask?.cancel()
                    searchTask = Task {
                        try? await Task.sleep(nanoseconds: 300_000_000)
                        guard !Task.isCancelled else { return }
                        await load(q.isEmpty ? nil : q)
                    }
                }
            if !query.isEmpty {
                Button { query = ""; Task { await load(nil) } } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(VoiidColor.placeholder)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, 10)
        .background(VoiidColor.fieldFill)
        .clipShape(Capsule())
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.bottom, VoiidSpacing.sm)
    }

    private var grid: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(gifs) { gif in
                    Button {
                        Haptics.tap()
                        pick(gif)
                    } label: {
                        ZStack {
                            // The PREVIEW (tinygif) in the grid — a wall of full-size GIFs
                            // would burn a phone's memory and the user's data for images they
                            // are only scanning.
                            AsyncImage(url: URL(string: gif.preview)) { phase in
                                if let image = phase.image {
                                    image.resizable().scaledToFill()
                                } else {
                                    Rectangle().fill(VoiidColor.fieldFill)
                                }
                            }
                            .frame(height: 108)
                            .clipped()
                            if downloading == gif.id {
                                Color.black.opacity(0.35)
                                ProgressView().tint(.white)
                            }
                        }
                        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(downloading != nil)
                    .accessibilityLabel(gif.description.isEmpty ? "GIF" : gif.description)
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.bottom, VoiidSpacing.lg)
        }
    }

    private var empty: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 30))
                .foregroundStyle(VoiidColor.placeholder)
            Text("No GIFs found")
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundStyle(VoiidColor.textPrimary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// A build with no TENOR_API_KEY says so, rather than spinning forever.
    private var unavailable: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "exclamationmark.triangle")
                .font(.system(size: 28))
                .foregroundStyle(VoiidColor.placeholder)
            Text("GIFs aren’t set up")
                .font(VoiidFont.rounded(15, .semibold))
                .foregroundStyle(VoiidColor.textPrimary)
            Text("This build has no GIF provider configured.")
                .font(VoiidFont.rounded(13, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func load(_ q: String?) async {
        loading = true
        let result = await GifService.shared.search(q)
        gifs = result.gifs
        configured = result.configured
        loading = false
    }

    private func pick(_ gif: GifService.Gif) {
        downloading = gif.id
        Task {
            // Downloaded HERE and handed over as bytes — never as a URL. The recipient's
            // device must never contact Tenor.
            if let data = await GifService.shared.download(gif.url) {
                dismiss()
                onPick(data)
            }
            downloading = nil
        }
    }
}
