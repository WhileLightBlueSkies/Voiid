//
//  SnakeMetalView.swift
//  Voiid
//
//  The Snake arena, drawn on the GPU.
//
//  WHY METAL RATHER THAN SwiftUI Canvas. The Canvas version froze, and the reason is
//  structural rather than a slow draw: trail state was mutated from inside the draw closure
//  while `@Published` frames arriving re-entered the same view. SwiftUI's render pass has to
//  be a pure function of state, and a continuous game's renderer fundamentally is not — it
//  owns motion between frames.
//
//  So the renderer owns its own loop. `MTKView` drives `draw(in:)` from a display link that
//  SwiftUI knows nothing about, and every mutable thing (trails, interpolation clock, name
//  plates) lives in the Renderer class below. SwiftUI is left doing what it is good at: the
//  HUD and the joystick, composited above the Metal layer.
//
//  Everything drawn is still server truth interpolated slightly into the past. Nothing here
//  predicts — the client remains a renderer, not a referee.
//

import Combine
import MetalKit
import SwiftUI
import simd

// MARK: - Shared shader types
//
// These must match Snake.metal field for field. Swift and MSL both lay these out with
// 4-byte-aligned floats and no padding surprises at this size, but the `_pad` in Uniforms is
// explicit because a float2/float/float tail would otherwise be padded differently.

private struct Uniforms {
    var cameraCentre: SIMD2<Float>
    var viewportSize: SIMD2<Float>
    var scale: Float
    var _pad: Float = 0
}

private struct CircleInstance {
    var centre: SIMD2<Float>
    var radius: Float
    var softness: Float
    var colour: SIMD4<Float>
}

private struct RibbonVertex {
    var world: SIMD2<Float>
    var colour: SIMD4<Float>
}

private struct SpriteInstance {
    var centre: SIMD2<Float>
    var size: SIMD2<Float>
    var uvOrigin: SIMD2<Float>
    var uvSize: SIMD2<Float>
    var tint: SIMD4<Float>
}

/// What the HUD needs from the renderer each frame. Published so SwiftUI can react without
/// the renderer having to know anything about views.
///
/// Deliberately NOT @MainActor-annotated: the renderer builds these values on the display
/// link thread and hops to the main actor only to publish them (see `publishHud`), which
/// keeps the per-frame work off the main thread entirely.
final class SnakeHudModel: ObservableObject {
    /// Leaderboard rows, best first, already ranked.
    @Published var board: [Row] = []
    @Published var timeRemaining: String = ""
    @Published var myMass: Int = 0

    struct Row: Identifiable {
        let id: String
        let rank: Int
        let name: String
        let mass: Int
        let colorIndex: Int
        let isMe: Bool
    }
}

// MARK: - SwiftUI bridge

struct SnakeMetalView: UIViewRepresentable {
    let engine: GamesEngine
    let me: String?
    let hud: SnakeHudModel
    /// Live joystick vector, so the head can face the thumb without waiting for the server.
    @Binding var stick: CGVector

    func makeCoordinator() -> SnakeRenderer {
        SnakeRenderer(engine: engine, me: me, hud: hud)
    }

    func makeUIView(context: Context) -> MTKView {
        let view = MTKView()
        view.device = MTLCreateSystemDefaultDevice()
        view.delegate = context.coordinator
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColor(red: 0.02, green: 0.02, blue: 0.05, alpha: 1)
        view.preferredFramesPerSecond = 60
        // Continuous redraw: this is a live simulation, not a document that changes on edit.
        view.isPaused = false
        view.enableSetNeedsDisplay = false
        view.isOpaque = true
        context.coordinator.configure(view: view)
        return view
    }

    func updateUIView(_ view: MTKView, context: Context) {
        context.coordinator.stick = stick
    }

    static func dismantleUIView(_ view: MTKView, coordinator: SnakeRenderer) {
        // Break the delegate cycle so the display link stops when the screen goes away.
        view.delegate = nil
        view.isPaused = true
    }
}

// MARK: - Renderer

final class SnakeRenderer: NSObject, MTKViewDelegate {
    private let engine: GamesEngine
    private let me: String?
    private let hud: SnakeHudModel

    var stick: CGVector = .zero

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var circlePipeline: MTLRenderPipelineState!
    private var ribbonPipeline: MTLRenderPipelineState!
    private var spritePipeline: MTLRenderPipelineState!
    private var sampler: MTLSamplerState!

    /// Name-plate glyphs, rasterised on demand and packed into one texture.
    private var labelAtlas: LabelAtlas?

    // Per-frame CPU-side buffers, reused so a frame allocates nothing.
    private var circles: [CircleInstance] = []
    private var ribbon: [RibbonVertex] = []
    private var sprites: [SpriteInstance] = []

    // GPU-side mirrors of the above.
    //
    // These exist because `setVertexBytes` is capped at 4 KB — a limit the arena blows past
    // immediately (300 pellets alone is ~9 KB of circle instances), and exceeding it is a
    // hard Metal validation failure, not a silent truncation. That was the startup crash.
    // Buffers are grown on demand and then reused, so a steady-state frame allocates nothing.
    private var circleBuffer: MTLBuffer?
    private var ribbonBuffer: MTLBuffer?
    private var spriteBuffer: MTLBuffer?

    /// Grow `buffer` if needed and copy `array` into it. Returns nil when empty.
    private func upload<T>(_ array: [T], into buffer: inout MTLBuffer?) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        let bytes = MemoryLayout<T>.stride * array.count
        if buffer == nil || buffer!.length < bytes {
            // Over-allocate so a slowly growing arena does not reallocate every frame.
            buffer = device.makeBuffer(length: max(bytes * 2, 4096), options: .storageModeShared)
        }
        guard let buffer else { return nil }
        array.withUnsafeBytes { raw in
            buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: bytes)
        }
        return buffer
    }

    /// Body trails, owned HERE rather than in SwiftUI state — this is the fix for the freeze.
    private let trails = TrailStore()

    private var viewSize: CGSize = .zero

    init(engine: GamesEngine, me: String?, hud: SnakeHudModel) {
        self.engine = engine
        self.me = me
        self.hud = hud
        super.init()
    }

    func configure(view: MTKView) {
        guard let device = view.device else { return }
        self.device = device
        queue = device.makeCommandQueue()

        // No assertionFailure here: that TRAPS in debug builds, so a shader problem became a
        // crash on entering the game rather than a blank arena with a log line.
        guard let library = device.makeDefaultLibrary() else {
            print("[snake] Metal library unavailable — arena will not draw")
            return
        }

        circlePipeline = Self.pipeline(device: device, library: library,
                                       vertex: "circleVertex", fragment: "circleFragment",
                                       pixelFormat: view.colorPixelFormat)
        ribbonPipeline = Self.pipeline(device: device, library: library,
                                       vertex: "ribbonVertex", fragment: "ribbonFragment",
                                       pixelFormat: view.colorPixelFormat)
        spritePipeline = Self.pipeline(device: device, library: library,
                                       vertex: "spriteVertex", fragment: "spriteFragment",
                                       pixelFormat: view.colorPixelFormat)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sampler = device.makeSamplerState(descriptor: sd)

        labelAtlas = LabelAtlas(device: device)
    }

    private static func pipeline(
        device: MTLDevice, library: MTLLibrary,
        vertex: String, fragment: String, pixelFormat: MTLPixelFormat
    ) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: vertex)
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = pixelFormat
        // Straight alpha blending: the arena is layered glows over a dark floor, and additive
        // blending would blow out to white wherever two glows overlap.
        d.colorAttachments[0].isBlendingEnabled = true
        d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        d.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
        d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        return try? device.makeRenderPipelineState(descriptor: d)
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewSize = size
    }

    // MARK: Frame

    func draw(in view: MTKView) {
        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor),
              circlePipeline != nil else { return }

        viewSize = view.drawableSize
        circles.removeAll(keepingCapacity: true)
        ribbon.removeAll(keepingCapacity: true)
        sprites.removeAll(keepingCapacity: true)

        if let frame = buildFrame() {
            var uniforms = frame
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

            // Bodies first, then circles over them (heads, food), then labels on top.
            if let buf = upload(ribbon, into: &ribbonBuffer), ribbonPipeline != nil {
                encoder.setRenderPipelineState(ribbonPipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: ribbon.count)
            }

            if let buf = upload(circles, into: &circleBuffer) {
                encoder.setRenderPipelineState(circlePipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 1)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: circles.count)
            }

            if let buf = upload(sprites, into: &spriteBuffer),
               let texture = labelAtlas?.texture, spritePipeline != nil {
                encoder.setRenderPipelineState(spritePipeline)
                encoder.setVertexBuffer(buf, offset: 0, index: 1)
                encoder.setFragmentTexture(texture, index: 0)
                encoder.setFragmentSamplerState(sampler, index: 0)
                encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                       instanceCount: sprites.count)
            }
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()
    }

    /// How far behind the newest frame to render.
    ///
    /// Slightly more than one 10 Hz tick, so there is virtually always a newer frame to
    /// interpolate towards. Less and the buffer runs dry constantly (the stutter this
    /// removes); much more and the controls start to feel remote.
    private static let interpDelay: Double = 0.15

    private func buildFrame() -> Uniforms? {
        let frames = engine.snakeFramesSnapshot
        guard let newest = frames.last else { return nil }

        // Pick the pair bracketing the render instant, on the SERVER's clock. Arrival jitter
        // moves the offset rather than the snake.
        var from = newest.state
        var to = newest.state
        var t = 1.0

        if frames.count >= 2 {
            let elapsed = CACurrentMediaTime() - newest.arrivedAt
            let renderT = newest.state.time + elapsed - Self.interpDelay
            var picked = false
            for i in stride(from: frames.count - 2, through: 0, by: -1) {
                let a = frames[i].state, b = frames[i + 1].state
                if renderT >= a.time {
                    let span = b.time - a.time
                    from = a; to = b
                    t = span > 1e-6 ? min(max((renderT - a.time) / span, 0), 1) : 1
                    picked = true
                    break
                }
            }
            // Older than everything buffered (a long stall): hold the oldest rather than
            // jumping to the newest.
            if !picked { from = frames[0].state; to = frames[1].state; t = 0 }
        }

        let state = to

        var heads: [String: CGPoint] = [:]
        var headings: [String: Double] = [:]
        for snake in state.snakes {
            let prev = from.snakes.first { $0.id == snake.id }
            let px = prev?.x ?? snake.x, py = prev?.y ?? snake.y
            heads[snake.id] = CGPoint(x: px + (snake.x - px) * t, y: py + (snake.y - py) * t)
            headings[snake.id] = Self.lerpAngle(prev?.heading ?? snake.heading, snake.heading, t)
        }

        trails.update(state: state, heads: heads)

        let focus = heads[me ?? ""] ?? .zero
        let mine = state.snakes.first { $0.id == me }
        let mass = mine?.mass ?? 10
        let zoom = 1.0 / (1.0 + log10(1 + mass / 30) * 0.42)
        let scale = Float(min(viewSize.width, viewSize.height) / 900.0 * zoom)

        buildArena(radius: state.arenaRadius)
        buildFood(state: state)

        // Rank by mass, so the label over a head and the HUD row always agree.
        let ranked = state.snakes.sorted { $0.mass > $1.mass }
        var rankOf: [String: Int] = [:]
        for (i, s) in ranked.enumerated() { rankOf[s.id] = i + 1 }

        for snake in state.snakes where snake.alive {
            buildSnake(snake: snake,
                       head: heads[snake.id] ?? .zero,
                       heading: headings[snake.id] ?? 0,
                       isMe: snake.id == me,
                       time: state.time,
                       rank: rankOf[snake.id] ?? 0,
                       scale: scale)
        }

        publishHud(state: state, ranked: ranked, mine: mine)

        return Uniforms(cameraCentre: SIMD2(Float(focus.x), Float(focus.y)),
                        viewportSize: SIMD2(Float(viewSize.width), Float(viewSize.height)),
                        scale: scale)
    }

    private static func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        var d = b - a
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return a + d * t
    }

    // MARK: Geometry builders

    private func buildArena(radius: Double) {
        // Floor, then a glow band, then the lethal edge drawn EXACTLY on the kill radius —
        // a wall whose visible edge disagrees with the killing surface makes every border
        // death feel unfair.
        circles.append(CircleInstance(
            centre: .zero, radius: Float(radius), softness: 0,
            colour: SIMD4(0.07, 0.06, 0.16, 1)))
        circles.append(CircleInstance(
            centre: .zero, radius: Float(radius), softness: 0.35,
            colour: SIMD4(0.35, 0.85, 1.0, 0.10)))

        // The edge as a thin ring: an outer disc with a slightly smaller floor disc on top.
        circles.append(CircleInstance(
            centre: .zero, radius: Float(radius + 8), softness: 0.02,
            colour: SIMD4(0.35, 0.85, 1.0, 0.85)))
        circles.append(CircleInstance(
            centre: .zero, radius: Float(radius - 2), softness: 0,
            colour: SIMD4(0.055, 0.05, 0.13, 1)))
    }

    private func buildFood(state: SnakeState) {
        for item in state.food {
            let r = Float(item.value >= 2 ? 7 : item.value < 1 ? 4.5 : 5.5)
            let colour: SIMD4<Float> = item.value >= 2
                ? SIMD4(1.0, 0.72, 0.45, 1)
                : SIMD4(1.0, 0.93, 0.62, 1)
            let centre = SIMD2(Float(item.position.x), Float(item.position.y))
            // Halo then core: cheap, and it is what makes the field read as lit rather than
            // as flat dots.
            circles.append(CircleInstance(centre: centre, radius: r * 2.4,
                                          softness: 0.75,
                                          colour: SIMD4(colour.x, colour.y, colour.z, 0.22)))
            circles.append(CircleInstance(centre: centre, radius: r, softness: 0, colour: colour))
        }
    }

    private func buildSnake(
        snake: SnakeState.Snake, head: CGPoint, heading: Double,
        isMe: Bool, time: Double, rank: Int, scale: Float
    ) {
        let points = trails.points(for: snake.id)
        guard points.count >= 2 else { return }

        let c = Self.palette(snake.colorIndex)
        let alpha: Float = time < snake.invulnUntil ? 0.55 : 1.0
        // Width comes from the SERVER's head radius, so the drawn body is exactly the shape
        // that kills. A local formula could drift from the hitbox on any tuning change.
        let width = Float(snake.headRadius) * 1.9

        appendRibbon(points: points, width: width * 1.7,
                     colour: SIMD4(c.x, c.y, c.z, 0.20 * alpha))
        appendRibbon(points: points, width: width,
                     colour: SIMD4(c.x, c.y, c.z, alpha))
        if isMe {
            appendRibbon(points: points, width: width * 0.28,
                         colour: SIMD4(1, 1, 1, 0.85 * alpha))
        }
        if snake.boosting {
            appendRibbon(points: points, width: width * 0.45,
                         colour: SIMD4(1, 1, 1, 0.35))
        }

        // Head: glow, body, then eyes facing the joystick for the local player so aim
        // responds on the same frame the thumb moves.
        let hc = SIMD2(Float(head.x), Float(head.y))
        let r = Float(snake.headRadius)
        circles.append(CircleInstance(centre: hc, radius: r * 2.6, softness: 0.8,
                                      colour: SIMD4(c.x, c.y, c.z, 0.30 * alpha)))
        circles.append(CircleInstance(centre: hc, radius: r, softness: 0,
                                      colour: SIMD4(c.x, c.y, c.z, alpha)))

        var look = heading
        if isMe, stick != .zero { look = atan2(stick.dy, stick.dx) }

        let eyeR = r * 0.32
        for side in [Float(-1), Float(1)] {
            let ex = hc.x + cos(Float(look)) * r * 0.34 - sin(Float(look)) * side * r * 0.42
            let ey = hc.y + sin(Float(look)) * r * 0.34 + cos(Float(look)) * side * r * 0.42
            circles.append(CircleInstance(centre: SIMD2(ex, ey), radius: eyeR, softness: 0,
                                          colour: SIMD4(1, 1, 1, alpha)))
            let px = ex + cos(Float(look)) * eyeR * 0.42
            let py = ey + sin(Float(look)) * eyeR * 0.42
            circles.append(CircleInstance(centre: SIMD2(px, py), radius: eyeR * 0.5, softness: 0,
                                          colour: SIMD4(0.04, 0.04, 0.08, alpha)))
        }

        buildLabel(snake: snake, head: head, rank: rank, radius: r, scale: scale, isMe: isMe)
    }

    /// Name, prefixed with the rank when the snake is in the top 10.
    private func buildLabel(
        snake: SnakeState.Snake, head: CGPoint, rank: Int,
        radius: Float, scale: Float, isMe: Bool
    ) {
        let name = SnakeState.label(for: snake, me: me)
        guard !name.isEmpty else { return }
        let text = rank > 0 && rank <= 10 ? "#\(rank) \(name)" : name

        guard let entry = labelAtlas?.entry(for: text) else { return }

        // Sized in POINTS then converted to world units, so a label stays legible whatever
        // the camera zoom is — the alternative is text that shrinks to nothing as you grow.
        let heightPoints: Float = 13
        let worldH = heightPoints / max(scale, 0.0001)
        let worldW = worldH * Float(entry.size.width / entry.size.height)

        sprites.append(SpriteInstance(
            centre: SIMD2(Float(head.x), Float(head.y) - radius - worldH * 0.9),
            size: SIMD2(worldW, worldH),
            uvOrigin: SIMD2(Float(entry.uvOrigin.x), Float(entry.uvOrigin.y)),
            uvSize: SIMD2(Float(entry.uvSize.width), Float(entry.uvSize.height)),
            tint: isMe ? SIMD4(1, 1, 1, 1) : SIMD4(0.85, 0.88, 1.0, 0.92)))
    }

    /// Triangulate a polyline into a thick ribbon.
    ///
    /// Two triangles per segment, with the joint offset along each point's averaged normal so
    /// corners do not pinch. Round caps are drawn as circle instances instead of geometry —
    /// far cheaper than fanning every joint, and visually identical at these widths.
    private func appendRibbon(points: [CGPoint], width: Float, colour: SIMD4<Float>) {
        guard points.count >= 2 else { return }
        let half = width * 0.5

        var normals: [SIMD2<Float>] = []
        normals.reserveCapacity(points.count)
        for i in 0..<points.count {
            let prev = points[max(0, i - 1)]
            let next = points[min(points.count - 1, i + 1)]
            var dx = Float(next.x - prev.x)
            var dy = Float(next.y - prev.y)
            let len = max(sqrt(dx * dx + dy * dy), 0.0001)
            dx /= len; dy /= len
            normals.append(SIMD2(-dy, dx))
        }

        for i in 0..<(points.count - 1) {
            let a = SIMD2(Float(points[i].x), Float(points[i].y))
            let b = SIMD2(Float(points[i + 1].x), Float(points[i + 1].y))
            let na = normals[i] * half
            let nb = normals[i + 1] * half

            let a0 = a + na, a1 = a - na
            let b0 = b + nb, b1 = b - nb

            ribbon.append(RibbonVertex(world: a0, colour: colour))
            ribbon.append(RibbonVertex(world: a1, colour: colour))
            ribbon.append(RibbonVertex(world: b0, colour: colour))

            ribbon.append(RibbonVertex(world: a1, colour: colour))
            ribbon.append(RibbonVertex(world: b1, colour: colour))
            ribbon.append(RibbonVertex(world: b0, colour: colour))
        }

        // Round off the tail so a body does not end in a hard chisel.
        if let tail = points.last {
            circles.append(CircleInstance(
                centre: SIMD2(Float(tail.x), Float(tail.y)),
                radius: half, softness: 0, colour: colour))
        }
    }

    private func publishHud(state: SnakeState, ranked: [SnakeState.Snake], mine: SnakeState.Snake?) {
        let rows = ranked.prefix(10).enumerated().map { idx, s in
            SnakeHudModel.Row(id: s.id, rank: idx + 1,
                              name: SnakeState.label(for: s, me: me),
                              mass: Int(s.mass), colorIndex: s.colorIndex,
                              isMe: s.id == me)
        }
        let left = max(0, state.duration - state.time)
        let timeText = String(format: "%d:%02d", Int(left) / 60, Int(left) % 60)
        let myMass = Int(mine?.mass ?? 0)

        // Hop to the main actor for the publish — this runs on the display link's thread and
        // SwiftUI state must not be written from anywhere else.
        Task { @MainActor in
            hud.board = rows
            hud.timeRemaining = timeText
            hud.myMass = myMass
        }
    }

    static func palette(_ index: Int) -> SIMD4<Float> {
        let p: [SIMD4<Float>] = [
            SIMD4(1.00, 0.23, 0.28, 1), SIMD4(0.13, 0.88, 0.94, 1),
            SIMD4(0.61, 0.36, 1.00, 1), SIMD4(0.36, 0.90, 0.36, 1),
            SIMD4(1.00, 0.54, 0.17, 1), SIMD4(1.00, 0.85, 0.24, 1),
            SIMD4(1.00, 0.31, 0.85, 1), SIMD4(0.07, 0.79, 0.55, 1),
            SIMD4(0.30, 0.66, 1.00, 1), SIMD4(0.78, 0.96, 0.24, 1),
            SIMD4(1.00, 0.69, 0.13, 1), SIMD4(0.55, 0.97, 0.78, 1),
        ]
        return p[((index % p.count) + p.count) % p.count]
    }
}

// MARK: - Label atlas

/// Rasterises name plates once each and packs them into a single texture.
///
/// Text is the one thing Metal has no primitive for. Rendering each label per frame through
/// Core Graphics would be a CPU upload every frame per snake; names change only when a snake
/// joins or its rank moves, so they are cached by string and only the small set of visible
/// labels is ever drawn.
private final class LabelAtlas {
    struct Entry {
        let uvOrigin: CGPoint
        let uvSize: CGSize
        let size: CGSize
    }

    private let device: MTLDevice
    private(set) var texture: MTLTexture?
    private var entries: [String: Entry] = [:]

    /// Where the next label goes. A simple shelf packer: labels are all one line of text, so
    /// rows of uniform height waste almost nothing and need no rectangle-packing search.
    private var penX: CGFloat = 0
    private var penY: CGFloat = 0
    private var rowHeight: CGFloat = 0

    private static let dimension = 1024
    private static let fontSize: CGFloat = 26

    private var context: CGContext?

    init(device: MTLDevice) {
        self.device = device
        let d = Self.dimension
        guard let ctx = CGContext(
            data: nil, width: d, height: d, bitsPerComponent: 8, bytesPerRow: d * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return }
        context = ctx

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: d, height: d, mipmapped: false)
        desc.usage = [.shaderRead]
        texture = device.makeTexture(descriptor: desc)
    }

    func entry(for text: String) -> Entry? {
        if let cached = entries[text] { return cached }
        return rasterise(text)
    }

    private func rasterise(_ text: String) -> Entry? {
        guard let ctx = context, let texture else { return nil }

        let font = UIFont.systemFont(ofSize: Self.fontSize, weight: .bold)
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font,
            .foregroundColor: UIColor.white,
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        var size = attributed.size()
        size.width = ceil(size.width) + 8
        size.height = ceil(size.height) + 4

        let d = CGFloat(Self.dimension)
        if penX + size.width > d {
            penX = 0
            penY += rowHeight
            rowHeight = 0
        }
        // Atlas full. Returning nil drops the label rather than corrupting the texture; with
        // a 1024px sheet and short handles this needs dozens of distinct labels to reach.
        if penY + size.height > d { return nil }

        UIGraphicsPushContext(ctx)
        ctx.saveGState()
        // Core Text draws bottom-up; flip so the label is not upside down in the atlas.
        ctx.translateBy(x: 0, y: d)
        ctx.scaleBy(x: 1, y: -1)
        attributed.draw(at: CGPoint(x: penX + 4, y: penY + 2))
        ctx.restoreGState()
        UIGraphicsPopContext()

        guard let data = ctx.data else { return nil }
        texture.replace(
            region: MTLRegionMake2D(0, 0, Self.dimension, Self.dimension),
            mipmapLevel: 0, withBytes: data, bytesPerRow: Self.dimension * 4)

        let entry = Entry(
            uvOrigin: CGPoint(x: penX / d, y: penY / d),
            uvSize: CGSize(width: size.width / d, height: size.height / d),
            size: size)
        entries[text] = entry

        penX += size.width
        rowHeight = max(rowHeight, size.height)
        return entry
    }
}
