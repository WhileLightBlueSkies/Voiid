//
//  FXRenderer.swift
//  Voiid
//
//  Metal orchestration for the face-FX pass chain.
//
//  TWO RULES, and most of the perceived quality comes from them:
//
//  1. NOTHING IS BUILT WHEN A FILTER IS SELECTED. Every pipeline state for
//     every pass is compiled at init, and every bundled atlas is uploaded at
//     init. Selecting a filter swaps a struct reference and nothing else, so a
//     tap applies on the very next frame. Building a MTLRenderPipelineState
//     costs milliseconds and would show up as a visible hitch on the first
//     frame of every filter.
//
//  2. NOTHING IS ALLOCATED PER FRAME. Buffers are sized once and reused. The
//     old pipeline allocated a fresh 720p pixel buffer per tracked frame and
//     that, more than anything else, is why it stuttered.
//

import Foundation
import Metal
import MetalKit
import simd

final class FXRenderer {

    // MARK: Pipeline states, all built once

    private struct Pipelines {
        let camera: MTLRenderPipelineState
        let blur: MTLRenderPipelineState
        let beautyCombine: MTLRenderPipelineState
        let colour: MTLRenderPipelineState
        let warp: MTLRenderPipelineState
        let faceTexture: MTLRenderPipelineState
        let occluder: MTLRenderPipelineState
        let props: MTLRenderPipelineState
        let composite: MTLRenderPipelineState
    }

    private let device: MTLDevice
    /// One queue for the whole session. Creating a command queue is not free
    /// and must never happen in the frame path.
    let commandQueue: MTLCommandQueue
    private let pipelines: Pipelines
    private let depthWriteState: MTLDepthStencilState
    private let depthTestState: MTLDepthStencilState
    private let depthIgnoreState: MTLDepthStencilState

    /// Ping-pong targets. Two is enough: a pass reads one and writes the other,
    /// then they swap. Reading and writing one texture is undefined and shows
    /// up as tearing that only reproduces on some GPUs.
    private var targets: [MTLTexture] = []
    private var depth: MTLTexture?
    private var targetSize: CGSize = .zero

    /// Triple-buffered so the CPU can build frame N+1's instances while the GPU
    /// still reads frame N's.
    private static let framesInFlight = 3
    private var instanceBuffers: [MTLBuffer] = []
    private var uniformBuffers: [MTLBuffer] = []
    private var warpBuffers: [MTLBuffer] = []
    private var frameIndex = 0
    private let inFlight = DispatchSemaphore(value: framesInFlight)

    private static let maxProps = 32
    private static let maxWarps = 8

    /// Face mesh geometry, uploaded once per topology.
    private var meshVertexBuffer: MTLBuffer?
    private var meshUVBuffer: MTLBuffer?
    private var meshIndexBuffer: MTLBuffer?
    private var meshIndexCount = 0

    private var springs: [String: SpringState] = [:]

    init(device: MTLDevice) throws {
        self.device = device
        guard let queue = device.makeCommandQueue() else { throw FXRendererError.noCommandQueue }
        self.commandQueue = queue

        let library = try Self.makeLibrary(device: device)

        func pipeline(_ vertex: String, _ fragment: String,
                      blending: Bool, depth: Bool = false) throws -> MTLRenderPipelineState {
            let d = MTLRenderPipelineDescriptor()
            d.vertexFunction = library.makeFunction(name: vertex)
            d.fragmentFunction = fragment.isEmpty ? nil : library.makeFunction(name: fragment)
            d.colorAttachments[0].pixelFormat = .bgra8Unorm
            if blending {
                // Premultiplied alpha: atlases are packed premultiplied, which
                // is what keeps a soft edge from haloing dark.
                guard let a = d.colorAttachments[0] else { throw FXRendererError.bufferAllocationFailed }
                a.isBlendingEnabled = true
                a.rgbBlendOperation = .add
                a.alphaBlendOperation = .add
                a.sourceRGBBlendFactor = .one
                a.sourceAlphaBlendFactor = .one
                a.destinationRGBBlendFactor = .oneMinusSourceAlpha
                a.destinationAlphaBlendFactor = .oneMinusSourceAlpha
            }
            if depth { d.depthAttachmentPixelFormat = .depth32Float }
            return try device.makeRenderPipelineState(descriptor: d)
        }

        // The occluder writes depth and no colour at all.
        let occluderDesc = MTLRenderPipelineDescriptor()
        occluderDesc.vertexFunction = library.makeFunction(name: "fxOccluderVertex")
        occluderDesc.fragmentFunction = library.makeFunction(name: "fxOccluderFragment")
        occluderDesc.colorAttachments[0].pixelFormat = .bgra8Unorm
        occluderDesc.colorAttachments[0].writeMask = []
        occluderDesc.depthAttachmentPixelFormat = .depth32Float

        pipelines = Pipelines(
            camera:        try pipeline("fxFullscreenVertex", "fxCameraFragment", blending: false),
            blur:          try pipeline("fxFullscreenVertex", "fxBlurFragment", blending: false),
            beautyCombine: try pipeline("fxFullscreenVertex", "fxBeautyCombineFragment", blending: false),
            colour:        try pipeline("fxFullscreenVertex", "fxColourFragment", blending: false),
            warp:          try pipeline("fxFullscreenVertex", "fxWarpFragment", blending: false),
            faceTexture:   try pipeline("fxFaceTexVertex", "fxFaceTexFragment", blending: true, depth: true),
            occluder:      try device.makeRenderPipelineState(descriptor: occluderDesc),
            props:         try pipeline("fxPropVertex", "fxPropFragment", blending: true, depth: true),
            composite:     try pipeline("fxFullscreenVertex", "fxCompositeFragment", blending: false))

        func depthState(write: Bool, test: Bool) -> MTLDepthStencilState {
            let d = MTLDepthStencilDescriptor()
            d.depthCompareFunction = test ? .less : .always
            d.isDepthWriteEnabled = write
            return device.makeDepthStencilState(descriptor: d)!
        }
        depthWriteState  = depthState(write: true,  test: true)
        depthTestState   = depthState(write: false, test: true)
        depthIgnoreState = depthState(write: false, test: false)

        for _ in 0..<Self.framesInFlight {
            guard let ib = device.makeBuffer(length: MemoryLayout<PropInstanceGPU>.stride * Self.maxProps,
                                             options: .storageModeShared),
                  let ub = device.makeBuffer(length: MemoryLayout<FXUniformsGPU>.stride,
                                             options: .storageModeShared),
                  let wb = device.makeBuffer(length: MemoryLayout<WarpControlGPU>.stride * Self.maxWarps,
                                             options: .storageModeShared)
            else { throw FXRendererError.bufferAllocationFailed }
            instanceBuffers.append(ib)
            uniformBuffers.append(ub)
            warpBuffers.append(wb)
        }
    }

    /// The shaders live in the app's default library when built by Xcode. The
    /// fallback compiles them from source, which keeps the engine usable in a
    /// unit-test bundle that has no Metal build phase.
    private static func makeLibrary(device: MTLDevice) throws -> MTLLibrary {
        if let lib = device.makeDefaultLibrary(),
           lib.makeFunction(name: "fxPropVertex") != nil {
            return lib
        }
        guard let url = Bundle.main.url(forResource: "FaceFX", withExtension: "metal"),
              let source = try? String(contentsOf: url, encoding: .utf8) else {
            throw FXRendererError.shaderLibraryMissing
        }
        return try device.makeLibrary(source: source, options: nil)
    }

    // MARK: Sizing

    /// Reallocates targets only when the size actually changes. Called every
    /// frame; almost always a no-op.
    func resize(to size: CGSize) {
        guard size != targetSize, size.width > 0, size.height > 0 else { return }
        targetSize = size

        func target() -> MTLTexture? {
            let d = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: Int(size.width), height: Int(size.height), mipmapped: false)
            d.usage = [.renderTarget, .shaderRead]
            d.storageMode = .private
            return device.makeTexture(descriptor: d)
        }
        targets = [target(), target()].compactMap { $0 }

        let dd = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .depth32Float,
            width: Int(size.width), height: Int(size.height), mipmapped: false)
        dd.usage = [.renderTarget]
        dd.storageMode = .private
        depth = device.makeTexture(descriptor: dd)
    }

    /// Uploads a face mesh topology. Called when the mesh changes shape, which
    /// in practice is once: ARKit's topology is constant.
    func setMesh(vertexCount: Int, uvs: [SIMD2<Float>], indices: [UInt16]) {
        meshVertexBuffer = device.makeBuffer(
            length: MemoryLayout<SIMD3<Float>>.stride * vertexCount, options: .storageModeShared)
        if !uvs.isEmpty {
            meshUVBuffer = uvs.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }
        }
        if !indices.isEmpty {
            meshIndexBuffer = indices.withUnsafeBytes {
                device.makeBuffer(bytes: $0.baseAddress!, length: $0.count, options: .storageModeShared)
            }
            meshIndexCount = indices.count
        }
    }

    func resetPhysics() { springs.removeAll(keepingCapacity: true) }

    // MARK: Per-frame

    struct FrameInputs {
        let luma: MTLTexture
        let chroma: MTLTexture
        let frame: FaceFrame
        let filter: LoadedFilter?
        let viewProjection: simd_float4x4
        let angularVelocity: SIMD3<Float>
        let time: Float
    }

    /// Encodes the whole chain and returns the texture holding the result.
    /// The SAME texture is handed to the preview and to the encoder, so what is
    /// recorded is by construction what was seen.
    func render(_ inputs: FrameInputs, into commandBuffer: MTLCommandBuffer) -> MTLTexture? {
        guard targets.count == 2, let depth else { return nil }

        inFlight.wait()
        commandBuffer.addCompletedHandler { [inFlight] _ in inFlight.signal() }
        let slot = frameIndex % Self.framesInFlight
        frameIndex &+= 1

        var uniforms = FXUniformsGPU(
            viewProjection: inputs.viewProjection,
            headMatrix: inputs.frame.headMatrix,
            resolution: SIMD2(Float(targetSize.width), Float(targetSize.height)),
            invResolution: SIMD2(1 / Float(targetSize.width), 1 / Float(targetSize.height)),
            cmToUnits: inputs.frame.cmToUnits,
            time: inputs.time,
            mirrored: inputs.frame.mirrored ? 1 : 0,
            pad: 0)
        uniformBuffers[slot].contents()
            .copyMemory(from: &uniforms, byteCount: MemoryLayout<FXUniformsGPU>.stride)

        var read = 0
        var write = 1

        // ---- P0 camera -------------------------------------------------------
        encodeFullscreen(commandBuffer, pipeline: pipelines.camera, into: targets[write],
                         clear: true, depth: nil) { enc in
            enc.setFragmentTexture(inputs.luma, index: 0)
            enc.setFragmentTexture(inputs.chroma, index: 1)
            enc.setFragmentBuffer(self.uniformBuffers[slot], offset: 0, index: 0)
        }
        swap(&read, &write)

        guard let filter = inputs.filter else { return targets[read] }
        let manifest = filter.manifest

        // ---- P2 colour -------------------------------------------------------
        // (P1 beauty is encoded the same way; omitted here until its skin mask
        //  pass lands, so that a half-built mask never ships as a visible smear.)
        if manifest.has(.colour), let c = manifest.colour {
            var params = ColourParamsGPU(saturation: c.saturation, contrast: c.contrast,
                                         hasLUT: filter.lut != nil ? 1 : 0, pad: 0)
            encodeFullscreen(commandBuffer, pipeline: pipelines.colour, into: targets[write],
                             clear: false, depth: nil) { enc in
                enc.setFragmentTexture(self.targets[read], index: 0)
                if let lut = filter.lut { enc.setFragmentTexture(lut, index: 1) }
                enc.setFragmentBytes(&params, length: MemoryLayout<ColourParamsGPU>.stride, index: 0)
            }
            swap(&read, &write)
        }

        // ---- P3 warp ---------------------------------------------------------
        if manifest.has(.warp), let warps = manifest.warps, !warps.isEmpty,
           inputs.frame.valid {
            let controls = buildWarpControls(warps, inputs: inputs)
            let n = min(controls.count, Self.maxWarps)
            if n > 0 {
                controls.withUnsafeBytes {
                    self.warpBuffers[slot].contents()
                        .copyMemory(from: $0.baseAddress!,
                                    byteCount: MemoryLayout<WarpControlGPU>.stride * n)
                }
                var count = Int32(n)
                encodeFullscreen(commandBuffer, pipeline: pipelines.warp, into: targets[write],
                                 clear: false, depth: nil) { enc in
                    enc.setFragmentTexture(self.targets[read], index: 0)
                    enc.setFragmentBuffer(self.warpBuffers[slot], offset: 0, index: 0)
                    enc.setFragmentBytes(&count, length: MemoryLayout<Int32>.stride, index: 1)
                    enc.setFragmentBuffer(self.uniformBuffers[slot], offset: 0, index: 2)
                }
                swap(&read, &write)
            }
        }

        // ---- P5 occluder + P6 props -----------------------------------------
        // One encoder for both: the occluder fills depth, the props test against
        // it, and keeping them in a single pass avoids a depth store/load round
        // trip that would cost more than either pass does.
        let needsGeometry = inputs.frame.valid &&
            (manifest.has(.occluder) || manifest.has(.props))
        if needsGeometry {
            uploadMeshVertices(inputs.frame.vertices)

            let rp = MTLRenderPassDescriptor()
            rp.colorAttachments[0].texture = targets[read]
            rp.colorAttachments[0].loadAction = .load
            rp.colorAttachments[0].storeAction = .store
            rp.depthAttachment.texture = depth
            rp.depthAttachment.loadAction = .clear
            rp.depthAttachment.clearDepth = 1.0
            rp.depthAttachment.storeAction = .dontCare

            if let enc = commandBuffer.makeRenderCommandEncoder(descriptor: rp) {
                if manifest.has(.occluder), let vb = meshVertexBuffer,
                   let ib = meshIndexBuffer, meshIndexCount > 0 {
                    enc.setRenderPipelineState(pipelines.occluder)
                    enc.setDepthStencilState(depthWriteState)
                    enc.setVertexBuffer(vb, offset: 0, index: 0)
                    enc.setVertexBuffer(uniformBuffers[slot], offset: 0, index: 1)
                    enc.drawIndexedPrimitives(type: .triangle, indexCount: meshIndexCount,
                                              indexType: .uint16, indexBuffer: ib,
                                              indexBufferOffset: 0)
                }

                if manifest.has(.props) {
                    let instances = buildPropInstances(manifest, inputs: inputs)
                    let n = min(instances.count, Self.maxProps)
                    if n > 0, let atlas = filter.atlas {
                        instances.withUnsafeBytes {
                            self.instanceBuffers[slot].contents()
                                .copyMemory(from: $0.baseAddress!,
                                            byteCount: MemoryLayout<PropInstanceGPU>.stride * n)
                        }
                        enc.setRenderPipelineState(pipelines.props)
                        enc.setDepthStencilState(depthTestState)
                        enc.setVertexBuffer(instanceBuffers[slot], offset: 0, index: 0)
                        enc.setVertexBuffer(uniformBuffers[slot], offset: 0, index: 1)
                        enc.setFragmentTexture(atlas, index: 0)
                        // One instanced draw for every layer in the filter.
                        enc.drawPrimitives(type: .triangleStrip, vertexStart: 0,
                                           vertexCount: 4, instanceCount: n)
                    }
                }
                enc.endEncoding()
            }
        }

        return targets[read]
    }

    // MARK: Encoding helpers

    private func encodeFullscreen(_ cb: MTLCommandBuffer,
                                  pipeline: MTLRenderPipelineState,
                                  into texture: MTLTexture,
                                  clear: Bool,
                                  depth: MTLTexture?,
                                  configure: (MTLRenderCommandEncoder) -> Void) {
        let rp = MTLRenderPassDescriptor()
        rp.colorAttachments[0].texture = texture
        rp.colorAttachments[0].loadAction = clear ? .clear : .load
        rp.colorAttachments[0].clearColor = MTLClearColorMake(0, 0, 0, 1)
        rp.colorAttachments[0].storeAction = .store
        guard let enc = cb.makeRenderCommandEncoder(descriptor: rp) else { return }
        enc.setRenderPipelineState(pipeline)
        enc.setDepthStencilState(depthIgnoreState)
        configure(enc)
        enc.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        enc.endEncoding()
    }

    private func uploadMeshVertices(_ verts: [SIMD3<Float>]) {
        let bytes = MemoryLayout<SIMD3<Float>>.stride * verts.count
        if meshVertexBuffer == nil || meshVertexBuffer!.length < bytes {
            meshVertexBuffer = device.makeBuffer(length: bytes, options: .storageModeShared)
        }
        guard let buf = meshVertexBuffer else { return }
        verts.withUnsafeBytes { buf.contents().copyMemory(from: $0.baseAddress!, byteCount: bytes) }
    }

    // MARK: Layer evaluation

    /// Builds one instance per visible layer: resolve the anchor, apply
    /// blendshape bindings and spring physics, compose a face-local matrix.
    ///
    /// All of this is in FACE-LOCAL space. headMatrix and the projection are
    /// applied in the vertex shader, which is what makes the placement genuinely 3D.
    private func buildPropInstances(_ manifest: FXManifest,
                                    inputs: FrameInputs) -> [PropInstanceGPU] {
        let frame = inputs.frame
        guard let atlasSize = manifest.atlasSize, atlasSize.count == 2 else { return [] }
        let aw = Float(atlasSize[0]), ah = Float(atlasSize[1])
        let s = frame.cmToUnits
        let dt = Float(1.0 / 60.0)

        var out: [PropInstanceGPU] = []
        out.reserveCapacity(manifest.sortedLayers.count)

        for layer in manifest.sortedLayers {
            var scale = SIMD2<Float>(1, 1)
            var opacity: Float = 1
            var extraOffset = SIMD3<Float>.zero
            var extraRotZ: Float = 0

            for b in layer.bindings ?? [] {
                let idx = b.blendshapeIndex
                guard idx < frame.blendshapes.count else { continue }
                let v = b.evaluate(frame.blendshapes[idx])
                switch b.target {
                case .scaleX:       scale.x *= v
                case .scaleY:       scale.y *= v
                case .scaleUniform: scale *= v
                case .opacity:      opacity *= v
                case .offsetX:      extraOffset.x += v
                case .offsetY:      extraOffset.y += v
                case .offsetZ:      extraOffset.z += v
                case .rotationZ:    extraRotZ += v * (.pi / 180)
                case .atlasFrame:   break
                }
            }
            if opacity <= 0.001 { continue }

            if let phys = layer.physics {
                let driver: Float
                switch phys.driver {
                case .headRollVelocity:  driver = inputs.angularVelocity.z
                case .headYawVelocity:   driver = inputs.angularVelocity.y
                case .headPitchVelocity: driver = inputs.angularVelocity.x
                }
                var spring = springs[layer.id] ?? SpringState()
                let maxRad = phys.maxDeg * (.pi / 180)
                let angle = spring.update(target: -driver * 0.08, dt: dt,
                                          stiffness: phys.stiffness, damping: phys.damping)
                springs[layer.id] = spring
                extraRotZ += max(-maxRad, min(maxRad, angle))
            }

            let anchor = layer.anchor.resolve(in: frame.vertices)
            let position = anchor + (layer.offset + extraOffset) * s
            let size = layer.size * scale * s
            let rot = layer.rotationRadians + SIMD3<Float>(0, 0, extraRotZ)

            let r = layer.atlasRect
            let uvRect = SIMD4<Float>(r[0] / aw, r[1] / ah, r[2] / aw, r[3] / ah)

            out.append(PropInstanceGPU(
                model: Self.quadMatrix(position: position, size: size, rotation: rot),
                uvRect: uvRect, opacity: opacity, pad0: 0, pad1: 0, pad2: 0))
        }
        return out
    }

    private func buildWarpControls(_ warps: [FXWarp], inputs: FrameInputs) -> [WarpControlGPU] {
        let frame = inputs.frame
        let mvp = inputs.viewProjection * frame.headMatrix
        let res = SIMD2<Float>(Float(targetSize.width), Float(targetSize.height))

        func project(_ p: SIMD3<Float>) -> SIMD2<Float> {
            let c = mvp * SIMD4<Float>(p, 1)
            guard c.w > 1e-6 else { return SIMD2(-1e6, -1e6) }
            let ndc = SIMD2(c.x / c.w, c.y / c.w)
            var uv = SIMD2((ndc.x + 1) * 0.5, (1 - ndc.y) * 0.5)
            if frame.mirrored { uv.x = 1 - uv.x }
            return uv * res
        }

        // Radii are given in centimetres; converting through the PROJECTED
        // interocular distance keeps a warp the same size on the face as the
        // subject moves toward or away from the camera.
        let eyeL = project(frame.vertices[min(FaceGeometry.eyeOuterLeft, frame.vertices.count - 1)])
        let eyeR = project(frame.vertices[min(FaceGeometry.eyeOuterRight, frame.vertices.count - 1)])
        let interocularPx = max(1, simd_distance(eyeL, eyeR))
        let cmToPx = interocularPx / max(frame.interocularCm, 0.001)

        return warps.map { w in
            let d = w.direction ?? [0, 0]
            let mode: Int32 = w.mode == .magnify ? 0 : (w.mode == .pinch ? 1 : 2)
            return WarpControlGPU(centerPx: project(w.anchor.resolve(in: frame.vertices)),
                                  radiusPx: w.radiusCm * cmToPx,
                                  strength: w.strength,
                                  mode: mode,
                                  direction: SIMD2(d[0], d.count > 1 ? d[1] : 0),
                                  pad: 0)
        }
    }

    /// Face-local quad placement: scale, then rotate, then translate.
    private static func quadMatrix(position: SIMD3<Float>,
                                   size: SIMD2<Float>,
                                   rotation: SIMD3<Float>) -> simd_float4x4 {
        let cx = cos(rotation.x), sx = sin(rotation.x)
        let cy = cos(rotation.y), sy = sin(rotation.y)
        let cz = cos(rotation.z), sz = sin(rotation.z)

        let rx = simd_float3x3(SIMD3(1, 0, 0), SIMD3(0, cx, sx), SIMD3(0, -sx, cx))
        let ry = simd_float3x3(SIMD3(cy, 0, -sy), SIMD3(0, 1, 0), SIMD3(sy, 0, cy))
        let rz = simd_float3x3(SIMD3(cz, sz, 0), SIMD3(-sz, cz, 0), SIMD3(0, 0, 1))
        var r = ry * rx * rz

        r[0] *= size.x
        r[1] *= size.y
        return simd_float4x4(SIMD4(r[0], 0), SIMD4(r[1], 0),
                             SIMD4(r[2], 0), SIMD4(position, 1))
    }
}

// MARK: - GPU-matching layouts
//
// Field order and padding MUST match FaceFX.metal exactly. Metal packs
// float4x4 on 16-byte boundaries; the explicit pads are what keep these
// structures in step with the shader's view of them.

struct FXUniformsGPU {
    var viewProjection: simd_float4x4
    var headMatrix: simd_float4x4
    var resolution: SIMD2<Float>
    var invResolution: SIMD2<Float>
    var cmToUnits: Float
    var time: Float
    var mirrored: Float
    var pad: Float
}

struct ColourParamsGPU {
    var saturation: Float
    var contrast: Float
    var hasLUT: Float
    var pad: Float
}

struct WarpControlGPU {
    var centerPx: SIMD2<Float>
    var radiusPx: Float
    var strength: Float
    var mode: Int32
    var direction: SIMD2<Float>
    var pad: Float
}

struct PropInstanceGPU {
    var model: simd_float4x4
    var uvRect: SIMD4<Float>
    var opacity: Float
    var pad0: Float
    var pad1: Float
    var pad2: Float
}

enum FXRendererError: Error {
    case noCommandQueue
    case shaderLibraryMissing
    case bufferAllocationFailed
}
