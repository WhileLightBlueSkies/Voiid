//
//  GifPickerSheet.swift
//  Voiid
//
//  GIF search, backed by our own /gifs proxy in front of GIPHY.
//
//  THE PRIVACY SHAPE, which is the whole reason this is not a two-line SDK drop-in:
//    - Search goes through OUR backend, so the API key never ships in the binary and users'
//      searches don't reach Google carrying their IP.
//    - Picking a GIF DOWNLOADS it here, then hands the bytes to the normal `sendMedia` path —
//      encrypted on-device, ciphertext to R2. The recipient never touches GIPHY at all.
//
//  That second point is the important one. Every other messenger sends a provider URL and
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
    @State private var failedPick = false
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

                // REQUIRED, not decorative. GIPHY's API terms oblige us to show a
                // "Powered By GIPHY" mark wherever the API is used, so it sits outside the
                // grid — pinned, and visible in the empty and no-results states too, which
                // a mark placed inside the scrolling results would not be.
                if configured { poweredByGiphy }
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
            .alert("Couldn't add that GIF", isPresented: $failedPick) {
                Button("OK", role: .cancel) {}
            } message: {
                Text("It may be too large or no longer available. Try another one.")
            }
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
                    // per keystroke — this costs us GIPHY quota on every call.
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
                            // A real surface under the preview, so a cell that is still
                            // loading is visibly a cell rather than a hole in the grid.
                            VoiidColor.fieldFill

                            // The PREVIEW (tinygif) in the grid — a wall of full-size GIFs
                            // would burn a phone's memory and the user's data for images they
                            // are only scanning.
                            //
                            // RemoteGifView, not AsyncImage: AsyncImage decodes a GIF to its
                            // first frame, so this grid was a wall of stills. Picking a GIF
                            // from a still is guesswork — the whole point is the motion.
                            RemoteGifView(url: gif.preview)
                                .frame(height: 108)
                                .clipped()
                            if downloading == gif.id {
                                Color.black.opacity(0.35)
                                ProgressView().tint(.white)
                            }
                        }
                        .frame(maxWidth: .infinity)
                        .frame(height: 108)
                        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                        // THE WHOLE CELL IS THE TAP TARGET.
                        //
                        // Without this the button had nothing hit-testable in it: the only
                        // thing inside is RemoteGifView, which sets allowsHitTesting(false)
                        // so its hosted UIImageView cannot swallow the touch, and a ZStack
                        // with no background has no area of its own. The result was a cell
                        // that looked tappable and did nothing at all.
                        .contentShape(RoundedRectangle(cornerRadius: VoiidRadius.md,
                                                       style: .continuous))
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

    /// The attribution GIPHY's terms require. Drawn rather than shipped as an image asset:
    /// one line of text needs no bitmap, scales with Dynamic Type, and stays crisp on every
    /// screen. If GIPHY ever requires their exact wordmark, swap this for the official asset.
    private var poweredByGiphy: some View {
        HStack(spacing: 5) {
            Image(systemName: "bolt.horizontal.fill")
                .font(.system(size: 9, weight: .bold))
            Text("POWERED BY GIPHY")
                .font(VoiidFont.rounded(10, .bold))
                .kerning(0.6)
        }
        .foregroundStyle(VoiidColor.textSecondary)
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
        .background(VoiidColor.background)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Powered by GIPHY")
    }

    /// A build with no GIPHY_API_KEY says so, rather than spinning forever.
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
            // device must never contact GIPHY.
            // HAND OVER FIRST, THEN DISMISS. The other way round, `dismiss()` begins tearing
            // this view down and `onPick` — a closure owned by it — never reaches the
            // parent, so picking a GIF silently sent nothing.
            if let data = await GifService.shared.download(gif.url) {
                onPick(data)
                dismiss()
            } else {
                // Say so. A failed download used to just clear the spinner, which is
                // indistinguishable from a tap that did not register.
                Haptics.error()
                failedPick = true
            }
            downloading = nil
        }
    }
}
