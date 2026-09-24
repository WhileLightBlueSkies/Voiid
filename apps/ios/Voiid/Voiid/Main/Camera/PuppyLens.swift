//
//  PuppyLens.swift
//  Voiid
//
//  The Puppy face lens: a 3D lens on ARKit face tracking, in place of the 2D dog stickers
//  the Vision engine used to draw (ClipFaceEffects.swift still draws every other effect).
//  Designed in Voiid Ui (Chat/Lenses/PuppyLens.swift); the rig below is that one.
//
//  The front TrueDepth camera gives a real 3D head pose and 52 expression readings a frame:
//    • floppy ears hung from the skull on springs, so they swing when you move and settle
//    • a glossy 3D nose that catches the light as you turn
//    • a tongue that slides out when the mouth opens (`jawOpen`), further when you really
//      stick it out (`tongueOut`), and wags while it is out
//    • an OCCLUDER — the face mesh drawn into depth only — so an ear swinging behind the
//      head is hidden by it like a real one
//
//  ── WHY NOT ARSCNView ───────────────────────────────────────────────────────────
//  A view only shows the lens; a Clip has to RECORD it. So the lens renders offscreen
//  (SCNRenderer into a Metal texture) and is composited over ARKit's camera image into one
//  pixel buffer per frame. That buffer is what the camera controller previews AND writes, so
//  the take is exactly what was on screen. ARKit also supplies the microphone while it runs,
//  because it owns the capture hardware and the AVCaptureSession is stopped meanwhile.
//
//  ── ALIGNMENT ───────────────────────────────────────────────────────────────────
//  The camera image is placed with ARKit's own `displayTransform` and the 3D camera with
//  its own projection and view matrices, all for the same portrait viewport. Deriving both
//  from ARKit is what keeps the ears on the head — including the front camera's mirroring,
//  which ARKit builds into both rather than leaving to us.
//

import ARKit
import CoreImage
import Metal
import SceneKit
import UIKit

final class FaceLensSession: NSObject, ARSessionDelegate {
    /// TrueDepth phones only. Everywhere else the lens is left off the rail.
    static var isSupported: Bool { ARFaceTrackingConfiguration.isSupported }

    /// The portrait frame the lens composes into. Matches the controller's 1080p takes.
    static let outputSize = CGSize(width: 1080, height: 1920)

    /// A composed frame (camera + lens, no colour look) with its capture time. Lens queue.
    var onFrame: ((CVPixelBuffer, CMTime) -> Void)?
    /// Microphone audio while the lens owns the hardware. Lens queue.
    var onAudio: ((CMSampleBuffer) -> Void)?
    var onFailure: (() -> Void)?

    private let session = ARSession()
    private let queue = DispatchQueue(label: "voiid.lens.frames", qos: .userInteractive)
    private let device = MTLCreateSystemDefaultDevice()
    private var commandQueue: MTLCommandQueue?
    private var sceneRenderer: SCNRenderer?
    private var ciContext: CIContext?
    private var colorTexture: MTLTexture?
    private var depthTexture: MTLTexture?
    private var pool: CVPixelBufferPool?

    private let scene = SCNScene()
    private let cameraNode = SCNNode()
    private let faceNode = SCNNode()
    private var occluder: ARSCNFaceGeometry?
    private let rig = PuppyRig()

    override init() {
        super.init()
        session.delegate = self
        session.delegateQueue = queue
        buildScene()
    }

    func start(withAudio audio: Bool) {
        let config = ARFaceTrackingConfiguration()
        config.maximumNumberOfTrackedFaces = 1
        config.isLightEstimationEnabled = true
        config.providesAudioData = audio
        if let format = Self.videoFormat() { config.videoFormat = format }
        session.run(config, options: [.resetTracking, .removeExistingAnchors])
    }

    func stop() { session.pause() }

    /// The sharpest 16:9 format, at 30 fps where there is a choice: the take is 9:16, and
    /// 60 fps would double the render cost for frames the 30 fps encoder drops anyway.
    private static func videoFormat() -> ARConfiguration.VideoFormat? {
        ARFaceTrackingConfiguration.supportedVideoFormats
            .filter { abs($0.imageResolution.width / $0.imageResolution.height - 16.0 / 9.0) < 0.02 }
            .max { a, b in
                if a.imageResolution.width != b.imageResolution.width {
                    return a.imageResolution.width < b.imageResolution.width
                }
                return abs(a.framesPerSecond - 30) > abs(b.framesPerSecond - 30)
            }
    }

    // MARK: Scene

    private func buildScene() {
        scene.background.contents = UIColor.clear

        let camera = SCNCamera()
        camera.zNear = 0.001
        camera.zFar = 100
        cameraNode.camera = camera
        scene.rootNode.addChildNode(cameraNode)

        let key = SCNNode()
        key.light = SCNLight()
        key.light?.type = .directional
        key.light?.intensity = 900
        key.eulerAngles = SCNVector3(-0.6, 0.4, 0)
        scene.rootNode.addChildNode(key)

        let fill = SCNNode()
        fill.light = SCNLight()
        fill.light?.type = .ambient
        fill.light?.intensity = 450
        scene.rootNode.addChildNode(fill)

        if let device, let geometry = ARSCNFaceGeometry(device: device) {
            geometry.firstMaterial?.colorBufferWriteMask = []
            let node = SCNNode(geometry: geometry)
            node.renderingOrder = -1
            faceNode.addChildNode(node)
            occluder = geometry
        }
        faceNode.addChildNode(rig.root)
        faceNode.isHidden = true
        scene.rootNode.addChildNode(faceNode)
    }

    /// Metal objects on first use, on the lens queue, sized to the output.
    private func prepare() -> Bool {
        if sceneRenderer != nil { return true }
        guard let device, let queue = device.makeCommandQueue() else { return false }
        let w = Int(Self.outputSize.width), h = Int(Self.outputSize.height)

        let color = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm_srgb,
                                                             width: w, height: h, mipmapped: false)
        color.usage = [.renderTarget, .shaderRead]
        color.storageMode = .private
        let depth = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .depth32Float,
                                                             width: w, height: h, mipmapped: false)
        depth.usage = .renderTarget
        depth.storageMode = .private

        var pool: CVPixelBufferPool?
        let attrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: w,
            kCVPixelBufferHeightKey as String: h,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:],
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey as String: 6] as CFDictionary,
                                attrs as CFDictionary, &pool)

        guard let colorTexture = device.makeTexture(descriptor: color),
              let depthTexture = device.makeTexture(descriptor: depth),
              let pool else { return false }
        let renderer = SCNRenderer(device: device, options: nil)
        renderer.scene = scene
        renderer.pointOfView = cameraNode
        renderer.autoenablesDefaultLighting = false

        self.commandQueue = queue
        self.colorTexture = colorTexture
        self.depthTexture = depthTexture
        self.pool = pool
        self.ciContext = CIContext(mtlCommandQueue: queue, options: [.cacheIntermediates: false])
        self.sceneRenderer = renderer
        return true
    }

    // MARK: ARSessionDelegate

    func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard prepare(), let buffer = compose(frame) else { return }
        onFrame?(buffer, CMTime(seconds: frame.timestamp, preferredTimescale: 1_000_000_000))
    }

    func session(_ session: ARSession, didOutputAudioSampleBuffer audioSampleBuffer: CMSampleBuffer) {
        onAudio?(audioSampleBuffer)
    }

    func session(_ session: ARSession, didFailWithError error: Error) {
        onFailure?()
    }

    private func compose(_ frame: ARFrame) -> CVPixelBuffer? {
        guard let renderer = sceneRenderer, let commandQueue, let ciContext, let pool,
              let colorTexture, let depthTexture else { return nil }
        let size = Self.outputSize
        let rect = CGRect(origin: .zero, size: size)

        // 1. The 3D camera, from ARKit, for this exact viewport.
        let arCamera = frame.camera
        cameraNode.camera?.projectionTransform = SCNMatrix4(
            arCamera.projectionMatrix(for: .portrait, viewportSize: size, zNear: 0.001, zFar: 100))
        cameraNode.simdTransform = arCamera.viewMatrix(for: .portrait).inverse

        // 2. The face: pose, the occluder mesh, and the rig's springs.
        if let face = frame.anchors.lazy.compactMap({ $0 as? ARFaceAnchor }).first, face.isTracked {
            faceNode.isHidden = false
            faceNode.simdTransform = face.transform
            occluder?.update(from: face.geometry)
            rig.update(face: face, time: frame.timestamp)
        } else {
            faceNode.isHidden = true
        }

        // 3. Render the lens alone, over transparent, into the colour texture.
        guard let commands = commandQueue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = colorTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store
        pass.depthAttachment.texture = depthTexture
        pass.depthAttachment.loadAction = .clear
        pass.depthAttachment.clearDepth = 1
        pass.depthAttachment.storeAction = .dontCare
        renderer.render(atTime: frame.timestamp, viewport: rect, commandBuffer: commands, passDescriptor: pass)
        commands.commit()

        // 4. The camera image into the same portrait frame. CIImage space is pixels with y
        //    up; displayTransform works in 0…1 with y down — hence the two flips around it.
        let pixels = frame.capturedImage
        let w = CGFloat(CVPixelBufferGetWidth(pixels)), h = CGFloat(CVPixelBufferGetHeight(pixels))
        let toNormalized = CGAffineTransform(a: 1 / w, b: 0, c: 0, d: -1 / h, tx: 0, ty: 1)
        let toView = CGAffineTransform(a: size.width, b: 0, c: 0, d: -size.height, tx: 0, ty: size.height)
        let transform = toNormalized
            .concatenating(frame.displayTransform(for: .portrait, viewportSize: size))
            .concatenating(toView)
        let background = CIImage(cvPixelBuffer: pixels).transformed(by: transform).cropped(to: rect)

        // 5. Lens over camera. A Metal texture's rows run top-down; CIImage's bottom-up.
        commands.waitUntilCompleted()
        guard let linear = CGColorSpace(name: CGColorSpace.linearSRGB),
              let texture = CIImage(mtlTexture: colorTexture, options: [.colorSpace: linear]) else { return nil }
        let lens = texture.transformed(by: CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))

        var out: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &out) == kCVReturnSuccess, let out else { return nil }
        ciContext.render(lens.composited(over: background), to: out, bounds: rect,
                         colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        return out
    }
}

/// The puppy, in face-anchor space: metres, origin at the centre of the head, +y up, +z out
/// of the face toward the camera.
private final class PuppyRig {
    let root = SCNNode()

    private let leftEar: SCNNode
    private let rightEar: SCNNode
    private let nose: SCNNode
    private let tongue: SCNNode
    private let tonguePivot = SCNNode()

    // Springs.
    private var earAngle = LensSpring(stiffness: 38, damping: 5.5)
    private var earSwing = LensSpring(stiffness: 30, damping: 4.5)
    private var tongueOut = LensSpring(stiffness: 180, damping: 13)
    private var lastRoll: Float = 0
    private var lastPitch: Float = 0
    private var lastTime: CFTimeInterval = 0

    init() {
        leftEar = PuppyRig.makeEar()
        rightEar = PuppyRig.makeEar()
        rightEar.scale = SCNVector3(-1, 1, 1)   // mirror, so the pair is symmetric
        nose = PuppyRig.makeNose()
        tongue = PuppyRig.makeTongue()

        // Ears hang from the upper sides of the skull.
        leftEar.position = SCNVector3(0.066, 0.078, -0.012)
        rightEar.position = SCNVector3(-0.066, 0.078, -0.012)
        root.addChildNode(leftEar)
        root.addChildNode(rightEar)

        // Nose tip sits just in front of the real nose tip.
        nose.position = SCNVector3(0, -0.012, 0.074)
        root.addChildNode(nose)

        // The tongue hinges at the lower lip and swings down and out.
        tonguePivot.position = SCNVector3(0, -0.050, 0.058)
        tonguePivot.addChildNode(tongue)
        tongue.scale = SCNVector3(1, 0.001, 1)
        root.addChildNode(tonguePivot)

        // Freckles — three dots each side of the muzzle.
        for (x, y) in [(0.024, -0.024), (0.031, -0.031), (0.022, -0.036)] {
            for side: Float in [-1, 1] {
                let dot = SCNNode(geometry: SCNSphere(radius: 0.0016))
                dot.geometry?.firstMaterial = Look.freckle
                dot.position = SCNVector3(Float(x) * side, Float(y), 0.066)
                root.addChildNode(dot)
            }
        }
    }

    func update(face: ARFaceAnchor, time: CFTimeInterval) {
        let dt = Float(lastTime == 0 ? 1.0 / 60 : min(0.05, time - lastTime))
        lastTime = time

        // Head pose from the anchor's transform, for the ears' physics.
        let m = face.transform
        let roll = atan2(m.columns.0.y, m.columns.1.y)
        let pitch = asin(max(-1, min(1, -m.columns.2.y)))
        let rollVel = (roll - lastRoll) / dt
        let pitchVel = (pitch - lastPitch) / dt
        lastRoll = roll; lastPitch = pitch

        // Ears: gravity keeps them hanging (they counter-rotate a little against a head tilt),
        // and a quick head move kicks them into a swing that settles.
        let hang = earAngle.step(target: -roll * 0.7 - rollVel * 0.06, dt: dt)
        let swing = earSwing.step(target: pitch * 0.5 + pitchVel * 0.05, dt: dt)
        leftEar.eulerAngles = SCNVector3(swing, 0, hang + 0.18)
        rightEar.eulerAngles = SCNVector3(swing, 0, hang - 0.18)

        // Tongue: open the mouth and it slides out; stick your tongue out and it goes further.
        let shapes = face.blendShapes
        let jaw = shapes[.jawOpen]?.floatValue ?? 0
        let tongueBlend = shapes[.tongueOut]?.floatValue ?? 0
        let openness = smoothstep(0.22, 0.55, jaw)
        let target = max(openness, min(1.3, tongueBlend * 1.3))
        let out = max(0, tongueOut.step(target: target, dt: dt))

        // Wag while it is out; still when it is in.
        let wag = sin(Float(time) * 9) * 0.22 * min(1, out)
        tongue.scale = SCNVector3(1, max(0.001, out), 1)
        // Out of the mouth and forward (−x tips the hanging tongue toward the camera), and
        // the hinge follows the lower lip down as the jaw drops.
        tonguePivot.eulerAngles = SCNVector3(-0.35 * out, 0, wag)
        tonguePivot.position = SCNVector3(0, -0.050 - jaw * 0.022, 0.058)
        tongue.isHidden = out < 0.02

        // The nose wiggles when the mouth moves — the small reaction that sells the whole lens.
        let sniff = 1 + 0.06 * jaw
        nose.scale = SCNVector3(1.35 * sniff, 0.92, 0.82)
    }

    // MARK: Pieces

    /// A long, rounded floppy ear: brown fur outside, a soft pink inner ear inset in front.
    private static func makeEar() -> SCNNode {
        let pivot = SCNNode()

        let outer = UIBezierPath()
        outer.move(to: CGPoint(x: -0.012, y: 0.004))
        outer.addCurve(to: CGPoint(x: 0.004, y: -0.092),
                       controlPoint1: CGPoint(x: -0.040, y: -0.020),
                       controlPoint2: CGPoint(x: -0.030, y: -0.085))
        outer.addCurve(to: CGPoint(x: 0.030, y: -0.010),
                       controlPoint1: CGPoint(x: 0.040, y: -0.098),
                       controlPoint2: CGPoint(x: 0.044, y: -0.040))
        outer.addCurve(to: CGPoint(x: -0.012, y: 0.004),
                       controlPoint1: CGPoint(x: 0.020, y: 0.010),
                       controlPoint2: CGPoint(x: 0.000, y: 0.012))
        outer.close()
        outer.flatness = 0.0003
        let shape = SCNShape(path: outer, extrusionDepth: 0.006)
        shape.chamferRadius = 0.0028
        shape.chamferMode = .both
        shape.firstMaterial = Look.fur
        let outerNode = SCNNode(geometry: shape)
        pivot.addChildNode(outerNode)

        let inner = UIBezierPath()
        inner.move(to: CGPoint(x: -0.004, y: -0.010))
        inner.addCurve(to: CGPoint(x: 0.006, y: -0.074),
                       controlPoint1: CGPoint(x: -0.022, y: -0.030),
                       controlPoint2: CGPoint(x: -0.014, y: -0.070))
        inner.addCurve(to: CGPoint(x: 0.020, y: -0.016),
                       controlPoint1: CGPoint(x: 0.026, y: -0.076),
                       controlPoint2: CGPoint(x: 0.028, y: -0.036))
        inner.close()
        inner.flatness = 0.0003
        let innerShape = SCNShape(path: inner, extrusionDepth: 0.0015)
        innerShape.chamferRadius = 0.0007
        innerShape.firstMaterial = Look.innerEar
        let innerNode = SCNNode(geometry: innerShape)
        innerNode.position = SCNVector3(0, 0, 0.0036)
        pivot.addChildNode(innerNode)

        return pivot
    }

    private static func makeNose() -> SCNNode {
        let node = SCNNode(geometry: SCNSphere(radius: 0.0135))
        node.geometry?.firstMaterial = Look.nose
        // A pale highlight bead, the glint that makes it read as wet.
        let glint = SCNNode(geometry: SCNSphere(radius: 0.0028))
        glint.geometry?.firstMaterial = Look.glint
        glint.position = SCNVector3(-0.004, 0.006, 0.011)
        node.addChildNode(glint)
        return node
    }

    /// Hangs DOWN from its hinge (−y), so scaling y slides it out from the mouth.
    private static func makeTongue() -> SCNNode {
        let path = UIBezierPath(roundedRect: CGRect(x: -0.0135, y: -0.052, width: 0.027, height: 0.052),
                                byRoundingCorners: [.bottomLeft, .bottomRight],
                                cornerRadii: CGSize(width: 0.0135, height: 0.0135))
        path.flatness = 0.0003
        let shape = SCNShape(path: path, extrusionDepth: 0.005)
        shape.chamferRadius = 0.0022
        shape.chamferMode = .both
        shape.firstMaterial = Look.tongue
        let node = SCNNode(geometry: shape)
        // The centre crease.
        let crease = SCNNode(geometry: SCNBox(width: 0.0014, height: 0.030, length: 0.001, chamferRadius: 0.0007))
        crease.geometry?.firstMaterial = Look.crease
        crease.position = SCNVector3(0, -0.020, 0.0030)
        node.addChildNode(crease)
        return node
    }
}

// MARK: - Art direction

private enum Look {
    static let fur: SCNMaterial = {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = furTexture()
        m.roughness.contents = 0.9
        m.metalness.contents = 0
        return m
    }()

    static let innerEar = pbr(UIColor(red: 0.96, green: 0.68, blue: 0.70, alpha: 1), roughness: 0.75)
    static let nose = pbr(UIColor(red: 0.07, green: 0.05, blue: 0.05, alpha: 1), roughness: 0.18)
    static let glint = pbr(UIColor(white: 1, alpha: 0.85), roughness: 0.05)
    static let freckle = pbr(UIColor(red: 0.25, green: 0.14, blue: 0.08, alpha: 1), roughness: 0.8)
    static let tongue: SCNMaterial = {
        let m = pbr(UIColor(red: 0.98, green: 0.45, blue: 0.55, alpha: 1), roughness: 0.28)
        m.diffuse.contents = tongueTexture()
        return m
    }()
    static let crease = pbr(UIColor(red: 0.80, green: 0.28, blue: 0.38, alpha: 1), roughness: 0.4)

    private static func pbr(_ color: UIColor, roughness: CGFloat) -> SCNMaterial {
        let m = SCNMaterial()
        m.lightingModel = .physicallyBased
        m.diffuse.contents = color
        m.roughness.contents = roughness
        m.metalness.contents = 0
        return m
    }

    /// Warm brown with darker strokes along the ear's length — fur direction, not flat paint.
    private static func furTexture() -> UIImage {
        let size = CGSize(width: 256, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let cg = ctx.cgContext
            let colors = [UIColor(red: 0.62, green: 0.39, blue: 0.20, alpha: 1).cgColor,
                          UIColor(red: 0.42, green: 0.24, blue: 0.11, alpha: 1).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                cg.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
            var rng = SystemRandomNumberGenerator()
            for _ in 0..<900 {
                let x = CGFloat.random(in: 0...size.width, using: &rng)
                let y = CGFloat.random(in: 0...size.height, using: &rng)
                let len = CGFloat.random(in: 6...16, using: &rng)
                cg.setStrokeColor(UIColor(red: 0.30, green: 0.17, blue: 0.08,
                                          alpha: CGFloat.random(in: 0.15...0.4, using: &rng)).cgColor)
                cg.setLineWidth(CGFloat.random(in: 0.6...1.4, using: &rng))
                cg.move(to: CGPoint(x: x, y: y))
                cg.addLine(to: CGPoint(x: x + CGFloat.random(in: -2...2, using: &rng), y: y + len))
                cg.strokePath()
            }
        }
    }

    private static func tongueTexture() -> UIImage {
        let size = CGSize(width: 128, height: 256)
        return UIGraphicsImageRenderer(size: size).image { ctx in
            let colors = [UIColor(red: 0.93, green: 0.36, blue: 0.47, alpha: 1).cgColor,
                          UIColor(red: 1.00, green: 0.58, blue: 0.64, alpha: 1).cgColor] as CFArray
            if let g = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1]) {
                ctx.cgContext.drawLinearGradient(g, start: .zero, end: CGPoint(x: 0, y: size.height), options: [])
            }
        }
    }
}

// MARK: - Motion

/// A damped spring toward a moving target, integrated at a fixed small step so its character
/// does not change with frame rate.
private struct LensSpring {
    let stiffness: Float
    let damping: Float
    private var x: Float = 0
    private var v: Float = 0

    init(stiffness: Float, damping: Float) {
        self.stiffness = stiffness
        self.damping = damping
    }

    mutating func step(target: Float, dt: Float) -> Float {
        var remaining = dt
        let h: Float = 1.0 / 240
        while remaining > 0 {
            let s = min(h, remaining)
            let a = stiffness * (target - x) - damping * v
            v += a * s
            x += v * s
            remaining -= s
        }
        return x
    }
}

private func smoothstep(_ a: Float, _ b: Float, _ x: Float) -> Float {
    let t = max(0, min(1, (x - a) / (b - a)))
    return t * t * (3 - 2 * t)
}
