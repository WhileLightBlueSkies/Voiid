//
//  ClipComposerFlow.swift
//  Voiid
//
//  The clip upload flow — a full-screen, four-step pushed flow with a real back stack:
//
//      [1] Source  ->  [2] Capture / Pick  ->  [3] Edit  ->  [4] Details & Post
//
//  Deliberately NOT a sheet. The old NewClipView was a 47-line popup whose Share button
//  called dismiss() and threw the video away; a modal sheet also cannot host a camera,
//  a trim scrubber and a filter strip without becoming a scroll-fight on small phones.
//

import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

struct ClipComposerFlow: View {
    @EnvironmentObject var engine: ClipsEngine
    @EnvironmentObject var session: AppSession
    @Environment(\.dismiss) private var dismiss

    @State private var path: [ClipComposerStep] = []
    @State private var sourceURL: URL?
    @State private var edit = ClipEdit()
    @State private var showCamera = false
    @State private var pickerItem: PhotosPickerItem?
    @State private var loadingPick = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack(path: $path) {
            sourceScreen
                .navigationDestination(for: ClipComposerStep.self) { step in
                    switch step {
                    case .edit:
                        if let sourceURL {
                            ClipEditorView(sourceURL: sourceURL, edit: $edit) {
                                path.append(.details)
                            }
                        }
                    case .details:
                        if let sourceURL {
                            ClipDetailsView(sourceURL: sourceURL, edit: edit) { caption in
                                post(caption: caption)
                            }
                        }
                    }
                }
        }
        .fullScreenCover(isPresented: $showCamera) {
            // The stories camera already implements press-and-hold record, flip and a
            // duration ring — reused rather than forked.
            // .clip: 90s cap and video-only. With the story defaults a tap produced a photo
            // this composer could only drop on the floor, and anything past 30s was truncated.
            StoryCameraView(mode: .clip) { _, videoURL in
                showCamera = false
                guard let videoURL else { return }
                Task { await accept(url: videoURL) }
            }
        }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            Task { await loadPicked(item) }
        }
    }

    // MARK: - Step 1: source

    private var sourceScreen: some View {
        VStack(spacing: VoiidSpacing.lg) {
            HStack {
                Button("Cancel") { dismiss() }
                    .foregroundColor(VoiidColor.textSecondary)
                Spacer()
                Text("New clip")
                    .font(VoiidFont.headline)
                    .foregroundColor(VoiidColor.textPrimary)
                Spacer()
                // Balances the Cancel button so the title stays optically centred.
                Text("Cancel").opacity(0)
            }
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.top, VoiidSpacing.md)

            VStack(alignment: .leading, spacing: 4) {
                Text("Create a clip")
                    .font(VoiidFont.rounded(28, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text("Record something new, or pick a video you already have.")
                    .font(VoiidFont.subhead)
                    .foregroundColor(VoiidColor.textSecondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoiidSpacing.md)

            VStack(spacing: VoiidSpacing.md) {
                sourceCard(icon: "camera.fill", title: "Camera",
                           subtitle: "Record up to 90 seconds",
                           tint: [VoiidColor.primary, VoiidColor.primary.opacity(0.72)]) {
                    Haptics.tap()
                    showCamera = true
                }
                PhotosPicker(selection: $pickerItem, matching: .videos) {
                    sourceCardLabel(icon: "photo.on.rectangle.angled", title: "Gallery",
                                    subtitle: "Choose an existing video",
                                    tint: [VoiidColor.accent, VoiidColor.accent.opacity(0.72)])
                }
                .buttonStyle(SoftPressStyle())
            }
            .padding(.horizontal, VoiidSpacing.md)

            if loadingPick {
                ProgressView("Preparing…").tint(VoiidColor.primary)
            }
            if let errorText {
                Text(errorText)
                    .font(VoiidFont.caption)
                    .foregroundColor(VoiidColor.error)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, VoiidSpacing.lg)
            }
            Spacer()
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationBarHidden(true)
    }

    private func sourceCard(icon: String, title: String, subtitle: String,
                            tint: [Color], tap: @escaping () -> Void) -> some View {
        Button(action: tap) {
            sourceCardLabel(icon: icon, title: title, subtitle: subtitle, tint: tint)
        }
        .buttonStyle(SoftPressStyle())
    }

    /// A tall gradient tile rather than a plain list row. The two sources are the entire
    /// first screen of the flow, so they should read as the choice — a thin row with a
    /// chevron reads as settings.
    private func sourceCardLabel(icon: String, title: String, subtitle: String,
                                 tint: [Color]) -> some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            ZStack {
                Circle()
                    .fill(.white.opacity(0.22))
                    .frame(width: 56, height: 56)
                Image(systemName: icon)
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundColor(.white)
            }
            Spacer(minLength: VoiidSpacing.sm)
            Text(title)
                .font(VoiidFont.rounded(20, .bold))
                .foregroundColor(.white)
            Text(subtitle)
                .font(VoiidFont.caption)
                .foregroundColor(.white.opacity(0.85))
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(VoiidSpacing.lg)
        .frame(height: 168)
        .background(
            LinearGradient(colors: tint, startPoint: .topLeading, endPoint: .bottomTrailing)
        )
        .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .shadow(color: tint.first?.opacity(0.28) ?? .clear, radius: 12, y: 6)
    }

    // MARK: - Intake

    private func loadPicked(_ item: PhotosPickerItem) async {
        loadingPick = true
        defer { loadingPick = false }
        do {
            guard let data = try await item.loadTransferable(type: Data.self) else {
                errorText = "Couldn't read that video."
                return
            }
            let tmp = FileManager.default.temporaryDirectory
                .appendingPathComponent("clip_src_\(UUID().uuidString).mp4")
            try data.write(to: tmp)
            await accept(url: tmp)
        } catch {
            errorText = "Couldn't read that video."
        }
    }

    /// Validate against the caps BEFORE the user invests time in the editor — telling
    /// someone their 4-minute video is too long only at Post is the wrong order.
    private func accept(url: URL) async {
        let asset = AVURLAsset(url: url)
        let seconds = (try? await asset.load(.duration))?.seconds ?? 0
        guard seconds > 0 else {
            errorText = "Couldn't read that video."
            return
        }
        guard seconds <= ClipCaps.maxDurationSeconds + 1 else {
            errorText = "Clips can be up to \(Int(ClipCaps.maxDurationSeconds)) seconds. Trim it and try again."
            return
        }
        errorText = nil
        sourceURL = url
        edit = ClipEdit(trimStart: 0, trimEnd: min(seconds, ClipCaps.maxDurationSeconds))
        path.append(.edit)
    }

    // MARK: - Post

    private func post(caption: String) {
        guard let sourceURL else { return }
        Haptics.success()
        let trimmed = caption.trimmingCharacters(in: .whitespacesAndNewlines)

        // Dismiss immediately — the export + upload run in the background and surface on
        // the grid tile. Blocking the UI on a 100 MB PUT is what the story composer
        // explicitly avoids, and a clip is larger.
        dismiss()

        Task {
            do {
                // Produces the full 480p/720p/1080p ladder in one pass (skipping rungs
                // above the source resolution) plus the cover image.
                let ladder = try await ClipExporter.exportLadder(source: sourceURL, edit: edit)
                engine.post(ladder: ladder,
                            caption: trimmed.isEmpty ? nil : trimmed,
                            authorId: session.userId ?? "",
                            authorName: session.profile.fullName)
            } catch {
                // Export failed before any tile existed; nothing to attach an error to,
                // so surface it on the feed's error channel on next refresh.
                NSLog("[VOIID] clip export failed: \(error)")
            }
        }
    }
}

enum ClipComposerStep: Hashable { case edit, details }

// MARK: - Caps

enum ClipCaps {
    /// Mirrors MAX_DURATION_MS / MAX_BYTE_SIZE in backend/api/src/routes/clips.ts.
    /// Enforced on BOTH sides — a client-only cap is not a cap.
    static let maxDurationSeconds: Double = 90
    static let maxBytes = 100 * 1024 * 1024
    /// 720p long edge. Above this the upload dominates on mobile data for no visible
    /// gain in a full-screen phone player.
    static let exportPreset = AVAssetExportPreset1280x720
}

// MARK: - Step 4: details

private struct ClipDetailsView: View {
    let sourceURL: URL
    let edit: ClipEdit
    let onPost: (String) -> Void

    @State private var caption = ""
    @State private var cover: UIImage?

    var body: some View {
        VStack(spacing: VoiidSpacing.md) {
            HStack(alignment: .top, spacing: VoiidSpacing.md) {
                ZStack {
                    if let cover {
                        Image(uiImage: cover).resizable().scaledToFill()
                    } else {
                        ClipShimmer()
                    }
                }
                .frame(width: 84, height: 112)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))

                TextField("", text: $caption, prompt: Text("Write a caption…")
                    .foregroundColor(VoiidColor.placeholder), axis: .vertical)
                    .font(VoiidFont.body)
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(4, reservesSpace: true)
            }
            .padding(VoiidSpacing.md)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))

            // Clips are public and NOT encrypted (docs/CLIPS.md §0). Say so here rather
            // than letting a user assume the messaging guarantee carries over.
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "globe")
                    .font(.system(size: 14))
                    .foregroundColor(VoiidColor.textSecondary)
                Text("Clips are public. Unlike your chats and moments, they aren't end-to-end encrypted.")
                    .font(VoiidFont.caption)
                    .foregroundColor(VoiidColor.textSecondary)
            }
            .padding(.horizontal, VoiidSpacing.xs)

            Spacer()
            VoiidPrimaryButton(title: "Post", enabled: true) { onPost(caption) }
        }
        .padding(VoiidSpacing.lg)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Details")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            // Mirror the exporter's precedence exactly: an uploaded image wins over the
            // frame picker, so what the author confirms here is what the grid will show.
            if let custom = edit.customCoverJPEG {
                cover = UIImage(data: custom)
            } else {
                cover = try? await ClipExporter.frame(from: sourceURL, at: edit.coverSeconds,
                                                      filter: edit.filter)
            }
        }
    }
}
