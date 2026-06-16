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
    @Environment(\.dismiss) private var dismiss
    @State private var tab: Tab = .photos
    @Namespace private var underline

    enum Tab: String, CaseIterable { case photos = "Photos", videos = "Videos", voice = "Voice", docs = "Docs" }

    private let grid = [GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3),
                        GridItem(.flexible(), spacing: 3)]

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                tabs
                ScrollView {
                    switch tab {
                    case .photos: photoGrid(DummyData.sharedPhotos)
                    case .videos: photoGrid(DummyData.sharedVideos)
                    case .voice:  list(DummyData.sharedVoice, icon: "mic.fill")
                    case .docs:   list(DummyData.sharedDocs, icon: "doc.fill")
                    }
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Shared media").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Done") { dismiss() } } }
        }
        .presentationDetents([.large])
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

    private func photoGrid(_ items: [VMediaItem]) -> some View {
        LazyVGrid(columns: grid, spacing: 3) {
            ForEach(items) { item in
                RoundedRectangle(cornerRadius: 4)
                    .fill(VoiidColor.accent.opacity(0.35))
                    .aspectRatio(1, contentMode: .fit)
                    .overlay(
                        Image(systemName: item.kind == .video ? "play.circle.fill" : "photo")
                            .font(.system(size: 24)).foregroundColor(VoiidColor.primary)
                    )
                    .overlay(alignment: .bottomTrailing) {
                        if item.kind == .video, !item.title.isEmpty {
                            Text(item.title).font(VoiidFont.rounded(10, .medium)).foregroundColor(.white)
                                .padding(3).background(.black.opacity(0.4)).clipShape(Capsule()).padding(4)
                        }
                    }
            }
        }
        .padding(3)
    }

    private func list(_ items: [VMediaItem], icon: String) -> some View {
        LazyVStack(spacing: 0) {
            ForEach(items) { item in
                HStack(spacing: VoiidSpacing.md) {
                    Image(systemName: icon).font(.system(size: 18)).foregroundColor(VoiidColor.primary)
                        .frame(width: 44, height: 44)
                        .background(VoiidColor.fieldFill).clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md))
                    Text(item.title.isEmpty ? "Item" : item.title)
                        .font(VoiidFont.rounded(15, .regular)).foregroundColor(VoiidColor.textPrimary)
                    Spacer()
                    Image(systemName: "chevron.right").font(.system(size: 13)).foregroundColor(VoiidColor.textSecondary)
                }
                .padding(.horizontal, VoiidSpacing.lg).padding(.vertical, VoiidSpacing.sm)
                Divider().background(VoiidColor.divider.opacity(0.3)).padding(.leading, 72)
            }
        }
        .padding(.top, VoiidSpacing.sm)
    }
}
