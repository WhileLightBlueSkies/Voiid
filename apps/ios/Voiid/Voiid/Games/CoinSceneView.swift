//
//  CoinSceneView.swift
//  Voiid
//
//  A REAL 3D COIN — an actual cylinder in SceneKit, not a flat disc pretending.
//
//  WHY THIS EXISTS. The first version was SwiftUI: a circle with `rotation3DEffect`, plus a
//  hand-drawn band faked in as the edge. It could never work, and the reason is structural
//  rather than a tuning problem — `rotation3DEffect` foreshortens a FLAT layer, so the "edge"
//  was a rectangle being squashed. Seen side-on it looked like a rectangle, because it was
//  one. No amount of gradient or clamping fixes a square silhouette; a coin's edge is a curved
//  surface and has to actually be curved.
//
//  SceneKit gives that for free: `SCNCylinder` is a solid, so the silhouette, the way light
//  travels round the rim, and the faces disappearing as it turns are all just true. It ships
//  with iOS, needs no package, and one spinning primitive costs nothing.
//
//  DELIBERATELY NOT RealityKit. RealityKit is the newer API and the wrong tool here: it is
//  built for AR/anchored content, wants a much heavier setup for a plain offscreen render, and
//  brings a far bigger runtime for what is one cylinder on a transparent background.
//
//  The faces are drawn with Core Graphics rather than shipped as image assets, so H and T stay
//  crisp at any size and the gold stays in one place in code.
//

import SceneKit
import SwiftUI

/// A gold coin that can be spun to land on a chosen face.
struct CoinSceneView: UIViewRepresentable {
    /// Nil while the toss is undecided — the coin idles. Set to "heads"/"tails" to land it.
    let result: String?
    /// Diameter in points, used to size the rendered face textures.
    let size: CGFloat

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = context.coordinator.buildScene(size: size)
        view.backgroundColor = .clear
        view.isOpaque = false
        // No controls: this is a decorative object, not something to inspect. Letting a drag
        // reorient it would also let the player park it edge-on over the result.
        view.allowsCameraControl = false
        view.antialiasingMode = .multisampling4X
        view.rendersContinuously = true
        context.coordinator.startIdleSpin()
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.land(on: result)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    // MARK: - Scene

    final class Coordinator {
        private let coin = SCNNode()
        private var landed = false

        /// Thickness as a fraction of the diameter. Real coins are thin; a fat one reads as a
        /// poker chip, and this is meant to be money.
        private static let relativeThickness: CGFloat = 0.11

        func buildScene(size: CGFloat) -> SCNScene {
            let scene = SCNScene()

            let radius: CGFloat = 1.0
            let height = radius * 2 * Self.relativeThickness
            // radialSegmentCount high enough that the rim is smooth rather than faceted — the
            // faceting is exactly what would give away a low-poly cylinder at this size.
            let cylinder = SCNCylinder(radius: radius, height: height)
            cylinder.radialSegmentCount = 96

            // THREE MATERIALS, in SCNCylinder's own order: side, top, bottom. Giving the two
            // ends different textures is what puts H on one face and T on the other — the
            // thing the flat version had to fake by swapping a label mid-rotation.
            cylinder.materials = [
                Self.edgeMaterial(),
                Self.faceMaterial(letter: "H", pixels: size * 3),
                Self.faceMaterial(letter: "T", pixels: size * 3),
            ]

            coin.geometry = cylinder
            // Stand it up: a cylinder is born lying down (axis along Y), and a coin faces the
            // viewer. After this, spinning it is a rotation about Y.
            coin.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            scene.rootNode.addChildNode(coin)

            let camera = SCNNode()
            camera.camera = SCNCamera()
            camera.camera?.usesOrthographicProjection = true
            // Fits the coin with a little air around it; orthographic so it neither
            // perspective-warps nor changes apparent size as it turns.
            camera.camera?.orthographicScale = 1.25
            camera.position = SCNVector3(0, 0, 6)
            scene.rootNode.addChildNode(camera)

            // A key light high and to the left, so the rim catches a highlight that travels
            // round it as the coin turns — the single strongest cue that this is a solid.
            // MUCH DIMMER THAN THE OBVIOUS VALUES. A metallic PBR surface reflects nearly all
            // of what hits it, so lighting a gold coin at "normal" intensities blows the face
            // to flat white every time it turns toward the key — which is what a first pass
            // looks like. These are deliberately low so the gold keeps its colour at the
            // brightest point of the spin.
            let key = SCNNode()
            key.light = SCNLight()
            key.light?.type = .directional
            key.light?.intensity = 260
            key.eulerAngles = SCNVector3(-0.5, -0.6, 0)
            scene.rootNode.addChildNode(key)

            // Fill, so the unlit side is dim metal rather than black.
            let fill = SCNNode()
            fill.light = SCNLight()
            fill.light?.type = .omni
            fill.light?.intensity = 150
            fill.position = SCNVector3(-3, 1, 5)
            scene.rootNode.addChildNode(fill)

            let ambient = SCNNode()
            ambient.light = SCNLight()
            ambient.light?.type = .ambient
            ambient.light?.intensity = 260
            scene.rootNode.addChildNode(ambient)

            return scene
        }

        // MARK: Motion

        /// Turn slowly while nobody has called.
        ///
        /// A dead-still coin under "Heads or tails?" reads as a disabled control, and turning
        /// it shows both faces before the player bets on one.
        func startIdleSpin() {
            guard !landed else { return }
            coin.removeAllActions()
            let spin = SCNAction.rotate(by: .pi * 2, around: SCNVector3(0, 1, 0), duration: 3.4)
            coin.runAction(.repeatForever(spin), forKey: "idle")
        }

        /// Spin fast, then STOP ON THE FACE THAT ACTUALLY LANDED.
        ///
        /// The end angle is exact, not approximate: a whole number of turns shows heads, a half
        /// turn more shows tails. Landing anywhere else would have the animation contradict the
        /// result printed under it.
        func land(on result: String?) {
            guard let result, !landed else { return }
            landed = true
            coin.removeAction(forKey: "idle")

            // Normalise first, so the landing always starts from a known angle regardless of
            // where the idle spin happened to be — otherwise the final face is a coin flip of
            // its own.
            let settle = SCNAction.customAction(duration: 0) { [weak self] _, _ in
                self?.coin.eulerAngles = SCNVector3(Float.pi / 2, 0, 0)
            }
            let turns: CGFloat = result == "heads" ? 5 : 5.5
            let flip = SCNAction.rotate(
                by: .pi * 2 * turns, around: SCNVector3(0, 1, 0), duration: 1.15)
            flip.timingMode = .easeOut

            coin.runAction(.sequence([settle, flip]))
        }

        // MARK: Materials

        private static func edgeMaterial() -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = millingTexture()
            // Tiled around the circumference. The repeat count IS the ridge count, and it is
            // high because real milling is fine — too few and it reads as a barcode.
            m.diffuse.wrapS = .repeat
            m.diffuse.wrapT = .clamp
            m.diffuse.contentsTransform = SCNMatrix4MakeScale(90, 1, 1)
            m.metalness.contents = 0.4
            // Not a mirror: brushed gold, so the highlight is a soft travelling band rather
            // than a hard glint. A chrome coin looks like plastic pretending to be metal.
            m.roughness.contents = 0.45
            m.lightingModel = .physicallyBased
            return m
        }

        private static func faceMaterial(letter: String, pixels: CGFloat) -> SCNMaterial {
            let m = SCNMaterial()
            m.diffuse.contents = faceTexture(letter: letter, pixels: max(pixels, 256))
            // METALNESS WELL UNDER 1. A fully metallic surface takes its colour entirely from
            // what it reflects, and there is no environment map here — so it reflects the key
            // light and nothing else, which is exactly how a gold coin turns into a white
            // disc. Backing it off lets the diffuse gold carry the colour.
            m.metalness.contents = 0.35
            m.roughness.contents = 0.45
            m.lightingModel = .physicallyBased
            // ROTATE THE TEXTURE A QUARTER TURN. SCNCylinder maps its end caps with the
            // texture's +Y running along the cylinder's axis, and the node is tipped upright
            // to face the camera — so an un-rotated letter ends up lying on its side.
            m.diffuse.contentsTransform = SCNMatrix4Mult(
                SCNMatrix4MakeTranslation(-0.5, -0.5, 0),
                SCNMatrix4Mult(
                    SCNMatrix4MakeRotation(.pi / 2, 0, 0, 1),
                    SCNMatrix4MakeTranslation(0.5, 0.5, 0)))
            return m
        }

        /// One face: gold ground, a struck rim, and a big bold letter.
        private static func faceTexture(letter: String, pixels: CGFloat) -> UIImage {
            let side = max(pixels, 256)
            let rect = CGRect(x: 0, y: 0, width: side, height: side)
            return UIGraphicsImageRenderer(size: rect.size).image { ctx in
                let cg = ctx.cgContext
                cg.setFillColor(UIColor(CricketGold.base).cgColor)
                cg.fill(rect)

                // Raised rim, drawn inside the edge so it reads as struck metal rather than a
                // ring floating on top.
                let inset = side * 0.055
                cg.setStrokeColor(UIColor(CricketGold.rim).cgColor)
                cg.setLineWidth(side * 0.055)
                cg.strokeEllipse(in: rect.insetBy(dx: inset, dy: inset))

                // A second, finer ridge — the detail that separates "gold circle" from "coin".
                cg.setStrokeColor(UIColor(CricketGold.rim).withAlphaComponent(0.5).cgColor)
                cg.setLineWidth(side * 0.014)
                cg.strokeEllipse(in: rect.insetBy(dx: side * 0.135, dy: side * 0.135))

                let font = UIFont.systemFont(ofSize: side * 0.52, weight: .black)
                let attrs: [NSAttributedString.Key: Any] = [
                    .font: font,
                    .foregroundColor: UIColor(CricketGold.letter),
                ]
                let text = letter as NSString
                let textSize = text.size(withAttributes: attrs)
                text.draw(
                    at: CGPoint(x: (side - textSize.width) / 2,
                                y: (side - textSize.height) / 2),
                    withAttributes: attrs)
            }
        }

        /// One milling ridge, tiled around the rim by the material's repeat transform.
        private static func millingTexture() -> UIImage {
            let w: CGFloat = 8, h: CGFloat = 8
            return UIGraphicsImageRenderer(size: CGSize(width: w, height: h)).image { ctx in
                let cg = ctx.cgContext
                cg.setFillColor(UIColor(CricketGold.base).cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: w, height: h))
                cg.setFillColor(UIColor(CricketGold.rim).cgColor)
                cg.fill(CGRect(x: 0, y: 0, width: w / 2, height: h))
            }
        }
    }
}

/// The coin's palette, shared by the 3D faces and anything else that needs to match it.
///
/// Mixed by hand rather than taken from the theme: `VoiidColor.accent` is the app's amber, tuned
/// for text on dark surfaces — not for a metal object that has to read as gold on both themes.
enum CricketGold {
    static let base = Color(red: 0.83, green: 0.65, blue: 0.22)
    static let rim = Color(red: 0.45, green: 0.31, blue: 0.05)
    static let letter = Color(red: 0.26, green: 0.17, blue: 0.02)
}
