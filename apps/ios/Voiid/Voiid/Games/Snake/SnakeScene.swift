//
//  SnakeScene.swift
//  Voiid
//
//  SpriteKit rendering and touch steering for Snake Arena.
//

import SpriteKit
import SwiftUI
import UIKit

// MARK: - Palette

enum SnakeColorPalette {
    static let colours: [SKColor] = [
        SKColor(red: 0.88, green: 0.31, blue: 0.25, alpha: 1),   // red
        SKColor(red: 0.18, green: 0.64, blue: 0.42, alpha: 1),   // green
        SKColor(red: 0.91, green: 0.65, blue: 0.18, alpha: 1),   // amber
        SKColor(red: 0.23, green: 0.49, blue: 0.85, alpha: 1),   // blue
        SKColor(red: 0.64, green: 0.36, blue: 0.85, alpha: 1),   // violet
        SKColor(red: 0.15, green: 0.72, blue: 0.72, alpha: 1),   // teal
        SKColor(red: 0.93, green: 0.44, blue: 0.62, alpha: 1),   // rose
        SKColor(red: 0.75, green: 0.79, blue: 0.30, alpha: 1)    // lime
    ]
    static func colour(_ i: Int) -> SKColor { colours[abs(i) % colours.count] }
}

// MARK: - Textures

enum SnakeTextures {
    static let disc: SKTexture = {
        let side: CGFloat = 64
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: side, height: side))
        let image = renderer.image { ctx in
            UIColor.white.setFill()
            ctx.cgContext.fillEllipse(in: CGRect(x: 1, y: 1, width: side - 2, height: side - 2))
        }
        let t = SKTexture(image: image)
        t.filteringMode = .linear
        return t
    }()
}

// MARK: - Sprites

private final class SnakeNode {
    let root = SKNode()
    private var discs: [SKSpriteNode] = []
    private let eyeL = SKSpriteNode(texture: SnakeTextures.disc)
    private let eyeR = SKSpriteNode(texture: SnakeTextures.disc)
    private let pupilL = SKSpriteNode(texture: SnakeTextures.disc)
    private let pupilR = SKSpriteNode(texture: SnakeTextures.disc)
    private let label = SKLabelNode(fontNamed: "AvenirNext-DemiBold")

    init() {
        for eye in [eyeL, eyeR] { eye.color = .white; eye.colorBlendFactor = 1; eye.zPosition = 3 }
        for p in [pupilL, pupilR] {
            p.color = SKColor(white: 0.09, alpha: 1); p.colorBlendFactor = 1; p.zPosition = 4
        }
        label.fontSize = 13
        label.fontColor = SKColor(white: 1, alpha: 0.55)
        label.zPosition = 5
        label.verticalAlignmentMode = .center
        root.addChild(eyeL); root.addChild(eyeR)
        root.addChild(pupilL); root.addChild(pupilR)
        root.addChild(label)
    }

    private func disc(_ i: Int) -> SKSpriteNode {
        while discs.count <= i {
            let s = SKSpriteNode(texture: SnakeTextures.disc)
            s.colorBlendFactor = 1
            root.insertChild(s, at: 0)
            discs.append(s)
        }
        return discs[i]
    }

    func sync(_ snake: Snake, visibleRect: CGRect, showLabel: Bool) {
        let colour = SnakeColorPalette.colour(snake.skin)
        let d = snake.radius * 2
        let pad = snake.radius * 2

        for (i, p) in snake.body.enumerated() {
            let node = disc(i)
            guard visibleRect.insetBy(dx: -pad, dy: -pad).contains(p) else {
                node.isHidden = true
                continue
            }
            node.isHidden = false
            node.position = p
            node.size = CGSize(width: d, height: d)
            node.color = colour
            let t = CGFloat(i) / CGFloat(max(snake.body.count - 1, 1))
            node.alpha = 1 - t * 0.18
            node.zPosition = CGFloat(snake.body.count - i) * 0.001
        }
        for i in snake.body.count..<discs.count { discs[i].isHidden = true }

        let r = snake.radius
        let fwd = CGPoint.fromAngle(snake.heading, length: r * 0.42)
        let side = CGPoint.fromAngle(snake.heading + .pi / 2, length: r * 0.46)
        let eyeSize = CGSize(width: r * 0.72, height: r * 0.72)
        let pupilSize = CGSize(width: r * 0.36, height: r * 0.36)
        let gaze = CGPoint.fromAngle(snake.desiredHeading, length: r * 0.16)

        eyeL.position = snake.head + fwd + side
        eyeR.position = snake.head + fwd - side
        eyeL.size = eyeSize; eyeR.size = eyeSize
        pupilL.position = eyeL.position + gaze
        pupilR.position = eyeR.position + gaze
        pupilL.size = pupilSize; pupilR.size = pupilSize

        label.isHidden = !showLabel
        if showLabel {
            label.text = snake.name
            label.position = snake.head + CGPoint(x: 0, y: r + 14)
        }
    }

    func teardown() { root.removeFromParent() }
}

// MARK: - Scene

final class SnakeScene: SKScene {

    let world = SnakeWorld()
    weak var session: SnakeSession?

    private var snakeNodes: [Int: SnakeNode] = [:]
    private var foodNodes: [SKSpriteNode] = []
    private let foodLayer = SKNode()
    private let snakeLayer = SKNode()
    private let arenaLayer = SKNode()
    private let cam = SKCameraNode()

    private var lastTime: TimeInterval = 0
    private var hudClock: CGFloat = 0
    private var prevKills = 0

    override func didMove(to view: SKView) {
        backgroundColor = SKColor(red: 0.043, green: 0.063, blue: 0.086, alpha: 1)
        scaleMode = .resizeFill

        addChild(arenaLayer)
        addChild(foodLayer)
        addChild(snakeLayer)
        camera = cam
        addChild(cam)

        buildArena()
        world.reset(botCount: session?.botCount ?? 11)
    }

    private func buildArena() {
        arenaLayer.removeAllChildren()

        let grid = SKShapeNode()
        let path = CGMutablePath()
        let step: CGFloat = 140
        let r = Cfg.arenaRadius
        var x = -r
        while x <= r {
            let h = sqrt(max(r * r - x * x, 0))
            path.move(to: CGPoint(x: x, y: -h)); path.addLine(to: CGPoint(x: x, y: h))
            x += step
        }
        var y = -r
        while y <= r {
            let w = sqrt(max(r * r - y * y, 0))
            path.move(to: CGPoint(x: -w, y: y)); path.addLine(to: CGPoint(x: w, y: y))
            y += step
        }
        grid.path = path
        grid.strokeColor = SKColor(white: 1, alpha: 0.045)
        grid.lineWidth = 1
        grid.zPosition = -10
        arenaLayer.addChild(grid)

        let rim = SKShapeNode(circleOfRadius: Cfg.arenaRadius)
        rim.strokeColor = SKColor(red: 0.88, green: 0.31, blue: 0.25, alpha: 0.5)
        rim.lineWidth = 6
        rim.glowWidth = 10
        rim.fillColor = .clear
        rim.zPosition = -9
        arenaLayer.addChild(rim)
    }

    private func aim(at location: CGPoint) {
        guard let p = world.player else { return }
        let v = location - p.head
        guard v.length > 4 else { return }
        world.playerAim = v.angle
    }

    /// Set by the SwiftUI shell. When a joystick is driving, the scene ignores taps on the
    /// arena so a stray touch beside the ring cannot yank the snake off course.
    var acceptsDirectTouches = true

    /// Steer by a direction vector rather than a target point, for the joystick.
    func aim(direction: CGPoint) {
        guard direction.length > 0.001 else { return }
        world.playerAim = direction.angle
    }

    override func touchesBegan(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsDirectTouches, let t = touches.first else { return }
        aim(at: t.location(in: self))
    }
    override func touchesMoved(_ touches: Set<UITouch>, with event: UIEvent?) {
        guard acceptsDirectTouches, let t = touches.first else { return }
        aim(at: t.location(in: self))
    }

    override func update(_ currentTime: TimeInterval) {
        let dt = lastTime == 0 ? 1.0 / 60 : min(currentTime - lastTime, 0.1)
        lastTime = currentTime

        world.playerBoosting = session?.boosting ?? false
        world.step(dt: CGFloat(dt))

        followCamera(dt: CGFloat(dt))
        syncSnakes()
        syncFood()
        publish(dt: CGFloat(dt))
    }

    private func followCamera(dt: CGFloat) {
        guard let p = world.player, p.alive else { return }
        cam.position = cam.position.lerp(to: p.head, t: min(1, dt * 9))
        let target = 1.0 + min(pow(p.mass / Cfg.startMass, 0.30) - 1, 1.6)
        cam.setScale(cam.xScale + (target - cam.xScale) * min(1, dt * 2))
    }

    private var visibleRect: CGRect {
        let w = size.width * cam.xScale, h = size.height * cam.yScale
        return CGRect(x: cam.position.x - w / 2, y: cam.position.y - h / 2, width: w, height: h)
    }

    private func syncSnakes() {
        let rect = visibleRect
        var seen = Set<Int>()

        for s in world.snakes where s.alive {
            seen.insert(s.id)
            let node: SnakeNode
            if let existing = snakeNodes[s.id] {
                node = existing
            } else {
                node = SnakeNode()
                snakeLayer.addChild(node.root)
                snakeNodes[s.id] = node
            }
            node.sync(s, visibleRect: rect, showLabel: !s.isPlayer && s.mass > 40)
        }

        for (id, node) in snakeNodes where !seen.contains(id) {
            node.teardown()
            snakeNodes.removeValue(forKey: id)
        }
    }

    private func syncFood() {
        let rect = visibleRect.insetBy(dx: -40, dy: -40)

        var drawn = 0
        for f in world.food {
            guard rect.contains(f.position) else { continue }
            if drawn >= foodNodes.count {
                let n = SKSpriteNode(texture: SnakeTextures.disc)
                n.colorBlendFactor = 1
                n.zPosition = -1
                foodLayer.addChild(n)
                foodNodes.append(n)
            }
            let n = foodNodes[drawn]
            n.isHidden = false
            n.position = f.position
            let d = f.radius * 2
            n.size = CGSize(width: d, height: d)
            n.color = SnakeColorPalette.colour(f.skin)
            n.alpha = 0.92
            drawn += 1
        }
        for i in drawn..<foodNodes.count { foodNodes[i].isHidden = true }
    }

    private func publish(dt: CGFloat) {
        hudClock += dt
        guard hudClock > 0.12, let session else { return }
        hudClock = 0

        if let p = world.player {
            if p.alive {
                session.score = p.score
                session.length = p.body.count
                session.rank = world.rank(of: p)
                session.mass = p.mass
                session.kills = world.playerKills
                if world.playerKills > prevKills {
                    prevKills = world.playerKills
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                }
            } else if session.alive {
                session.alive = false
                session.best = max(session.best, p.score)
                session.boosting = false
                UIImpactFeedbackGenerator(style: .heavy).impactOccurred()
            }
        }
        session.leaderboard = world.leaderboard()
    }

    func restart() {
        for (_, n) in snakeNodes { n.teardown() }
        snakeNodes.removeAll()
        cam.setScale(1)
        prevKills = 0
        world.reset(botCount: session?.botCount ?? 11)
        if let p = world.player { cam.position = p.head }
        session?.reset()
    }

    func pause() {
        world.isPaused = true
    }

    func resume() {
        world.isPaused = false
    }
}
