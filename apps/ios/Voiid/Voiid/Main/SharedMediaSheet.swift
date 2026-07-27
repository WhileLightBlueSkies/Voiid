//
//  SharedMediaSheet.swift
//  Voiid
//
//  "See all" shared media — segmented Photos / Videos / Voice / Documents.
//  Used by both Group Info and 1:1 Contact Profile.
//

import SwiftUI

struct SharedMediaSheet: View {
    let title: String
    /// The conversation whose REAL shared media (from the decrypted message store) is shown.
    let conversationId: String
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .photos
    @Namespace private var underline

    enum Tab: String, CaseIterable { case photos = "Photos", videos = "Videos", voice = "Voice", docs = "Docs" }

    private let grid = [GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3)]

    /// Every media attachment in this conversation, newest first, straight from the store.
    private var mediaRefs: [MediaRef] {
        ChatEngine.shared.messages(conversationId: conversationId)
            .compactMap { $0.media }.reversed()
    }
    private var photos: [MediaRef] { mediaRefs.filter { $0.mime.hasPrefix("image/") } }
    private var videos: [MediaRef] { mediaRefs.filter { $0.mime.hasPrefix("video/") } }
    private var voice: [MediaRef]  { mediaRefs.filter { $0.mime.hasPrefix("audio/") } }
    private var docs: [MediaRef]   { mediaRefs.filter {
        !$0.mime.hasPrefix("image/") && !$0.mime.hasPrefix("video/") && !$0.mime.hasPrefix("audio/") } }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabs
                ScrollView {
                    switch tab {
                    case .photos: mediaGrid(photos, isVideo: false)
                    case .videos: mediaGrid(videos, isVideo: true)
                    case .voice:  refList(voice, icon: "mic.fill", label: "Voice message")
                    case .docs:   refList(docs, icon: "doc.fill", label: "Document")
                    }
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Shared media").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
    }

    @ViewBuilder private func mediaGrid(_ refs: [MediaRef], isVideo: Bool) -> some View {
        if refs.isEmpty { emptyState(isVideo ? "No videos yet" : "No photos yet") }
        else {
            LazyVGrid(columns: grid, spacing: 3) {
                ForEach(refs, id: \.mediaUrl) { ref in
                    SharedMediaThumb(ref: ref).aspectRatio(1, contentMode: .fill).clipped()
                        .clipShape(RoundedRectangle(cornerRadius: 4))
                }
            }
            .padding(3)
        }
    }

    @ViewBuilder private func refList(_ refs: [MediaRef], icon: String, label: String) -> some View {
        if refs.isEmpty { emptyState("Nothing here yet") }
        else {
            LazyVStack(spacing: 0) {
                ForEach(refs, id: \.mediaUrl) { _ in
                    HStack(spacing: VoiidSpacing.md) {
                        Image(systemName: icon).font(.system(size: 18)).foregroundColor(VoiidColor.primary)
                            .frame(width: 44, height: 44)
                            .background(VoiidColor.fieldFill).clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md))
                        Text(label).font(VoiidFont.rounded(15, .regular)).foregroundColor(VoiidColor.textPrimary)
                        Spacer()
                    }
                    .padding(.horizontal, VoiidSpacing.lg).padding(.vertical, VoiidSpacing.sm)
                    Divider().background(VoiidColor.divider.opacity(0.3)).padding(.leading, 72)
                }
            }
            .padding(.top, VoiidSpacing.sm)
        }
    }

    private func emptyState(_ text: String) -> some View {
        Text(text).font(VoiidFont.rounded(14, .regular)).foregroundColor(VoiidColor.textSecondary)
            .frame(maxWidth: .infinity).padding(.top, 60)
    }

    private var tabs: some View {
        HStack(spacing: 0) {
            ForEach(Tab.allCases, id: \.self) { t in
                Button {
                    Haptics.selection()
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.8)) { tab = t }
                } label: {
                    VStack(spacing: 6) {
                        Text(t.rawValue)
                            .font(VoiidFont.rounded(14, .semibold))
                            .foregroundColor(tab == t ? VoiidColor.primary : VoiidColor.textSecondary)
                        ZStack {
                            Capsule().fill(.clear).frame(height: 3)
                            if tab == t {
                                Capsule().fill(VoiidColor.primary).frame(height: 3)
                                    .matchedGeometryEffect(id: "u", in: underline)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.top, VoiidSpacing.sm)
        .overlay(VoiidColor.divider.opacity(0.4).frame(height: 1), alignment: .bottom)
    }

}

/// A real decrypted media thumbnail (local-first via MediaCache), reused by the shared-media
/// grid AND the Group Info / Contact Profile "Media, links & docs" strips.
struct SharedMediaThumb: View {
    let ref: MediaRef
    @State private var image: UIImage?
    var body: some View {
        ZStack {
            if let image { Image(uiImage: image).resizable().scaledToFill() }
            else { RoundedRectangle(cornerRadius: 4).fill(VoiidColor.accent.opacity(0.25))
                .overlay(ProgressView()) }
        }
        .task(id: ref.mediaUrl) {
            if let hit = MediaCache.shared.image(ref.mediaUrl) { image = hit; return }
            if let data = try? await ChatEngine.shared.fetchMedia(ref) {
                MediaCache.shared.setData(data, ref.mediaUrl)
                image = UIImage(data: data)
            }
        }
    }
}
