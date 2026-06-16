//
//  ClipFullscreenView.swift
//  Voiid
//
//  Instagram-Reels-style fullscreen player. Tap comments/caption -> the reel
//  shrinks into a box at the top and the comments panel slides up below it.
//

import SwiftUI

struct ClipFullscreenView: View {
    let clip: VClip
    @EnvironmentObject var clips: ClipsStore
    @Environment(\.dismiss) private var dismiss
    @State private var liked = false
    @State private var showComments = false
    @State private var commentDraft = ""

    var body: some View {
        GeometryReader { geo in
            VStack(spacing: 0) {
                // The reel — full screen normally; shrinks to a top box when comments open.
                reel
                    .frame(height: showComments ? geo.size.height * 0.42 : geo.size.height)
                    .clipped()

                if showComments {
                    commentsPanel
                        .frame(height: geo.size.height * 0.58)
                        .transition(.move(edge: .bottom))
                }
            }
            .animation(.spring(response: 0.4, dampingFraction: 0.85), value: showComments)
        }
        .background(Color.black.ignoresSafeArea())
        .ignoresSafeArea(.keyboard)
    }

    // MARK: reel

    private var reel: some View {
        ZStack {
            LinearGradient(colors: [VoiidColor.primary, .black], startPoint: .top, endPoint: .bottom)
            Image(systemName: "play.circle.fill").font(.system(size: 64)).foregroundColor(.white.opacity(0.85))

            VStack {
                HStack {
                    Button { showComments ? closeComments() : dismiss() } label: {
                        Image(systemName: showComments ? "chevron.down" : "chevron.left")
                            .font(.title2).foregroundColor(.white)
                    }
                    Spacer()
                }
                .padding()
                Spacer()
                HStack(alignment: .bottom) {
                    VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                        HStack { VoiidAvatar(size: 44).clipShape(Circle())
                            Text(clip.authorName).font(VoiidFont.rounded(15, .semibold)).foregroundColor(.white) }
                        if !showComments {
                            Text(clip.heading).font(VoiidFont.rounded(14, .regular)).foregroundColor(.white)
                            // Tapping the caption opens comments (per request)
                            Button { openComments() } label: {
                                Text(clip.caption).font(VoiidFont.rounded(12, .regular))
                                    .foregroundColor(.white.opacity(0.85)).underline()
                            }
                        }
                    }
                    Spacer()
                    if !showComments {
                        VStack(spacing: VoiidSpacing.lg) {
                            action(liked ? "heart.fill" : "heart", "\(clip.likes + (liked ? 1 : 0))",
                                   liked ? VoiidColor.error : .white) {
                                Haptics.tap(); liked.toggle(); if liked { clips.toggleLike(clip) }
                            }
                            action("bubble.right.fill", "\(clip.comments)", .white) { openComments() }
                            action("paperplane.fill", "Share", .white) {}
                        }
                    }
                }
                .padding()
            }
        }
    }

    // MARK: comments panel (slides up below the shrunken reel)

    private var commentsPanel: some View {
        VStack(spacing: 0) {
            Capsule().fill(VoiidColor.divider).frame(width: 40, height: 4).padding(.vertical, VoiidSpacing.sm)
            HStack {
                Text("\(clips.comments.count) comments")
                    .font(VoiidFont.rounded(15, .semibold)).foregroundColor(VoiidColor.textPrimary)
                Spacer()
                Button { closeComments() } label: {
                    Image(systemName: "xmark").foregroundColor(VoiidColor.textSecondary)
                }
            }
            .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.sm)
            Divider()

            ScrollView {
                LazyVStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    ForEach(clips.comments) { c in
                        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                            VoiidAvatar(size: 32, imageName: c.authorPhoto).clipShape(Circle())
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.authorName).font(VoiidFont.rounded(13, .semibold)).foregroundColor(VoiidColor.textPrimary)
                                Text(c.text).font(VoiidFont.rounded(14, .regular)).foregroundColor(VoiidColor.textPrimary)
                            }
                            Spacer()
                            Image(systemName: "heart").font(.system(size: 13)).foregroundColor(VoiidColor.textSecondary)
                        }
                    }
                }
                .padding(VoiidSpacing.lg)
            }

            Divider()
            HStack(spacing: VoiidSpacing.sm) {
                TextField("", text: $commentDraft,
                          prompt: Text("Add a comment…").foregroundColor(VoiidColor.placeholder))
                    .font(VoiidFont.rounded(15, .regular)).foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.md).frame(height: 44)
                    .background(VoiidColor.fieldFill).clipShape(Capsule())
                Button {
                    let t = commentDraft.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
                    Haptics.tap(); clips.addComment(t); commentDraft = ""
                } label: {
                    Image(systemName: "paperplane.fill").font(.system(size: 22)).foregroundColor(VoiidColor.primary)
                }
            }
            .padding(.horizontal, VoiidSpacing.md).padding(.vertical, VoiidSpacing.sm)
        }
        .background(VoiidColor.background)
        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
    }

    private func openComments() { Haptics.tap(); withAnimation { showComments = true } }
    private func closeComments() { withAnimation { showComments = false } }

    private func action(_ icon: String, _ label: String, _ color: Color, _ tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            VStack(spacing: 4) {
                Image(systemName: icon).font(.system(size: 26)).foregroundColor(color)
                Text(label).font(VoiidFont.rounded(11, .medium)).foregroundColor(.white)
            }
        }
    }
}
