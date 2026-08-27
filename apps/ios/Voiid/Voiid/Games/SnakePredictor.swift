//
//  SnakePredictor.swift
//  Voiid
//
//  Client-side prediction for the LOCAL player's snake only.
//
//  WHY THIS EXISTS. Every other snake is interpolated ~150 ms in the past, which is correct:
//  we cannot know where someone else is going. But applying that to your OWN snake means your
//  thumb moves and the head answers a fifth of a second later, and no amount of smoothing
//  fixes a control that lags — it just makes a laggy control smooth.
//
//  So the local head is simulated HERE, immediately, using the same movement maths the server
//  runs (constant forward speed, heading clamped to a turn rate). When the authoritative
//  position arrives it is blended in rather than snapped to, so a correction reads as a small
//  drift instead of a teleport.
//
//  THIS IS NOT AUTHORITY. The server still decides collisions, growth, death and everything
//  else; prediction only answers "where would my head be by now?" between frames. If the
//  server disagrees, the server wins — the blend just makes losing gracefully invisible.
//
//  MUST MIRROR the server's `moveAll` (backend/games/src/engine/snake/index.ts). If the two
//  drift apart, the correction blend grows and the snake starts to feel rubbery — which is
//  the signal that these constants need re-syncing, not that the blend needs slowing down.
//

import CoreGraphics
import QuartzCore

/// Movement constants, mirrored from the server's TUNING.
///
/// Duplicated deliberately rather than sent over the wire: they change rarely, and threading
/// them through every frame would cost bandwidth to tell the client something it can hold as
/// a constant. The cost of that choice is that a tuning change must be made in both places —
/// hence the comment on the server side pointing back here.
enum SnakeMotion {
    static let baseSpeed: Double = 300
    static let boostSpeed: Double = 510
    static let turnRate: Double = 500 * .pi / 180
    static let turnRateBoost: Double = 540 * .pi / 180
    static let minBoostMass: Double = 12
    /// Speed multiplier inside a slick. Mirrors HAZARD_TUNING.SLICK_SPEED on the server.
    static let slickSpeed: Double = 0.62
}

/// Predicted state for the local snake, advanced every render frame.
final class SnakePredictor {
    /// Where we believe our head is right now.
    private(set) var position: CGPoint = .zero
    /// The heading we believe we are travelling on.
    private(set) var heading: Double = 0

    /// Server time this snake stays slowed by a slick until, and the server clock it is
    /// compared against. Both are pushed in by the renderer each frame from the newest frame —
    /// the predictor has no clock of its own, and comparing a server deadline against a local
    /// timestamp would be meaningless.
    private var slickUntil: Double = 0
    private var serverTime: Double = 0

    /// Called each frame with the newest server frame's clock and this snake's slick deadline.
    func setSlick(until: Double, serverTime now: Double) {
        slickUntil = until
        serverTime = now
    }

    /// What the player is currently asking for. Written by the joystick, read every frame.
    var desiredHeading: Double?
    var boosting = false

    /// Set false until the first server frame, so we never predict from nothing.
    private var started = false
    private var lastStep: TimeInterval = 0

    /// How far the prediction is currently allowed to be wrong before we stop blending and
    /// simply accept the server. A correction bigger than this means something happened that
    /// prediction cannot model — a death, a respawn, a teleport — and easing toward it would
    /// draw a long wrong line across the arena.
    private static let hardSnapDistance: Double = 260

    /// Seconds to fold a correction in over. Long enough to be invisible, short enough that
    /// the prediction cannot stay meaningfully wrong.
    private static let correctionTime: Double = 0.15

    /// The correction still being absorbed, in world units.
    private var correction: CGVector = .zero
    private var correctionRemaining: Double = 0

    /// Discard everything. Called on respawn and when leaving a match — a stale prediction
    /// surviving into a new life would draw the snake at its previous corpse.
    func reset(position: CGPoint, heading: Double) {
        self.position = position
        self.heading = heading
        correction = .zero
        correctionRemaining = 0
        started = true
        lastStep = CACurrentMediaTime()
    }

    /// Fold in the server's authoritative position.
    ///
    /// The delta between where we thought we were and where the server says we are becomes a
    /// correction that decays over `correctionTime`, rather than being applied at once.
    func reconcile(serverPosition: CGPoint, serverHeading: Double, alive: Bool) {
        guard alive else {
            started = false
            return
        }
        guard started else {
            reset(position: serverPosition, heading: serverHeading)
            return
        }

        let dx = serverPosition.x - position.x
        let dy = serverPosition.y - position.y
        let error = hypot(dx, dy)

        if error > Self.hardSnapDistance {
            // Too far to be a prediction error. Accept it outright.
            reset(position: serverPosition, heading: serverHeading)
            return
        }

        correction = CGVector(dx: dx, dy: dy)
        correctionRemaining = Self.correctionTime

        // The server's heading is authoritative too, but it is a fifth of a second old — so
        // it is folded in gently rather than assigned, or every frame would yank the head
        // back toward where the player was aiming two frames ago.
        var delta = serverHeading - heading
        while delta > .pi { delta -= 2 * .pi }
        while delta < -.pi { delta += 2 * .pi }
        heading += delta * 0.2
    }

    /// Advance one render frame. Returns the position to draw the local head at.
    func step(now: TimeInterval) -> CGPoint? {
        guard started else { return nil }

        let dt = min(now - lastStep, 0.05)   // clamp: a stall must not teleport the snake
        lastStep = now
        guard dt > 0 else { return position }

        // Turn toward the desired heading at the legal rate — the same clamp the server
        // applies, which is what keeps the two simulations agreeing.
        if let want = desiredHeading {
            let rate = boosting ? SnakeMotion.turnRateBoost : SnakeMotion.turnRate
            var delta = want - heading
            while delta > .pi { delta -= 2 * .pi }
            while delta < -.pi { delta += 2 * .pi }
            heading += max(-rate * dt, min(rate * dt, delta))
        }

        // SLICKS SLOW THE PREDICTION TOO. The server multiplies speed by SLICK_SPEED while a
        // snake is in one; if the predictor did not, the local head would run ahead at full
        // speed and be dragged back every frame for as long as the player stayed in the slick —
        // a rubber-band exactly where the game is asking them to steer carefully.
        var speed = boosting ? SnakeMotion.boostSpeed : SnakeMotion.baseSpeed
        if serverTime < slickUntil { speed *= SnakeMotion.slickSpeed }
        position.x += cos(heading) * speed * dt
        position.y += sin(heading) * speed * dt

        // Absorb any outstanding correction a slice at a time.
        if correctionRemaining > 0 {
            let slice = min(dt / correctionRemaining, 1)
            position.x += correction.dx * slice
            position.y += correction.dy * slice
            correction.dx *= (1 - slice)
            correction.dy *= (1 - slice)
            correctionRemaining -= dt
        }

        return position
    }
}
