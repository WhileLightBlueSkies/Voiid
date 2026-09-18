//
//  LudoDiceView.swift
//  Voiid
//
//  A REAL 3D SOLID DIE in SceneKit inspired by Ludo King:
//  Lays completely flat on the board at rest, with smooth beveled chamfers,
//  vibrant iconic red Ace, high-contrast glossy pips, and explosive 3D roll dynamics.
//

import SwiftUI
import SceneKit
import UIKit
import Combine

// MARK: - Flat Resting Euler Angles

/// Returns the exact Euler angles (in radians) to lay face `value` (1...6)
/// 100% FLAT and square to the screen with zero diagonal tilt.
func diceRestEulerAngles(for value: Int) -> SCNVector3 {
    let pi = Float.pi
    switch value {
    case 1:
        // Face 1 is Front (+Z) -> Flat
        return SCNVector3(0, 0, 0)
    case 6:
        // Face 6 is Back (-Z) -> Flat (180° around Y)
        return SCNVector3(0, pi, 0)
    case 2:
        // Face 2 is Top (+Y) -> Flat (+90° around X)
        return SCNVector3(pi / 2, 0, 0)
    case 5:
        // Face 5 is Bottom (-Y) -> Flat (-90° around X)
        return SCNVector3(-pi / 2, 0, 0)
    case 3:
        // Face 3 is Right (+X) -> Flat (-90° around Y)
        return SCNVector3(0, -pi / 2, 0)
    case 4:
        // Face 4 is Left (-X) -> Flat (+90° around Y)
        return SCNVector3(0, pi / 2, 0)
    default:
        return SCNVector3(0, 0, 0)
    }
}

/// Backwards compatibility for legacy callers
func diceRestAngles(for value: Int) -> (x: Double, y: Double) {
    let euler = diceRestEulerAngles(for: value)
    return (Double(euler.x) * 180 / Double.pi, Double(euler.y) * 180 / Double.pi)
}

// MARK: - Texture Generator (Ludo King Style)

private enum DiceTextureGenerator {

    /// Generates a photorealistic 512x512 texture for a die face.
    /// Clean, glossy porcelain white body with prominent, glossy indented pips:
    /// - Face 1: Large vibrant Crimson Red center pip (Ludo King signature)
    /// - Faces 2-6: Deep obsidian black pips with concave depth and specular glints.
    static func generateFace(value: Int, size: CGFloat = 512) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: rect.size)

        return renderer.image { ctx in
            let cg = ctx.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()

            // 1. Pure Porcelain Glossy White Surface
            let ivoryColors = [
                UIColor.white.cgColor,
                UIColor(red: 0.96, green: 0.97, blue: 0.98, alpha: 1.0).cgColor
            ] as CFArray

            if let gradient = CGGradient(colorsSpace: colorSpace, colors: ivoryColors, locations: [0.0, 1.0]) {
                cg.drawLinearGradient(
                    gradient,
                    start: CGPoint(x: 0, y: 0),
                    end: CGPoint(x: size, y: size),
                    options: []
                )
            }

            // 2. Soft Edge Vignette (gives subtle 3D roundness near the chamfer borders)
            let borderColors = [
                UIColor.clear.cgColor,
                UIColor(red: 0.88, green: 0.90, blue: 0.92, alpha: 0.55).cgColor
            ] as CFArray
            if let edgeGradient = CGGradient(colorsSpace: colorSpace, colors: borderColors, locations: [0.75, 1.0]) {
                cg.drawRadialGradient(
                    edgeGradient,
                    startCenter: CGPoint(x: size / 2, y: size / 2),
                    startRadius: size * 0.38,
                    endCenter: CGPoint(x: size / 2, y: size / 2),
                    endRadius: size * 0.71,
                    options: []
                )
            }

            // 3. Pip Coordinates (Generous, balanced spacing)
            let margin = size * 0.265
            let left = margin
            let right = size - margin
            let midX = size * 0.5
            let top = margin
            let bottom = size - margin
            let midY = size * 0.5

            var centers: [CGPoint] = []
            switch value {
            case 1:
                centers = [CGPoint(x: midX, y: midY)]
            case 2:
                centers = [CGPoint(x: left, y: top), CGPoint(x: right, y: bottom)]
            case 3:
                centers = [CGPoint(x: left, y: top), CGPoint(x: midX, y: midY), CGPoint(x: right, y: bottom)]
            case 4:
                centers = [CGPoint(x: left, y: top), CGPoint(x: right, y: top),
                           CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom)]
            case 5:
                centers = [CGPoint(x: left, y: top), CGPoint(x: right, y: top),
                           CGPoint(x: midX, y: midY),
                           CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom)]
            case 6:
                centers = [CGPoint(x: left, y: top), CGPoint(x: right, y: top),
                           CGPoint(x: left, y: midY), CGPoint(x: right, y: midY),
                           CGPoint(x: left, y: bottom), CGPoint(x: right, y: bottom)]
            default:
                centers = [CGPoint(x: midX, y: midY)]
            }

            // 4. Pip Sizes:
            // Face 1 Ace is slightly larger crimson ruby (Ludo King iconic red dot)
            let isAce = (value == 1)
            let pipRadius: CGFloat = isAce ? size * 0.138 : size * 0.088

            for center in centers {
                drawRecessedPip(
                    in: cg,
                    center: center,
                    radius: pipRadius,
                    isAce: isAce,
                    colorSpace: colorSpace
                )
            }
        }
    }

    /// Renders a single countersunk spherical pip with clean bevels, bowl depth, and lacquer gloss.
    private static func drawRecessedPip(
        in cg: CGContext,
        center: CGPoint,
        radius: CGFloat,
        isAce: Bool,
        colorSpace: CGColorSpace
    ) {
        cg.saveGState()

        let pipRect = CGRect(x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2)

        // A. Drilled Bevel Ring
        // Bottom-Right rim highlight
        cg.saveGState()
        let highlightPath = UIBezierPath(ovalIn: pipRect.offsetBy(dx: 1.2, dy: 1.2))
        cg.addPath(highlightPath.cgPath)
        cg.setStrokeColor(UIColor(white: 1.0, alpha: 0.75).cgColor)
        cg.setLineWidth(radius * 0.12)
        cg.strokePath()
        cg.restoreGState()

        // Top-Left rim shadow (subtle drilled depth)
        cg.saveGState()
        let rimShadowPath = UIBezierPath(ovalIn: pipRect.offsetBy(dx: -1.2, dy: -1.2))
        cg.addPath(rimShadowPath.cgPath)
        cg.setStrokeColor(UIColor(white: 0.45, alpha: 0.35).cgColor)
        cg.setLineWidth(radius * 0.12)
        cg.strokePath()
        cg.restoreGState()

        // B. Pip Hole Fill
        let pipPath = UIBezierPath(ovalIn: pipRect)
        cg.addPath(pipPath.cgPath)
        cg.clip()

        let lacquerColors: CFArray
        if isAce {
            // Bold, Juicy Ludo King Red (#E53935 -> #D32F2F)
            lacquerColors = [
                UIColor(red: 0.82, green: 0.12, blue: 0.12, alpha: 1.0).cgColor,
                UIColor(red: 0.95, green: 0.24, blue: 0.24, alpha: 1.0).cgColor
            ] as CFArray
        } else {
            // High-contrast Obsidian Piano-Black
            lacquerColors = [
                UIColor(red: 0.08, green: 0.09, blue: 0.11, alpha: 1.0).cgColor,
                UIColor(red: 0.16, green: 0.19, blue: 0.22, alpha: 1.0).cgColor
            ] as CFArray
        }

        if let bowlGrad = CGGradient(colorsSpace: colorSpace, colors: lacquerColors, locations: [0.0, 1.0]) {
            cg.drawLinearGradient(
                bowlGrad,
                start: CGPoint(x: center.x, y: center.y - radius),
                end: CGPoint(x: center.x, y: center.y + radius),
                options: []
            )
        }

        // C. Inner Concave Depth Shadow
        let innerShadowColors = [
            UIColor.black.withAlphaComponent(0.45).cgColor,
            UIColor.clear.cgColor
        ] as CFArray
        if let innerShadow = CGGradient(colorsSpace: colorSpace, colors: innerShadowColors, locations: [0.0, 1.0]) {
            cg.drawRadialGradient(
                innerShadow,
                startCenter: CGPoint(x: center.x - radius * 0.2, y: center.y - radius * 0.25),
                startRadius: 0,
                endCenter: CGPoint(x: center.x, y: center.y),
                endRadius: radius * 0.95,
                options: []
            )
        }

        // D. Specular Meniscus Glint (wet lacquer shine)
        let glintRect = CGRect(
            x: center.x + radius * 0.12,
            y: center.y + radius * 0.12,
            width: radius * 0.44,
            height: radius * 0.34
        )
        let glintColors = [
            UIColor.white.withAlphaComponent(0.55).cgColor,
            UIColor.white.withAlphaComponent(0.0).cgColor
        ] as CFArray
        if let glintGrad = CGGradient(colorsSpace: colorSpace, colors: glintColors, locations: [0.0, 1.0]) {
            cg.drawRadialGradient(
                glintGrad,
                startCenter: CGPoint(x: glintRect.midX, y: glintRect.midY),
                startRadius: 0,
                endCenter: CGPoint(x: glintRect.midX, y: glintRect.midY),
                endRadius: glintRect.width * 0.6,
                options: []
            )
        }

        cg.restoreGState()
    }

    /// Ground drop shadow underneath the die.
    static func generateContactShadow(size: CGFloat = 256) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: size, height: size)
        let renderer = UIGraphicsImageRenderer(size: rect.size)

        return renderer.image { ctx in
            let cg = ctx.cgContext
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            let shadowColors = [
                UIColor.black.withAlphaComponent(0.65).cgColor,
                UIColor.black.withAlphaComponent(0.30).cgColor,
                UIColor.black.withAlphaComponent(0.0).cgColor
            ] as CFArray

            if let grad = CGGradient(colorsSpace: colorSpace, colors: shadowColors, locations: [0.0, 0.50, 1.0]) {
                cg.drawRadialGradient(
                    grad,
                    startCenter: CGPoint(x: size / 2, y: size / 2),
                    startRadius: 0,
                    endCenter: CGPoint(x: size / 2, y: size / 2),
                    endRadius: size * 0.48,
                    options: []
                )
            }
        }
    }
}

// MARK: - SceneKit 3D Dice View (Lays Flat)

struct LudoDiceSceneView: UIViewRepresentable {
    let targetValue: Int
    let rollTrigger: Int
    let size: CGFloat

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.buildScene()
        view.backgroundColor = .clear
        view.isOpaque = false
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = false
        return view
    }

    func updateUIView(_ uiView: SCNView, context: Context) {
        context.coordinator.update(
            targetValue: targetValue,
            rollTrigger: rollTrigger,
            in: uiView
        )
    }

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    // MARK: Coordinator

    final class Coordinator {
        private let rootDieNode = SCNNode()
        private let boxNode = SCNNode()
        private let shadowNode = SCNNode()
        private var lastRollTrigger = -1
        private var isFirstAppearance = true

        func buildScene() -> SCNScene {
            let scene = SCNScene()

            // 1. SOLID BOX GEOMETRY with Chamfered Edges
            // chamferRadius 0.12 gives smooth, pillowed edges that catch specular light
            let box = SCNBox(width: 1.0, height: 1.0, length: 1.0, chamferRadius: 0.12)
            box.chamferSegmentCount = 14

            // SCNBox 6 materials mapping:
            // 0: Front (+Z) -> 1
            // 1: Right (+X) -> 3
            // 2: Back (-Z)  -> 6 (1 + 6 = 7)
            // 3: Left (-X)  -> 4 (3 + 4 = 7)
            // 4: Top (+Y)   -> 2
            // 5: Bottom (-Y)-> 5 (2 + 5 = 7)
            // ALL OPPOSITE SIDES SUM TO 7!
            let faceValues = [1, 3, 6, 4, 2, 5]
            box.materials = faceValues.map { val in
                let mat = SCNMaterial()
                mat.diffuse.contents = DiceTextureGenerator.generateFace(value: val, size: 512)
                mat.lightingModel = .physicallyBased
                mat.roughness.contents = 0.15
                mat.metalness.contents = 0.02
                mat.specular.contents = UIColor(white: 0.98, alpha: 1.0)
                mat.shininess = 95
                return mat
            }

            boxNode.geometry = box
            rootDieNode.addChildNode(boxNode)
            scene.rootNode.addChildNode(rootDieNode)

            // 2. Ground Contact Shadow Plane
            let shadowPlane = SCNPlane(width: 1.6, height: 1.6)
            let shadowMat = SCNMaterial()
            shadowMat.diffuse.contents = DiceTextureGenerator.generateContactShadow(size: 256)
            shadowMat.lightingModel = .constant
            shadowMat.isDoubleSided = false
            shadowPlane.materials = [shadowMat]

            shadowNode.geometry = shadowPlane
            shadowNode.position = SCNVector3(0, 0, -0.56)
            scene.rootNode.addChildNode(shadowNode)

            // 3. Camera pointing directly at the die (Laying Flat!)
            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.usesOrthographicProjection = false
            camera.camera?.fieldOfView = 36.0
            // Centered straight in front of the die so it lays 100% flat
            camera.position = SCNVector3(0, 0, 2.75)
            camera.look(at: SCNVector3(0, 0, 0))
            scene.rootNode.addChildNode(camera)

            // 4. Directional Key Light (highlights top and left chamfers)
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 900
            key.light?.color = UIColor(white: 1.0, alpha: 1.0)
            key.eulerAngles = SCNVector3(-0.65, -0.65, 0)
            scene.rootNode.addChildNode(key)

            // Fill Light (keeps pips and right chamfer crisp)
            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .omni
            fill.light?.intensity = 380
            fill.position = SCNVector3(2.5, 1.8, 3.2)
            scene.rootNode.addChildNode(fill)

            // Ambient Light (bright, clean white base)
            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 520
            ambient.light?.color = UIColor(white: 0.98, alpha: 1.0)
            scene.rootNode.addChildNode(ambient)

            // Initial flat resting pose for face 1
            rootDieNode.eulerAngles = diceRestEulerAngles(for: 1)

            return scene
        }

        func update(targetValue: Int, rollTrigger: Int, in scnView: SCNView) {
            guard rollTrigger != lastRollTrigger else { return }

            if isFirstAppearance {
                isFirstAppearance = false
                lastRollTrigger = rollTrigger
                rootDieNode.eulerAngles = diceRestEulerAngles(for: targetValue)
                scnView.setNeedsDisplay()
                return
            }

            lastRollTrigger = rollTrigger
            performPhysicsRoll(to: targetValue, in: scnView)
        }

        /// Performs a tight, centered 3D tumble and crisp bounce, settling COMPLETELY FLAT.
        private func performPhysicsRoll(to targetValue: Int, in scnView: SCNView) {
            scnView.rendersContinuously = true
            boxNode.removeAllActions()
            rootDieNode.removeAllActions()
            shadowNode.removeAllActions()

            let targetEuler = diceRestEulerAngles(for: targetValue)

            // 1. Tightly Centered Vertical Pop & Slam (Max 0.14 lift - stays strictly in frame)
            let lift = SCNAction.move(to: SCNVector3(0, 0, 0.14), duration: 0.16)
            lift.timingMode = SCNActionTimingMode.easeOut

            let drop = SCNAction.move(to: SCNVector3(0, 0, 0), duration: 0.20)
            drop.timingMode = SCNActionTimingMode.easeIn

            // Snappy micro-bounce upon landing
            let bounceUp = SCNAction.move(to: SCNVector3(0, 0, 0.04), duration: 0.06)
            bounceUp.timingMode = SCNActionTimingMode.easeOut
            let bounceDown = SCNAction.move(to: SCNVector3(0, 0, 0), duration: 0.08)
            bounceDown.timingMode = SCNActionTimingMode.easeIn

            let zSequence = SCNAction.sequence([lift, drop, bounceUp, bounceDown])
            boxNode.runAction(zSequence)

            // Subtle squash & stretch scale upon landing
            let squash = SCNAction.scale(to: 1.05, duration: 0.06)
            squash.timingMode = SCNActionTimingMode.easeOut
            let settleScale = SCNAction.scale(to: 1.0, duration: 0.08)
            settleScale.timingMode = SCNActionTimingMode.easeIn
            let scaleSequence = SCNAction.sequence([
                SCNAction.wait(duration: 0.36),
                squash,
                settleScale
            ])
            boxNode.runAction(scaleSequence)

            // 2. Clean Forward Tumble without Gimbal Lock
            // Tumbles cleanly along the primary pitch axis (2 forward flips = 4π)
            // with a single clean 360° twist on Y (2π) and ZERO Z rotation.
            // This prevents chaotic tumbling outside the box while looking like a realistic forward roll!
            let tumbleX = targetEuler.x + 4 * Float.pi
            let tumbleY = targetEuler.y + 2 * Float.pi
            let tumbleZ = targetEuler.z

            let tumble = SCNAction.rotateTo(
                x: CGFloat(tumbleX),
                y: CGFloat(tumbleY),
                z: CGFloat(tumbleZ),
                duration: 0.44,
                usesShortestUnitArc: false
            )
            tumble.timingMode = SCNActionTimingMode.easeOut

            rootDieNode.runAction(tumble) { [weak self] in
                DispatchQueue.main.async {
                    scnView.rendersContinuously = false
                    Haptics.rigid()
                    self?.rootDieNode.eulerAngles = targetEuler
                }
            }

            // 3. Subtle Contact Shadow (remains tightly centered under the die)
            let shadowDim = SCNAction.fadeOpacity(to: 0.45, duration: 0.16)
            let shadowRestore = SCNAction.fadeOpacity(to: 1.0, duration: 0.20)
            shadowNode.runAction(SCNAction.sequence([shadowDim, shadowRestore]))
        }
    }
}

// MARK: - Legacy DiceView Adapter

/// Retained for backwards compatibility
struct DiceView: View {
    var rotationX: Double = 0
    var rotationY: Double = 0
    var side: CGFloat = 76

    var body: some View {
        LudoDiceSceneView(targetValue: 1, rollTrigger: 0, size: side)
            .frame(width: side, height: side)
    }
}

// MARK: - Observing Wrapper with Ludo King Tray Presentation

struct DiceBox: View {
    @ObservedObject var roller: DiceRoller
    var side: CGFloat = 76
    var onTap: (() -> Void)? = nil

    var body: some View {
        Button {
            Haptics.tap()
            onTap?()
        } label: {
            ZStack {
                // Ludo King Style Recessed Tray / Rolling Pad
                RoundedRectangle(cornerRadius: 18, style: .continuous)
                    .fill(
                        LinearGradient(
                            colors: [
                                Color(ludoHex: 0x162330),
                                Color(ludoHex: 0x0D1620)
                            ],
                            startPoint: .top,
                            endPoint: .bottom
                        )
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 18, style: .continuous)
                            .strokeBorder(
                                onTap != nil
                                    ? Color(ludoHex: 0xC9A227).opacity(0.85) // Brass highlight when active
                                    : Color(ludoHex: 0x243344),
                                lineWidth: onTap != nil ? 1.8 : 1.0
                            )
                    )
                    .shadow(
                        color: onTap != nil ? Color(ludoHex: 0xC9A227).opacity(0.28) : Color.black.opacity(0.35),
                        radius: onTap != nil ? 8 : 4,
                        x: 0,
                        y: 2
                    )

                // 3D SceneKit Flat Die
                LudoDiceSceneView(
                    targetValue: roller.value,
                    rollTrigger: roller.rollTrigger,
                    size: side - 8
                )
                .frame(width: side - 8, height: side - 8)
            }
            .frame(width: side, height: side)
        }
        .buttonStyle(PressDown())
        .disabled(onTap == nil)
    }
}

// MARK: - Roll Driver

@MainActor
final class DiceRoller: ObservableObject {
    @Published private(set) var rotationX: Double = 0
    @Published private(set) var rotationY: Double = 0
    @Published private(set) var value: Int = 1
    @Published private(set) var rollTrigger: Int = 0

    private var turns = 0

    @discardableResult
    func roll(reduceMotion: Bool = false) async -> Int {
        turns += 1
        let rolled = Int.random(in: 1...6)
        value = rolled

        let rest = diceRestAngles(for: rolled)
        rotationX = rest.x + 360 * Double(turns * 2)
        rotationY = rest.y + 360 * Double(turns * 3)

        rollTrigger += 1

        if reduceMotion {
            return rolled
        }

        // Mid-tumble haptic tick
        Task {
            try? await Task.sleep(for: .milliseconds(320))
            Haptics.soft()
        }

        // Wait for roll duration (matches Theme.Timing.diceTumble = 0.95s)
        try? await Task.sleep(for: .seconds(Theme.Timing.diceTumble))
        return rolled
    }
}

// MARK: - Preview

#Preview("3D Ludo King Dice (Flat)") {
    ZStack {
        Color(ludoHex: 0x0E1620).ignoresSafeArea()
        HStack(spacing: 20) {
            DiceBox(roller: DiceRoller(), side: 80, onTap: {})
        }
    }
}
