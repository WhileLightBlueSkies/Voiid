//
//  ClipEditor.swift
//  Voiid
//
//  The editor's engine: the edit description, the filters, the looping preview player and
//  the exporter. The editor SCREEN is ClipEditorScreen.swift.
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
//  THE PREVIEW IS VIDEO, NOT A FRAME. It used to be a single still from
//  AVAssetImageGenerator, which meant you could not judge a trim, could not see a filter on
//  motion, and could not hear anything at all — so the mute toggle was a blind switch. It is
//  now a looping AVPlayer whose `videoComposition` is built from the SAME CIFilter closure
//  the exporter uses, so what plays here is what gets encoded. Trim and cover are dragged on
//  a strip of real frames rather than on abstract sliders, which is the only way to see
//  where a handle actually lands.
//

import SwiftUI
import PhotosUI
import AVFoundation
import CoreImage
import CoreImage.CIFilterBuiltins
import UIKit
import Combine

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
    /// Text placed on the video, burned in at export (ClipTextOverlay.swift).
    var texts: [ClipTextOverlay] = []

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
/// Nonisolated: the export and the preview apply it inside AVFoundation's per-frame handler,
/// on AVFoundation's own threads. It is pure image math with no state to protect.
nonisolated enum ClipFilter: String, CaseIterable, Identifiable, Equatable, Sendable {
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
    ///
    /// These are Apple's OWN photo-effect filters — the same set Photos ships — so on iOS
    /// the system really does provide the looks. Android has no equivalent system library
    /// (Google Photos' filters are private to that app), so its side builds the same looks
    /// out of colour matrices; see the Android enum for the matching values.
    ///
    /// PREVIOUSLY TWO PAIRS WERE DUPLICATES: vivid and chrome both mapped to
    /// CIPhotoEffectChrome, and dramatic and noir both to CIPhotoEffectNoir. Ten filters
    /// offered eight distinct looks, and picking "Vivid" silently gave you Chrome. Each
    /// entry below is now a different transform.
    var ciFilterName: String? {
        switch self {
        case .none: return nil
        // Vivid is a saturation boost, not a film emulation — built below rather than
        // borrowed from a preset, since CIPhotoEffect has no "more colourful" entry.
        case .vivid: return nil
        // Dramatic is high-contrast COLOUR. Mapping it to Noir made it a second mono filter.
        case .dramatic: return nil
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
        switch self {
        case .none:
            return input

        case .vivid:
            // Saturation 1.45 and a touch of contrast — matched to the Android VIVID matrix
            // so the same clip looks the same on both platforms.
            let f = CIFilter.colorControls()
            f.inputImage = input
            f.saturation = 1.45
            f.contrast = 1.05
            return f.outputImage ?? input

        case .dramatic:
            // Hard contrast, slightly desaturated, slightly darker — a colour look, not mono.
            let f = CIFilter.colorControls()
            f.inputImage = input
            f.saturation = 0.85
            f.contrast = 1.35
            f.brightness = -0.05
            return f.outputImage ?? input

        default:
            guard let name = ciFilterName, let f = CIFilter(name: name) else { return input }
            f.setValue(input, forKey: kCIInputImageKey)
            return f.outputImage ?? input
        }
    }
}

// MARK: - Editor screen: ClipEditorScreen.swift

// MARK: - Looping filtered preview

/// The editor's video preview: plays the trimmed range on a loop with the chosen filter
/// applied live.
///
/// The filter runs through `AVVideoComposition(asset:applyingCIFiltersWithHandler:)` — the
/// SAME mechanism and the same `ClipFilter.apply(to:)` closure the exporter uses — so the
/// preview cannot drift from the encode. Looping is a periodic time observer rather than an
/// `AVPlayerLooper`, because the loop range is the TRIM, not the whole asset, and it moves
/// while the user drags.
final class ClipPreviewPlayer: ObservableObject {
    let player = AVPlayer()

    /// Playhead in seconds, for the marker on the trim strip.
    @Published private(set) var position: Double = 0
    /// Whether it is meant to be playing — the editor's play/pause state.
    @Published private(set) var isPlaying = true

    private var observer: Any?
    private var loopStart: Double = 0
    private var loopEnd: Double = .greatestFiniteMagnitude
    private var wasPlaying = true

    func load(source: URL, filter: ClipFilter) async {
        let asset = AVURLAsset(url: source)
        let item = AVPlayerItem(asset: asset)
        item.videoComposition = await Self.composition(for: asset, filter: filter)
        player.replaceCurrentItem(with: item)
        player.actionAtItemEnd = .pause
        installObserver()
        player.play()
        wasPlaying = true
        isPlaying = true
    }

    /// Tap on the video: pause where it is, or carry on from there.
    func togglePlayback() {
        if wasPlaying {
            player.pause()
            wasPlaying = false
        } else {
            if position >= loopEnd - 0.05 || position < loopStart { seek(to: loopStart) }
            player.play()
            wasPlaying = true
        }
        isPlaying = wasPlaying
    }

    /// Hold still on one frame (the cover picker), without losing the play state to resume.
    func hold(at seconds: Double) {
        player.pause()
        seek(to: seconds)
    }

    func applyFilter(_ filter: ClipFilter, source: URL) async {
        guard let item = player.currentItem else { return }
        item.videoComposition = await Self.composition(for: AVURLAsset(url: source), filter: filter)
    }

    private static func composition(for asset: AVURLAsset,
                                    filter: ClipFilter) async -> AVVideoComposition? {
        // `.none` skips the composition entirely so an unfiltered preview is a plain decode.
        guard filter != .none else { return nil }
        return try? await AVVideoComposition.videoComposition(with: asset) { request in
            let output = filter.apply(to: request.sourceImage.clampedToExtent())
                .cropped(to: request.sourceImage.extent)
            request.finish(with: output, context: nil)
        }
    }

    func setLoop(start: Double, end: Double) {
        loopStart = start
        loopEnd = max(end, start + 0.1)
        if position < start || position > loopEnd { seek(to: start) }
        player.play()
        wasPlaying = true
        isPlaying = true
    }

    /// Called continuously while a trim handle is dragged: park the playhead on the frame
    /// under the finger so the handle position is legible in the preview.
    func scrub(to seconds: Double) {
        player.pause()
        wasPlaying = false
        isPlaying = false
        seek(to: seconds)
    }

    func setMuted(_ muted: Bool) { player.isMuted = muted }

    func pause() { player.pause() }

    func resume() { if wasPlaying { player.play() } }

    private func installObserver() {
        if let observer { player.removeTimeObserver(observer) }
        observer = player.addPeriodicTimeObserver(
            forInterval: CMTime(seconds: 0.05, preferredTimescale: 600), queue: .main
        ) { [weak self] time in
            guard let self else { return }
            let seconds = time.seconds
            // The loop needs a fine tick, but publishing every one of them would re-render
            // the whole editor twenty times a second to move a two-point line.
            if abs(seconds - self.position) >= 0.1 { self.position = seconds }
            guard self.wasPlaying else { return }
            if seconds >= self.loopEnd - 0.02 { self.seek(to: self.loopStart) }
        }
    }

    private func seek(to seconds: Double) {
        // A small tolerance: an exact seek on long-GOP H.264 is slow enough to stutter every
        // loop, and a couple of frames either side is invisible here.
        player.seek(to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
                    toleranceBefore: CMTime(seconds: 0.05, preferredTimescale: 600),
                    toleranceAfter: CMTime(seconds: 0.05, preferredTimescale: 600))
    }

    deinit {
        // The periodic observer retains a block referencing the player; without removing it
        // the decode keeps running after the composer is gone.
        if let observer { player.removeTimeObserver(observer) }
        player.replaceCurrentItem(with: nil)
    }
}

/// A bare AVPlayerLayer. AVKit's `VideoPlayer` brings transport controls, which would sit on
/// top of the trim handles and offer a scrubber that disagrees with them.
struct ClipPlayerLayer: UIViewRepresentable {
    let player: AVPlayer
    var gravity: AVLayerVideoGravity = .resizeAspect

    func makeUIView(context: Context) -> PlayerHost {
        let view = PlayerHost()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = gravity
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerHost, context: Context) {
        uiView.playerLayer.player = player
        uiView.playerLayer.videoGravity = gravity
    }

    final class PlayerHost: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - Export

/// The text overlay, drawn once per frame size and reused for every frame. The composition
/// handler runs on AVFoundation's own threads, hence the lock.
nonisolated private final class TextOverlayCache: @unchecked Sendable {
    private let texts: [ClipTextOverlay]
    private let lock = NSLock()
    private var size: CGSize = .zero
    private var image: CIImage?

    init(_ texts: [ClipTextOverlay]) { self.texts = texts }

    func overlay(for extent: CGRect) -> CIImage? {
        guard !texts.isEmpty else { return nil }
        lock.lock(); defer { lock.unlock() }
        if extent.size != size {
            size = extent.size
            image = ClipTextRenderer.overlay(texts, frame: extent.size)?
                .transformed(by: CGAffineTransform(translationX: extent.minX, y: extent.minY))
        }
        return image
    }
}

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

    /// Evenly spaced thumbnails across the whole source, for the trim and cover scrubbers.
    /// Deliberately UNFILTERED and generated from one AVAssetImageGenerator: this is a map
    /// of where you are in the video, not a colour preview, and ten generators would decode
    /// the file ten times over.
    static func filmstrip(from url: URL, count: Int = 10) async -> [UIImage] {
        let asset = AVURLAsset(url: url)
        guard let total = (try? await asset.load(.duration))?.seconds, total > 0 else { return [] }
        let gen = AVAssetImageGenerator(asset: asset)
        gen.appliesPreferredTrackTransform = true
        gen.maximumSize = CGSize(width: 160, height: 280)
        gen.requestedTimeToleranceBefore = CMTime(seconds: 0.5, preferredTimescale: 600)
        gen.requestedTimeToleranceAfter = CMTime(seconds: 0.5, preferredTimescale: 600)

        var frames: [UIImage] = []
        for index in 0..<count {
            // Sample the MIDDLE of each slice: the frame at t=0 is often a black lead-in.
            let seconds = total * (Double(index) + 0.5) / Double(count)
            guard let (image, _) = try? await gen.image(
                at: CMTime(seconds: seconds, preferredTimescale: 600)) else { continue }
            frames.append(UIImage(cgImage: image))
        }
        return frames
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

        // The filter and any text are baked in via a CI video composition — the same
        // mechanism Photos uses. With neither, it is skipped and the clip is a straight
        // transcode.
        var videoComposition: AVVideoComposition?
        if edit.filter != .none || !edit.texts.isEmpty {
            let filter = edit.filter
            let text = TextOverlayCache(edit.texts)
            videoComposition = AVVideoComposition(asset: composition) { request in
                let source = request.sourceImage
                var output = filter.apply(to: source.clampedToExtent()).cropped(to: source.extent)
                if let overlay = text.overlay(for: source.extent) {
                    output = overlay.composited(over: output)
                }
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
    private static func encode(_ prepared: Prepared, quality: ClipQuality,
                               onProgress: @escaping (Double) -> Void = { _ in }) async -> (URL, Int)? {
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

        // The session only reports progress when asked, so it is sampled while it runs.
        let ticker = Task {
            while !Task.isCancelled {
                onProgress(Double(session.progress))
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
        await session.export()
        ticker.cancel()
        guard session.status == .completed else {
            NSLog("[VOIID] clip encode \(quality.rawValue) failed: \(String(describing: session.error))")
            return nil
        }

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
    static func exportLadder(source: URL, edit: ClipEdit,
                             onProgress: @escaping (Double) -> Void = { _ in }) async throws -> LadderOutput {
        let prepared = try await prepare(source: source, edit: edit)

        var renditions: [ClipQuality: (url: URL, size: Int)] = [:]
        // Sequential, not concurrent: three simultaneous hardware encodes contend for the
        // same VideoToolbox session and on older devices simply fail.
        let rungs = ClipQuality.allCases
        for (index, quality) in rungs.enumerated() {
            if let (url, size) = await encode(prepared, quality: quality, onProgress: { f in
                onProgress((Double(index) + f) / Double(rungs.count))
            }) {
                renditions[quality] = (url, size)
            }
            onProgress(Double(index + 1) / Double(rungs.count))
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
