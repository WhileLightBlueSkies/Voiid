import SwiftUI

enum SpotlightShapeType: Equatable {
    case circle
    case rounded(CGFloat)
    case capsule
}

struct SpotlightTargetInfo: Equatable {
    let id: String
    let bounds: CGRect
    let shape: SpotlightShapeType
    let padding: CGFloat

    func offsetBy(dx: CGFloat, dy: CGFloat) -> SpotlightTargetInfo {
        SpotlightTargetInfo(
            id: id,
            bounds: bounds.offsetBy(dx: dx, dy: dy),
            shape: shape,
            padding: padding
        )
    }
}

struct WalkthroughSpotlightPreferenceKey: PreferenceKey {
    static var defaultValue: [String: SpotlightTargetInfo] = [:]
    static func reduce(
        value: inout [String: SpotlightTargetInfo],
        nextValue: () -> [String: SpotlightTargetInfo]
    ) {
        value.merge(nextValue(), uniquingKeysWith: { _, new in new })
    }
}

extension View {
    func walkthroughTarget(
        _ id: String,
        shape: SpotlightShapeType = .rounded(12),
        padding: CGFloat = 8
    ) -> some View {
        background(
            GeometryReader { geo in
                Color.clear.preference(
                    key: WalkthroughSpotlightPreferenceKey.self,
                    value: [
                        id: SpotlightTargetInfo(
                            id: id,
                            bounds: geo.frame(in: .global),
                            shape: shape,
                            padding: padding
                        )
                    ]
                )
            }
        )
    }
}

/// A shape that punches an even-odd transparent hole in the full canvas rect.
struct SpotlightCutoutShape: Shape {
    var target: SpotlightTargetInfo?

    func path(in rect: CGRect) -> Path {
        var path = Path()
        // Outer full-screen rectangle
        path.addRect(rect)

        // Punch out the target hole if present
        if let info = target {
            let pad = info.padding
            let bounds = info.bounds.insetBy(dx: -pad, dy: -pad)

            switch info.shape {
            case .circle:
                let diameter = max(bounds.width, bounds.height)
                let center = CGPoint(x: bounds.midX, y: bounds.midY)
                let circleRect = CGRect(
                    x: center.x - diameter / 2,
                    y: center.y - diameter / 2,
                    width: diameter,
                    height: diameter
                )
                path.addEllipse(in: circleRect)

            case .rounded(let radius):
                path.addRoundedRect(
                    in: bounds,
                    cornerSize: CGSize(width: radius, height: radius),
                    style: .continuous
                )

            case .capsule:
                let radius = min(bounds.width, bounds.height) / 2
                path.addRoundedRect(
                    in: bounds,
                    cornerSize: CGSize(width: radius, height: radius),
                    style: .continuous
                )
            }
        }

        return path
    }
}

/// Directional speech bubble triangular arrow
struct SpeechBubbleArrow: Shape {
    let pointingUp: Bool

    func path(in rect: CGRect) -> Path {
        var path = Path()
        if pointingUp {
            path.move(to: CGPoint(x: 0, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width / 2, y: 0))
            path.addLine(to: CGPoint(x: rect.width, y: rect.height))
            path.closeSubpath()
        } else {
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: rect.width / 2, y: rect.height))
            path.addLine(to: CGPoint(x: rect.width, y: 0))
            path.closeSubpath()
        }
        return path
    }
}
