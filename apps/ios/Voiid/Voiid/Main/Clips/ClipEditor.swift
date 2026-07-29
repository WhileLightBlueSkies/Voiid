//
//  ClipEditor.swift
//  Voiid
//
//  Step 3 of the composer: trim, filter, cover frame.
//
//  ON "ALL THE FILTERS ON THE PHONE": iOS has NO public API that enumerates or applies
//  the Photos app's own filter list. The real equivalent — and what Photos itself is
//  built on — is Core Image: the `CIPhotoEffect*` family is the same Vivid/Dramatic/
//  Mono/Noir/Process/Transfer set, applied to video through
//  `AVVideoComposition(asset:applyingCIFiltersWithHandler:)`. The filter list is
//  defined once here as data so Android's Media3 `Effect` list can present exactly the
//  same strip in the same order (docs/CLIPS.md §5.3).
//
//  The editor only ever produces an EDIT DESCRIPTION (`ClipEdit`); nothing is
//  re-encoded until export. Re-encoding per tweak would make the strip unusable.
//

import SwiftUI
import PhotosUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit

// MARK: - Edit description

struct ClipEdit: Equatable {
    var trimStart: Double = 0
    var trimEnd: Double = 0
    var filter: ClipFilter = .none
    var muted: Bool = false
    /// Seconds into the SOURCE (not the trimmed range) for the grid cover frame.
    var coverSeconds: Double = 0
    /// A separate image the author picked instead of a video frame. When set, this wins
    /// over `coverSeconds` — see ClipCoverSource.
    var customCoverJPEG: Data?

    var duration: Double { max(0, trimEnd - trimStart) }

    /// What the grid tile will actually show. The grid is ENTIRELY cover images, so this
    /// is the highest-leverage choice in the whole composer.
    var coverSource: ClipCoverSource { customCoverJPEG == nil ? .frame : .upload }
}

/// Where a clip's cover image came from. Reported to the server (`cover_source`) so the
/// editor can restore the right state and so "how often do people replace the cover" is
/// answerable without guessing.
enum ClipCoverSource: String, Equatable {
    case frame   // lifted from the video itself
    case upload  // a separate image the author chose
}

/// Keep names/order identical to the Android list.
enum ClipFilter: String, CaseIterable, Identifiable, Equatable {
    case none, vivid, dramatic, mono, noir, fade, chrome, process, transfer, instant

    var id: String { rawValue }

    var label: String {
        switch self {
        case .none: return "Original"
        case .vivid: return "Vivid"
        case .dramatic: return "Dramatic"
        case .mono: return "Mono"
        case .noir: return "Noir"
        case .fade: return "Fade"
        case .chrome: return "Chrome"
        case .process: return "Process"
        case .transfer: return "Transfer"
        case .instant: return "Instant"
        }
    }

    /// The Core Image filter name, or nil for the untouched original.
    var ciFilterName: String? {
        switch self {
        case .none: return nil
        case .vivid: return "CIPhotoEffectChrome"
        case .dramatic: return "CIPhotoEffectNoir"
        case .mono: return "CIPhotoEffectMono"
        case .noir: return "CIPhotoEffectNoir"
        case .fade: return "CIPhotoEffectFade"
        case .chrome: return "CIPhotoEffectChrome"
        case .process: return "CIPhotoEffectProcess"
        case .transfer: return "CIPhotoEffectTransfer"
        case .instant: return "CIPhotoEffectInstant"
        }
    }

    func apply(to input: CIImage) -> CIImage {
        guard let name = ciFilterName, let f = CIFilter(name: name) else { return input }
        f.setValue(input, forKey: kCIInputImageKey)
        return f.outputImage ?? input
    }
}

// MARK: - Editor screen

struct ClipEditorView: View {
    let sourceURL: URL
    @Binding var edit: ClipEdit
    let onNext: () -> Void

    @State private var duration: Double = 0
    @State private var preview: UIImage?
    @State private var filterThumbs: [ClipFilter: UIImage] = [:]
    @State private var scrubSeconds: Double = 0
    @State private var coverPickerItem: PhotosPickerItem?

    var body: some View {
        VStack(spacing: VoiidSpacing.md) {
            previewPane
            trimPane
            filterStrip
            Spacer(minLength: 0)
            VoiidPrimaryButton(title: "Next", enabled: edit.duration >= 0.5) { onNext() }
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        .onChange(of: edit.filter) { _, _ in Task { await refreshPreview() } }
        .onChange(of: scrubSeconds) { _, _ in Task { await refreshPreview() } }
    }

    // MARK: Preview

    private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .fill(Color.black)
            if let preview {
                Image(uiImage: preview)
                    .resizable()
                    .scaledToFit()
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            } else {
                ClipShimmer()
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            }
        }
        .frame(maxHeight: 380)
    }

    // MARK: Trim + cover

    private var trimPane: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack {
                Text("Trim").font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
                Spacer()
                Text(String(format: "%.1fs", edit.duration))
                    .font(VoiidFont.caption).foregroundColor(VoiidColor.textSecondary)
            }

            if duration > 0 {
                VStack(spacing: 2) {
                    HStack(spacing: VoiidSpacing.sm) {
                        Text("Start").font(VoiidFont.caption).foregroundColor(VoiidColor.textSecondary)
                        Slider(value: Binding(
                            get: { edit.trimStart },
                            set: { v in
                                edit.trimStart = min(v, max(0, edit.trimEnd - 0.5))
                                scrubSeconds = edit.trimStart
                            }), in: 0...max(0.5, duration))
                            .tint(VoiidColor.primary)
                    }
                    HStack(spacing: VoiidSpacing.sm) {
                        Text("End").font(VoiidFont.caption).foregroundColor(VoiidColor.textSecondary)
                        Slider(value: Binding(
                            get: { edit.trimEnd },
                            set: { v in
                                // Clamp to the 90s cap here as well as at intake: a long
                                // source can be trimmed DOWN into range rather than rejected.
                                let capped = min(v, edit.trimStart + ClipCaps.maxDurationSeconds)
                                edit.trimEnd = max(capped, edit.trimStart + 0.5)
                                scrubSeconds = edit.trimEnd
                            }), in: 0...max(0.5, duration))
                            .tint(VoiidColor.primary)
                    }
                }
            }

            // The grid is entirely cover images, so this is the highest-leverage control
            // in the whole flow — never cut it.
            coverSection

            Toggle("Mute audio", isOn: $edit.muted)
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textPrimary)
                .tint(VoiidColor.primary)
        }
    }

    // MARK: Cover

    /// Two ways to set the grid tile: scrub to a frame, or upload a separate image.
    /// An uploaded image WINS over the scrubber (and clearing it returns to the frame),
    /// so the two controls can never disagree about what the tile will show.
    private var coverSection: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack {
                Text("Cover").font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
                Spacer()
                if edit.customCoverJPEG != nil {
                    Button {
                        Haptics.tap()
                        edit.customCoverJPEG = nil
                    } label: {
                        Text("Use a video frame")
                            .font(VoiidFont.caption)
                            .foregroundColor(VoiidColor.primary)
                    }
                }
            }

            HStack(spacing: VoiidSpacing.md) {
                // Live preview of exactly what the grid tile will be.
                ZStack {
                    if let data = edit.customCoverJPEG, let img = UIImage(data: data) {
                        Image(uiImage: img).resizable().scaledToFill()
                    } else if let preview {
                        Image(uiImage: preview).resizable().scaledToFill()
                    } else {
                        ClipShimmer()
                    }
                }
                .frame(width: 54, height: 72)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.sm, style: .continuous))

                VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
                    if edit.customCoverJPEG == nil {
                        Button {
                            Haptics.tap()
                            edit.coverSeconds = scrubSeconds
                        } label: {
                            Text("Use current frame")
                                .font(VoiidFont.subhead)
                                .foregroundColor(VoiidColor.primary)
                        }
                    } else {
                        Text("Custom image")
                            .font(VoiidFont.subhead)
                            .foregroundColor(VoiidColor.textPrimary)
                    }

                    PhotosPicker(selection: $coverPickerItem, matching: .images) {
                        Text(edit.customCoverJPEG == nil ? "Upload an image" : "Change image")
                            .font(VoiidFont.subhead)
                            .foregroundColor(VoiidColor.primary)
                    }
                }
                Spacer()
            }

            // The scrubber is meaningless while a custom image is in force — hide it
            // rather than leave a control that silently does nothing.
            if edit.customCoverJPEG == nil {
                Slider(value: $scrubSeconds, in: 0...max(0.5, duration))
                    .tint(VoiidColor.accent)
            }
        }
        .onChange(of: coverPickerItem) { _, item in
            guard let item else { return }
            Task { await loadCustomCover(item) }
        }
    }

    /// Re-encode the picked image to a bounded JPEG. An 8 MB HEIC straight from the
    /// camera roll would be a 200x heavier grid tile than the frames it sits beside.
    private func loadCustomCover(_ item: PhotosPickerItem) async {
        guard let data = try? await item.loadTransferable(type: Data.self),
              let image = UIImage(data: data) else { return }

        let maxEdge: CGFloat = 1080
        let scale = min(1, maxEdge / max(image.size.width, image.size.height))
        let target = CGSize(width: image.size.width * scale, height: image.size.height * scale)
        let resized = UIGraphicsImageRenderer(size: target).image { _ in
            image.draw(in: CGRect(origin: .zero, size: target))
        }
        if let jpeg = resized.jpegData(compressionQuality: 0.8) {
            edit.customCoverJPEG = jpeg
            Haptics.success()
        }
    }

    // MARK: Filters

    private var filterStrip: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            Text("Filters").font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: VoiidSpacing.sm) {
                    ForEach(ClipFilter.allCases) { f in
                        Button {
                            Haptics.tap()
                            edit.filter = f
                        } label: {
                            VStack(spacing: 4) {
                                ZStack {
                                    if let t = filterThumbs[f] {
                                        Image(uiImage: t).resizable().scaledToFill()
                                    } else {
                                        ClipShimmer()
                                    }
                                }
                                .frame(width: 54, height: 72)
                                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.sm, style: .continuous))
                                .overlay(
                                    RoundedRectangle(cornerRadius: VoiidRadius.sm, style: .continuous)
                                        .stroke(edit.filter == f ? VoiidColor.primary : .clear, lineWidth: 2))
                                Text(f.label)
                                    .font(VoiidFont.rounded(10, .medium))
                                    .foregroundColor(edit.filter == f ? VoiidColor.primary : VoiidColor.textSecondary)
                            }
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
    }

    // MARK: Loading

    private func load() async {
        let asset = AVURLAsset(url: sourceURL)
        duration = (try? await asset.load(.duration))?.seconds ?? 0
        if edit.trimEnd <= 0 { edit.trimEnd = min(duration, ClipCaps.maxDurationSeconds) }
        scrubSeconds = edit.trimStart
        await refreshPreview()
        await buildFilterThumbs()
    }

    private func refreshPreview() async {
        preview = try? await ClipExporter.frame(from: sourceURL, at: scrubSeconds, filter: edit.filter)
    }

    /// One decode, N filter applications — decoding the frame once per filter would make
    /// the strip take ten times as long to populate.
    private func buildFilterThumbs() async {
        guard let base = try? await ClipExporter.rawFrame(from: sourceURL, at: max(0.1, edit.trimStart)) else { return }
        let ci = CIImage(cgImage: base)
        let context = CIContext()
        for f in ClipFilter.allCases {
            let out = f.apply(to: ci)
            if let cg = context.createCGImage(out, from: ci.extent) {
                filterThumbs[f] = UIImage(cgImage: cg)
            }
        }
    }
}

// MARK: - Export

enum ClipExportError: Error { case noVideoTrack, exportFailed(String), noFrame }

enum ClipExporter {
    struct Output {
        let url: URL
        let thumbnailJPEG: Data
        let durationMs: Int
        let width: Int
        let height: Int
    }

    /// A single decoded frame, unfiltered — the base for the filter strip.
    static func rawFrame(from url: URL, at seconds: Double) async throws -> CGImage {
        let asset = AVURLAsset(url: url)
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 360, height: 640)
        // Zero tolerance would make the generator seek to an exact PTS and often fail on
        // long-GOP H.264; a small window is both faster and more reliable.
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.3, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.3, preferredTimescale: 600)
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        let (image, _) = try await gen.image(at: time)
        return image
    }

    /// A decoded frame with the chosen filter applied — the editor preview and the cover.
    static func frame(from url: URL, at seconds: Double, filter: ClipFilter) async throws -> UIImage {
        let cg = try await rawFrame(from: url, at: seconds)
        guard filter != .none else { return UIImage(cgImage: cg) }
        let out = filter.apply(to: CIImage(cgImage: cg))
        let ctx = CIContext()
        guard let rendered = ctx.createCGImage(out, from: CIImage(cgImage: cg).extent) else {
            return UIImage(cgImage: cg)
        }
        return UIImage(cgImage: rendered)
    }

    /// Build the trimmed/filtered composition once, so the three renditions all encode
    /// from the SAME edit rather than re-deriving it (and possibly disagreeing) per pass.
    private struct Prepared {
        let composition: AVMutableComposition
        let videoComposition: AVVideoComposition?
        let sourceLongEdge: CGFloat
        let width: Int
        let height: Int
        let start: Double
        let end: Double
    }

    private static func prepare(source: URL, edit: ClipEdit) async throws -> Prepared {
        let asset = AVURLAsset(url: source)
        guard let track = try await asset.loadTracks(withMediaType: .video).first else {
            throw ClipExportError.noVideoTrack
        }

        let naturalSize = try await track.load(.naturalSize)
        let transform = try await track.load(.preferredTransform)
        let rendered = naturalSize.applying(transform)
        let width = Int(abs(rendered.width))
        let height = Int(abs(rendered.height))

        let composition = AVMutableComposition()
        let videoTrack = composition.addMutableTrack(withMediaType: .video,
                                                     preferredTrackID: kCMPersistentTrackID_Invalid)
        let fullDuration = try await asset.load(.duration).seconds
        let start = max(0, edit.trimStart)
        let end = edit.trimEnd > start ? min(edit.trimEnd, fullDuration) : fullDuration
        let range = CMTimeRange(
            start: CMTime(seconds: start, preferredTimescale: 600),
            duration: CMTime(seconds: max(0.1, end - start), preferredTimescale: 600))

        try videoTrack?.insertTimeRange(range, of: track, at: .zero)
        videoTrack?.preferredTransform = transform

        if !edit.muted, let audio = try await asset.loadTracks(withMediaType: .audio).first {
            let audioTrack = composition.addMutableTrack(withMediaType: .audio,
                                                         preferredTrackID: kCMPersistentTrackID_Invalid)
            try? audioTrack?.insertTimeRange(range, of: audio, at: .zero)
        }

        // The filter is baked in via a CI video composition — the same mechanism Photos
        // uses. `.none` skips it entirely so an unfiltered clip is a straight transcode.
        var videoComposition: AVVideoComposition?
        if edit.filter != .none {
            let filter = edit.filter
            videoComposition = AVVideoComposition(asset: composition) { request in
                let output = filter.apply(to: request.sourceImage.clampedToExtent())
                    .cropped(to: request.sourceImage.extent)
                request.finish(with: output, context: nil)
            }
        }

        return Prepared(composition: composition, videoComposition: videoComposition,
                        sourceLongEdge: max(abs(rendered.width), abs(rendered.height)),
                        width: width, height: height, start: start, end: end)
    }

    /// Encode one rendition. Returns nil when the source is already smaller than this
    /// rung — UPSCALING is never worth it: it costs upload bytes and encode time to
    /// produce a file that looks no better than the one below it.
    private static func encode(_ prepared: Prepared, quality: ClipQuality) async -> (URL, Int)? {
        // 10% tolerance so a 1920x1080 source still counts as satisfying .fhd rather
        // than being rejected by a rounding difference.
        guard prepared.sourceLongEdge >= quality.longEdge * 0.9 || quality == .sd else { return nil }

        let preset: String
        switch quality {
        case .sd: preset = AVAssetExportPreset640x480
        case .hd: preset = AVAssetExportPreset1280x720
        case .fhd: preset = AVAssetExportPreset1920x1080
        }
        guard let session = AVAssetExportSession(asset: prepared.composition, presetName: preset) else {
            return nil
        }
        session.videoComposition = prepared.videoComposition

        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip_\(quality.rawValue)_\(UUID().uuidString).mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        // Moves the moov atom to the front so playback can start before the whole file
        // has arrived. Without this the player buffers the entire clip first.
        session.shouldOptimizeForNetworkUse = true

        await session.export()
        guard session.status == .completed else { return nil }

        let attrs = try? FileManager.default.attributesOfItem(atPath: out.path)
        let size = (attrs?[.size] as? Int) ?? 0
        // A rendition over the cap is dropped rather than failing the whole post — the
        // ladder still has smaller rungs, and the baseline is checked separately.
        if size > ClipCaps.maxBytes {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return (out, size)
    }

    /// Apply the whole edit list and produce the full rendition ladder in one go.
    ///
    /// The BASELINE (`Output.url`) is the best rung that actually encoded; the others
    /// ride along in `renditions`. At least one must succeed or the post fails — a clip
    /// with no video is not a clip.
    static func exportLadder(source: URL, edit: ClipEdit) async throws -> LadderOutput {
        let prepared = try await prepare(source: source, edit: edit)

        var renditions: [ClipQuality: (url: URL, size: Int)] = [:]
        // Sequential, not concurrent: three simultaneous hardware encodes contend for the
        // same VideoToolbox session and on older devices simply fail.
        for quality in ClipQuality.allCases {
            if let (url, size) = await encode(prepared, quality: quality) {
                renditions[quality] = (url, size)
            }
        }
        guard !renditions.isEmpty else {
            throw ClipExportError.exportFailed("Couldn't process that video.")
        }

        // Baseline = the highest rung produced, so a client that ignores renditions
        // entirely still gets the best available file.
        let baselineQuality = [ClipQuality.fhd, .hd, .sd].first { renditions[$0] != nil }!
        let baseline = renditions[baselineQuality]!

        let jpeg = try await coverJPEG(source: source, edit: edit,
                                       start: prepared.start, end: prepared.end)

        return LadderOutput(
            baseline: baseline.url,
            baselineSize: baseline.size,
            renditions: renditions,
            thumbnailJPEG: jpeg,
            coverSource: edit.coverSource,
            durationMs: Int((prepared.end - prepared.start) * 1000),
            width: prepared.width, height: prepared.height)
    }

    /// The grid tile image: either the author's uploaded image, or a frame from the video.
    private static func coverJPEG(source: URL, edit: ClipEdit,
                                  start: Double, end: Double) async throws -> Data {
        // An uploaded cover WINS over the frame picker and is deliberately NOT filtered:
        // the filter applies to the video, and silently tinting a photo the author chose
        // would be a surprise they cannot undo.
        if let custom = edit.customCoverJPEG { return custom }

        let cover = try await frame(from: source,
                                    at: min(max(edit.coverSeconds, start), max(start, end - 0.1)),
                                    filter: edit.filter)
        guard let jpeg = cover.jpegData(compressionQuality: 0.8) else {
            throw ClipExportError.noFrame
        }
        return jpeg
    }

    struct LadderOutput {
        let baseline: URL
        let baselineSize: Int
        let renditions: [ClipQuality: (url: URL, size: Int)]
        let thumbnailJPEG: Data
        let coverSource: ClipCoverSource
        let durationMs: Int
        let width: Int
        let height: Int
    }
}
