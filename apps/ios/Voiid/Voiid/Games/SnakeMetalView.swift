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
import MetalPerformanceShaders
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
    /// My head, in world units. Published for the coach, which proves "you steered" by
    /// measuring distance travelled rather than by listening to a control — so it works for
    /// both steering schemes without knowing either exists.
    @Published var myHead: CGPoint = .zero

    // BOOST STATE, so the HUD can show what boost is costing.
    //
    // Boost drains mass and drops it behind you as food, and it cuts out entirely below
    // MIN_BOOST_MASS — none of which was visible. SNAKE.md §3.2 calls an invisible mechanic
    // "an unfair-feeling mechanic purely because it is invisible": you hold the button, nothing
    // obvious happens, and later you are shorter for reasons you never saw.
    /// True while boost is actually TAKING EFFECT — held AND affordable. Not the same as the
    /// button being down: below the floor the engine ignores the input entirely.
    @Published var boostActive: Bool = false
    /// How much boost fuel is left, 0-1. Mass above the floor, as a fraction of a full tank.
    @Published var boostFuel: Double = 1

    /// Recent kills, newest first — the match's running commentary.
    ///
    /// `kill` events were already parsed on both platforms and rendered as NOTHING textual, so
    /// the single most dramatic thing that happens in a match left no trace on screen. "You ate
    /// Priya" is the line a player screenshots; "someone died somewhere" is not, which is why
    /// this needs the victim's name and not just a count.
    @Published var killFeed: [KillEntry] = []

    struct KillEntry: Identifiable, Equatable {
        let id: UUID
        let text: String
        /// True when the local player did the eating — their own kills are worth colouring.
        let mine: Bool
        /// When it landed, so the overlay can expire it.
        let at: TimeInterval
    }

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
    /// Whether boost is held, so prediction uses the right speed.
    let boosting: Bool

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
        // Feed the stick straight into the predictor so the local head begins turning on the
        // frame the thumb moves, rather than waiting for the server to confirm the heading.
        if stick != .zero {
            context.coordinator.predictor.desiredHeading = atan2(stick.dy, stick.dx)
        }
        context.coordinator.predictor.boosting = boosting
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

    /// Where the camera actually is, as opposed to where the head is.
    ///
    /// The camera used to BE the head — `focus` was the raw interpolated head position, so
    /// every bit of positional error became a full-screen movement at 1:1. Server frames do
    /// not arrive evenly, and the render clock is derived from arrival time, so that error is
    /// constant and visible: the whole arena jerked along the axis of travel several times a
    /// second. Following with a spring absorbs it.
    ///
    /// Nil until the first frame, so the camera starts ON the player rather than springing in
    /// from the arena origin.
    private var cameraCentre: CGPoint?
    /// Last known head position, held so a frame without one cannot pin the camera to (0,0).
    private var lastFocus: CGPoint?
    /// Timestamp of the previous draw, for frame-rate-independent smoothing.
    private var lastCameraStep: TimeInterval = 0

    /// Follow time constant. ~80 ms reads as "attached but not welded"; larger feels laggy,
    /// smaller stops absorbing the jitter it exists to absorb.
    private static let cameraTau: Double = 0.08
    /// Beyond this the head did not move, it TELEPORTED (a respawn puts you anywhere in the
    /// arena). Springing across that gap sends the camera flying over the whole map, so a
    /// jump this large cuts instead. A snake covers ~24 units in a tick at boost speed, so
    /// 300 is far outside anything legitimate motion can produce.
    private static let cameraTeleport: Double = 300

    /// Hitstop + slow-mo on kill/death (GAMES_ANIMATION.md §5.4). PRESENTATION-CLOCK ONLY —
    /// this dilates the WALL-CLOCK dt fed to the camera spring, particles and shake, and
    /// never touches `buildFrame`'s interpolation math above, which reads the server's own
    /// clock and IS the "renderer, not referee" boundary this file's header comment describes.
    /// A bug in this timeline can make the game feel wrong for a fraction of a second; it
    /// cannot make it wrong.
    private let impact = ImpactTimeline()

    private var device: MTLDevice!
    private var queue: MTLCommandQueue!
    private var circlePipeline: MTLRenderPipelineState!
    private var ribbonPipeline: MTLRenderPipelineState!
    private var spritePipeline: MTLRenderPipelineState!
    private var floorPipeline: MTLRenderPipelineState!
    /// Same geometry as the main pipelines but writing ADDITIVE rather than straight-alpha,
    /// into the half-res bloom target. See `renderBloomSource` for why additive here and
    /// straight-alpha on the main pass are both correct at the same time.
    private var circleBloomPipeline: MTLRenderPipelineState!
    private var ribbonBloomPipeline: MTLRenderPipelineState!
    /// Draws the blurred bloom texture back over the final frame, additively.
    private var compositePipeline: MTLRenderPipelineState!
    private var sampler: MTLSamplerState!

    // MARK: Bloom
    //
    // GAMES_ANIMATION.md §5.1: "Render bright elements to an offscreen half-res texture,
    // two-pass Gaussian blur, composite additively. This one change does more for 'out of
    // this world' than any other single item on the list."
    //
    // HALF RESOLUTION, DELIBERATELY. Bloom is a low-frequency effect — nobody can tell a glow
    // was blurred at half the screen's detail, and rendering + blurring a SECOND full arena
    // every frame would roughly double the fill-rate cost of the whole draw for an effect
    // that is meant to be soft in the first place.
    //
    // MPSImageGaussianBlur RATHER THAN A HAND-WRITTEN SEPARABLE BLUR. Apple's kernel is tuned
    // per-GPU-family and already does the two-pass horizontal/vertical split internally; a
    // hand-rolled version would be more MSL to maintain for a worse result on some devices.
    /// What actually got fed into the bloom source this frame — only the head glow halos and
    /// the arena edge ring, i.e. the things in `buildFrame` that are ALREADY additive-looking
    /// (soft, saturated, meant to feel like light). Body ribbons and food are excluded: bloom
    /// on flat opaque fills reads as blur, not glow, and would soften the very shapes the
    /// player needs to judge collisions against.
    private var bloomCircles: [CircleInstance] = []
    private var bloomTexture: MTLTexture?
    private var bloomBlurred: MTLTexture?
    private var bloomSize: CGSize = .zero

    /// Name-plate glyphs, rasterised on demand and packed into one texture.
    private var labelAtlas: LabelAtlas?
    /// The hex-lattice floor tile, repeated across the arena (GAMES_SNAKE_VISUALS §3.1).
    private var hexTexture: MTLTexture?
    private var repeatSampler: MTLSamplerState?

    // Per-frame CPU-side buffers, reused so a frame allocates nothing.
    private var circles: [CircleInstance] = []
    private var ribbon: [RibbonVertex] = []
    /// Arena geography, as triangles.
    ///
    /// ITS OWN BUFFER AND ITS OWN DRAW, before the bodies, because terrain has to be UNDER the
    /// snakes and the circle pass runs after the ribbon pass. Hazards used to be circle
    /// instances, which meant they drew OVER every snake body despite the "terrain first"
    /// comment above `buildHazards` — a rock on top of a snake makes the snake look like it has
    /// already crashed. Same pipeline as the bodies (CPU-triangulated, one buffer, one call),
    /// so this costs a draw call and no new shader.
    private var hazardTris: [RibbonVertex] = []
    private var sprites: [SpriteInstance] = []
    /// Floor quads, drawn before everything else and with their own texture.
    private var floorSprites: [SpriteInstance] = []

    // GPU-side mirrors of the above.
    //
    // These exist because `setVertexBytes` is capped at 4 KB — a limit the arena blows past
    // immediately (300 pellets alone is ~9 KB of circle instances), and exceeding it is a
    // hard Metal validation failure, not a silent truncation. That was the startup crash.
    // Buffers are grown on demand and then reused, so a steady-state frame allocates nothing.
    private var circleBuffer: [MTLBuffer?] = []
    private var ribbonBuffer: [MTLBuffer?] = []
    private var hazardBuffer: [MTLBuffer?] = []
    private var spriteBuffer: [MTLBuffer?] = []
    private var floorBuffer: [MTLBuffer?] = []

    /// Grow `buffer` if needed and copy `array` into it. Returns nil when empty.
    /// Frames the GPU may have in flight at once. Three is the standard depth: enough that
    /// the CPU never waits, small enough that latency stays imperceptible.
    private static let maxFramesInFlight = 3
    /// Which slot of each ring the CURRENT frame writes into.
    private var frameSlot = 0
    /// Blocks the CPU if it ever gets three frames ahead of the GPU.
    private let frameSemaphore = DispatchSemaphore(value: SnakeRenderer.maxFramesInFlight)

    /**
     * Copy `array` into this frame's slot of a triple-buffered ring.
     *
     * WRITING A SINGLE SHARED BUFFER EVERY FRAME IS A RACE, and it was a real one: the GPU
     * may still be reading last frame's contents when the CPU overwrites them, which corrupts
     * geometry and can wedge the drawable — rendering fine and then going blank mid-match.
     * A ring plus the semaphore below means the buffer being written is never the buffer
     * being read.
     */
    private func upload<T>(_ array: [T], into ring: inout [MTLBuffer?]) -> MTLBuffer? {
        guard !array.isEmpty else { return nil }
        if ring.count < Self.maxFramesInFlight {
            ring = Array(repeating: nil, count: Self.maxFramesInFlight)
        }

        let bytes = MemoryLayout<T>.stride * array.count
        if ring[frameSlot] == nil || ring[frameSlot]!.length < bytes {
            // Over-allocate so a slowly growing arena does not reallocate every frame.
            ring[frameSlot] = device.makeBuffer(
                length: max(bytes * 2, 4096), options: .storageModeShared)
        }
        guard let buffer = ring[frameSlot] else { return nil }
        array.withUnsafeBytes { raw in
            buffer.contents().copyMemory(from: raw.baseAddress!, byteCount: bytes)
        }
        return buffer
    }

    /// Body trails, owned HERE rather than in SwiftUI state — this is the fix for the freeze.
    private let trails = TrailStore()
    /// Local-snake prediction. See SnakePredictor for why only the local snake gets this.
    let predictor = SnakePredictor()

    /// Presentation-only VFX driven by the server's per-tick events (GAMES_ANIMATION.md §5.3).
    /// A death/kill/eat/spawn a client never learns about from `events` is invisible motion —
    /// this is what turns those four strings into sparks, bursts and rings. Nothing here is
    /// authoritative: it reads events, it never produces them, so a bug here cannot desync a
    /// match, only under- or over-decorate one.
    private let particles = ParticleSystem()
    /// Ids of events already spawned-for, so a frame that repeats an event (a resync, a
    /// duplicate broadcast) cannot double-spawn. Keyed by (kind, snakeId, tick) rather than
    /// object identity since events are plain structs with no id of their own.
    private var lastEventTime: Double = -1
    /// Wall-clock throttle for the `eat` haptic — see its call site for why.
    private var lastEatHapticAt: TimeInterval = 0
    /// Consecutive pellets eaten without a pause, driving the rising eat pitch.
    private var eatStreak = 0
    private var lastEatAt: TimeInterval = 0
    /// A gap longer than this ends a streak — grazing stays flat, real runs climb.
    private static let eatStreakGap: TimeInterval = 0.6
    /// Roughly an octave of climb, then hold.
    private static let eatStreakCap = 24
    /// Local player's boost state as of the last frame, so start/end sounds fire once on the
    /// TRANSITION rather than every frame boost happens to be held/released — there is no
    /// server event for this (boost is continuous per-tick state, not a discrete event like
    /// eat/kill/death/spawn), so the edge has to be detected client-side.
    private var wasBoosting = false

    private var viewSize: CGSize = .zero
    /// When the HUD was last pushed to SwiftUI; see `publishHud` for why it is throttled.
    private var lastHudPublish: TimeInterval = 0
    /// Wall-clock time of the previous draw, for the particle system's own dt — independent of
    /// the camera's dt and the render clock, because particles must keep animating even during
    /// a network stall (nothing about a spark's decay is server truth).
    private var lastParticleStep: TimeInterval = 0

    /// The render clock, in SERVER time. Persistent renderer state — NOT recomputed per frame.
    /// See `advanceClock`.
    private var renderClock: Double = 0
    /// Host-clock timestamp of the previous `advanceClock` call, for the clock's own dt.
    private var lastDrawAt: TimeInterval = 0

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
                                       pixelFormat: view.colorPixelFormat, blend: .straightAlpha)
        ribbonPipeline = Self.pipeline(device: device, library: library,
                                       vertex: "ribbonVertex", fragment: "ribbonFragment",
                                       pixelFormat: view.colorPixelFormat, blend: .straightAlpha)
        spritePipeline = Self.pipeline(device: device, library: library,
                                       vertex: "spriteVertex", fragment: "spriteFragment",
                                       pixelFormat: view.colorPixelFormat, blend: .straightAlpha)

        // Bloom source pipelines render the SAME two shaders into the half-res bloom texture,
        // but ADDITIVE: two overlapping glows should brighten each other (that is what light
        // does), where the main pass's straight alpha would just occlude one with the other.
        // The bloom texture always starts cleared to black, so additive-onto-black behaves
        // exactly like "just draw the glow" for a single instance and correctly accumulates
        // for overlapping ones.
        circleBloomPipeline = Self.pipeline(device: device, library: library,
                                            vertex: "circleVertex", fragment: "circleFragment",
                                            pixelFormat: Self.bloomPixelFormat, blend: .additive)
        ribbonBloomPipeline = Self.pipeline(device: device, library: library,
                                            vertex: "ribbonVertex", fragment: "ribbonFragment",
                                            pixelFormat: Self.bloomPixelFormat, blend: .additive)
        // bloomCompositeFragment, NOT spriteFragment — see that shader's doc comment in
        // Snake.metal. Using the label shader here was the bug that washed the whole arena to
        // white the instant bloom had any coverage: it hardcodes output RGB to the tint colour
        // (correct for name-plate text, wrong for compositing a colour bloom texture) and this
        // pass always passed a pure-white tint, so every additive-blended pixel painted white.
        compositePipeline = Self.pipeline(device: device, library: library,
                                          vertex: "spriteVertex", fragment: "bloomCompositeFragment",
                                          pixelFormat: view.colorPixelFormat, blend: .additive)

        let sd = MTLSamplerDescriptor()
        sd.minFilter = .linear
        sd.magFilter = .linear
        sampler = device.makeSamplerState(descriptor: sd)

        labelAtlas = LabelAtlas(device: device)
        hexTexture = Self.makeHexTile(device: device)

        // REPEAT addressing is the whole point: one quad covers the arena and the sampler
        // tiles the lattice across it, so a few hundred hexes cost one draw rather than a few
        // hundred.
        let rd = MTLSamplerDescriptor()
        rd.minFilter = .linear
        rd.magFilter = .linear
        rd.sAddressMode = .repeat
        rd.tAddressMode = .repeat
        repeatSampler = device.makeSamplerState(descriptor: rd)
    }

    private enum BlendMode { case straightAlpha, additive }

    private static func pipeline(
        device: MTLDevice, library: MTLLibrary,
        vertex: String, fragment: String, pixelFormat: MTLPixelFormat, blend: BlendMode
    ) -> MTLRenderPipelineState? {
        let d = MTLRenderPipelineDescriptor()
        d.vertexFunction = library.makeFunction(name: vertex)
        d.fragmentFunction = library.makeFunction(name: fragment)
        d.colorAttachments[0].pixelFormat = pixelFormat
        d.colorAttachments[0].isBlendingEnabled = true
        switch blend {
        case .straightAlpha:
            // The arena is layered glows over a dark floor; additive here would blow out to
            // white wherever two glows overlap on the MAIN pass, which is not what a body or a
            // food pellet should do to what is behind it.
            d.colorAttachments[0].sourceRGBBlendFactor = .sourceAlpha
            d.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
            d.colorAttachments[0].sourceAlphaBlendFactor = .sourceAlpha
            d.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha
        case .additive:
            // dst + src, uncapped. Correct for light: two glows overlapping should be brighter
            // than either alone, and this is also what the FINAL composite needs — the blurred
            // bloom texture is added ON TOP of the already-complete main-pass frame, never
            // replacing it.
            d.colorAttachments[0].sourceRGBBlendFactor = .one
            d.colorAttachments[0].destinationRGBBlendFactor = .one
            d.colorAttachments[0].sourceAlphaBlendFactor = .one
            d.colorAttachments[0].destinationAlphaBlendFactor = .one
        }
        do {
            return try device.makeRenderPipelineState(descriptor: d)
        } catch {
            // `try?` here previously swallowed the actual Metal validation error, which is
            // exactly the "arena renders nothing, no log line, no crash" failure mode this is
            // guarding against — a bad pipeline (e.g. an unsupported pixelFormat/blend
            // combination on some GPU families) left `circlePipeline` (etc.) nil, and
            // draw(in:) silently no-ops on that. Logging the real reason turns a silent white
            // screen into a diagnosable one.
            print("[snake] pipeline '\(vertex)+\(fragment)' failed: \(error)")
            return nil
        }
    }

    /// A format MPSImageGaussianBlur can both read and write. .bgra8Unorm (the drawable's own
    /// format) works but rgba16Float gives the blur headroom above 1.0 so a bright cluster of
    /// overlapping glows blurs into a wider, still-bright halo instead of clipping to white at
    /// the source before the blur even runs.
    private static let bloomPixelFormat: MTLPixelFormat = .rgba16Float

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {
        viewSize = size
        allocateBloomTargets(for: size)
    }

    /// Half the drawable's resolution, per §5.1's "half resolution, always". Reallocated only
    /// when the drawable size actually changes (rotation, split view), never per frame.
    private func allocateBloomTargets(for size: CGSize) {
        guard size.width > 0, size.height > 0, let device else { return }
        let w = max(1, Int(size.width / 2))
        let h = max(1, Int(size.height / 2))
        bloomSize = CGSize(width: w, height: h)

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: Self.bloomPixelFormat, width: w, height: h, mipmapped: false)
        desc.usage = [.renderTarget, .shaderRead]
        desc.storageMode = .private
        bloomTexture = device.makeTexture(descriptor: desc)
        bloomBlurred = device.makeTexture(descriptor: desc)
    }

    // MARK: Frame

    func draw(in view: MTKView) {
        // Wait if the GPU is three frames behind, and advance to this frame's ring slot.
        // Without this the CPU can lap the GPU and overwrite buffers mid-read.
        frameSemaphore.wait()
        frameSlot = (frameSlot + 1) % Self.maxFramesInFlight

        guard let drawable = view.currentDrawable,
              let descriptor = view.currentRenderPassDescriptor,
              let commands = queue.makeCommandBuffer(),
              circlePipeline != nil
        else {
            // MUST signal on EVERY path out past the wait. Miss one and the semaphore drains
            // to zero, after which every later frame blocks forever — a permanent freeze
            // rather than a dropped frame. `currentDrawable` returning nil is routine (it
            // happens whenever the view is off-screen), so this path is taken in normal use.
            frameSemaphore.signal()
            return
        }

        viewSize = view.drawableSize
        circles.removeAll(keepingCapacity: true)
        ribbon.removeAll(keepingCapacity: true)
        sprites.removeAll(keepingCapacity: true)
        hazardTris.removeAll(keepingCapacity: true)
        floorSprites.removeAll(keepingCapacity: true)
        bloomCircles.removeAll(keepingCapacity: true)

        guard let frame = buildFrame() else {
            // Nothing to draw yet (no frame has arrived): still present a cleared drawable
            // rather than skipping the frame entirely, or the view briefly shows garbage.
            if let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) {
                encoder.endEncoding()
            }
            commands.present(drawable)
            // This path commits real GPU work, so it releases its slot the same way the main
            // path does. Committing without a handler would leak a slot per frame until the
            // semaphore hit zero and the view locked up.
            commands.addCompletedHandler { [frameSemaphore] _ in frameSemaphore.signal() }
            commands.commit()
            return
        }
        var uniforms = frame

        // PASS 1 — bloom source, half-res, additive, into an offscreen texture. Only the
        // circles buildFrame classified as glow (bloomCircles) go here; see the property's
        // doc comment for why bodies and food halos are excluded.
        renderBloomSource(commands: commands, uniforms: &uniforms)

        // PASS 2 — blur pass 1's output in place. Two-pass separable Gaussian, entirely
        // Apple's kernel; this call does both directions internally.
        blurBloom(commands: commands)

        // PASS 3 — the main, full-resolution frame exactly as before bloom existed.
        guard let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor) else {
            commands.present(drawable)
            commands.commit()
            return
        }
        encoder.setVertexBytes(&uniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

        // Floor FIRST, under everything — it is a texture the arena sits on, and drawing it
        // after the bodies would paint the lattice over the snakes.
        if let buf = upload(floorSprites, into: &floorBuffer),
           let tex = hexTexture, let smp = repeatSampler, floorPipeline != nil {
            encoder.setRenderPipelineState(floorPipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 1)
            encoder.setFragmentTexture(tex, index: 0)
            encoder.setFragmentSamplerState(smp, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: floorSprites.count)
        }

        // TERRAIN FIRST — under the bodies and under the food, which is what the arena's
        // geography is supposed to be. Same pipeline as the bodies; a separate draw is what
        // puts it beneath them.
        if let buf = upload(hazardTris, into: &hazardBuffer), ribbonPipeline != nil {
            encoder.setRenderPipelineState(ribbonPipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: hazardTris.count)
        }

        // Bodies next, then circles over them (heads, food), then labels on top.
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

        // PASS 4 — composite the blurred bloom texture additively ON TOP of the main pass,
        // as one full-screen quad. Additive: this brightens what is already drawn, it never
        // replaces it, which is what makes bloom read as light spilling off the glowing
        // shapes rather than a soft double-exposure of the whole scene.
        compositeBloom(encoder: encoder)

        // PASS 5 — the death impact tint (GAMES_ANIMATION.md §5.4's "desaturate over 400ms").
        // A TRUE desaturation would need to sample the drawable itself, which this pipeline
        // cannot do without a second full-resolution offscreen pass and a grayscale shader —
        // real cost for an effect that lasts 400ms and is seen by exactly one player, the one
        // who just died. This darkens and cools the frame instead: straight-alpha near-black
        // over everything, same read (the arena visually recoiling) at a fraction of the GPU
        // cost. Revisit with a real desaturate if bloom's fill-rate headroom allows it later.
        deathTint(encoder: encoder)

        if let buf = upload(sprites, into: &spriteBuffer),
           let texture = labelAtlas?.texture, spritePipeline != nil {
            encoder.setRenderPipelineState(spritePipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 1)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.setFragmentSamplerState(sampler, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: sprites.count)
        }

        encoder.endEncoding()
        commands.present(drawable)
        // Release this frame's slot only once the GPU has actually finished with it.
        commands.addCompletedHandler { [frameSemaphore] _ in frameSemaphore.signal() }
        commands.commit()
    }

    /// PASS 1: render `bloomCircles` into the half-res offscreen texture, additive, cleared
    /// to black first. Uniforms are scaled to the bloom texture's own (half) resolution so
    /// world-to-clip math still lands correctly at the smaller size.
    private func renderBloomSource(commands: MTLCommandBuffer, uniforms: inout Uniforms) {
        // Off after user testing: the neon wash made the arena hard to read. Bailing here
        // skips the blur passes entirely rather than rendering into a texture that is then
        // composited at zero strength.
        guard Self.bloomEnabled else { return }
        guard let bloomTexture, bloomSize.width > 0 else { return }

        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = bloomTexture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        pass.colorAttachments[0].storeAction = .store

        guard let encoder = commands.makeRenderCommandEncoder(descriptor: pass) else { return }

        var bloomUniforms = uniforms
        bloomUniforms.viewportSize = SIMD2(Float(bloomSize.width * 2), Float(bloomSize.height * 2))
        // scale is world-units -> POINTS, unaffected by the render target's pixel resolution —
        // the viewport halving above is what maps the same world extent onto the smaller
        // texture, exactly as it would if the whole app were running at half point-scale.
        encoder.setVertexBytes(&bloomUniforms, length: MemoryLayout<Uniforms>.stride, index: 0)

        if !ribbon.isEmpty, let buf = upload(ribbon, into: &ribbonBloomBuffer),
           ribbonBloomPipeline != nil {
            encoder.setRenderPipelineState(ribbonBloomPipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: ribbon.count)
        }

        if !bloomCircles.isEmpty, let buf = upload(bloomCircles, into: &bloomCircleBuffer),
           circleBloomPipeline != nil {
            encoder.setRenderPipelineState(circleBloomPipeline)
            encoder.setVertexBuffer(buf, offset: 0, index: 1)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4,
                                   instanceCount: bloomCircles.count)
        }

        encoder.endEncoding()
    }

    /// PASS 2: MPSImageGaussianBlur, bloomTexture -> bloomBlurred. Sigma is in TEXTURE pixels
    /// (i.e. already half-res, so this reads roughly 2x as wide on screen as the number alone
    /// suggests) — intentional, that is what makes bloom read as soft light rather than a
    /// sharpened edge glow.
    ///
    /// WAS 6.0. At half-res that is a genuinely huge kernel — wide enough that on a real
    /// device the blur was smearing across most of the visible arena rather than staying
    /// local to the glowing shapes, which is what "the whole game looks blurry, not like
    /// Android" was: this is the ONLY thing that differs between the two renderers (Android's
    /// tier-C approximation is layered sharp strokes, not a real blur — see
    /// GAMES_ANIMATION.md §4), so an oversized blur radius here is exactly what would produce
    /// that gap. 2.5 keeps the "these things emit light" read from §3.3 without smearing body/
    /// food edges the player needs to judge collisions against.
    private func blurBloom(commands: MTLCommandBuffer) {
        guard let bloomTexture, let bloomBlurred else { return }
        let blur = MPSImageGaussianBlur(device: device, sigma: 2.5)
        blur.encode(commandBuffer: commands, sourceTexture: bloomTexture,
                    destinationTexture: bloomBlurred)
    }

    /// PASS 4: draw the blurred bloom texture as one full-screen quad, additive, into the
    /// already-open main-pass encoder. Reuses the sprite pipeline's vertex stage (a textured
    /// quad is a textured quad) but through `compositePipeline`, which blends additively
    /// instead of the sprite pass's straight alpha.
    private func compositeBloom(encoder: MTLRenderCommandEncoder) {
        guard Self.bloomEnabled else { return }
        guard let bloomBlurred, compositePipeline != nil, viewSize.width > 0 else { return }

        // One instance, sized and centred to cover the whole viewport in WORLD space at the
        // current camera scale — i.e. exactly what is on screen right now, since the source
        // texture was rendered with the same camera uniforms.
        let scale = uniformsScaleForComposite
        guard scale > 0 else { return }
        let worldW = Float(viewSize.width) / scale
        let worldH = Float(viewSize.height) / scale
        // tint.rgb is UNUSED by bloomCompositeFragment (it samples the real texel colour
        // instead) — only tint.a reaches the shader, as the intensity scale. Left as
        // SIMD4(1,1,1,_) rather than a 2-component type only because SpriteInstance's layout
        // is shared with the label sprite pass, where rgb does matter.
        let quad = SpriteInstance(
            centre: lastCameraCentreSIMD,
            size: SIMD2(worldW, worldH),
            uvOrigin: .zero, uvSize: SIMD2(1, 1),
            tint: SIMD4(1, 1, 1, Self.bloomIntensity))

        guard let buf = upload([quad], into: &compositeBuffer) else { return }
        encoder.setRenderPipelineState(compositePipeline)
        encoder.setVertexBuffer(buf, offset: 0, index: 1)
        encoder.setFragmentTexture(bloomBlurred, index: 0)
        encoder.setFragmentSamplerState(sampler, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
    }

    /// How strongly the blurred glow is added back over the main pass. Low: this is meant to
    /// be felt as "these things emit light", not to wash the arena out. Tuned by eye against
    /// the existing palette rather than derived from anything.
    /// Bloom strength. ZERO — the neon look was removed after user testing.
    ///
    /// The pipeline is left intact rather than deleted: the effect is a real one and turning
    /// it back on is a one-line change, whereas re-deriving the blur passes would not be.
    /// `bloomEnabled` short-circuits the passes entirely so a disabled effect costs nothing
    /// per frame rather than rendering into a texture nobody composites.
    private static let bloomIntensity: Float = 0
    private static let bloomEnabled = false

    /// Arena boundary half-thickness, per user testing ("make the border more thick").
    private static let borderWidth: Float = 7
    /// Body outline thickness, per user testing ("make the outline more thick").
    private static let outlineWidth: Float = 3.5

    /// PASS 5: darken the frame by `impact.desaturation`, straight-alpha, near-black with a
    /// faint cool tint. See the call site's comment for why this stands in for a true
    /// desaturate. A full-viewport circle through the EXISTING circle pipeline — no new
    /// pipeline object, no new shader — sized past the diagonal so its edge is always off
    /// screen regardless of aspect ratio or camera scale.
    private func deathTint(encoder: MTLRenderCommandEncoder) {
        let amount = impact.desaturation
        guard amount > 0, circlePipeline != nil, viewSize.width > 0 else { return }

        let scale = uniformsScaleForComposite
        guard scale > 0 else { return }
        let coverWorld = Float(hypot(viewSize.width, viewSize.height)) / scale

        // Peak alpha capped at 0.6, not 1.0: the point is a punch, not a blackout — the death
        // panel appears over this a beat later and must still be legible against it.
        let tint = CircleInstance(
            centre: lastCameraCentreSIMD, radius: coverWorld, softness: 0,
            colour: SIMD4(0.02, 0.03, 0.06, amount * 0.6))

        guard let buf = upload([tint], into: &deathTintBuffer) else { return }
        encoder.setRenderPipelineState(circlePipeline)
        encoder.setVertexBuffer(buf, offset: 0, index: 1)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4, instanceCount: 1)
    }

    private var deathTintBuffer: [MTLBuffer?] = []

    // Rings, like every other per-frame buffer: these are written each frame while the GPU
    // may still be reading the previous one, which is the race that blanked the view.
    private var ribbonBloomBuffer: [MTLBuffer?] = []
    private var bloomCircleBuffer: [MTLBuffer?] = []
    private var compositeBuffer: [MTLBuffer?] = []
    /// Cached from the last `buildFrame` uniforms so `compositeBloom` (called from inside the
    /// main encoder, after `buildFrame` already ran) can size its full-screen quad correctly.
    private var lastCameraCentreSIMD: SIMD2<Float> = .zero
    private var uniformsScaleForComposite: Float = 0

    /// How far behind the newest frame to render.
    ///
    /// TWO AND A HALF ticks, not one and a half.
    ///
    /// At 1.5 ticks the buffer ran dry on any frame that arrived even slightly late — and on
    /// a mobile network that is most of them — so the render clock repeatedly caught up with
    /// the newest frame, held, and jumped. That hold-jump cycle IS the jitter. 2.5 ticks means
    /// a frame can be 150 ms late before the buffer runs dry instead of 50 ms.
    ///
    /// THIS WAS CUT TO 0.15 ONCE, AND THE ARGUMENT FOR CUTTING IT WAS BACKWARDS. The reasoning
    /// was that the delay made the controls feel remote — true when it was written, because
    /// back then it applied to every snake including the one the player is steering. But the
    /// LOCAL snake is predicted now, not interpolated (see `predictor` below): this constant
    /// no longer touches it at all. Prediction did not make a smaller delay affordable, it
    /// made a LARGER one free. What is left behind the clock is other snakes and the food
    /// field, where 100 ms of extra staleness is invisible and a stall is not.
    private static let interpDelay: Double = 0.25   // 2.5 ticks at tickHz 10

    /// How far past the newest buffered frame a head may be carried on its last heading before
    /// the world simply holds. See the `overshoot` call site in `buildFrame`. Identical on
    /// Android (`MAX_EXTRAPOLATION`).
    private static let maxExtrapolation: Double = 0.10

    /// The instant to draw the world at, in SERVER time.
    ///
    /// NEVER anchored to a frame's ARRIVAL time. Arrival jitter is precisely what the frame
    /// buffer exists to absorb; rebuilding the clock from it on every frame feeds that jitter
    /// straight back into the picture — the world snaps by (0.1 - interArrivalGap) seconds of
    /// travel, ten times a second, which at BASE_SPEED 240 u/s is most of a head radius per
    /// snap. Instead the clock free-runs on the local display clock and closes any drift by
    /// running slightly fast or slow. A ±10% rate error is imperceptible; a position snap is
    /// the bug.
    private func advanceClock(newest: GamesEngine.SnakeFrame) -> Double {
        let now = CACurrentMediaTime()
        let dt = lastDrawAt > 0 ? min(now - lastDrawAt, 0.25) : 0
        lastDrawAt = now

        let target = newest.state.time - Self.interpDelay

        // First frame, or a real stall (app backgrounded, socket reconnected): hard resync.
        // Springing across a gap this large would sweep the world instead of cutting.
        if renderClock == 0 || abs(target - renderClock) > 0.5 {
            renderClock = target
        } else {
            let drift = target - renderClock
            let rate = 1.0 + max(-0.10, min(0.10, drift * 0.5))
            renderClock += dt * rate
        }
        return renderClock
    }

    private func buildFrame() -> Uniforms? {
        let frames = engine.snakeFramesSnapshot
        guard let newest = frames.last else { return nil }

        // Pick the pair bracketing the render instant, on the SERVER's clock. Arrival jitter
        // moves the offset rather than the snake.
        var from = newest.state
        var to = newest.state
        var t = 1.0

        // Advanced EVERY frame, including when only one server frame is buffered: the clock is
        // persistent state, and skipping the call would let its `dt` accumulate across the gap
        // and lurch on the next draw.
        let renderT = advanceClock(newest: newest)

        if frames.count >= 2 {
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

        // BUFFER DRY — carry each head forward along its last heading rather than freezing.
        //
        // A frozen world reads as a hang, which is the worst available response to a stall:
        // the player cannot tell it from the app dying. 100 ms of a straight line is very
        // likely correct — a snake's turn rate is capped (SnakeMotion.turnRate), so it cannot
        // have gone far off this path — and the bound means the client can never invent a
        // position the server would not confirm. It also stays under TrailStore's 60-unit
        // resync distance at boost speed (510 * 0.10 = 51), so extrapolating never triggers a
        // trail re-seed and the body follows the head instead of detaching from it.
        let overshoot = min(max(renderT - newest.state.time, 0), Self.maxExtrapolation)

        var heads: [String: CGPoint] = [:]
        var headings: [String: Double] = [:]
        /// Signed turn rate, radians per second, per snake. This is the only INTENT signal a
        /// remote snake carries: the server sends where it points, never where it is steering.
        var turnRates: [String: Double] = [:]
        for snake in state.snakes {
            let prev = from.snakes.first { $0.id == snake.id }
            let px = prev?.x ?? snake.x, py = prev?.y ?? snake.y
            var head = CGPoint(x: px + (snake.x - px) * t, y: py + (snake.y - py) * t)
            let heading = Self.lerpAngle(prev?.heading ?? snake.heading, snake.heading, t)
            // Dead snakes are not extrapolated: they are not moving, and sliding a corpse
            // forward is inventing motion rather than covering for a missing frame.
            if overshoot > 0, snake.alive {
                let speed = snake.boosting ? SnakeMotion.boostSpeed : SnakeMotion.baseSpeed
                head.x += cos(heading) * speed * overshoot
                head.y += sin(heading) * speed * overshoot
            }
            heads[snake.id] = head
            headings[snake.id] = heading
            // Measured across the whole server interval rather than the interpolated slice, so
            // it does not scale with how far between frames this particular draw landed.
            let span = max(to.time - from.time, 1e-4)
            if let prev {
                turnRates[snake.id] = Self.angleDifference(prev.heading, snake.heading) / span
            }
        }

        // THE LOCAL SNAKE IS PREDICTED, not interpolated.
        //
        // Every other snake is drawn ~150 ms in the past because we cannot know where someone
        // else is going. Doing that to your OWN snake means your thumb moves and the head
        // answers a fifth of a second later — smoothing a laggy control only makes it a
        // smooth laggy control. So the local head runs the server's own movement maths
        // locally and folds server corrections in over 150 ms instead of snapping to them.
        if let me, let mine = state.snakes.first(where: { $0.id == me }) {
            // Reconcile against the NEWEST frame, not the interpolated one: the point of
            // prediction is to be ahead of the render clock, so correcting toward a
            // deliberately-stale position would drag it back into the past.
            let newestMine = frames.last?.state.snakes.first { $0.id == me }
            if let newestMine {
                predictor.reconcile(
                    serverPosition: CGPoint(x: newestMine.x, y: newestMine.y),
                    serverHeading: newestMine.heading,
                    alive: newestMine.alive)
            }

            if mine.alive, let predicted = predictor.step(now: CACurrentMediaTime()) {
                heads[me] = predicted
                headings[me] = predictor.heading
            }
        }

        trails.update(state: state, heads: heads)

        // TRIGGER DETECTION RUNS BEFORE stepCamera, deliberately separate from the spawn loop
        // below. `impact.dilate` is read INSIDE stepCamera on the very next line, so the
        // trigger must already be live by the time we get there — spawning particles can
        // safely wait until after buildSnake since ParticleSystem.step runs later in this
        // function, but a freeze that started one frame late would show the camera still
        // sliding for 16ms while everything else had already stopped.
        if state.time > lastEventTime {
            for event in state.events {
                if event.kind == "kill" {
                    // EVERY kill goes in the feed, not just mine. A feed that only reports
                    // your own kills is a personal scoreboard; the point is knowing the arena
                    // is dangerous and who is doing the damage.
                    recordKill(event: event, state: state)

                    if event.snakeId == me {
                        impact.triggerKill()
                        GameHaptics.kill()
                        GameAudio.shared.play("kill", gain: 0.75)
                    }
                }
                if event.kind == "death", event.snakeId == me {
                    impact.triggerDeath()
                    GameHaptics.death()
                    GameAudio.shared.play("death", gain: 0.85)
                    // THE SHARED SOUND (docs/games/SOUND_DESIGN.md §3/§4.2). Snake's `catch`
                    // moment is being killed BY ANOTHER SNAKE — your run was ended by an
                    // opponent, which is the same event Tic Tac Toe, RPS and cricket all mark
                    // with this file. Snake is not exempt from the vocabulary.
                    //
                    // The BORDER is deliberately excluded: you were not caught, you crashed.
                    // `death` carries the server's own cause ("border" | "body" | "head"), so
                    // this asks rather than guesses.
                    if event.cause != "border" {
                        GameAudio.shared.play(GameAudio.catchShared, gain: 0.55)
                    }
                }
                if event.kind == "spawn", event.snakeId == me {
                    GameAudio.shared.play("spawn", gain: 0.6)
                }
            }
        }

        let mine = state.snakes.first { $0.id == me }

        // boost_start/boost_loop/boost_end: no server EVENT for these (boost is per-tick
        // continuous state, not a discrete occurrence like eat/kill), so the transition is
        // detected here from consecutive frames.
        let isBoosting = mine?.alive == true && mine?.boosting == true
        if isBoosting, !wasBoosting {
            GameAudio.shared.play("boost_start", gain: 0.6)
            GameAudio.shared.startLoop("boost_loop", gain: 0.35)
        } else if !isBoosting, wasBoosting {
            GameAudio.shared.stopLoop("boost_loop")
            GameAudio.shared.play("boost_end", gain: 0.55)
        }
        wasBoosting = isBoosting

        let mass = mine?.mass ?? 10
        // Zoom out as mass grows so a big snake stays framed, log-damped so growth reads as
        // "the world got a little smaller" rather than a nauseating continuous zoom-out.
        // Already an eased function of mass (not a snapped tier), so this alone satisfies
        // GAMES_ANIMATION.md §5.2's "mass zoom" — look-ahead and shake below are what it adds.
        let zoom = 1.0 / (1.0 + log10(1 + mass / 30) * 0.42)
        let scale = Float(min(viewSize.width, viewSize.height) / 900.0 * zoom)

        // LOOK-AHEAD: "offset toward the heading, scaled by speed — the player sees where they
        // are going instead of where they are" (§5.2). Only for the local player: an
        // opponent's heading is not something the camera should react to.
        let lookAhead = Self.computeLookAhead(mine: mine, headingsById: headings, me: me)
        let target = heads[me ?? ""].map {
            CGPoint(x: $0.x + lookAhead.x, y: $0.y + lookAhead.y)
        }
        let focus = stepCamera(target: target)

        buildArena(radius: state.arenaRadius)
        // Terrain first: under the food and under the snakes. A rock drawn over a snake would
        // make the snake look like it had already crashed into it.
        buildHazards(state: state)
        buildFood(state: state)

        // Rank by mass, so the label over a head and the HUD row always agree.
        let ranked = state.snakes.sorted { $0.mass > $1.mass }
        var rankOf: [String: Int] = [:]
        for (i, s) in ranked.enumerated() { rankOf[s.id] = i + 1 }

        for snake in state.snakes where snake.alive {
            buildSnake(snake: snake,
                       head: heads[snake.id] ?? .zero,
                       heading: headings[snake.id] ?? 0,
                       turnRate: turnRates[snake.id] ?? 0,
                       isMe: snake.id == me,
                       time: state.time,
                       rank: rankOf[snake.id] ?? 0,
                       scale: scale)
        }

        // NEW events only. `t` only ever increases within a match (the runtime's tick loop is
        // the sole writer), so "this frame's t is newer than the last frame we spawned for" is
        // sufficient de-duplication without tracking individual event identity — a resync or a
        // repeated broadcast of the SAME tick carries the same `t` and is correctly skipped.
        if state.time > lastEventTime {
            for event in state.events {
                let colour = state.snakes.first { $0.id == event.snakeId }
                    .map { Self.palette($0.colorIndex) } ?? SIMD4(1, 1, 1, 1)
                particles.spawn(kind: event.kind, at: event.position, colour: colour)

                // Rate-limited: `eat` can fire several times a second in a food-dense patch,
                // and a Taptic Engine retriggered that fast reads as a buzz rather than a
                // series of distinct ticks. 60ms floor keeps individual eats distinguishable
                // without saturating the hardware queue.
                if event.kind == "eat", event.snakeId == me,
                   CACurrentMediaTime() - lastEatHapticAt > 0.06 {
                    GameHaptics.eat()
                    lastEatHapticAt = CACurrentMediaTime()
                    // A RISING RUN, not a random variant.
                    //
                    // Random pitch gives variety but no meaning: every pellet sounds like the
                    // last one. Stepping the pitch up while you keep eating turns a corpse
                    // pile — or a good run through open food — into an audible crescendo, and
                    // that is the cheapest dopamine in the genre. The streak resets after a
                    // short gap so ordinary grazing stays flat and only real runs climb.
                    let now = CACurrentMediaTime()
                    if now - lastEatAt > Self.eatStreakGap { eatStreak = 0 } else { eatStreak += 1 }
                    lastEatAt = now
                    // Cap the climb: past an octave it stops reading as triumphant and starts
                    // reading as a kettle.
                    let step = min(eatStreak, Self.eatStreakCap)
                    let pitch = pow(2.0, Float(step) / 24.0)   // ~half a semitone per pellet
                    GameAudio.shared.play("eat_1", pitch: pitch, gain: 0.6)
                }

                // Screen shake on YOUR kills only. `event.snakeId` on a `kill` event is the
                // KILLER (snake/index.ts kill() pushes `id: killerId`), so this fires for the
                // player who just won a fight, not their victim. Hitstop for the same event was
                // already triggered above, before stepCamera ran — see that block's comment.
                if event.kind == "kill", event.snakeId == me {
                    triggerShake(magnitude: 6)
                }
            }
            lastEventTime = state.time
        }
        // Presentation clocks (particles, and the camera spring inside stepCamera above) run
        // on this DILATED dt, not raw wall-clock — this is the entire mechanism by which
        // hitstop/slow-mo happens. The interpolation math above `state = to` is untouched: the
        // server's own clock, never dilated, is what keeps this a renderer and not a referee.
        let particleNow = CACurrentMediaTime()
        let rawDt = lastParticleStep > 0 ? particleNow - lastParticleStep : 0
        particles.step(dt: impact.dilate(rawDt))
        lastParticleStep = particleNow
        // Particles ARE light in this renderer (see ParticleSystem.appendInstances), so they
        // feed the bloom source the same way the head/food/edge glows do.
        particles.appendInstances(into: &bloomCircles)

        publishHud(state: state, ranked: ranked, mine: mine)

        // Shake is added HERE, after the follow spring, never fed back into `cameraCentre` —
        // see the property's doc comment for why.
        let shake = currentShake(scale: scale)
        let cameraSIMD = SIMD2(Float(focus.x + shake.x), Float(focus.y + shake.y))
        // Cached for `compositeBloom`, which runs later in the SAME draw call from inside the
        // main-pass encoder and has no other way to know this frame's camera/scale.
        lastCameraCentreSIMD = cameraSIMD
        uniformsScaleForComposite = scale

        return Uniforms(cameraCentre: cameraSIMD,
                        viewportSize: SIMD2(Float(viewSize.width), Float(viewSize.height)),
                        scale: scale)
    }

    /// Advance the camera toward the local player's head and return where it now is.
    ///
    /// `target` is nil when this frame carries no head for us — the local player is not in the
    /// snake list yet, or `me` itself is nil because the token store had not loaded when the
    /// arena opened. The old code fell through to `.zero` in that case, which is not "no
    /// change", it is the middle of the arena: the view teleported away from the player and
    /// their snake wandered off screen. Android already guards this (`CameraMemory`); iOS
    /// never got the fix.
    private func stepCamera(target: CGPoint?) -> CGPoint {
        if let target { lastFocus = target }
        guard let goal = target ?? lastFocus else { return cameraCentre ?? .zero }

        let now = CACurrentMediaTime()
        let rawDt = lastCameraStep > 0 ? min(now - lastCameraStep, 0.1) : 0
        lastCameraStep = now
        // Dilated by the impact timeline: during a hitstop freeze this is 0, so the camera
        // correctly HOLDS rather than continuing to chase a moving target while the world is
        // frozen — a camera that kept sliding during a freeze would read as the freeze not
        // having worked.
        let dt = impact.dilate(rawDt)

        guard let current = cameraCentre else {
            cameraCentre = goal          // first frame: start on the player, do not spring in
            return goal
        }

        // A respawn is a teleport, not motion. Cut.
        if hypot(goal.x - current.x, goal.y - current.y) > Self.cameraTeleport {
            cameraCentre = goal
            return goal
        }

        // Exponential smoothing, framed in seconds so it behaves identically at 60 and 120 Hz.
        // `1 - exp(-dt/tau)` is the frame-rate-independent form; a bare `k * dt` lerp would
        // make the camera stiffer on a ProMotion display than on a 60 Hz one.
        let a = dt > 0 ? 1 - exp(-dt / Self.cameraTau) : 1
        let next = CGPoint(x: current.x + (goal.x - current.x) * a,
                           y: current.y + (goal.y - current.y) * a)
        cameraCentre = next
        return next
    }

    /// Offset the camera toward where the local player is HEADED, scaled by speed — "the
    /// player sees where they are going instead of where they are" (GAMES_ANIMATION.md §5.2).
    /// Returns .zero (no offset) for a dead/absent/boosting-unknown player rather than
    /// optionals, since every caller immediately adds this to a point.
    private static func computeLookAhead(
        mine: SnakeState.Snake?, headingsById: [String: Double], me: String?
    ) -> CGPoint {
        guard let mine, mine.alive, let heading = headingsById[me ?? ""] else { return .zero }
        // BASE_SPEED/BOOST_SPEED from the server's TUNING (snake/index.ts) — duplicated here
        // as a presentation constant rather than threaded through the wire, because look-ahead
        // distance affects nothing about the simulation and a slightly-wrong guess at boost
        // speed only makes the offset a little short or long, never incorrect gameplay.
        let speed = mine.boosting ? 510.0 : 300.0
        // Distance scales with speed but caps out — otherwise a long boost would push the
        // camera so far ahead the player's own snake nears the screen edge.
        let distance = min(speed * Self.lookAheadSeconds, Self.lookAheadMax)
        return CGPoint(x: cos(heading) * distance, y: sin(heading) * distance)
    }

    /// How far ahead to look, in seconds of travel at current speed.
    private static let lookAheadSeconds: Double = 0.35
    private static let lookAheadMax: Double = 140

    // MARK: Screen shake
    //
    // "3-6 px, 200 ms, decaying" (§5.2/§3.1). A camera-space effect, deliberately never
    // written into `cameraCentre` itself — shake must never feed back into the follow spring
    // (stepCamera's teleport check would otherwise occasionally misfire on a big shake) or
    // persist across a screen-size change, so it is tracked separately and added to the
    // camera's output only at the point `buildFrame` returns its Uniforms.
    private var shakeStartedAt: TimeInterval = 0
    private var shakeMagnitude: Double = 0
    private var shakeSeed: Double = 0

    /// Trigger a shake. Called once per `kill` event where the LOCAL player is the killer —
    /// see the call site in buildFrame. A later call while one is already decaying simply
    /// restarts it at the new (typically larger) magnitude rather than summing, which is what
    /// keeps a rapid double-kill feeling like one strong hit instead of an accelerating wobble.
    private func triggerShake(magnitude: Double) {
        // REDUCE MOTION: no shake at all. A camera that moves when the world did not is the
        // clearest possible case of motion for its own sake, and ImpactTimeline's flash
        // already announces the kill (docs/games/CROSS_CUTTING.md §13).
        guard !UIAccessibility.isReduceMotionEnabled else { return }
        shakeStartedAt = CACurrentMediaTime()
        shakeMagnitude = magnitude
        shakeSeed = Double.random(in: 0..<1000)
    }

    private static let shakeDuration: Double = 0.2

    /// Current shake offset in WORLD units (divided by scale so it reads as a constant number
    /// of on-screen points regardless of zoom, matching "3-6 px" being a screen measurement).
    private func currentShake(scale: Float) -> CGPoint {
        guard shakeMagnitude > 0 else { return .zero }
        let elapsed = CACurrentMediaTime() - shakeStartedAt
        guard elapsed < Self.shakeDuration else { shakeMagnitude = 0; return .zero }

        // Decaying sine, per §3.1's "decaying sine" rather than random jitter — a sine reads
        // as an impact recoiling, where per-frame random noise reads as the RENDERER being
        // unstable, which is exactly the wrong association for a kill (a good thing) to carry.
        let decay = 1 - elapsed / Self.shakeDuration
        let phase = (elapsed + shakeSeed) * 40
        let px = Double(sin(phase)) * shakeMagnitude * decay
        let py = Double(cos(phase * 1.3)) * shakeMagnitude * decay
        let worldScale = Double(max(scale, 0.0001))
        return CGPoint(x: px / worldScale, y: py / worldScale)
    }

    /// How far ahead of its current heading a remote snake looks, in seconds of its own turn
    /// rate. Long enough to read as anticipation, short enough that the eyes never leave the
    /// head they belong to.
    private static let gazeLead: Double = 0.18

    private static func lerpAngle(_ a: Double, _ b: Double, _ t: Double) -> Double {
        a + angleDifference(a, b) * t
    }

    /// Shortest signed rotation from `a` to `b`, in -pi...pi.
    private static func angleDifference(_ a: Double, _ b: Double) -> Double {
        var d = b - a
        while d > .pi { d -= 2 * .pi }
        while d < -.pi { d += 2 * .pi }
        return d
    }

    // MARK: Geometry builders

    private func buildArena(radius: Double) {
        // Floor, then a glow band, then the lethal edge drawn EXACTLY on the kill radius —
        // a wall whose visible edge disagrees with the killing surface makes every border
        // death feel unfair.
        circles.append(CircleInstance(
            centre: .zero, radius: Float(radius), softness: 0,
            colour: SIMD4(0.07, 0.06, 0.16, 1)))

        // Hex lattice floor. UVs are scaled by arena size / tile size, so the sampler's
        // .repeat addressing lays the lattice out across one quad instead of us emitting a
        // few hundred hexes as geometry.
        if let hexTexture {
            let side = Float(radius) * 2
            let tiles = side / Float(hexTexture.width)
            floorSprites.append(SpriteInstance(
                centre: .zero,
                size: SIMD2(side, side),
                uvOrigin: SIMD2(0, 0),
                uvSize: SIMD2(tiles, tiles * Float(hexTexture.width) / Float(hexTexture.height)),
                tint: SIMD4(1, 1, 1, 1)))
        }
        // NO full-arena wash. This used to be a soft cyan disc at the FULL arena radius,
        // which tinted the entire play field blue and washed out the floor, the hex lattice
        // and every snake colour — it is why iOS looked nothing like Android, which never had
        // an equivalent layer. The boundary glow belongs at the boundary, not over the arena.

        // The edge as a thin ring: an outer disc with a slightly smaller floor disc on top.
        // Thicker per user testing. Still centred on the lethal radius: a heavier wall must
        // not become one whose visible edge disagrees with the killing surface.
        let edge = CircleInstance(
            centre: .zero, radius: Float(radius) + Self.borderWidth, softness: 0.02,
            colour: SIMD4(0.35, 0.85, 1.0, 0.85))
        circles.append(edge)
        // Bloom is off (see `bloomEnabled`), so the edge no longer feeds it. Leaving this
        // unconditional would have queued work for a pass that never composites.
        if Self.bloomEnabled { bloomCircles.append(edge) }
        circles.append(CircleInstance(
            centre: .zero, radius: Float(radius) - Self.borderWidth, softness: 0,
            colour: SIMD4(0.055, 0.05, 0.13, 1)))
    }

    /// Arena geography: rocks, spikes and slicks.
    ///
    /// DRAWN UNDER THE FOOD AND THE SNAKES, because it is terrain — a rock that occluded a
    /// snake would make the snake look like it had already crashed. That is why these go into
    /// `hazardTris` and get their own draw before the bodies, rather than into `circles`, which
    /// is drawn LAST and was therefore putting every rock on top of every snake.
    ///
    /// EACH KIND HAS TO READ AS WHAT IT DOES, not merely as different colours. This used to be
    /// three stacked circles per hazard, so a rock, a retracted spike and a slick were the same
    /// shape three times — see SnakeHazardArt's header. Now:
    ///
    ///   ROCK    a faceted, irregular boulder with a hard contact shadow. Opaque, no glow. It
    ///           kills like the wall so it is drawn like the wall.
    ///   SPIKE   a ring of teeth that visibly RISE from a socket, plus a warning glow in the
    ///           quarter-second before they do. Its state is the gameplay.
    ///   SLICK   a wandering translucent puddle with a moving sheen. Soft everywhere, no rim —
    ///           a slick that looks like a wall costs the player position for nothing.
    private func buildHazards(state: SnakeState) {
        for (index, h) in state.hazards.enumerated() {
            let centre = SIMD2(Float(h.x), Float(h.y))
            let r = Float(h.radius)

            switch h.kind {
            case "rock":
                buildRock(index: index, centre: centre, radius: r)
            case "spike":
                buildSpike(h, index: index, centre: centre, radius: r, time: state.time)
            default:
                buildSlick(index: index, centre: centre, radius: r, time: state.time)
            }
        }
    }

    /// Base rock colour, before the per-facet shade.
    private static let rockBody = SIMD3<Float>(0.34, 0.34, 0.42)

    private func buildRock(index: Int, centre: SIMD2<Float>, radius r: Float) {
        let variant = ((index % SnakeHazardArt.rockVariants) + SnakeHazardArt.rockVariants)
            % SnakeHazardArt.rockVariants
        let outline = SnakeHazardArt.rockOutline(variant: variant)

        // CONTACT SHADOW FIRST, so it sits under the body. A hard ellipse offset down-right
        // rather than the old concentric soft ring, which made every rock look like it was
        // floating a few units above the floor.
        let shadow = SIMD2<Float>(centre.x + r * 0.14, centre.y + r * 0.20)
        appendFan(centre: shadow, points: outline.map {
            CGPoint(x: $0.x * 1.15, y: $0.y * 0.45)
        }, radius: r, colour: SIMD4(0.05, 0.04, 0.10, 0.50))

        // The body, one triangle per edge, each shaded by which facet its midpoint falls in —
        // hard edges between the three, because faceting is what reads as stone.
        for i in 0..<outline.count {
            let a = outline[i]
            let b = outline[(i + 1) % outline.count]
            let mid = CGPoint(x: (a.x + b.x) / 2, y: (a.y + b.y) / 2)
            let shade = Float(SnakeHazardArt.facetShade(SnakeHazardArt.facet(mid)))
            let c = Self.rockBody * shade
            appendTriangle(
                SIMD2(centre.x, centre.y),
                SIMD2(centre.x + Float(a.x) * r, centre.y + Float(a.y) * r),
                SIMD2(centre.x + Float(b.x) * r, centre.y + Float(b.y) * r),
                colour: SIMD4(c.x, c.y, c.z, 1))
        }
    }

    private func buildSpike(
        _ h: SnakeState.Hazard, index: Int, centre: SIMD2<Float>, radius r: Float, time: Double
    ) {
        let period = h.period ?? 3
        let offset = h.offset ?? 0
        let out = SnakeHazardArt.extended(
            period: period, offset: offset, duty: 0.45, time: time)
        let tell = SnakeHazardArt.tell(
            period: period, offset: offset, duty: 0.45, time: time)

        // THE SOCKET IS ALWAYS DRAWN, so a player can plan a route through a spike field rather
        // than being surprised by one that pops up. It brightens as the teeth are about to come.
        let socketLift = Float(tell) * 0.45
        appendFan(
            centre: centre,
            points: (0..<16).map { i in
                let a = Double(i) / 16 * 2 * .pi
                return CGPoint(x: cos(a) * 0.5, y: sin(a) * 0.5)
            },
            radius: r,
            colour: SIMD4(0.30 + socketLift, 0.14 + socketLift * 0.3,
                          0.16 + socketLift * 0.2, 0.9))

        guard out > 0.001 else { return }

        // The teeth. Bright, hard-edged and unmistakable at full extension; at a partial one
        // they are visibly on their way, which is the whole point of animating this at all.
        let hot = SIMD4<Float>(1.0, 0.42 + Float(out) * 0.2, 0.32, 1)
        for i in 0..<SnakeHazardArt.spikeTeeth {
            let (a, b, tip) = SnakeHazardArt.spikeTooth(i, extended: out)
            appendTriangle(
                SIMD2(centre.x + Float(a.x) * r, centre.y + Float(a.y) * r),
                SIMD2(centre.x + Float(b.x) * r, centre.y + Float(b.y) * r),
                SIMD2(centre.x + Float(tip.x) * r, centre.y + Float(tip.y) * r),
                colour: hot)
        }
    }

    private func buildSlick(index: Int, centre: SIMD2<Float>, radius r: Float, time: Double) {
        let variant = ((index % 4) + 4) % 4
        let outline = SnakeHazardArt.slickOutline(variant: variant)
        appendFan(centre: centre, points: outline, radius: r,
                  colour: SIMD4(0.35, 0.70, 0.95, 0.16))

        // A SHEEN BAND sweeping across on a 4-second cycle, so it reads as WET. Same barely-there
        // amplitude as the Sea Battle caustics — it must prove the surface is liquid without ever
        // drawing an edge.
        let sweep = Float(sin(time * 1.57 + Double(variant) * 2.1)) * 0.45
        appendFan(
            centre: SIMD2(centre.x + sweep * r, centre.y),
            points: outline.map { CGPoint(x: $0.x * 0.5, y: $0.y * 0.62) },
            radius: r,
            colour: SIMD4(0.62, 0.88, 1.0, 0.10))
    }

    // MARK: - Triangle helpers

    /// A closed outline as a triangle fan from its centre.
    private func appendFan(
        centre: SIMD2<Float>, points: [CGPoint], radius r: Float, colour: SIMD4<Float>
    ) {
        guard points.count >= 3 else { return }
        for i in 0..<points.count {
            let a = points[i]
            let b = points[(i + 1) % points.count]
            appendTriangle(
                centre,
                SIMD2(centre.x + Float(a.x) * r, centre.y + Float(a.y) * r),
                SIMD2(centre.x + Float(b.x) * r, centre.y + Float(b.y) * r),
                colour: colour)
        }
    }

    private func appendTriangle(
        _ a: SIMD2<Float>, _ b: SIMD2<Float>, _ c: SIMD2<Float>, colour: SIMD4<Float>
    ) {
        hazardTris.append(RibbonVertex(world: a, colour: colour))
        hazardTris.append(RibbonVertex(world: b, colour: colour))
        hazardTris.append(RibbonVertex(world: c, colour: colour))
    }

    private func buildFood(state: SnakeState) {
        for item in state.food {
            let r = Float(item.value >= 2 ? 7 : item.value < 1 ? 4.5 : 5.5)
            // Colour from the pellet's SERVER-ASSIGNED id — free on the wire, stable for the
            // pellet's life, and identical on every device. Corpse pellets keep their warm
            // tint: "someone died here" is gameplay information, not decoration.
            let colour: SIMD4<Float> = item.value >= 2
                ? SIMD4(1.0, 0.72, 0.45, 1)
                : Self.foodPalette[
                    ((item.id % Self.foodPalette.count) + Self.foodPalette.count)
                        % Self.foodPalette.count]
            let centre = SIMD2(Float(item.position.x), Float(item.position.y))
            // Halo then core: cheap, and it is what makes the field read as lit rather than
            // as flat dots. The halo (not the core) also feeds bloom — the core stays a crisp
            // dot so eating still reads as picking up something precise, while the halo
            // becomes the soft light spilling off it.
            // 1.8x, matching Android. At 2.4 with a soft edge the halos overlapped across a
            // 260-pellet field and the whole floor read as hazy — the two platforms have to
            // agree here or the same arena looks like two different games.
            let halo = CircleInstance(centre: centre, radius: r * 1.8,
                                      softness: 0.6,
                                      colour: SIMD4(colour.x, colour.y, colour.z, 0.22))
            circles.append(halo)
            bloomCircles.append(halo)
            circles.append(CircleInstance(centre: centre, radius: r, softness: 0, colour: colour))
        }
    }

    private func buildSnake(
        snake: SnakeState.Snake, head: CGPoint, heading: Double, turnRate: Double,
        isMe: Bool, time: Double, rank: Int, scale: Float
    ) {
        let points = trails.points(for: snake.id)
        guard points.count >= 2 else { return }

        let c = Self.palette(snake.colorIndex)
        let alpha: Float = time < snake.invulnUntil ? 0.55 : 1.0
        // THE DRAWN BODY IS THE LETHAL BODY, exactly.
        //
        // This used to be `headRadius * 1.9`, which was a guess dressed as a rule: the engine
        // kills on `headR + bodyRadius` (see snake/index.ts bodyHit), and 1.9 * hr is only
        // about half that. The result was an invisible lethal margin of 11-23 world units
        // around every snake — wider on bigger ones — so a player died from a clear gap away
        // with nothing on screen to explain it. It read as lag; it was geometry.
        //
        // `bodyRadius` now comes from the server on the same frame as the position that uses
        // it, so the two cannot drift on a tuning change. Doubled because `width` is a full
        // stroke width and the radius is a half-width.
        let width = Float(snake.bodyRadius) * 2

        // Glow stays a SINGLE colour under the bands. A banded glow just muddies — the halo
        // separates the snake from the floor, it does not repeat the pattern.
        let skin = SnakeSkins.resolve(snake.skin, fallback: c)
        let halo = skin.glow ?? c
        // A TIGHT, thick outline rather than a wide glow. User testing asked for heavier
        // outlines and no neon; a dark rim separates a snake from the floor and from other
        // snakes far more legibly than a coloured haze, especially where bodies overlap.
        appendRibbon(points: points, width: width + Self.outlineWidth * 2,
                     colour: SIMD4(0.04, 0.04, 0.08, 0.85 * alpha))
        if Self.bloomEnabled {
            appendRibbon(points: points, width: width * 1.7,
                         colour: SIMD4(halo.x, halo.y, halo.z, 0.20 * alpha))
        }

        // Banded body (docs/GAMES_SNAKE_VISUALS.md §2.3): one span per band along the arc,
        // rather than one stroke for the whole snake.
        appendBands(points: points, skin: skin, width: width, alpha: alpha)
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
        // The head halo is the single most-looked-at glow in the game — it is what makes
        // "every bright thing emits" (GAMES_ANIMATION.md §3.3) actually true of the thing the
        // player is steering. The opaque head disc below stays out of bloom for the same
        // reason food's core does: the shape that kills must read as crisp and precisely
        // sized, never softened.
        let headHalo = CircleInstance(centre: hc, radius: r * 2.6, softness: 0.8,
                                      colour: SIMD4(c.x, c.y, c.z, 0.30 * alpha))
        circles.append(headHalo)
        bloomCircles.append(headHalo)
        circles.append(CircleInstance(centre: hc, radius: r, softness: 0,
                                      colour: SIMD4(c.x, c.y, c.z, alpha)))

        // GAZE LEADS THE TURN. Eyes that point exactly where the head already points are inert;
        // eyes that look where the snake is STEERING read as an animal deciding, and they warn
        // you which way an opponent is about to cut in front of you a moment before it does.
        //
        // The local snake has the real signal — the thumb — so it uses it directly. A remote
        // snake carries no intent on the wire: the server sends where it points, never where it
        // is turning toward. Its turn RATE is the next best thing, and leading the heading by a
        // fraction of a second of that turn is what the desired heading would have been.
        var look = heading
        if isMe, stick != .zero {
            look = atan2(stick.dy, stick.dx)
        } else {
            // Clamped, so a snake spinning at its turn cap does not end up cross-eyed.
            look += max(-0.55, min(0.55, turnRate * Self.gazeLead))
        }

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

    /// Stroke a trail as repeating colour bands.
    ///
    /// Two details decide whether this reads as a skin or as stripes:
    ///
    ///  - Consecutive spans SHARE an endpoint, so the round caps cover the join. Butt-jointed
    ///    spans leave hairline gaps on curves, which is exactly where the eye goes.
    ///  - Bands are anchored to the HEAD (index 0), not the tail. Anchoring at the tail makes
    ///    the pattern crawl backwards as the snake eats, which reads as a rendering fault
    ///    rather than as movement.
    private func appendBands(
        points: [CGPoint], skin: SnakeSkin, width: Float, alpha: Float
    ) {
        guard points.count >= 2, !skin.bands.isEmpty else { return }

        // TAIL FALLOFF. The far end of a body sits slightly darker than the head, which reads
        // as depth — the body receding — without costing a shader or a second pass. Kept small
        // deliberately: this is a depth cue, and a tail faded far enough to notice as a fade
        // starts to hide the part of the snake that can still kill you.
        let bodyLength = Self.polylineLength(points)
        func fadeAt(_ d: Float) -> Float {
            1 - Self.tailFalloff * min(d / max(bodyLength, 1e-4), 1)
        }

        // A single-band skin is the fallback path, and one ribbon is cheaper and smoother
        // than a one-colour band walk.
        if skin.bands.count == 1 {
            let b = skin.bands[0]
            appendRibbon(points: points, width: width, colour: SIMD4(b.x, b.y, b.z, alpha),
                         fade: (fadeAt(0), fadeAt(bodyLength)))
            return
        }

        var span: [CGPoint] = [points[0]]
        /// Distance from the head to the START of the current span.
        var walked: Float = 0
        var bandIndex = 0
        var used: Float = 0
        var cursor = points[0]
        var i = 1

        while i < points.count {
            let target = points[i]
            let segLen = Float(hypot(target.x - cursor.x, target.y - cursor.y))
            if segLen < 1e-4 { i += 1; continue }

            let remaining = skin.bandLength - used
            if segLen <= remaining {
                span.append(target)
                used += segLen
                cursor = target
                i += 1
                continue
            }

            // The band ends inside this segment: cut there, emit, resume from the cut.
            let t = CGFloat(remaining / segLen)
            let cut = CGPoint(x: cursor.x + (target.x - cursor.x) * t,
                              y: cursor.y + (target.y - cursor.y) * t)
            span.append(cut)

            let b = skin.bands[bandIndex % skin.bands.count]
            let spanLength = Self.polylineLength(span)
            appendRibbon(points: span, width: width, colour: SIMD4(b.x, b.y, b.z, alpha),
                         fade: (fadeAt(walked), fadeAt(walked + spanLength)))
            walked += spanLength

            bandIndex += 1
            used = 0
            cursor = cut
            span = [cut]
        }

        if span.count >= 2 {
            let b = skin.bands[bandIndex % skin.bands.count]
            appendRibbon(points: span, width: width, colour: SIMD4(b.x, b.y, b.z, alpha),
                         fade: (fadeAt(walked), fadeAt(walked + Self.polylineLength(span))))
        }
    }

    /// How much darker the far end of a body sits than the head, as a fraction of its alpha.
    private static let tailFalloff: Float = 0.18

    private static func polylineLength(_ points: [CGPoint]) -> Float {
        guard points.count >= 2 else { return 0 }
        var acc: Float = 0
        for i in 1..<points.count {
            acc += Float(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
        }
        return acc
    }

    /// Triangulate a polyline into a thick ribbon.
    ///
    /// Two triangles per segment, with the joint offset along each point's averaged normal so
    /// corners do not pinch. Round caps are drawn as circle instances instead of geometry —
    /// far cheaper than fanning every joint, and visually identical at these widths.
    /// - Parameter fade: alpha multipliers at the START and END of this span, interpolated
    ///   across it by arc length. `(1, 1)` — the default — leaves the colour untouched.
    private func appendRibbon(
        points: [CGPoint], width: Float, colour: SIMD4<Float>,
        fade: (from: Float, to: Float) = (1, 1)
    ) {
        guard points.count >= 2 else { return }
        let half = width * 0.5

        // Arc length up to each point, so the fade tracks DISTANCE rather than point index —
        // trail points are not evenly spaced (the head end is resampled far more finely than a
        // decimated tail), so fading by index would bunch the gradient at the head.
        var lengths: [Float] = [0]
        lengths.reserveCapacity(points.count)
        var acc: Float = 0
        for i in 1..<points.count {
            acc += Float(hypot(points[i].x - points[i - 1].x, points[i].y - points[i - 1].y))
            lengths.append(acc)
        }
        let total = max(acc, 1e-4)
        func shade(_ i: Int) -> SIMD4<Float> {
            let k = fade.from + (fade.to - fade.from) * (lengths[i] / total)
            return SIMD4(colour.x, colour.y, colour.z, colour.w * k)
        }

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

            let ca = shade(i), cb = shade(i + 1)

            ribbon.append(RibbonVertex(world: a0, colour: ca))
            ribbon.append(RibbonVertex(world: a1, colour: ca))
            ribbon.append(RibbonVertex(world: b0, colour: cb))

            ribbon.append(RibbonVertex(world: a1, colour: ca))
            ribbon.append(RibbonVertex(world: b1, colour: cb))
            ribbon.append(RibbonVertex(world: b0, colour: cb))
        }

        // Round off the tail so a body does not end in a hard chisel.
        if let tail = points.last {
            circles.append(CircleInstance(
                centre: SIMD2(Float(tail.x), Float(tail.y)),
                radius: half, softness: 0, colour: shade(points.count - 1)))
        }
    }

    /// Turn a `kill` event into a line of commentary.
    ///
    /// NAMES, NOT IDS. A feed is only worth having if it says WHO — and the only place that
    /// knows what this device calls a person is this device, so names resolve locally exactly
    /// as they do above the heads and in the leaderboard.
    private func recordKill(event: SnakeState.Event, state: SnakeState) {
        // `snakeId` on a kill is the KILLER and `victimId` the victim — see the engine's own
        // note on that asymmetry. Without both there is no sentence to write, so a malformed
        // event is dropped rather than rendered as "someone ate someone".
        guard let victimId = event.victimId else { return }
        let killer = state.snakes.first { $0.id == event.snakeId }
        let victim = state.snakes.first { $0.id == victimId }
        guard let killer, let victim else { return }

        let iKilled = killer.id == me
        let iDied = victim.id == me
        let killerName = iKilled ? "You" : SnakeState.label(for: killer, me: me)
        let victimName = iDied ? "you" : SnakeState.label(for: victim, me: me)
        let text = "\(killerName) ate \(victimName)"

        let entry = SnakeHudModel.KillEntry(
            id: UUID(), text: text,
            // Coloured for either side of a kill involving the player: being eaten is as much
            // your news as eating someone.
            mine: iKilled || iDied,
            at: CACurrentMediaTime())

        Task { @MainActor in
            // Newest first, capped at three. A longer feed becomes a wall that covers the
            // arena, and in a six-snake match the older lines are stale within seconds.
            hud.killFeed = ([entry] + hud.killFeed).prefix(3).map { $0 }
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
        let myHead = CGPoint(x: mine?.x ?? 0, y: mine?.y ?? 0)

        // `boosting && mass > floor` mirrors the engine's own condition exactly — the client
        // must not claim boost is working when the server is ignoring it.
        let mass = mine?.mass ?? 0
        let active = (mine?.boosting ?? false) && mass > SnakeMotion.minBoostMass
        // Full at twice the floor. Chosen because it is roughly where a mid-match snake sits,
        // so the bar reads as "most of a tank" rather than pinned at either end for a whole
        // match — a meter that never moves teaches nothing.
        let fuel = min(max((mass - SnakeMotion.minBoostMass)
                           / SnakeMotion.minBoostMass, 0), 1)

        // THROTTLED TO ~6 Hz, and that matters more than it looks.
        //
        // Publishing every frame spawned a Task 60 times a second, each one hopping to the
        // main actor and writing three @Published values — so SwiftUI re-rendered the whole
        // HUD 60x/s on top of the Metal draw, and the main thread had no room left for touch
        // dispatch. A leaderboard does not need 60 Hz; the arena does, and the arena is not
        // SwiftUI's job any more.
        let now = CACurrentMediaTime()
        guard now - lastHudPublish >= 0.16 else { return }
        lastHudPublish = now

        Task { @MainActor in
            hud.board = rows
            hud.timeRemaining = timeText
            hud.myMass = myMass
            hud.myHead = myHead
            hud.boostActive = active
            hud.boostFuel = fuel
        }
    }

    /// Food colours — saturated and distinct, so a field of pellets reads as scattered
    /// treasure rather than as uniform dots. Indexed by the pellet's server-assigned id.
    static let foodPalette: [SIMD4<Float>] = [
        SIMD4(0.91, 0.30, 0.24, 1), SIMD4(0.61, 0.35, 0.71, 1),
        SIMD4(0.20, 0.60, 0.86, 1), SIMD4(0.09, 0.65, 0.54, 1),
        SIMD4(0.16, 0.71, 0.39, 1), SIMD4(0.83, 0.67, 0.05, 1),
        SIMD4(0.84, 0.54, 0.06, 1), SIMD4(0.79, 0.44, 0.12, 1),
        SIMD4(1.00, 0.44, 0.66, 1), SIMD4(0.36, 0.90, 0.36, 1),
        SIMD4(0.13, 0.88, 0.94, 1), SIMD4(1.00, 0.85, 0.24, 1),
    ]

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

// MARK: - Impact timeline (hitstop + slow-mo)

/// Turns a `kill`/`death` event into a brief FREEZE followed by a SLOW recovery, applied to
/// the presentation clock only (GAMES_ANIMATION.md §5.4: "a 120ms hitstop freeze on a kill,
/// and a subtle speed-ramp when boost engages... nothing communicates impact more cheaply").
///
/// Death additionally drives a screen-space desaturate/flash — see `desaturation` — matching
/// the 400ms desaturate / 500ms 0.3x slow-mo the doc specifies and that GAMES_AUDIO.md §8.7's
/// `death` sound recipe was ALREADY BUILT to line up with (its envelope comment cites these
/// exact numbers), so this is the piece that makes the two land together rather than the
/// sound anticipating an effect that did not exist yet.
///
/// A later trigger while one is active REPLACES it rather than stacking — the same "restart,
/// don't sum" rule `triggerShake` uses, and for the same reason: a rapid double-kill should
/// read as one strong beat, not an escalating stutter.
private final class ImpactTimeline {
    private enum Kind { case kill, death }
    private var kind: Kind?
    private var startedAt: TimeInterval = 0

    private static let killFreeze: Double = 0.12       // "120ms hitstop" — exact per the doc
    private static let killRecover: Double = 0          // a kill has no slow-mo tail, just the stop
    private static let deathFreeze: Double = 0.10
    private static let deathSlowDuration: Double = 0.5  // matches GAMES_AUDIO §8.7's death envelope
    private static let deathSlowFactor: Double = 0.3    // "slow-mo to 0.3x" — doc's exact number
    private static let deathDesaturateDuration: Double = 0.4

    /// REDUCE MOTION (docs/games/CROSS_CUTTING.md §13).
    ///
    /// Hitstop and screen shake shipped without an opt-out, and for a motion-sensitive player
    /// that is not a rough edge — it is a game they cannot play at all. Under this flag the
    /// slow-mo and the shake are replaced by a FLASH: the information survives (you can still
    /// tell instantly that you killed something or died), the vestibular load does not.
    ///
    /// Read per trigger rather than cached at init, so turning the setting on mid-match takes
    /// effect on the next event instead of after a relaunch. It is a cheap UIKit property.
    private(set) var reduceMotion = UIAccessibility.isReduceMotionEnabled
    private static let flashDuration: Double = 0.20

    func triggerKill() {
        reduceMotion = UIAccessibility.isReduceMotionEnabled
        kind = .kill
        startedAt = CACurrentMediaTime()
    }

    func triggerDeath() {
        reduceMotion = UIAccessibility.isReduceMotionEnabled
        kind = .death
        startedAt = CACurrentMediaTime()
    }

    /// How much of `rawDt` should actually be applied to the presentation clock this frame.
    /// 0 during a freeze, `deathSlowFactor * rawDt` during the slow-mo tail, `rawDt` otherwise.
    func dilate(_ rawDt: Double) -> Double {
        guard let kind, rawDt > 0 else { return rawDt }
        let elapsed = CACurrentMediaTime() - startedAt

        // NO TIME DILATION AT ALL under reduce motion — neither the freeze nor the slow-mo
        // tail. A world that stops and restarts is exactly the kind of motion this setting
        // exists to remove. The flash below carries the event instead.
        guard !reduceMotion else {
            if elapsed >= Self.flashDuration { self.kind = nil }
            return rawDt
        }

        switch kind {
        case .kill:
            if elapsed < Self.killFreeze { return 0 }
            self.kind = nil
            return rawDt
        case .death:
            if elapsed < Self.deathFreeze { return 0 }
            let sinceSlowStart = elapsed - Self.deathFreeze
            if sinceSlowStart < Self.deathSlowDuration { return rawDt * Self.deathSlowFactor }
            self.kind = nil
            return rawDt
        }
    }

    /// 0 (no effect) to 1 (fully desaturated), for the death flash only — a kill is too brief
    /// and too frequent to carry a screen-space tint without the arena feeling like it strobes
    /// every few seconds in a busy match.
    ///
    /// Under reduce motion a kill DOES get one, because the shake that used to announce it is
    /// gone and something has to. It is kept short and well under the death tint's weight, so
    /// the two remain distinguishable and a busy match does not strobe.
    var desaturation: Float {
        guard let kind else { return 0 }
        let elapsed = CACurrentMediaTime() - startedAt

        if reduceMotion {
            guard elapsed < Self.flashDuration else { return 0 }
            let fade = Float(1 - elapsed / Self.flashDuration)
            return kind == .death ? fade : fade * 0.5
        }

        guard kind == .death, elapsed < Self.deathDesaturateDuration else { return 0 }
        // Snaps up, eases out — an impact arrives instantly and fades, it does not fade in.
        return Float(1 - elapsed / Self.deathDesaturateDuration)
    }
}

// MARK: - Particles

/// A fixed pool of presentation-only sparks/bursts, driven by the server's `death`/`kill`/
/// `eat`/`spawn` events (GAMES_ANIMATION.md §5.3).
///
/// FIXED POOL, NOT A GROWING ARRAY. A death converts a whole body into food and fires a burst
/// at the same instant several other snakes might eat — without a cap, a chaotic scrum could
/// allocate thousands of particles in one frame. `capacity` bounds the absolute worst case; a
/// full pool simply stops accepting new spawns until old ones expire, which reads as "the
/// newest burst is a little sparser" rather than as a frame-rate cliff.
///
/// EVERYTHING HERE IS CLIENT-ONLY. `step` and `spawn` never touch `SnakeState` or send
/// anything — this class only reads events the server already committed to. A bug here can
/// make an effect look wrong; it cannot make a match wrong, which is the same guarantee the
/// renderer as a whole makes (see the note at the top of this file).
private final class ParticleSystem {
    private struct Particle {
        var position: SIMD2<Float>
        var velocity: SIMD2<Float>
        var life: Float          // seconds remaining
        var maxLife: Float       // for fading by REMAINING fraction, not absolute time
        var size: Float
        var colour: SIMD4<Float>
    }

    private static let capacity = 512
    private var particles: [Particle] = []
    private var rng = SystemRandomNumberGenerator()

    /// Turn one server event into particles. Called once per NEW event (the caller de-dupes by
    /// server tick), so spawn counts here are "per occurrence", not "per frame".
    func spawn(kind: String, at position: CGPoint, colour: SIMD4<Float>) {
        switch kind {
        case "eat":
            // "6-10 sparks converging into the head" — GAMES_ANIMATION.md §5.3. Converging
            // reads as inward vectors from a ring around the food's last position, which is
            // simpler and just as readable as animating toward a moving head.
            emit(count: Int.random(in: 6...10, using: &rng), at: position,
                speed: 40...90, life: 0.28...0.4, size: 2.5...4, colour: colour)
        case "kill":
            // "radial burst in the victim's colour" — bigger, faster, longer-lived than eat,
            // because a kill is the rarest and most important event in the game.
            emit(count: 22, at: position, speed: 90...220, life: 0.4...0.65, size: 3...6,
                colour: colour)
        case "spawn":
            // "expanding ring" — a burst is close enough at this scale and reuses the same
            // primitive rather than adding a second particle shape to the pipeline.
            emit(count: 16, at: position, speed: 60...140, life: 0.35...0.5, size: 2...4,
                colour: colour)
        case "death":
            // The dying snake's OWN death is handled as a screen-space effect elsewhere
            // (hitstop/slow-mo/desaturate, §5.4) — a world-space burst here would double up
            // with that and read as noisy rather than dramatic. Other snakes' deaths still get
            // a burst so a scrum reads as violent from every point of view but your own.
            emit(count: 18, at: position, speed: 70...160, life: 0.4...0.6, size: 3...5,
                colour: colour)
        default:
            break
        }
    }

    private func emit(
        count: Int, at position: CGPoint, speed: ClosedRange<Float>,
        life: ClosedRange<Float>, size: ClosedRange<Float>, colour: SIMD4<Float>
    ) {
        guard particles.count < Self.capacity else { return }
        let budget = min(count, Self.capacity - particles.count)
        let p = SIMD2(Float(position.x), Float(position.y))
        for _ in 0..<budget {
            let angle = Float.random(in: 0..<(2 * .pi), using: &rng)
            let s = Float.random(in: speed, using: &rng)
            let l = Float.random(in: life, using: &rng)
            particles.append(Particle(
                position: p,
                velocity: SIMD2(cos(angle) * s, sin(angle) * s),
                life: l, maxLife: l,
                size: Float.random(in: size, using: &rng),
                colour: colour))
        }
    }

    /// Advance every particle and drop the dead ones. `dt` is WALL-CLOCK time, deliberately
    /// not the server's simulation clock — a spark's decay is not gameplay, and freezing it
    /// during a network stall (while the render clock legitimately holds) would look broken
    /// rather than paused.
    func step(dt: Double) {
        guard dt > 0, !particles.isEmpty else { return }
        let d = Float(dt)
        for i in particles.indices.reversed() {
            particles[i].life -= d
            if particles[i].life <= 0 {
                particles.remove(at: i)
                continue
            }
            particles[i].position += particles[i].velocity * d
            // Light drag so bursts settle rather than sailing off in straight lines forever —
            // most of the visual read happens in the first ~150ms regardless.
            particles[i].velocity *= (1 - min(d * 2.2, 1))
        }
    }

    /// Emit every live particle as a circle instance, additive glow only (no opaque core —
    /// unlike food/heads, a spark IS the light, there is nothing solid under it to protect
    /// from softening). Appended to `into`, the renderer's bloomCircles list, so particles get
    /// the same Gaussian bloom as everything else that is meant to read as light.
    func appendInstances(into out: inout [CircleInstance]) {
        for p in particles {
            let fade = max(0, p.life / p.maxLife)
            out.append(CircleInstance(
                centre: p.position, radius: p.size, softness: 0.6,
                colour: SIMD4(p.colour.x, p.colour.y, p.colour.z, p.colour.w * fade)))
        }
    }
}

extension SnakeRenderer {
    /// Draw one seamless hexagon-lattice tile.
    ///
    /// A repeat unit of a pointy-top hex grid is `w` by `1.5 * r`; those proportions are not
    /// approximate, and getting them wrong shows up as visible banding across the floor —
    /// which is far more distracting than having no texture at all.
    ///
    /// Deliberately dark and low contrast: the floor is a texture, not a subject. If the
    /// hexes read as brightly as the food, the food stops reading as food.
    static func makeHexTile(device: MTLDevice) -> MTLTexture? {
        let r: CGFloat = 34
        let w = sqrt(3.0) * r
        let tileW = Int(w.rounded())
        let tileH = Int((r * 1.5).rounded())

        guard tileW > 0, tileH > 0,
              let ctx = CGContext(
                data: nil, width: tileW, height: tileH, bitsPerComponent: 8,
                bytesPerRow: tileW * 4, space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
        else { return nil }

        ctx.setStrokeColor(red: 0.59, green: 0.75, blue: 1.0, alpha: 0.12)
        ctx.setLineWidth(1.4)

        func hex(_ cx: CGFloat, _ cy: CGFloat) {
            for i in 0..<6 {
                let a = CGFloat(i) * .pi / 3 - .pi / 6
                let p = CGPoint(x: cx + r * cos(a), y: cy + r * sin(a))
                if i == 0 { ctx.move(to: p) } else { ctx.addLine(to: p) }
            }
            ctx.closePath()
            ctx.strokePath()
        }

        // The unit plus its wrapped neighbours, so the tile is seamless on every edge.
        for dx in -1...1 {
            for dy in -1...1 {
                hex(CGFloat(dx) * w, CGFloat(dy) * r * 1.5)
                hex(CGFloat(dx) * w + w / 2, CGFloat(dy) * r * 1.5 + r * 0.75)
            }
        }

        let desc = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .rgba8Unorm, width: tileW, height: tileH, mipmapped: false)
        desc.usage = [.shaderRead]
        guard let tex = device.makeTexture(descriptor: desc), let data = ctx.data
        else { return nil }
        tex.replace(region: MTLRegionMake2D(0, 0, tileW, tileH),
                    mipmapLevel: 0, withBytes: data, bytesPerRow: tileW * 4)
        return tex
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
