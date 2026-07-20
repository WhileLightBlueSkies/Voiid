//
//  CallPiPController.swift
//  Voiid
//
//  Picture-in-Picture for 1:1 video calls.
//
//  WHY THIS EXISTS: `RTCMTLVideoView` (the Metal renderer used everywhere else)
//  cannot be picture-in-picture'd. iOS only knows how to PiP an
//  `AVSampleBufferDisplayLayer` driven through
//  `AVPictureInPictureController.ContentSource(sampleBufferDisplayLayer:playbackDelegate:)`.
//  So we implement our own `RTCVideoRenderer` that takes the REMOTE track's
//  `RTCVideoFrame`s, turns each into a `CMSampleBuffer`, and enqueues it into a
//  sample-buffer layer. That one layer both fills the in-app call screen and
//  backs the system PiP window, so backgrounding the app hands the *same*
//  pixel stream to the PiP window with no re-plumbing.
//
//  RUNTIME CAVEAT: PiP does not work in the iOS Simulator. Everything here is
//  compile-verified and guarded (`isPictureInPictureSupported`), but the actual
//  PiP window, the automatic start-on-background, and the restore tap can only
//  be validated on real hardware with two devices on a live call.
//

import Foundation
import AVFoundation
import AVKit
import CoreImage
import CoreMedia
import CoreVideo
import Combine
import UIKit
// @preconcurrency: WebRTC's ObjC types (RTCVideoFrame, RTCVideoTrack) predate
// Swift concurrency and aren't Sendable-annotated. Frame handoff to the render
// queue is safe — each frame is owned solely by the queue once handed over.
@preconcurrency import WebRTC

extension Notification.Name {
    /// Posted when the user taps the PiP window to come back to the call.
    /// `ContentView` observes this and re-presents the call screen if it was gone.
    static let voiidRestoreCallUI = Notification.Name("voiidRestoreCallUI")
}

// MARK: - Host view

/// A `UIView` whose backing layer IS an `AVSampleBufferDisplayLayer`, so the
/// layer is guaranteed to be in the view hierarchy (a hard requirement for
/// `canStartPictureInPictureAutomaticallyFromInline`).
final class SampleBufferVideoHostView: UIView {
    override class var layerClass: AnyClass { AVSampleBufferDisplayLayer.self }

    var displayLayer: AVSampleBufferDisplayLayer {
        // Safe: `layerClass` above guarantees the type.
        layer as! AVSampleBufferDisplayLayer
    }

    override init(frame: CGRect) {
        super.init(frame: frame)
        backgroundColor = .black
        displayLayer.videoGravity = .resizeAspectFill
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }
}

// MARK: - RTCVideoFrame -> CVPixelBuffer

/// Converts WebRTC frames into `CVPixelBuffer`s suitable for an
/// `AVSampleBufferDisplayLayer`, handling both hardware-decoded
/// (`RTCCVPixelBuffer`, already NV12) and software/I420 frames, plus rotation.
///
/// Not thread safe on its own — `SampleBufferVideoRenderer` confines it to a
/// single serial queue.
private final class PixelBufferConverter {
    /// Pool for the I420 -> NV12 conversion output.
    private var nv12Pool: CVPixelBufferPool?
    private var nv12Width = 0
    private var nv12Height = 0

    /// Pool for the rotated output (BGRA — CoreImage renders into it directly).
    private var rotatedPool: CVPixelBufferPool?
    private var rotatedWidth = 0
    private var rotatedHeight = 0

    private lazy var ciContext = CIContext(options: [.useSoftwareRenderer: false])

    /// Returns a displayable pixel buffer with the frame's rotation baked in.
    func pixelBuffer(from frame: RTCVideoFrame) -> CVPixelBuffer? {
        guard let upright = basePixelBuffer(from: frame) else { return nil }
        return applyRotation(frame.rotation, to: upright)
    }

    // MARK: base buffer

    private func basePixelBuffer(from frame: RTCVideoFrame) -> CVPixelBuffer? {
        // Hardware-decoded path: the frame already carries a CVPixelBuffer. Use it
        // as-is unless it needs cropping, in which case fall through to the I420
        // path (which resolves the crop for us) rather than reimplementing it.
        if let cv = frame.buffer as? RTCCVPixelBuffer, !cv.requiresCropping() {
            return cv.pixelBuffer
        }
        return nv12Buffer(from: frame.buffer.toI420())
    }

    /// I420 (3 planar) -> NV12 (biplanar), the format the display layer likes.
    private func nv12Buffer(from i420: RTCI420BufferProtocol) -> CVPixelBuffer? {
        let width = Int(i420.width)
        let height = Int(i420.height)
        guard width > 0, height > 0 else { return nil }

        if nv12Pool == nil || nv12Width != width || nv12Height != height {
            nv12Pool = Self.makePool(width: width, height: height,
                                     format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            nv12Width = width
            nv12Height = height
        }
        guard let pool = nv12Pool else { return nil }

        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let dst = out else { return nil }

        guard CVPixelBufferLockBaseAddress(dst, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(dst, []) }

        // --- Luma: straight row copy (strides usually differ). ---
        if let dstY = CVPixelBufferGetBaseAddressOfPlane(dst, 0) {
            let dstStrideY = CVPixelBufferGetBytesPerRowOfPlane(dst, 0)
            let srcStrideY = Int(i420.strideY)
            let srcY = i420.dataY
            let copyBytes = min(dstStrideY, srcStrideY)
            for row in 0..<height {
                memcpy(dstY.advanced(by: row * dstStrideY),
                       srcY.advanced(by: row * srcStrideY),
                       copyBytes)
            }
        }

        // --- Chroma: interleave the separate U and V planes into one UV plane. ---
        if let dstUV = CVPixelBufferGetBaseAddressOfPlane(dst, 1) {
            let dstStrideUV = CVPixelBufferGetBytesPerRowOfPlane(dst, 1)
            let chromaWidth = Int(i420.chromaWidth)
            let chromaHeight = Int(i420.chromaHeight)
            let srcStrideU = Int(i420.strideU)
            let srcStrideV = Int(i420.strideV)
            let srcU = i420.dataU
            let srcV = i420.dataV
            let uv = dstUV.assumingMemoryBound(to: UInt8.self)
            for row in 0..<chromaHeight {
                let rowBase = uv.advanced(by: row * dstStrideUV)
                let uRow = srcU.advanced(by: row * srcStrideU)
                let vRow = srcV.advanced(by: row * srcStrideV)
                for col in 0..<chromaWidth {
                    rowBase[col * 2] = uRow[col]
                    rowBase[col * 2 + 1] = vRow[col]
                }
            }
        }
        return dst
    }

    // MARK: rotation

    /// PiP renders straight from the enqueued sample buffers, so a CALayer
    /// transform would NOT rotate the PiP window — the rotation has to be baked
    /// into the pixels.
    private func applyRotation(_ rotation: RTCVideoRotation, to source: CVPixelBuffer) -> CVPixelBuffer? {
        let orientation: CGImagePropertyOrientation
        switch rotation {
        case ._0:   return source
        case ._90:  orientation = .right
        case ._180: orientation = .down
        case ._270: orientation = .left
        @unknown default: return source
        }

        let srcWidth = CVPixelBufferGetWidth(source)
        let srcHeight = CVPixelBufferGetHeight(source)
        let swaps = (rotation == ._90 || rotation == ._270)
        let outWidth = swaps ? srcHeight : srcWidth
        let outHeight = swaps ? srcWidth : srcHeight
        guard outWidth > 0, outHeight > 0 else { return source }

        if rotatedPool == nil || rotatedWidth != outWidth || rotatedHeight != outHeight {
            rotatedPool = Self.makePool(width: outWidth, height: outHeight,
                                        format: kCVPixelFormatType_32BGRA)
            rotatedWidth = outWidth
            rotatedHeight = outHeight
        }
        guard let pool = rotatedPool else { return source }

        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &out) == kCVReturnSuccess,
              let dst = out else { return source }

        let image = CIImage(cvPixelBuffer: source).oriented(orientation)
        // `oriented` leaves the extent origin off-zero; move it back to (0,0).
        let normalized = image.transformed(by: CGAffineTransform(translationX: -image.extent.origin.x,
                                                                y: -image.extent.origin.y))
        ciContext.render(normalized, to: dst)
        return dst
    }

    // MARK: pool

    private static func makePool(width: Int, height: Int, format: OSType) -> CVPixelBufferPool? {
        let attrs: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: format,
            kCVPixelBufferWidthKey: width,
            kCVPixelBufferHeightKey: height,
            kCVPixelBufferIOSurfacePropertiesKey: [:] as CFDictionary,   // required for display/PiP
            kCVPixelBufferMetalCompatibilityKey: true,
        ]
        var pool: CVPixelBufferPool?
        let status = CVPixelBufferPoolCreate(kCFAllocatorDefault,
                                             [kCVPixelBufferPoolMinimumBufferCountKey: 4] as CFDictionary,
                                             attrs as CFDictionary,
                                             &pool)
        guard status == kCVReturnSuccess else {
            NSLog("[VOIID] PiP: pixel buffer pool creation failed (\(status))")
            return nil
        }
        return pool
    }
}

// MARK: - RTCVideoRenderer -> AVSampleBufferDisplayLayer

/// Receives remote video frames (on WebRTC's decoder thread) and enqueues them
/// into the sample-buffer layer that powers both the in-app view and PiP.
final class SampleBufferVideoRenderer: NSObject, RTCVideoRenderer, @unchecked Sendable {
    /// All conversion + enqueueing is confined to this one serial queue.
    private let queue = DispatchQueue(label: "com.voiid.call.pip.render", qos: .userInteractive)
    private let converter = PixelBufferConverter()

    private let lock = NSLock()
    /// Captured on the main thread at bind time so we never touch CALayer
    /// properties from the render queue.
    private var _renderer: AVSampleBufferVideoRenderer?
    private var renderer: AVSampleBufferVideoRenderer? {
        lock.lock(); defer { lock.unlock() }
        return _renderer
    }

    /// Point the renderer at a layer (or `nil` to stop rendering). Main thread.
    func bind(layer: AVSampleBufferDisplayLayer?) {
        lock.lock()
        _renderer = layer?.sampleBufferRenderer
        lock.unlock()
    }

    // MARK: RTCVideoRenderer

    nonisolated func setSize(_ size: CGSize) { /* the layer sizes itself from the buffers */ }

    nonisolated func renderFrame(_ frame: RTCVideoFrame?) {
        guard let frame else { return }
        queue.async { [weak self] in self?.enqueue(frame) }
    }

    // MARK: rendering

    private func enqueue(_ frame: RTCVideoFrame) {
        guard let renderer else { return }
        guard let pixelBuffer = converter.pixelBuffer(from: frame) else { return }
        guard let sample = Self.makeSampleBuffer(pixelBuffer, timeStampNs: frame.timeStampNs) else { return }

        // A failed renderer stays failed until flushed (happens after some
        // backgrounding transitions) — recover instead of freezing the picture.
        if renderer.status == .failed { renderer.flush() }
        renderer.enqueue(sample)
    }

    private static func makeSampleBuffer(_ pixelBuffer: CVPixelBuffer, timeStampNs: Int64) -> CMSampleBuffer? {
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
                                                           imageBuffer: pixelBuffer,
                                                           formatDescriptionOut: &formatDescription) == noErr,
              let formatDescription else { return nil }

        var timing = CMSampleTimingInfo(
            duration: .invalid,
            presentationTimeStamp: CMTime(value: timeStampNs, timescale: 1_000_000_000),
            decodeTimeStamp: .invalid
        )
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault,
                                                       imageBuffer: pixelBuffer,
                                                       formatDescription: formatDescription,
                                                       sampleTiming: &timing,
                                                       sampleBufferOut: &sample) == noErr,
              let sample else { return nil }

        // Live call video: show every frame the instant it lands. This also means
        // we don't need a control timebase (there is nothing to seek).
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let raw = CFArrayGetValueAtIndex(attachments, 0)
            let dict = unsafeBitCast(raw, to: CFMutableDictionary.self)
            CFDictionarySetValue(dict,
                                 Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }
}

// MARK: - PiP controller

/// Owns the single sample-buffer layer used for remote video + its
/// `AVPictureInPictureController`. Wired to `CallService` in `observe(_:)`, so
/// PiP follows the call lifecycle without the call engine knowing about AVKit.
@MainActor
final class CallPiPController: NSObject, ObservableObject {
    static let shared = CallPiPController()

    /// True while the system PiP window is on screen.
    @Published private(set) var isPiPActive = false
    /// False when the device/OS refuses PiP — the UI can stay silent about it.
    let isSupported = AVPictureInPictureController.isPictureInPictureSupported()

    /// The view the call screen hosts. Shared (one layer for in-app + PiP).
    let hostView = SampleBufferVideoHostView()

    private let renderer = SampleBufferVideoRenderer()
    private var pipController: AVPictureInPictureController?
    private weak var attachedTrack: RTCVideoTrack?
    private var cancellables = Set<AnyCancellable>()

    private override init() { super.init() }

    /// Follow the call engine: attach on remote track arrival, tear down on end.
    func observe(_ service: CallService) {
        guard cancellables.isEmpty else { return }

        service.$remoteVideoTrack
            .removeDuplicates { $0 === $1 }
            .sink { [weak self] track in
                Task { @MainActor in self?.attach(track: track) }
            }
            .store(in: &cancellables)

        service.$active
            .sink { [weak self] call in
                if call == nil || call?.state == .ended {
                    Task { @MainActor in self?.teardown() }
                }
            }
            .store(in: &cancellables)
    }

    // MARK: attach / detach

    private func attach(track: RTCVideoTrack?) {
        guard track !== attachedTrack else { return }
        detachTrack()
        guard let track else { return }

        renderer.bind(layer: hostView.displayLayer)
        track.add(renderer)
        attachedTrack = track
        preparePiPController()
    }

    private func detachTrack() {
        if let attachedTrack { attachedTrack.remove(renderer) }
        attachedTrack = nil
        renderer.bind(layer: nil)
    }

    /// Build the PiP controller once a remote video track exists. Everything is
    /// optional: if PiP is unsupported or the controller can't be created, the
    /// call carries on as a normal full-screen video call.
    private func preparePiPController() {
        guard isSupported else {
            NSLog("[VOIID] PiP unsupported on this device — video call continues without it")
            return
        }
        guard pipController == nil else { return }

        let source = AVPictureInPictureController.ContentSource(
            sampleBufferDisplayLayer: hostView.displayLayer,
            playbackDelegate: self
        )
        let controller = AVPictureInPictureController(contentSource: source)
        // The whole point: backgrounding the app during a video call pops PiP.
        controller.canStartPictureInPictureAutomaticallyFromInline = true
        controller.delegate = self
        pipController = controller
    }

    /// Call ended (or the screen went away): stop PiP so no orphan window is left.
    func teardown() {
        if let pipController, pipController.isPictureInPictureActive {
            pipController.stopPictureInPicture()
        }
        detachTrack()
        pipController?.delegate = nil
        pipController = nil
        isPiPActive = false
        hostView.displayLayer.sampleBufferRenderer.flush()
    }

    // MARK: gravity

    /// PiP windows are small — letterbox there, fill in-app.
    fileprivate func setPiPPresentation(_ active: Bool) {
        hostView.displayLayer.videoGravity = active ? .resizeAspect : .resizeAspectFill
        isPiPActive = active
    }
}

// MARK: - AVPictureInPictureControllerDelegate

extension CallPiPController: AVPictureInPictureControllerDelegate {
    nonisolated func pictureInPictureControllerWillStartPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.setPiPPresentation(true) }
    }

    nonisolated func pictureInPictureControllerDidStopPictureInPicture(_ controller: AVPictureInPictureController) {
        Task { @MainActor in self.setPiPPresentation(false) }
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                failedToStartPictureInPictureWithError error: Error) {
        NSLog("[VOIID] PiP failed to start: \(error.localizedDescription)")
        Task { @MainActor in self.setPiPPresentation(false) }
    }

    /// User tapped the PiP window to come back. Ask the app to show the call
    /// screen again (it is usually still presented underneath, in which case the
    /// notification is a no-op), then let the system dismiss the PiP window.
    nonisolated func pictureInPictureController(
        _ controller: AVPictureInPictureController,
        restoreUserInterfaceForPictureInPictureStopWithCompletionHandler completionHandler: @escaping (Bool) -> Void
    ) {
        Task { @MainActor in
            NotificationCenter.default.post(name: .voiidRestoreCallUI, object: nil)
            completionHandler(true)
        }
    }
}

// MARK: - AVPictureInPictureSampleBufferPlaybackDelegate

/// A live call has no timeline: no scrubber, never paused, seeking is a no-op.
extension CallPiPController: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                setPlaying playing: Bool) {
        // Live stream — there is nothing to pause. Deliberately ignored.
    }

    /// An infinite range tells PiP this is live content, which hides the scrubber.
    nonisolated func pictureInPictureControllerTimeRangeForPlayback(
        _ controller: AVPictureInPictureController
    ) -> CMTimeRange {
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated func pictureInPictureControllerIsPlaybackPaused(
        _ controller: AVPictureInPictureController
    ) -> Bool {
        false
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                didTransitionToRenderSize newRenderSize: CMVideoDimensions) {
        // Nothing to do: the layer scales the incoming buffers itself.
    }

    nonisolated func pictureInPictureController(_ controller: AVPictureInPictureController,
                                                skipByInterval skipInterval: CMTime,
                                                completion completionHandler: @escaping () -> Void) {
        completionHandler()   // can't skip a live call; complete immediately
    }
}
