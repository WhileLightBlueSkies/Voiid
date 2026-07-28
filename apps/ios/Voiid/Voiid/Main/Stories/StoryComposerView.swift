//
//  StoryComposerView.swift
//  Voiid
//
//  Capture-or-pick → preview + caption → audience chip → Share. The story posts
//  optimistically (StoryEngine handles the background upload + fan-out), so Share dismisses
//  immediately and never blocks on a 50 MB upload.
//
//  HARD CAPS are enforced HERE, before any bytes reach the engine (§8.2): the crypto holds
//  the blob in memory twice and copies it across the FFI twice, there is no streaming
//  encryption, so the caps are non-negotiable. Images re-encode to JPEG (long edge ≤1920,
//  q0.8, ≤10 MB); video must be ≤30 s and re-encodes to H.264 720p (≤50 MB).
//

import SwiftUI
import PhotosUI
import AVFoundation
import UIKit

struct StoryComposerView: View {
    @Environment(\.dismiss) private var dismiss

    @State private var pickerItem: PhotosPickerItem?
    @State private var previewImage: UIImage?
    @State private var pickedVideoURL: URL?
    @State private var caption = ""
    @State private var showCamera = false
    @State private var showAudience = false
    @State private var processing = false
    @State private var errorText: String?

    // Audience: pre-selected with every contact you can reach (§2.2), or the last custom set.
    @State private var audience: Set<String> = []

    /// Everyone reachable — the directory UNION 1:1 conversation peers. Using the directory
    /// alone silently excluded anyone you chat with but never saved as a contact, so their
    /// story never reached them. See UserDirectory.storyReachableUserIds().
    private var everyoneIds: Set<String> {
        UserDirectory.shared.storyReachableUserIds()
    }
    private var audienceLabel: String {
        audience.count == everyoneIds.count ? "My Contacts (\(audience.count))" : "Custom (\(audience.count))"
    }
    private var hasMedia: Bool { previewImage != nil || pickedVideoURL != nil }

    var body: some View {
        NavigationStack {
            VStack(spacing: VoiidSpacing.md) {
                preview
                if hasMedia {
                    VoiidTextField(placeholder: "Add a caption…", text: $caption)
                    audienceChip
                }
                if let errorText {
                    Text(errorText).font(VoiidFont.caption).foregroundColor(VoiidColor.error)
                        .multilineTextAlignment(.center)
                }
                Spacer()
                VoiidPrimaryButton(title: processing ? "Preparing…" : "Share",
                                   enabled: hasMedia && !audience.isEmpty && !processing) { share() }
            }
            .padding(VoiidSpacing.lg)
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("New Story").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
            .onAppear { if audience.isEmpty { audience = Set(StorySettings.shared.lastCustomAudience ?? Array(everyoneIds)) } }
            .onChange(of: pickerItem) { _, item in Task { await loadPicked(item) } }
            .fullScreenCover(isPresented: $showCamera) {
                StoryCameraView { photo, video in Task { await handleCamera(photo: photo, video: video) } }
            }
            .sheet(isPresented: $showAudience) { StoryAudiencePickerView(selected: $audience) }
        }
    }

    // MARK: - Preview / source picker

    @ViewBuilder private var preview: some View {
        if let previewImage {
            Image(uiImage: previewImage).resizable().scaledToFit()
                .frame(maxHeight: 420).clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg))
        } else if pickedVideoURL != nil {
            RoundedRectangle(cornerRadius: VoiidRadius.lg).fill(Color.black)
                .frame(height: 420)
                .overlay(Image(systemName: "video.fill").font(.system(size: 44)).foregroundColor(.white.opacity(0.8)))
        } else {
            VStack(spacing: VoiidSpacing.md) {
                Button { showCamera = true } label: {
                    sourceTile(icon: "camera.fill", label: "Camera")
                }
                PhotosPicker(selection: $pickerItem, matching: .any(of: [.images, .videos])) {
                    sourceTile(icon: "photo.on.rectangle", label: "Gallery")
                }
            }
        }
    }

    private func sourceTile(icon: String, label: String) -> some View {
        RoundedRectangle(cornerRadius: VoiidRadius.lg).fill(VoiidColor.fieldFill)
            .frame(height: 180)
            .overlay(VStack(spacing: VoiidSpacing.sm) {
                Image(systemName: icon).font(.system(size: 40)).foregroundColor(VoiidColor.primary)
                Text(label).font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
            })
    }

    private var audienceChip: some View {
        Button { showAudience = true } label: {
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "person.2.fill").foregroundColor(VoiidColor.primary)
                Text(audienceLabel).foregroundColor(VoiidColor.textPrimary)
                Spacer()
                Image(systemName: "chevron.right").font(.caption).foregroundColor(VoiidColor.placeholder)
            }
            .padding(.horizontal, VoiidSpacing.md).frame(height: 52)
            .background(VoiidColor.surfaceCard).clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md))
        }
    }

    // MARK: - Media loading

    private func loadPicked(_ item: PhotosPickerItem?) async {
        guard let item else { return }
        errorText = nil
        if let data = try? await item.loadTransferable(type: Data.self) {
            // Images decode to a UIImage; anything else is treated as a video payload.
            if let img = UIImage(data: data) {
                previewImage = img; pickedVideoURL = nil
            } else {
                let url = FileManager.default.temporaryDirectory.appendingPathComponent("pick_\(UUID().uuidString).mov")
                try? data.write(to: url)
                await handleCamera(photo: nil, video: url)
            }
        }
    }

    private func handleCamera(photo: Data?, video: URL?) async {
        if let photo, let img = UIImage(data: photo) { previewImage = img; pickedVideoURL = nil }
        else if let video {
            let seconds = try? await AVURLAsset(url: video).load(.duration).seconds
            if let seconds, seconds > 31 { errorText = "Stories can be up to 30 seconds"; pickedVideoURL = nil; return }
            pickedVideoURL = video; previewImage = nil
        }
    }

    // MARK: - Share (enforce caps, re-encode, post optimistically)

    private func share() {
        processing = true
        errorText = nil
        let cap = caption
        let ids = Array(audience)
        StorySettings.shared.rememberAudience(ids, isCustom: audience.count != everyoneIds.count)
        Task {
            do {
                if let img = previewImage {
                    let (data, w, h) = try encodeImage(img)
                    await StoryEngine.shared.postStory(mediaData: data, mime: "image/jpeg", caption: cap,
                                                       width: w, height: h, durationMs: nil, audienceUserIds: ids)
                } else if let video = pickedVideoURL {
                    let (data, w, h, ms) = try await encodeVideo(video)
                    await StoryEngine.shared.postStory(mediaData: data, mime: "video/mp4", caption: cap,
                                                       width: w, height: h, durationMs: ms, audienceUserIds: ids)
                }
                dismiss()
            } catch let e as CapError {
                processing = false; errorText = e.message
            } catch {
                processing = false; errorText = "Couldn't prepare that media."
            }
        }
    }

    private enum CapError: Error { case tooBig(String); var message: String { if case .tooBig(let m) = self { return m }; return "" } }

    /// Re-encode an image to JPEG, long edge ≤1920, quality 0.8, ≤10 MB plaintext.
    private func encodeImage(_ image: UIImage) throws -> (Data, Int, Int) {
        let maxEdge: CGFloat = 1920
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: target)
        let resized = renderer.image { _ in image.draw(in: CGRect(origin: .zero, size: target)) }
        guard let data = resized.jpegData(compressionQuality: 0.8) else { throw CapError.tooBig("Couldn't encode image") }
        guard data.count <= 10 * 1024 * 1024 else { throw CapError.tooBig("Image is too large") }
        return (data, Int(target.width), Int(target.height))
    }

    /// Re-encode video to H.264 720p mp4, ≤50 MB plaintext, ≤30 s (duration already checked).
    private func encodeVideo(_ url: URL) async throws -> (Data, Int?, Int?, Int) {
        let asset = AVURLAsset(url: url)
        let duration = (try? await asset.load(.duration).seconds) ?? 0
        guard duration <= 31 else { throw CapError.tooBig("Stories can be up to 30 seconds") }
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("story_out_\(UUID().uuidString).mp4")
        try? FileManager.default.removeItem(at: out)
        guard let export = AVAssetExportSession(asset: asset, presetName: AVAssetExportPreset1280x720) else {
            throw CapError.tooBig("Couldn't prepare video")
        }
        export.outputURL = out
        export.outputFileType = .mp4
        export.shouldOptimizeForNetworkUse = true
        // exportAsynchronously is available on every supported target (the no-arg async
        // export() is iOS 18+), so bridge it through a continuation.
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            export.exportAsynchronously { cont.resume() }
        }
        guard export.status == .completed, let data = try? Data(contentsOf: out) else {
            throw CapError.tooBig("Couldn't prepare video")
        }
        guard data.count <= 50 * 1024 * 1024 else { throw CapError.tooBig("Video is too large") }
        let track = try? await asset.loadTracks(withMediaType: .video).first?.load(.naturalSize)
        let w = track.map { Int(abs($0.width)) }
        let h = track.map { Int(abs($0.height)) }
        return (data, w, h, Int(duration * 1000))
    }
}
