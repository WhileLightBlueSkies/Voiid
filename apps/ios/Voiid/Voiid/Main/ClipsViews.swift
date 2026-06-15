//
//  ClipsViews.swift
//  Voiid
//
//  Clips: feed (Screen-9), fullscreen player (Screen-10), comments (Screen-10.5),
//  new clip upload (Screen-10.5b). Vertical-scroll short-video feed on dummy data.
//

import SwiftUI
import PhotosUI

// MARK: - Feed

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

// MARK: - Fullscreen player

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

// MARK: - Comments sheet

struct ClipCommentsView: View {
    @EnvironmentObject var clips: ClipsStore
    @State private var draft = ""
    var body: some View {
        VStack(spacing: 0) {
            Text("Comments").font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary).padding()
            Divider()
            ScrollView {
                LazyVStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    ForEach(clips.comments) { c in
                        HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                            VoiidAvatar(size: 30, imageName: c.authorPhoto)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(c.authorName).font(VoiidFont.subhead).foregroundColor(VoiidColor.textPrimary)
                                Text(c.text).font(VoiidFont.footnote).foregroundColor(VoiidColor.textSecondary)
                            }
                        }
                    }
                }.padding()
            }
            Divider()
            HStack {
                TextField("Add a comment…", text: $draft)
                    .font(VoiidFont.body).padding(.horizontal, VoiidSpacing.md).frame(height: 44)
                    .background(VoiidColor.fieldFill).clipShape(Capsule())
                Button {
                    let t = draft.trimmingCharacters(in: .whitespaces); guard !t.isEmpty else { return }
                    Haptics.tap(); clips.addComment(t); draft = ""
                } label: { Image(systemName: "arrow.up.circle.fill").font(.system(size: 30)).foregroundColor(VoiidColor.primary) }
            }.padding()
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .presentationDetents([.medium, .large])
    }
}

// MARK: - New clip upload

struct NewClipView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var description = ""
    @State private var pickerItem: PhotosPickerItem?
    @State private var picked = false

    var body: some View {
        NavigationStack {
            VStack(spacing: VoiidSpacing.md) {
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    RoundedRectangle(cornerRadius: VoiidRadius.lg)
                        .fill(VoiidColor.fieldFill)
                        .frame(height: 360)
                        .overlay(VStack(spacing: VoiidSpacing.sm) {
                            Image(systemName: picked ? "checkmark.circle.fill" : "video.badge.plus")
                                .font(.system(size: 54)).foregroundColor(VoiidColor.primary)
                            Text(picked ? "Video selected" : "Tap to pick a video")
                                .font(VoiidFont.body).foregroundColor(VoiidColor.textSecondary)
                        })
                }
                .onChange(of: pickerItem) { _, v in picked = v != nil; if picked { Haptics.success() } }

                VoiidTextField(placeholder: "Title", text: $title)
                VoiidTextField(placeholder: "Description", text: $description)
                Spacer()
                VoiidPrimaryButton(title: "Share", enabled: picked && !title.isEmpty) {
                    Haptics.success(); dismiss()
                }
            }
            .padding(VoiidSpacing.lg)
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("New Clip").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }
}
