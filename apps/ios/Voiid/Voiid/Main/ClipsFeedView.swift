//
//  ClipsFeedView.swift
//  Voiid
//
//  Clips feed (Figma Screen-9) — short-video feed on dummy data.
//

import SwiftUI

struct ClipsFeedView: View {
    @EnvironmentObject var clips: ClipsStore
    @State private var openFullscreen: VClip?
    @State private var showUpload = false

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                header
                ScrollView {
                    LazyVStack(spacing: VoiidSpacing.lg) {
                        ForEach(clips.clips) { clip in
                            Button { Haptics.tap(); openFullscreen = clip } label: { card(clip) }
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.top, VoiidSpacing.md)
                    .padding(.bottom, 100)
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .fullScreenCover(item: $openFullscreen) { ClipFullscreenView(clip: $0) }
            .sheet(isPresented: $showUpload) { NewClipView() }
        }
    }

    private var header: some View {
        HStack {
            Text("Clips").font(VoiidFont.display).foregroundColor(VoiidColor.textPrimary)
            Spacer()
            Button { showUpload = true } label: {
                Image(systemName: "plus.circle.fill").font(.system(size: 28)).foregroundColor(VoiidColor.primary)
            }
            Image(systemName: "video.fill").font(.system(size: 22)).foregroundColor(VoiidColor.primary)
                .padding(.leading, VoiidSpacing.sm)
        }
        .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
    }

    private func card(_ clip: VClip) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack(spacing: VoiidSpacing.sm) {
                VoiidAvatar(size: 35, imageName: clip.authorPhoto)
                Text(clip.authorName).font(VoiidFont.subhead).foregroundColor(VoiidColor.textPrimary)
            }
            RoundedRectangle(cornerRadius: VoiidRadius.lg)
                .fill(LinearGradient(colors: [VoiidColor.primary.opacity(0.7), VoiidColor.accent],
                                     startPoint: .top, endPoint: .bottom))
                .aspectRatio(1, contentMode: .fit)
                .overlay(Image(systemName: "play.circle.fill").font(.system(size: 54)).foregroundColor(.white.opacity(0.9)))
            HStack(spacing: VoiidSpacing.lg) {
                Label("\(clip.likes)", systemImage: "heart").font(VoiidFont.subhead)
                Label("\(clip.comments)", systemImage: "bubble.right").font(VoiidFont.subhead)
            }
            .foregroundColor(VoiidColor.textSecondary)
        }
        .padding(VoiidSpacing.sm)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
    }
}
