import SwiftUI

/// Decorative artwork shared by the home card and the shorter setup banner.
/// GeometryReader constrains the bitmap to its slot instead of its intrinsic size.
struct GameArtwork: View {
    let game: Game
    var isSetup = false

    private var assetName: String? {
        let suffix = isSetup ? "Setup" : "Home"
        switch game.id {
        case "ludo": return "GameLudo\(suffix)"
        case "snake": return "GameSnake\(suffix)"
        case "carrom": return "GameCarrom\(suffix)"
        default: return nil
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                if let assetName {
                    Image(assetName)
                        .resizable()
                        .scaledToFill()
                        .frame(width: geometry.size.width, height: geometry.size.height,
                               alignment: .trailing)
                        .clipped()

                    // Native titles stay legible across crops, themes and screen sizes.
                    LinearGradient(stops: [
                        .init(color: .black.opacity(0.46), location: 0),
                        .init(color: .black.opacity(0.22), location: 0.55),
                        .init(color: .clear, location: 1)
                    ], startPoint: .leading, endPoint: .trailing)
                    LinearGradient(colors: [.clear, .black.opacity(0.32)],
                                   startPoint: .top, endPoint: .bottom)
                } else {
                    LinearGradient(colors: [game.tintA, game.tintB.opacity(0.75)],
                                   startPoint: .topLeading, endPoint: .bottomTrailing)
                    Image(systemName: game.symbol)
                        .font(.system(size: isSetup ? 92 : 120, weight: .medium))
                        .foregroundStyle(.white.opacity(0.16))
                        .frame(maxWidth: .infinity, alignment: .trailing)
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
            .clipped()
        }
        .accessibilityHidden(true)
        .allowsHitTesting(false)
    }
}
