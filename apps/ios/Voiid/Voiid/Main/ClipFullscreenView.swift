//
//  ClipFullscreenView.swift
//  Voiid
//
//  Clips fullscreen player (Figma Screen-10) — like / comment / share.
//

import SwiftUI

struct ClipFullscreenView: View {
    let clip: VClip
    @EnvironmentObject var clips: ClipsStore
    @Environment(\.dismiss) private var dismiss
    @State private var liked = false
    @State private var showComments = false

    var body: some View {
        ZStack {
            LinearGradient(colors: [VoiidColor.primary, .black], startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
            VStack {
                HStack {
                    Button { dismiss() } label: { Image(systemName: "chevron.left").font(.title2).foregroundColor(.white) }
                    Spacer()
                }.padding()
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                        HStack { VoiidAvatar(size: 53); Text(clip.authorName).font(VoiidFont.headline).foregroundColor(.white) }
                        Text(clip.heading).font(VoiidFont.subhead).foregroundColor(.white)
                        Text(clip.caption).font(VoiidFont.footnote).foregroundColor(.white.opacity(0.8))
                    }
                    Spacer()
                    VStack(spacing: VoiidSpacing.lg) {
                        action(liked ? "heart.fill" : "heart", "\(clip.likes + (liked ? 1 : 0))", liked ? VoiidColor.error : .white) {
                            Haptics.tap(); liked.toggle(); if liked { clips.toggleLike(clip) }
                        }
                        action("bubble.right", "\(clip.comments)", .white) { showComments = true }
                        action("paperplane", "Share", .white) {}
                    }
                }.padding()
            }
        }
        .sheet(isPresented: $showComments) { ClipCommentsView() }
    }

    private func action(_ icon: String, _ label: String, _ color: Color, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 28)).foregroundColor(color)
                Text(label).font(VoiidFont.caption).foregroundColor(.white)
            }
        }
    }
}
