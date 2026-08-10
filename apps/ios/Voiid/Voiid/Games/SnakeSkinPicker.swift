//
//  SnakeSkinPicker.swift
//  Voiid
//
//  Choose a snake before a match — a catalogue skin, or any colour you like.
//
//  UNLOCKS ARE ON CUMULATIVE LENGTH, NOT WINS. Gating cosmetics on winning punishes exactly
//  the players most likely to quit: someone losing every match would never unlock anything,
//  which is the opposite of what progression is for. Length accrues whether you win or lose,
//  so every match moves you forward and a bad run still pays.
//
//  Thresholds are deliberately shallow at the start (the first unlock lands inside a couple
//  of matches) and widen after. The point is to teach that playing unlocks things, which a
//  player only learns by having it happen to them early.
//
//  Mirrors Android `SnakeSkinPicker.kt`.
//

import SwiftUI

/// A selectable snake appearance: a catalogue skin, or a custom colour.
enum SnakeChoice: Equatable {
    case skin(String)
    /// Packed 0xRRGGBB.
    case colour(Int)
}

enum SnakeSkinCatalogue {
    /// Skin id -> cumulative length needed. Absent means free from the start.
    static let unlocks: [(id: String, name: String, requires: Int)] = [
        ("rainbow", "Rainbow", 0),
        ("candy",   "Candy",   0),
        ("shadow",  "Shadow",  150),
        ("frost",   "Frost",   400),
        ("lava",    "Lava",    800),
        ("bunny",   "Bunny",   1500),
        ("corgi",   "Corgi",   2500),
        ("lion",    "Lion",    4000),
        ("unicorn", "Unicorn", 6000),
    ]

    static func isUnlocked(_ id: String, totalLength: Int) -> Bool {
        guard let entry = unlocks.first(where: { $0.id == id }) else { return true }
        return totalLength >= entry.requires
    }
}

/// Persisted choice, so a player picks once rather than every match.
enum SnakeChoiceStore {
    private static let skinKey = "voiid.snake.skin"
    private static let colourKey = "voiid.snake.colour"

    static var current: SnakeChoice {
        let d = UserDefaults.standard
        if let skin = d.string(forKey: skinKey), !skin.isEmpty { return .skin(skin) }
        let c = d.integer(forKey: colourKey)
        return c > 0 ? .colour(c) : .skin("rainbow")
    }

    static func save(_ choice: SnakeChoice) {
        let d = UserDefaults.standard
        switch choice {
        case .skin(let id):
            d.set(id, forKey: skinKey)
            d.removeObject(forKey: colourKey)
        case .colour(let rgb):
            d.set(rgb, forKey: colourKey)
            d.removeObject(forKey: skinKey)
        }
    }

    /// The options bag for `createSolo` / `create`. Skin travels as a string; a custom colour
    /// travels as a packed int, because the shared options type is [String: Int].
    static var matchOptions: [String: Int] {
        if case .colour(let rgb) = current { return ["color": rgb] }
        return [:]
    }

    /// The skin id, when one is chosen. Sent separately since it is not an Int.
    static var skinId: String? {
        if case .skin(let id) = current { return id }
        return nil
    }
}

struct SnakeSkinPicker: View {
    let onDone: () -> Void

    @State private var choice: SnakeChoice = SnakeChoiceStore.current
    @State private var customColour: Color = .red

    private var total: Int { SnakeRecordStore.totalLength }

    private let columns = [GridItem(.adaptive(minimum: 92), spacing: 12)]

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack {
                Text("Your snake")
                    .font(.system(size: 20, weight: .heavy))
                Spacer()
                // Progress is stated plainly. A locked item with no visible distance to it
                // reads as a paywall rather than as a goal.
                Text("\(total) total length")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.secondary)
            }

            ScrollView {
                LazyVGrid(columns: columns, spacing: 12) {
                    ForEach(SnakeSkinCatalogue.unlocks, id: \.id) { entry in
                        let unlocked = SnakeSkinCatalogue.isUnlocked(entry.id, totalLength: total)
                        SkinSwatch(
                            id: entry.id,
                            name: entry.name,
                            unlocked: unlocked,
                            remaining: max(0, entry.requires - total),
                            selected: choice == .skin(entry.id))
                        .onTapGesture {
                            guard unlocked else { return }
                            choice = .skin(entry.id)
                            SnakeChoiceStore.save(choice)
                            Haptics.selection()
                        }
                    }
                }
            }

            Divider()

            HStack(spacing: 12) {
                ColorPicker("Custom colour", selection: $customColour, supportsOpacity: false)
                    .labelsHidden()
                Text("Custom colour")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Button("Use") {
                    choice = .colour(customColour.packedRGB)
                    SnakeChoiceStore.save(choice)
                    Haptics.selection()
                }
                .font(.system(size: 14, weight: .bold))
            }

            Button {
                onDone()
            } label: {
                Text("Done")
                    .font(.system(size: 16, weight: .heavy))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 14)
                    .background(VoiidColor.primary, in: RoundedRectangle(cornerRadius: 14))
                    .foregroundStyle(.white)
            }
        }
        .padding(20)
    }
}

private struct SkinSwatch: View {
    let id: String
    let name: String
    let unlocked: Bool
    let remaining: Int
    let selected: Bool

    var body: some View {
        VStack(spacing: 6) {
            // The swatch shows the ACTUAL bands, so what you pick is what you get.
            let skin = SnakeSkins.resolve(id, fallback: SIMD4(0.6, 0.6, 0.6, 1))
            HStack(spacing: 0) {
                ForEach(Array(skin.bands.enumerated()), id: \.offset) { _, b in
                    Color(red: Double(b.x), green: Double(b.y), blue: Double(b.z))
                }
            }
            .frame(height: 34)
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .opacity(unlocked ? 1 : 0.25)
            .overlay {
                if !unlocked {
                    Image(systemName: "lock.fill")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(.white.opacity(0.9))
                }
            }
            .overlay {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(VoiidColor.primary, lineWidth: selected ? 3 : 0)
            }

            Text(unlocked ? name : "\(remaining) more")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(unlocked ? .primary : .secondary)
                .lineLimit(1)
        }
    }
}

private extension Color {
    /// Pack to 0xRRGGBB for the wire.
    var packedRGB: Int {
        #if canImport(UIKit)
        var r: CGFloat = 0, g: CGFloat = 0, b: CGFloat = 0, a: CGFloat = 0
        UIColor(self).getRed(&r, green: &g, blue: &b, alpha: &a)
        return (Int(r * 255) << 16) | (Int(g * 255) << 8) | Int(b * 255)
        #else
        return 0xFF3B47
        #endif
    }
}
