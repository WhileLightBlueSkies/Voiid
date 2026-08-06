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

// MARK: - Editor screen

struct ClipEditorView: View {
    let sourceURL: URL
    @Binding var edit: ClipEdit
    let onNext: () -> Void

    @Environment(\.scenePhase) private var scenePhase

    @State private var duration: Double = 0
    @State private var filmstrip: [UIImage] = []
    @State private var coverPreview: UIImage?
    @State private var filterThumbs: [ClipFilter: UIImage] = [:]
    @State private var coverPickerItem: PhotosPickerItem?
    @StateObject private var preview = ClipPreviewPlayer()

    var body: some View {
        VStack(spacing: VoiidSpacing.md) {
            previewPane
            ScrollView {
                VStack(spacing: VoiidSpacing.md) {
                    trimPane
                    coverSection
                    Toggle("Mute audio", isOn: $edit.muted)
                        .font(VoiidFont.subhead)
                        .foregroundColor(VoiidColor.textPrimary)
                        .tint(VoiidColor.primary)
                    filterStrip
                }
            }
            VoiidPrimaryButton(title: "Next", enabled: edit.duration >= 0.5) { onNext() }
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("Edit")
        .navigationBarTitleDisplayMode(.inline)
        .task { await load() }
        // Pushing Details fires onDisappear but leaves this view alive in the stack, so
        // `.task` never runs again — releasing the player here would leave a black preview
        // on the way back. Pause instead; the player is released in ClipPreviewPlayer.deinit
        // when the whole composer goes away.
        .onAppear { preview.resume() }
        .onDisappear { preview.pause() }
        .onChange(of: edit.filter) { _, f in
            Task {
                await preview.applyFilter(f, source: sourceURL)
                await refreshCoverPreview()
            }
        }
        .onChange(of: edit.muted) { _, m in preview.setMuted(m) }
        .onChange(of: edit.coverSeconds) { _, _ in Task { await refreshCoverPreview() } }
        .onChange(of: scenePhase) { _, phase in
            // A player left running behind a backgrounded app keeps decoding for nothing.
            if phase == .active { preview.resume() } else { preview.pause() }
        }
    }

    // MARK: Preview

    private var previewPane: some View {
        ZStack {
            RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                .fill(Color.black)
            ClipPlayerLayer(player: preview.player)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            if filmstrip.isEmpty {
                ClipShimmer()
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
                    .allowsHitTesting(false)
            }
        }
        .frame(maxHeight: 320)
    }

    // MARK: Trim

    private var trimPane: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            HStack {
                Text("Trim").font(VoiidFont.headline).foregroundColor(VoiidColor.textPrimary)
                Spacer()
                Text(String(format: "%.1fs", edit.duration))
                    .font(VoiidFont.caption).foregroundColor(VoiidColor.textSecondary)
            }

            if duration > 0 {
                ClipFilmstripBar(
                    thumbs: filmstrip,
                    duration: duration,
                    // The trimmed window, plus a playhead so the loop is legible.
                    windowStart: edit.trimStart,
                    windowEnd: edit.trimEnd,
                    playhead: preview.position,
                    handles: .both,
                    onDrag: { which, seconds in
                        if which == .start {
                            edit.trimStart = min(seconds, max(0, edit.trimEnd - 0.5))
                            preview.scrub(to: edit.trimStart)
                        } else {
                            // Clamp to the 90s cap here as well as at intake: a long source
                            // can be trimmed DOWN into range rather than rejected.
                            let capped = min(seconds, edit.trimStart + ClipCaps.maxDurationSeconds)
                            edit.trimEnd = max(capped, edit.trimStart + 0.5)
                            preview.scrub(to: edit.trimEnd)
                        }
                    },
                    onRelease: {
                        Haptics.selection()
                        preview.setLoop(start: edit.trimStart, end: edit.trimEnd)
                    })
            }
        }
    }

    // MARK: Cover

    /// Two ways to set the grid tile: drag the cover handle to a frame, or upload a separate
    /// image. An uploaded image WINS over the scrubber (and clearing it returns to the
    /// frame), so the two controls can never disagree about what the tile will show.
    ///
    /// The grid is entirely cover images, so this is the highest-leverage control in the
    /// whole flow — never cut it.
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
                    } else if let coverPreview {
                        Image(uiImage: coverPreview).resizable().scaledToFill()
                    } else {
                        ClipShimmer()
                    }
                }
                .frame(width: 54, height: 72)
                .clipped()
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.sm, style: .continuous))

                VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
                    Text(edit.customCoverJPEG == nil ? "Drag to pick a frame" : "Custom image")
                        .font(VoiidFont.subhead)
                        .foregroundColor(VoiidColor.textPrimary)

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
            if edit.customCoverJPEG == nil && duration > 0 {
                ClipFilmstripBar(
                    thumbs: filmstrip,
                    duration: duration,
                    windowStart: 0,
                    windowEnd: duration,
                    playhead: nil,
                    handles: .cover(edit.coverSeconds),
                    onDrag: { _, seconds in edit.coverSeconds = seconds },
                    onRelease: { Haptics.selection() })
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

        await preview.load(source: sourceURL, filter: edit.filter)
        preview.setMuted(edit.muted)
        preview.setLoop(start: edit.trimStart, end: edit.trimEnd)

        await refreshCoverPreview()
        filmstrip = await ClipExporter.filmstrip(from: sourceURL)
        await buildFilterThumbs()
    }

    private func refreshCoverPreview() async {
        coverPreview = try? await ClipExporter.frame(from: sourceURL, at: edit.coverSeconds,
                                                     filter: edit.filter)
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
    }

    /// Called continuously while a trim handle is dragged: park the playhead on the frame
    /// under the finger so the handle position is legible in the preview.
    func scrub(to seconds: Double) {
        player.pause()
        wasPlaying = false
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
private struct ClipPlayerLayer: UIViewRepresentable {
    let player: AVPlayer

    func makeUIView(context: Context) -> PlayerHost {
        let view = PlayerHost()
        view.playerLayer.player = player
        view.playerLayer.videoGravity = .resizeAspect
        view.backgroundColor = .black
        return view
    }

    func updateUIView(_ uiView: PlayerHost, context: Context) {
        uiView.playerLayer.player = player
    }

    final class PlayerHost: UIView {
        override class var layerClass: AnyClass { AVPlayerLayer.self }
        var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
    }
}

// MARK: - Filmstrip scrubber

/// A row of real frames with draggable handles — the visual anchor two abstract labelled
/// sliders never gave. Used twice: with `.both` handles it is the trim window, with
/// `.cover` it is Instagram's single-handle "Edit cover".
private struct ClipFilmstripBar: View {
    enum Handle { case start, end }
    enum Mode: Equatable {
        case both
        case cover(Double)
    }

    let thumbs: [UIImage]
    let duration: Double
    let windowStart: Double
    let windowEnd: Double
    let playhead: Double?
    let handles: Mode
    let onDrag: (Handle, Double) -> Void
    let onRelease: () -> Void

    private let barHeight: CGFloat = 56
    private let gripWidth: CGFloat = 14
    /// The visible grip is thin, but the thing a finger has to hit is not.
    private let touchWidth: CGFloat = 44

    var body: some View {
        GeometryReader { geo in
            let width = max(1, geo.size.width)
            ZStack(alignment: .topLeading) {
                filmstrip(width: width)

                switch handles {
                case .both:
                    let xs = position(windowStart, width)
                    let xe = position(windowEnd, width)
                    Rectangle().fill(Color.black.opacity(0.55))
                        .frame(width: xs, height: barHeight)
                    Rectangle().fill(Color.black.opacity(0.55))
                        .frame(width: max(0, width - xe), height: barHeight)
                        .offset(x: xe)
                    RoundedRectangle(cornerRadius: VoiidRadius.sm, style: .continuous)
                        .stroke(VoiidColor.accent, lineWidth: 2)
                        .frame(width: max(0, xe - xs), height: barHeight)
                        .offset(x: xs)
                    if let playhead {
                        Rectangle().fill(.white)
                            .frame(width: 2, height: barHeight)
                            .offset(x: position(playhead, width))
                            .allowsHitTesting(false)
                    }
                    grip(x: xs, width: width, handle: .start)
                    grip(x: xe, width: width, handle: .end)

                case .cover(let seconds):
                    grip(x: position(seconds, width), width: width, handle: .start)
                }
            }
            .frame(height: barHeight)
            .coordinateSpace(.named("filmstrip"))
        }
        .frame(height: barHeight)
    }

    private func filmstrip(width: CGFloat) -> some View {
        HStack(spacing: 0) {
            if thumbs.isEmpty {
                ClipShimmer()
            } else {
                ForEach(Array(thumbs.enumerated()), id: \.offset) { _, image in
                    Image(uiImage: image)
                        .resizable()
                        .scaledToFill()
                        .frame(width: width / CGFloat(thumbs.count), height: barHeight)
                        .clipped()
                }
            }
        }
        .frame(width: width, height: barHeight)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.sm, style: .continuous))
    }

    private func position(_ seconds: Double, _ width: CGFloat) -> CGFloat {
        guard duration > 0 else { return 0 }
        return CGFloat(min(max(seconds / duration, 0), 1)) * width
    }

    private func grip(x: CGFloat, width: CGFloat, handle: Handle) -> some View {
        Capsule()
            .fill(VoiidColor.accent)
            .frame(width: gripWidth, height: barHeight)
            .overlay(Capsule().fill(Color.black.opacity(0.35)).frame(width: 2, height: 18))
            .frame(width: touchWidth, height: barHeight)
            .contentShape(Rectangle())
            .offset(x: x - touchWidth / 2)
            .gesture(
                DragGesture(minimumDistance: 0, coordinateSpace: .named("filmstrip"))
                    .onChanged { value in
                        let clamped = min(max(value.location.x, 0), width)
                        onDrag(handle, Double(clamped / width) * duration)
                    }
                    .onEnded { _ in onRelease() }
            )
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
