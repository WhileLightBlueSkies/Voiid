//
//  FaceFXEngine.swift
//  Voiid
//
//  The whole face-FX subsystem behind one type. ClipCameraView talks to this
//  and to nothing else inside FaceFX/.
//
//  Selecting a filter is deliberately trivial — a reference swap under a lock.
//  Every expensive thing (pipeline states, atlas uploads, the canonical model,
//  the ARKit session) has already happened by the time the rail is tappable,
//  so a tap shows the filter on the very next frame rather than after a hitch.
//

import Foundation
import ARKit
import Metal
import CoreVideo
import simd

protocol FaceFXEngineDelegate: AnyObject {
    /// A finished frame. `texture` is the SAME texture the recorder receives,
    /// so preview and recording cannot diverge.
    func faceFXEngine(_ engine: FaceFXEngine,
                      didRender texture: MTLTexture,
                      commandBuffer: MTLCommandBuffer,
                      frame: FaceFrame)
}

final class FaceFXEngine {

    enum State { case idle, running, unsupported }

    weak var delegate: FaceFXEngineDelegate?
    private(set) var state: State = .idle

    let device: MTLDevice
    private let renderer: FXRenderer
    private let store: FXAssetStore
    private let tracker: FaceTracker
    private let canonical: CanonicalFaceModel

    private let selectionLock = NSLock()
    private var _selected: LoadedFilter?
    private var _selectedId: String?

    private var textureCache: CVMetalTextureCache?
    private var startTime = CFAbsoluteTimeGetCurrent()

    /// Filters this device can actually run, in rail order.
    private(set) var availableFilterIds: [String] = []

    /// Face filters need ARKit face tracking, which is front-camera only.
    /// The rail is hidden rather than populated with things that cannot work.
    static var isSupported: Bool { FaceTracker.isSupported }

    init(device: MTLDevice) throws {
        self.device = device
        self.canonical = try CanonicalFaceModel.loadBundled()
        self.renderer = try FXRenderer(device: device)
        self.store = FXAssetStore(device: device)
        self.tracker = FaceTracker(canonical: canonical)

        CVMetalTextureCacheCreate(kCFAllocatorDefault, nil, device, nil, &textureCache)

        // Everything expensive happens here, before the UI exists.
        availableFilterIds = store.loadBundled()

        // ARKit's mesh has its own topology; the canonical UVs and indices are
        // only used for the Android mesh and for face textures, so the occluder
        // topology is supplied when the first ARKit frame reveals it.
        renderer.setMesh(vertexCount: canonical.meshVertexCount,
                         uvs: canonical.uvs,
                         indices: canonical.triangles)

        tracker.delegate = self
        state = Self.isSupported ? .idle : .unsupported
    }

    // MARK: Lifecycle

    func start() {
        guard state != .unsupported else { return }
        startTime = CFAbsoluteTimeGetCurrent()
        tracker.start()
        state = .running
    }

    func stop() {
        tracker.stop()
        renderer.resetPhysics()
        state = .idle
    }

    func resize(to size: CGSize) { renderer.resize(to: size) }

    // MARK: Selection

    var selectedFilterId: String? {
        selectionLock.lock(); defer { selectionLock.unlock() }
        return _selectedId
    }

    /// Nothing here touches the GPU. Pass `nil` for no filter.
    func select(filterId: String?) {
        let next = filterId.flatMap { store.filter($0) }
        selectionLock.lock()
        _selected = next
        _selectedId = next == nil ? nil : filterId
        selectionLock.unlock()

        // Physics and smoothing are per-filter: a new filter must not inherit
        // the previous one's spring energy, or its ears arrive mid-bounce.
        renderer.resetPhysics()
        tracker.resetSmoothing()
    }

    private var currentFilter: LoadedFilter? {
        selectionLock.lock(); defer { selectionLock.unlock() }
        return _selected
    }

    // MARK: Texture plumbing

    /// Wraps a plane of the ARKit pixel buffer as a Metal texture. Zero copy —
    /// the GPU reads the camera's own IOSurface.
    private func texture(from buffer: CVPixelBuffer,
                         plane: Int,
                         format: MTLPixelFormat) -> MTLTexture? {
        guard let cache = textureCache else { return nil }
        let w = CVPixelBufferGetWidthOfPlane(buffer, plane)
        let h = CVPixelBufferGetHeightOfPlane(buffer, plane)
        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            kCFAllocatorDefault, cache, buffer, nil, format, w, h, plane, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture else { return nil }
        return CVMetalTextureGetTexture(cvTexture)
    }
}

extension FaceFXEngine: FaceTrackerDelegate {
    func faceTracker(_ tracker: FaceTracker,
                     didProduce frame: FaceFrame,
                     pixelBuffer: CVPixelBuffer,
                     camera: ARCamera) {
        guard let luma = texture(from: pixelBuffer, plane: 0, format: .r8Unorm),
              let chroma = texture(from: pixelBuffer, plane: 1, format: .rg8Unorm),
              let commandBuffer = renderer.commandQueue.makeCommandBuffer()
        else { return }

        let size = CGSize(width: CVPixelBufferGetWidth(pixelBuffer),
                          height: CVPixelBufferGetHeight(pixelBuffer))
        renderer.resize(to: size)

        let projection = camera.projectionMatrix(
            for: .portrait, viewportSize: size, zNear: 0.001, zFar: 10)

        let inputs = FXRenderer.FrameInputs(
            luma: luma, chroma: chroma, frame: frame,
            filter: currentFilter,
            viewProjection: projection,
            angularVelocity: tracker.angularVelocity,
            time: Float(CFAbsoluteTimeGetCurrent() - startTime))

        guard let output = renderer.render(inputs, into: commandBuffer) else { return }
        delegate?.faceFXEngine(self, didRender: output,
                               commandBuffer: commandBuffer, frame: frame)
        commandBuffer.commit()
    }
}
