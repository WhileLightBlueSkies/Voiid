//
//  ClipCameraView.swift
//  Voiid
//
//  The dedicated clip camera: multi-take recording with a LIVE-FILTERED viewfinder.
//
//  WHY THIS EXISTS. Clips used to borrow the story camera in a `.clip` mode, which is a
//  single-shot camera: it fires `onCapture` and dismisses the moment the first recording
//  finalizes, and the composer accepted exactly one URL. So iOS had no multi-take, no undo
//  and no banked progress while Android already had all three, and the shape of that camera
//  ruled out ever putting the filter strip in the live preview.
//
//  CAPTURE PIPELINE. Unlike the story camera this does NOT use AVCaptureMovieFileOutput or
//  AVCaptureVideoPreviewLayer — neither can render a CIFilter. Frames come off
//  AVCaptureVideoDataOutput, are filtered per-frame for the preview only, and are written to
//  disk CLEAN through an AVAssetWriter. The chosen filter travels with the finished URL and
//  is baked exactly once at export, so the edit stays non-destructive and the colour is never
//  applied twice. (The movie output and the data output do not usefully coexist in one
//  session, which is why this is a separate camera and stories are left alone.)
//
//  SEGMENTS. Each press/release is one take written to its own `clip_seg_<uuid>.mp4`. They
//  are concatenated only when the author commits: re-muxing after every stop would stall the
//  shutter for seconds on a long take. A single 1× take is handed over untouched.
//

import SwiftUI
import AVFoundation
import CoreImage
import MetalKit
import PhotosUI
import Photos
import UIKit
import Combine

// MARK: - Takes

/// One recorded segment plus the playback rate the author picked for it.
///
/// Recording always happens at 1×; the rate is applied at join time. That keeps the shutter
/// responsive and keeps the camera's output a plain recording rather than an already-rendered
/// edit — the same "produce a description, render once" rule the editor follows.
struct ClipTake: Identifiable, Equatable {
    let id = UUID()
    let url: URL
    /// Seconds actually written to the file, i.e. real time at 1×.
    let recordedSeconds: Double
    /// 0.3…3. Applied by `ClipTakeJoiner`.
    let speed: Double

    /// Seconds this take will contribute to the FINISHED clip. A 0.3× take stretches, a 3×
    /// take shrinks — the 90s cap has to be counted in these, not in recorded seconds.
    var outputSeconds: Double { recordedSeconds / speed }
}

/// The record-rail rates, matching Instagram's set.
enum ClipSpeed {
    static let options: [Double] = [0.3, 0.5, 1, 2, 3]

    static func label(_ v: Double) -> String {
        v == v.rounded() ? "\(Int(v))×" : String(format: "%.1f×", v)
    }
}

// MARK: - Screen

struct ClipCameraView: View {
    var maxSeconds: Double = ClipCaps.maxDurationSeconds
    /// The joined recording plus the filter chosen in the viewfinder. The filter is passed
    /// as an EDIT, never burnt into the file, so the editor can still change it.
    var onDone: (URL, ClipFilter) -> Void
    /// A video chosen from the library. It goes through the composer's existing intake so
    /// duration and cap validation are identical for recordings and imports.
    var onGalleryPicked: (PhotosPickerItem) -> Void
    var onClose: () -> Void

    @StateObject private var cam = ClipCameraController()

    @State private var pickerItem: PhotosPickerItem?
    @State private var galleryThumb: UIImage?
    @State private var joining = false
    @State private var confirmImport = false
    @State private var pendingImport: PhotosPickerItem?

    // Shutter gesture bookkeeping — see `shutterPressChanged`.
    @State private var pressActive = false
    @State private var pressBegan = Date()
    @State private var pressConsumed = false

    private var totalSeconds: Double { cam.bankedSeconds + cam.liveSeconds }
    private var full: Bool { totalSeconds >= maxSeconds - 0.05 }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()

            ClipCameraPreview(renderer: cam.renderer,
                              onZoom: { cam.zoom(scale: $0, began: $1) },
                              onFocus: { cam.focus(atNormalizedViewPoint: $0) },
                              onFlip: { if !cam.isRecording { Haptics.tap(); cam.flip() } })
                .ignoresSafeArea()

            VStack(spacing: 0) {
                topBar
                progressTicks
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.top, VoiidSpacing.sm)
                Spacer(minLength: 0)
                if let text = cam.errorText {
                    Text(text)
                        .font(VoiidFont.footnote)
                        .foregroundColor(.white)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal, VoiidSpacing.md)
                        .padding(.vertical, VoiidSpacing.sm)
                        .background(Color.black.opacity(0.6))
                        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.sm, style: .continuous))
                        .padding(.horizontal, VoiidSpacing.lg)
                }
                Spacer(minLength: 0)
                if !cam.isRecording { speedRail }
                filterRail
                bottomBar
            }
            .padding(.bottom, VoiidSpacing.md)

            if joining {
                ZStack {
                    Color.black.opacity(0.55).ignoresSafeArea()
                    ProgressView("Putting your takes together…")
                        .tint(.white)
                        .foregroundColor(.white)
                }
            }
        }
        .statusBarHidden(true)
        .onAppear {
            cam.maxSeconds = maxSeconds
            cam.start()
            loadGalleryThumb()
        }
        .onDisappear { cam.stop() }
        .onChange(of: pickerItem) { _, item in
            guard let item else { return }
            pickerItem = nil
            // An import replaces the takes, so ask first rather than silently binning work.
            if cam.takes.isEmpty {
                onGalleryPicked(item)
            } else {
                pendingImport = item
                confirmImport = true
            }
        }
        .confirmationDialog("Use a video from your library?",
                            isPresented: $confirmImport, titleVisibility: .visible) {
            Button("Discard takes and import", role: .destructive) {
                if let item = pendingImport {
                    cam.discardTakes()
                    onGalleryPicked(item)
                }
                pendingImport = nil
            }
            Button("Keep recording", role: .cancel) { pendingImport = nil }
        } message: {
            Text("The \(cam.takes.count) take\(cam.takes.count == 1 ? "" : "s") you've recorded will be discarded.")
        }
    }

    // MARK: Top bar

    private var topBar: some View {
        HStack(spacing: VoiidSpacing.sm) {
            roundButton("xmark", label: "Close") {
                cam.stop()
                cam.discardTakes()
                onClose()
            }
            Spacer()
            if totalSeconds > 0 || cam.isRecording {
                // Elapsed AND the cap, so a 90s clip does not stop at what looks like an
                // arbitrary moment with no warning it was coming.
                Text(String(format: "%02d:%02d / %02d:%02d",
                            Int(totalSeconds) / 60, Int(totalSeconds) % 60,
                            Int(maxSeconds) / 60, Int(maxSeconds) % 60))
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundColor(.white)
                    .padding(.horizontal, VoiidSpacing.md)
                    .padding(.vertical, 6)
                    .background(cam.isRecording ? VoiidColor.error : Color.black.opacity(0.4))
                    .clipShape(Capsule())
            }
            Spacer()
            if cam.hasTorch {
                roundButton(cam.torchOn ? "bolt.fill" : "bolt.slash",
                            label: "Flash", active: cam.torchOn) {
                    Haptics.tap()
                    cam.toggleTorch()
                }
            }
            roundButton("arrow.triangle.2.circlepath.camera", label: "Flip camera") {
                // Flipping mid-take would have to cut the segment; simply not offered while
                // recording, which is what the Android camera does too.
                guard !cam.isRecording else { return }
                Haptics.tap()
                cam.flip()
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.top, VoiidSpacing.sm)
    }

    /// One tick per banked take plus the in-flight one, so "how much have I got" is
    /// answerable at a glance and undo has a visual anchor.
    private var progressTicks: some View {
        GeometryReader { geo in
            HStack(spacing: 2) {
                ForEach(cam.takes) { take in
                    Capsule()
                        .fill(Color.white)
                        .frame(width: tickWidth(take.outputSeconds, in: geo.size.width))
                }
                if cam.isRecording {
                    Capsule()
                        .fill(VoiidColor.error)
                        .frame(width: tickWidth(cam.liveSeconds, in: geo.size.width))
                }
                Spacer(minLength: 0)
            }
            .frame(height: 3)
        }
        .frame(height: 3)
        .opacity(cam.takes.isEmpty && !cam.isRecording ? 0 : 1)
    }

    private func tickWidth(_ seconds: Double, in total: CGFloat) -> CGFloat {
        max(2, total * CGFloat(min(1, seconds / maxSeconds)))
    }

    // MARK: Rails

    private var speedRail: some View {
        HStack(spacing: VoiidSpacing.sm) {
            ForEach(ClipSpeed.options, id: \.self) { s in
                Button {
                    Haptics.selection()
                    cam.selectedSpeed = s
                } label: {
                    Text(ClipSpeed.label(s))
                        .font(VoiidFont.rounded(13, .semibold))
                        .foregroundColor(cam.selectedSpeed == s ? .black : .white)
                        .frame(minWidth: 48, minHeight: 44)
                        .background(cam.selectedSpeed == s ? Color.white : Color.black.opacity(0.35))
                        .clipShape(Capsule())
                }
                .buttonStyle(SoftPressStyle())
            }
        }
        .padding(.bottom, VoiidSpacing.sm)
    }

    private var filterRail: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: VoiidSpacing.sm) {
                ForEach(ClipFilter.allCases) { f in
                    Button {
                        Haptics.selection()
                        cam.filter = f
                    } label: {
                        Text(f.label)
                            .font(VoiidFont.rounded(13, .semibold))
                            .foregroundColor(cam.filter == f ? .black : .white)
                            .padding(.horizontal, VoiidSpacing.md)
                            .frame(minHeight: 44)
                            .background(cam.filter == f ? Color.white : Color.black.opacity(0.35))
                            .clipShape(Capsule())
                    }
                    .buttonStyle(SoftPressStyle())
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
        }
        .frame(height: 44)
        .padding(.bottom, VoiidSpacing.md)
    }

    // MARK: Bottom bar

    private var bottomBar: some View {
        HStack(spacing: 0) {
            galleryButton
            Spacer(minLength: VoiidSpacing.sm)
            undoButton
            Spacer(minLength: VoiidSpacing.sm)
            shutter
            Spacer(minLength: VoiidSpacing.sm)
            acceptButton
            Spacer(minLength: VoiidSpacing.sm)
            // Balances the gallery button so the shutter stays optically centred.
            Color.clear.frame(width: 52, height: 52)
        }
        .padding(.horizontal, VoiidSpacing.md)
    }

    /// Instagram's corner thumbnail. The image only appears when library access has ALREADY
    /// been granted — opening the camera is not the moment to demand a new permission.
    private var galleryButton: some View {
        PhotosPicker(selection: $pickerItem, matching: .videos) {
            ZStack {
                if let galleryThumb {
                    Image(uiImage: galleryThumb).resizable().scaledToFill()
                } else {
                    Color.white.opacity(0.15)
                    Image(systemName: "photo.on.rectangle.angled")
                        .font(.system(size: 20))
                        .foregroundColor(.white)
                }
            }
            .frame(width: 52, height: 52)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .stroke(.white.opacity(0.6), lineWidth: 1))
        }
        .buttonStyle(SoftPressStyle())
    }

    private var undoButton: some View {
        // Present but inert while recording rather than vanishing, so the row does not
        // reflow under the user's thumb mid-take.
        Group {
            if !cam.takes.isEmpty && !cam.isRecording {
                roundButton("arrow.uturn.backward", label: "Undo last take") {
                    Haptics.tap()
                    cam.undoLastTake()
                }
            } else {
                Color.clear.frame(width: 44, height: 44)
            }
        }
        .frame(width: 44, height: 44)
    }

    private var acceptButton: some View {
        Group {
            if !cam.takes.isEmpty && !cam.isRecording {
                Button {
                    Haptics.success()
                    commit()
                } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 20, weight: .semibold))
                        .foregroundColor(VoiidColor.textOnPrimary)
                        .frame(width: 52, height: 52)
                        .background(VoiidColor.primary)
                        .clipShape(Circle())
                }
                .buttonStyle(SoftPressStyle())
                .accessibilityLabel("Use clip")
            } else {
                Color.clear.frame(width: 52, height: 52)
            }
        }
        .frame(width: 52, height: 52)
    }

    private var shutter: some View {
        Circle()
            .stroke(.white, lineWidth: 4)
            .frame(width: 76, height: 76)
            .overlay(
                RoundedRectangle(cornerRadius: cam.isRecording ? 8 : 31, style: .continuous)
                    .fill(cam.isRecording ? VoiidColor.error : .white)
                    .frame(width: cam.isRecording ? 34 : 62, height: cam.isRecording ? 34 : 62)
                    .animation(.spring(response: 0.25, dampingFraction: 0.7), value: cam.isRecording)
            )
            .contentShape(Circle())
            .gesture(
                // A DragGesture with no minimum distance is the only reliable press/release
                // signal here: onLongPressGesture's `pressing` callback also fires for a
                // plain tap, which would start and immediately end a 0.1s take.
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !pressActive else { return }
                        pressActive = true
                        shutterPressChanged(true)
                    }
                    .onEnded { _ in
                        pressActive = false
                        shutterPressChanged(false)
                    }
            )
            .accessibilityLabel(cam.isRecording ? "Stop recording" : "Record")
    }

    private func shutterPressChanged(_ pressing: Bool) {
        if pressing {
            if cam.isRecording {
                // A second press ends a take that is running locked.
                cam.stopRecording()
                pressConsumed = true
            } else {
                guard !full else { return }
                pressConsumed = false
                pressBegan = Date()
                cam.startRecording()
            }
            return
        }
        if pressConsumed { pressConsumed = false; return }
        // Under a third of a second reads as a TAP, which LOCKS the take running — nobody
        // holds a finger down for ninety seconds. A real press-and-hold ends on release,
        // which is how a burst of short segments gets banked.
        if Date().timeIntervalSince(pressBegan) >= 0.35 { cam.stopRecording() }
    }

    // MARK: Commit

    private func commit() {
        let takes = cam.takes
        guard !takes.isEmpty else { return }
        joining = true
        let filter = cam.filter
        Task {
            let joined = await ClipTakeJoiner.join(takes: takes)
            await MainActor.run {
                joining = false
                guard let joined else {
                    cam.errorText = "Couldn't put those takes together."
                    return
                }
                cam.forgetTakes()
                cam.stop()
                onDone(joined, filter)
            }
        }
    }

    // MARK: Chrome helpers

    private func roundButton(_ systemName: String, label: String,
                             active: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.system(size: 18, weight: .semibold))
                .foregroundColor(active ? .black : .white)
                .frame(width: 44, height: 44)
                .background(active ? Color.white : Color.black.opacity(0.35))
                .clipShape(Circle())
        }
        .buttonStyle(SoftPressStyle())
        .accessibilityLabel(label)
    }

    private func loadGalleryThumb() {
        let status = PHPhotoLibrary.authorizationStatus(for: .readWrite)
        guard status == .authorized || status == .limited else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            let options = PHFetchOptions()
            options.fetchLimit = 1
            options.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: false)]
            let result = PHAsset.fetchAssets(with: .video, options: options)
            guard let asset = result.firstObject else { return }
            let request = PHImageRequestOptions()
            request.deliveryMode = .opportunistic
            request.isNetworkAccessAllowed = false
            PHImageManager.default().requestImage(
                for: asset, targetSize: CGSize(width: 156, height: 156),
                contentMode: .aspectFill, options: request
            ) { image, _ in
                guard let image else { return }
                DispatchQueue.main.async { galleryThumb = image }
            }
        }
    }
}

// MARK: - Metal viewfinder

/// The live preview. An `AVCaptureVideoPreviewLayer` cannot render a CIFilter at all, so the
/// filtered frames are drawn into an MTKView instead — the same shape Signal-iOS uses.
///
/// The gesture recognisers live in the UIView rather than in SwiftUI because focus needs the
/// exact aspect-fill geometry (which only the view knows) and because a single/double tap
/// pair resolves cleanly with `require(toFail:)`.
private struct ClipCameraPreview: UIViewRepresentable {
    let renderer: ClipCameraRenderer
    let onZoom: (CGFloat, Bool) -> Void
    /// Normalised (0…1) point inside the VISIBLE video, y down.
    let onFocus: (CGPoint) -> Void
    let onFlip: () -> Void

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView(frame: .zero, device: MTLCreateSystemDefaultDevice())
        // CIContext renders straight into the drawable's texture, which it cannot do while
        // the drawable is framebuffer-only.
        view.framebufferOnly = false
        view.isOpaque = true
        view.backgroundColor = .black
        view.colorPixelFormat = .bgra8Unorm
        view.preferredFramesPerSecond = 30
        view.delegate = renderer
        renderer.attach(to: view)

        context.coordinator.onZoom = onZoom
        context.coordinator.onFocus = onFocus
        context.coordinator.onFlip = onFlip
        context.coordinator.renderer = renderer

        let pinch = UIPinchGestureRecognizer(target: context.coordinator,
                                             action: #selector(Coordinator.handlePinch(_:)))
        let doubleTap = UITapGestureRecognizer(target: context.coordinator,
                                               action: #selector(Coordinator.handleDoubleTap(_:)))
        doubleTap.numberOfTapsRequired = 2
        let tap = UITapGestureRecognizer(target: context.coordinator,
                                         action: #selector(Coordinator.handleTap(_:)))
        tap.require(toFail: doubleTap)
        view.addGestureRecognizer(pinch)
        view.addGestureRecognizer(doubleTap)
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ uiView: MTKView, context: Context) {
        context.coordinator.onZoom = onZoom
        context.coordinator.onFocus = onFocus
        context.coordinator.onFlip = onFlip
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    final class Coordinator: NSObject {
        var onZoom: ((CGFloat, Bool) -> Void)?
        var onFocus: ((CGPoint) -> Void)?
        var onFlip: (() -> Void)?
        weak var renderer: ClipCameraRenderer?

        @objc func handlePinch(_ g: UIPinchGestureRecognizer) {
            switch g.state {
            case .began: onZoom?(1, true)
            case .changed: onZoom?(g.scale, false)
            default: break
            }
        }

        @objc func handleDoubleTap(_ g: UITapGestureRecognizer) { onFlip?() }

        @objc func handleTap(_ g: UITapGestureRecognizer) {
            guard let view = g.view, let renderer,
                  let normalized = renderer.normalizedPoint(forViewPoint: g.location(in: view),
                                                            in: view.bounds.size) else { return }
            onFocus?(normalized)
        }
    }
}

/// Holds the most recent filtered frame and draws it aspect-fill. Deliberately NOT an
/// ObservableObject: frames arrive 30 times a second on the capture queue and publishing
/// each one would push a SwiftUI invalidation per frame.
final class ClipCameraRenderer: NSObject, MTKViewDelegate {
    private let lock = NSLock()
    private var latest: CIImage?
    private var extent: CGRect = .zero
    private var ciContext: CIContext?
    private var commandQueue: MTLCommandQueue?
    private let colorSpace = CGColorSpaceCreateDeviceRGB()

    func attach(to view: MTKView) {
        guard let device = view.device, let queue = device.makeCommandQueue() else { return }
        commandQueue = queue
        // Intermediates are useless here: every frame is a different image, so caching them
        // only grows memory.
        ciContext = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
    }

    func submit(_ image: CIImage) {
        lock.lock()
        latest = image
        extent = image.extent
        lock.unlock()
    }

    /// Maps a point in the view to 0…1 inside the visible (aspect-filled, therefore cropped)
    /// video, so tap-to-focus lands where the finger actually is rather than where an
    /// un-cropped mapping would put it.
    func normalizedPoint(forViewPoint point: CGPoint, in size: CGSize) -> CGPoint? {
        lock.lock(); let ex = extent; lock.unlock()
        guard ex.width > 0, ex.height > 0, size.width > 0, size.height > 0 else { return nil }
        let scale = max(size.width / ex.width, size.height / ex.height)
        let drawnWidth = ex.width * scale
        let drawnHeight = ex.height * scale
        let originX = (size.width - drawnWidth) / 2
        let originY = (size.height - drawnHeight) / 2
        let u = (point.x - originX) / drawnWidth
        let v = (point.y - originY) / drawnHeight
        return CGPoint(x: min(max(u, 0), 1), y: min(max(v, 0), 1))
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let ciContext, let commandQueue,
              let drawable = view.currentDrawable,
              let buffer = commandQueue.makeCommandBuffer() else { return }
        lock.lock(); let image = latest; lock.unlock()
        guard let image else { return }

        let size = view.drawableSize
        let ex = image.extent
        guard ex.width > 0, ex.height > 0, size.width > 0, size.height > 0 else { return }

        // Aspect-fill: scale to cover, then centre. Done as a transform on the image rather
        // than as a source rect so the render bounds stay the whole drawable.
        let scale = max(size.width / ex.width, size.height / ex.height)
        let dx = (size.width - ex.width * scale) / 2 - ex.origin.x * scale
        let dy = (size.height - ex.height * scale) / 2 - ex.origin.y * scale
        let shown = image
            .transformed(by: CGAffineTransform(scaleX: scale, y: scale))
            .transformed(by: CGAffineTransform(translationX: dx, y: dy))

        ciContext.render(shown, to: drawable.texture, commandBuffer: buffer,
                         bounds: CGRect(origin: .zero, size: size), colorSpace: colorSpace)
        buffer.present(drawable)
        buffer.commit()
    }
}

// MARK: - Capture controller

/// NOT @MainActor: session configuration, frame delivery and writer appends all run on
/// private serial queues (isolating them to the main actor would freeze the UI and is
/// Apple-discouraged). Every @Published mutation hops back to main.
final class ClipCameraController: NSObject, ObservableObject,
                                  AVCaptureVideoDataOutputSampleBufferDelegate,
                                  AVCaptureAudioDataOutputSampleBufferDelegate {

    let session = AVCaptureSession()
    let renderer = ClipCameraRenderer()

    private let videoOut = AVCaptureVideoDataOutput()
    private let audioOut = AVCaptureAudioDataOutput()
    private let sessionQueue = DispatchQueue(label: "voiid.clip.camera.session")
    private let videoQueue = DispatchQueue(label: "voiid.clip.camera.video")
    private let audioQueue = DispatchQueue(label: "voiid.clip.camera.audio")
    /// Every writer touch happens here, so video and audio appends can never interleave
    /// mid-call from their two delivery queues.
    private let writerQueue = DispatchQueue(label: "voiid.clip.camera.writer")

    private var cameraInput: AVCaptureDeviceInput?
    private var micInput: AVCaptureDeviceInput?
    private var device: AVCaptureDevice?
    private var position: AVCaptureDevice.Position = .back
    private var configured = false
    private var pendingStopAfterFinish = false

    // MARK: Published state

    @Published var isRecording = false
    @Published var takes: [ClipTake] = []
    /// Output seconds of the take currently being written (already speed-adjusted).
    @Published var liveSeconds: Double = 0
    @Published var errorText: String?
    @Published var hasTorch = false
    @Published var torchOn = false
    @Published var selectedSpeed: Double = 1
    @Published var filter: ClipFilter = .none {
        didSet {
            filterLock.lock(); liveFilter = filter; filterLock.unlock()
        }
    }

    /// Re-derived from what is on disk rather than accumulated, so undo can never drift.
    var bankedSeconds: Double { takes.reduce(0) { $0 + $1.outputSeconds } }

    var maxSeconds: Double = ClipCaps.maxDurationSeconds

    private let filterLock = NSLock()
    private var liveFilter: ClipFilter = .none

    // MARK: Writer state — writerQueue only

    private var writer: AVAssetWriter?
    private var writerVideoInput: AVAssetWriterInput?
    private var writerAudioInput: AVAssetWriterInput?
    private var writing = false
    private var sessionStarted = false
    private var firstPTS: CMTime = .invalid
    private var lastPTS: CMTime = .invalid
    private var takeURL: URL?
    private var takeSpeed: Double = 1
    /// Recorded (1×) seconds this take is allowed before the cap is reached.
    private var recordBudget: Double = 0
    private var lastPublishedLive: Double = -1

    // MARK: Lifecycle

    func start() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            // Re-entering the camera after a push to the editor only needs the session back.
            if self.configured {
                if !self.session.isRunning { self.session.startRunning() }
                return
            }
            self.configured = true
            self.session.beginConfiguration()
            self.attachCamera(position: self.position)
            self.attachMicrophone()
            // 1080p explicitly, not `.high`: the export ladder's top rung is 1080p and a
            // 720p source would silently skip it. Asked AFTER the inputs are attached,
            // because a preset is only answerable against the devices in the session.
            if self.session.canSetSessionPreset(.hd1920x1080) {
                self.session.sessionPreset = .hd1920x1080
            } else {
                self.session.sessionPreset = .high
            }

            self.videoOut.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            self.videoOut.alwaysDiscardsLateVideoFrames = true
            self.videoOut.setSampleBufferDelegate(self, queue: self.videoQueue)
            if self.session.canAddOutput(self.videoOut) { self.session.addOutput(self.videoOut) }

            self.audioOut.setSampleBufferDelegate(self, queue: self.audioQueue)
            if self.session.canAddOutput(self.audioOut) { self.session.addOutput(self.audioOut) }

            self.session.commitConfiguration()
            self.applyConnectionGeometry()
            self.session.startRunning()
        }
    }

    /// Tearing the session down while a take is still being written truncates the file, so a
    /// recording in flight is finished first and the session stops from its completion.
    func stop() {
        if isRecording {
            pendingStopAfterFinish = true
            stopRecording()
            return
        }
        setTorch(on: false)
        sessionQueue.async { [weak self] in
            guard let self, self.session.isRunning else { return }
            self.session.stopRunning()
        }
    }

    private func attachCamera(position: AVCaptureDevice.Position) {
        if let cameraInput { session.removeInput(cameraInput) }
        guard let dev = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: dev),
              session.canAddInput(input) else {
            DispatchQueue.main.async { self.errorText = "Couldn't start the camera." }
            return
        }
        session.addInput(input)
        cameraInput = input
        device = dev
        let torch = dev.hasTorch
        DispatchQueue.main.async {
            self.hasTorch = torch
            if !torch { self.torchOn = false }
        }
    }

    private func attachMicrophone() {
        guard micInput == nil, let mic = AVCaptureDevice.default(for: .audio),
              let input = try? AVCaptureDeviceInput(device: mic),
              session.canAddInput(input) else { return }
        session.addInput(input)
        micInput = input
    }

    /// The buffers are rotated and mirrored HERE, once, so the preview and the written file
    /// agree and the file needs no preferred transform downstream.
    private func applyConnectionGeometry() {
        guard let connection = videoOut.connection(with: .video) else { return }
        if connection.isVideoRotationAngleSupported(90) { connection.videoRotationAngle = 90 }
        if connection.isVideoMirroringSupported {
            connection.automaticallyAdjustsVideoMirroring = false
            connection.isVideoMirrored = (position == .front)
        }
    }

    func flip() {
        guard !isRecording else { return }
        position = (position == .back) ? .front : .back
        sessionQueue.async { [weak self] in
            guard let self else { return }
            self.session.beginConfiguration()
            self.attachCamera(position: self.position)
            self.session.commitConfiguration()
            self.applyConnectionGeometry()
        }
    }

    // MARK: Hardware controls

    func toggleTorch() { setTorch(on: !torchOn) }

    private func setTorch(on: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.device, dev.hasTorch else { return }
            guard (try? dev.lockForConfiguration()) != nil else { return }
            dev.torchMode = on ? .on : .off
            dev.unlockForConfiguration()
            DispatchQueue.main.async { self.torchOn = on }
        }
    }

    private var zoomAtGestureStart: CGFloat = 1

    func zoom(scale: CGFloat, began: Bool) {
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.device else { return }
            if began { self.zoomAtGestureStart = dev.videoZoomFactor; return }
            let ceiling = min(dev.activeFormat.videoMaxZoomFactor, dev.maxAvailableVideoZoomFactor)
            let target = min(max(self.zoomAtGestureStart * scale, dev.minAvailableVideoZoomFactor),
                             ceiling)
            guard (try? dev.lockForConfiguration()) != nil else { return }
            dev.videoZoomFactor = target
            dev.unlockForConfiguration()
        }
    }

    /// `point` is 0…1 inside the visible video, y down. `focusPointOfInterest` is always
    /// expressed against a landscape-home-button-right sensor regardless of device
    /// orientation, so a portrait viewfinder point has to be rotated into that space — and
    /// un-mirrored again when the front camera preview is mirrored.
    func focus(atNormalizedViewPoint point: CGPoint) {
        let u = (position == .front) ? (1 - point.x) : point.x
        let devicePoint = CGPoint(x: point.y, y: 1 - u)
        Haptics.tap()
        sessionQueue.async { [weak self] in
            guard let self, let dev = self.device else { return }
            guard (try? dev.lockForConfiguration()) != nil else { return }
            if dev.isFocusPointOfInterestSupported, dev.isFocusModeSupported(.autoFocus) {
                dev.focusPointOfInterest = devicePoint
                dev.focusMode = .autoFocus
            }
            if dev.isExposurePointOfInterestSupported, dev.isExposureModeSupported(.continuousAutoExposure) {
                dev.exposurePointOfInterest = devicePoint
                dev.exposureMode = .continuousAutoExposure
            }
            dev.unlockForConfiguration()
        }
    }

    // MARK: Recording

    func startRecording() {
        guard !isRecording else { return }
        let remaining = maxSeconds - bankedSeconds
        guard remaining > 0.2 else { return }
        let speed = selectedSpeed
        Haptics.rigid()
        isRecording = true
        liveSeconds = 0
        errorText = nil
        // Recording is always 1×; a 0.3× take yields 1/0.3 output seconds per recorded
        // second, so the RECORDED budget has to be scaled by the speed or a slow-motion
        // take would sail past the backend's 90s cap.
        let budget = remaining * speed
        writerQueue.async { [weak self] in self?.beginWriter(speed: speed, budget: budget) }
    }

    func stopRecording() {
        guard isRecording else { return }
        writerQueue.async { [weak self] in self?.finishTake() }
    }

    func undoLastTake() {
        guard let last = takes.popLast() else { return }
        try? FileManager.default.removeItem(at: last.url)
        // `bankedSeconds` is a sum over what remains, so nothing needs correcting here —
        // subtracting the last measured duration is what drifts.
    }

    /// Throw away every take and its file. Used by Close and by a gallery import.
    func discardTakes() {
        for take in takes { try? FileManager.default.removeItem(at: take.url) }
        takes = []
    }

    /// Hand the takes on WITHOUT deleting them — the joiner owns the files from here.
    func forgetTakes() { takes = [] }

    /// The encoder settings AVFoundation recommends for this session, corrected for the
    /// quarter-turn the connection applies.
    ///
    /// The recommendation is quoted against the SENSOR, which is landscape, so on a rotated
    /// connection it can hand back a 1920×1080 target for 1080×1920 buffers — every take
    /// would come out pillarboxed. The swap is a no-op when the recommendation already came
    /// back portrait.
    private func portraitVideoSettings() -> [String: Any]? {
        guard var settings = videoOut.recommendedVideoSettingsForAssetWriter(writingTo: .mp4)
        else { return nil }
        guard let connection = videoOut.connection(with: .video),
              connection.videoRotationAngle == 90 || connection.videoRotationAngle == 270,
              let width = settings[AVVideoWidthKey] as? NSNumber,
              let height = settings[AVVideoHeightKey] as? NSNumber,
              width.intValue > height.intValue else { return settings }
        settings[AVVideoWidthKey] = height
        settings[AVVideoHeightKey] = width
        return settings
    }

    private func beginWriter(speed: Double, budget: Double) {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip_seg_\(UUID().uuidString).mp4")
        do {
            let assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)
            let videoInput = AVAssetWriterInput(mediaType: .video,
                                                outputSettings: portraitVideoSettings())
            videoInput.expectsMediaDataInRealTime = true
            guard assetWriter.canAdd(videoInput) else { throw ClipCameraError.writerRejectedInput }
            assetWriter.add(videoInput)

            var audioInput: AVAssetWriterInput?
            if let audioSettings = audioOut.recommendedAudioSettingsForAssetWriter(writingTo: .mp4)
                as? [String: Any] {
                let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
                input.expectsMediaDataInRealTime = true
                if assetWriter.canAdd(input) {
                    assetWriter.add(input)
                    audioInput = input
                }
            }

            guard assetWriter.startWriting() else { throw ClipCameraError.writerRejectedInput }

            writer = assetWriter
            writerVideoInput = videoInput
            writerAudioInput = audioInput
            takeURL = url
            takeSpeed = speed
            recordBudget = budget
            sessionStarted = false
            firstPTS = .invalid
            lastPTS = .invalid
            lastPublishedLive = -1
            writing = true
        } catch {
            try? FileManager.default.removeItem(at: url)
            DispatchQueue.main.async {
                self.isRecording = false
                self.errorText = "Couldn't start recording."
            }
        }
    }

    /// Close the current take. A take cut short by the cap is COMPLETE and playable, so it is
    /// kept — the AssetWriter equivalent of the story camera's salvage branch, where hitting
    /// `maxRecordedDuration` reports an "error" that actually means success.
    private func finishTake() {
        guard writing, let assetWriter = writer, let url = takeURL else { return }
        writing = false
        let recorded = (sessionStarted && lastPTS.isValid && firstPTS.isValid)
            ? (lastPTS - firstPTS).seconds : 0
        let speed = takeSpeed

        writerVideoInput?.markAsFinished()
        writerAudioInput?.markAsFinished()
        writer = nil
        writerVideoInput = nil
        writerAudioInput = nil
        takeURL = nil

        assetWriter.finishWriting { [weak self] in
            guard let self else { return }
            let ok = assetWriter.status == .completed && recorded >= 0.15
            DispatchQueue.main.async {
                self.isRecording = false
                self.liveSeconds = 0
                if ok {
                    self.takes.append(ClipTake(url: url, recordedSeconds: recorded, speed: speed))
                } else {
                    try? FileManager.default.removeItem(at: url)
                    // A dropped take with no message is indistinguishable from a broken
                    // shutter button.
                    if assetWriter.status == .failed {
                        self.errorText = assetWriter.error?.localizedDescription
                            ?? "That take couldn't be saved."
                    }
                }
                if self.pendingStopAfterFinish {
                    self.pendingStopAfterFinish = false
                    self.stop()
                }
            }
        }
    }

    // MARK: Frame delivery

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer,
                       from connection: AVCaptureConnection) {
        if output === videoOut {
            if let pixels = CMSampleBufferGetImageBuffer(sampleBuffer) {
                filterLock.lock(); let active = liveFilter; filterLock.unlock()
                // The FILTER IS PREVIEW-ONLY. The buffer handed to the writer below is the
                // untouched one, so the colour is baked exactly once, at export.
                renderer.submit(active.apply(to: CIImage(cvPixelBuffer: pixels)))
            }
            writerQueue.async { [weak self] in self?.appendVideo(sampleBuffer) }
        } else if output === audioOut {
            writerQueue.async { [weak self] in self?.appendAudio(sampleBuffer) }
        }
    }

    private func appendVideo(_ sample: CMSampleBuffer) {
        guard writing, let assetWriter = writer, let input = writerVideoInput,
              assetWriter.status == .writing else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        guard pts.isValid else { return }

        if !sessionStarted {
            assetWriter.startSession(atSourceTime: pts)
            sessionStarted = true
            firstPTS = pts
        }
        lastPTS = pts
        if input.isReadyForMoreMediaData { input.append(sample) }

        let recorded = (pts - firstPTS).seconds
        publishLive(recorded / takeSpeed)
        if recorded >= recordBudget { finishTake() }
    }

    private func appendAudio(_ sample: CMSampleBuffer) {
        // Audio that arrives before the first video frame would drag the session start
        // backwards and open the take with a black lead-in.
        guard writing, sessionStarted, let assetWriter = writer, let input = writerAudioInput,
              assetWriter.status == .writing, input.isReadyForMoreMediaData else { return }
        input.append(sample)
    }

    /// Publishing every frame would push a SwiftUI invalidation 30 times a second for a
    /// label that shows whole seconds.
    private func publishLive(_ seconds: Double) {
        guard abs(seconds - lastPublishedLive) >= 0.05 else { return }
        lastPublishedLive = seconds
        DispatchQueue.main.async { self.liveSeconds = seconds }
    }
}

private enum ClipCameraError: Error { case writerRejectedInput }

// MARK: - Joining takes

enum ClipTakeJoiner {

    /// Concatenate the takes into the single file the rest of the composer expects, applying
    /// each take's speed as a time scale.
    ///
    /// A lone 1× take is returned AS-IS: every take shares the same codec and session
    /// settings, so joining them is a passthrough remux, and copying one file through a full
    /// export would be pure loss in the overwhelmingly common case.
    static func join(takes: [ClipTake]) async -> URL? {
        guard !takes.isEmpty else { return nil }
        if takes.count == 1, takes[0].speed == 1 { return takes[0].url }

        let composition = AVMutableComposition()
        guard let videoTrack = composition.addMutableTrack(
                withMediaType: .video, preferredTrackID: kCMPersistentTrackID_Invalid) else {
            return nil
        }
        let audioTrack = composition.addMutableTrack(
            withMediaType: .audio, preferredTrackID: kCMPersistentTrackID_Invalid)

        var cursor = CMTime.zero
        var scaled = false

        for take in takes {
            let asset = AVURLAsset(url: take.url)
            guard let source = try? await asset.loadTracks(withMediaType: .video).first,
                  let duration = try? await asset.load(.duration),
                  duration.seconds > 0 else { continue }
            let range = CMTimeRange(start: .zero, duration: duration)
            do {
                try videoTrack.insertTimeRange(range, of: source, at: cursor)
            } catch {
                continue
            }
            if let sourceAudio = try? await asset.loadTracks(withMediaType: .audio).first,
               let audioTrack {
                try? audioTrack.insertTimeRange(range, of: sourceAudio, at: cursor)
            }

            if take.speed != 1 {
                scaled = true
                let target = CMTimeMultiplyByFloat64(duration, multiplier: 1.0 / take.speed)
                composition.scaleTimeRange(CMTimeRange(start: cursor, duration: duration),
                                           toDuration: target)
                cursor = cursor + target
            } else {
                cursor = cursor + duration
            }
        }

        guard cursor.seconds > 0 else { return nil }

        // Passthrough is invalid for a scaled segment — retiming needs a real encode — but
        // it is exactly right for a plain join, where every take already shares the encoder
        // settings the session produced.
        let primary = scaled ? AVAssetExportPreset1920x1080 : AVAssetExportPresetPassthrough
        if let out = await export(composition, preset: primary) {
            cleanUp(takes)
            return out
        }
        if primary == AVAssetExportPresetPassthrough,
           let out = await export(composition, preset: AVAssetExportPreset1920x1080) {
            cleanUp(takes)
            return out
        }
        return nil
    }

    private static func export(_ composition: AVMutableComposition, preset: String) async -> URL? {
        guard let session = AVAssetExportSession(asset: composition, presetName: preset) else {
            return nil
        }
        let out = FileManager.default.temporaryDirectory
            .appendingPathComponent("clip_takes_\(UUID().uuidString).mp4")
        session.outputURL = out
        session.outputFileType = .mp4
        session.shouldOptimizeForNetworkUse = true
        await session.export()
        guard session.status == .completed else {
            try? FileManager.default.removeItem(at: out)
            return nil
        }
        return out
    }

    /// The takes are consumed by the join; leaving them behind would double the temp-file
    /// cost of every multi-segment recording.
    private static func cleanUp(_ takes: [ClipTake]) {
        for take in takes { try? FileManager.default.removeItem(at: take.url) }
    }
}
