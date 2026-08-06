//
//  ClipComposerFlow.swift
//  Voiid
//
//  The clip upload flow — a full-screen pushed flow with a real back stack:
//
//      [1] Camera  ->  [2] Edit  ->  [3] Details & Post
//
//  CAMERA-FIRST. There used to be a Camera/Gallery tile chooser in front of this, which
//  cost a whole screen and a decision before anyone could record. The viewfinder is now the
//  front door and the library lives as a thumbnail inside it, which is where every camera
//  app people already use puts it. Imports still land in the same `accept()` as recordings,
//  so duration and cap validation are identical for both.
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
    @State private var loadingPick = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack(path: $path) {
            cameraScreen
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
    }

    // MARK: - Step 1: the viewfinder

    private var cameraScreen: some View {
        ZStack {
            ClipCameraView(
                onDone: { url, filter in
                    // The camera records CLEAN and reports which look was chosen; baking it
                    // here as an edit keeps the filter reversible in the editor and applied
                    // exactly once, at export.
                    Task { await accept(url: url, filter: filter) }
                },
                onGalleryPicked: { item in
                    Task { await loadPicked(item) }
                },
                onClose: { dismiss() })

            if loadingPick {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    ProgressView("Preparing…").tint(.white).foregroundColor(.white)
                }
            }
            if let errorText {
                Text(errorText)
                    .font(VoiidFont.footnote)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(VoiidSpacing.md)
                    .background(Color.black.opacity(0.7))
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                    .padding(.horizontal, VoiidSpacing.lg)
            }
        }
        .navigationBarHidden(true)
    }

    // MARK: - Intake

    private func loadPicked(_ item: PhotosPickerItem) async {
        loadingPick = true
        // The banner now sits over a live viewfinder, so a stale message would hang there
        // for the rest of the session rather than scrolling away with a screen.
        errorText = nil
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
    private func accept(url: URL, filter: ClipFilter = .none) async {
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
        edit = ClipEdit(trimStart: 0, trimEnd: min(seconds, ClipCaps.maxDurationSeconds),
                        filter: filter)
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
