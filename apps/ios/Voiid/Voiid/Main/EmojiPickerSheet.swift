//
//  EmojiPickerSheet.swift
//  Voiid
//
//  Full emoji picker with search. Emojis come from Unicode scalar ranges
//  (the device renders them), grouped into categories.
//

import SwiftUI

struct EmojiPickerSheet: View {
    var onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 8)

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // search
                HStack(spacing: VoiidSpacing.sm) {
                    Image(systemName: "magnifyingglass").foregroundColor(VoiidColor.placeholder)
                    TextField("", text: $query, prompt: Text("Search emoji").foregroundColor(VoiidColor.placeholder))
                        .font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
                        .autocorrectionDisabled()
                }
                .padding(.horizontal, VoiidSpacing.md).frame(height: 44)
                .background(VoiidColor.fieldFill).clipShape(Capsule())
                .padding(VoiidSpacing.lg)

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: VoiidSpacing.lg, pinnedViews: [.sectionHeaders]) {
                        ForEach(EmojiData.categories) { cat in
                            let items = filtered(cat)
                            if !items.isEmpty {
                                Section {
                                    LazyVGrid(columns: columns, spacing: 6) {
                                        ForEach(items, id: \.self) { e in
                                            Button { Haptics.tap(); onPick(e); dismiss() } label: {
                                                Text(e).font(.system(size: 30))
                                            }
                                            .buttonStyle(BouncyEmojiStyle())
                                        }
                                    }
                                } header: {
                                    Text(cat.name)
                                        .font(VoiidFont.rounded(13, .semibold)).foregroundColor(VoiidColor.textSecondary)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.vertical, 4)
                                        .background(VoiidColor.background)
                                }
                            }
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.bottom, VoiidSpacing.xl)
                }
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Choose emoji").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } } }
        }
    }

    private func filtered(_ cat: EmojiData.Category) -> [String] {
        guard !query.isEmpty else { return cat.emojis }
        // simple keyword: match the category name; otherwise show all (emoji names aren't indexed)
        return cat.name.localizedCaseInsensitiveContains(query) ? cat.emojis : []
    }
}

// MARK: - Emoji data (generated from Unicode ranges)

enum EmojiData {
    struct Category: Identifiable { let id = UUID(); let name: String; let emojis: [String] }

    static let categories: [Category] = [
        Category(name: "Smileys & People", emojis: scalars(0x1F600...0x1F64F) + scalars(0x1F910...0x1F92F)),
        Category(name: "Gestures & Body", emojis: scalars(0x1F440...0x1F450) + scalars(0x1F90C...0x1F90F)),
        Category(name: "Animals & Nature", emojis: scalars(0x1F400...0x1F43F) + scalars(0x1F980...0x1F9AF)),
        Category(name: "Food & Drink", emojis: scalars(0x1F345...0x1F37F)),
        Category(name: "Activities & Sports", emojis: scalars(0x1F380...0x1F3CF)),
        Category(name: "Travel & Places", emojis: scalars(0x1F680...0x1F6C0)),
        Category(name: "Objects", emojis: scalars(0x1F4A1...0x1F4FF)),
        Category(name: "Symbols", emojis: scalars(0x2764...0x2764) + scalars(0x1F500...0x1F53F)),
    ]

    /// Build emoji strings from a scalar range, skipping anything that isn't a real emoji.
    private static func scalars(_ range: ClosedRange<Int>) -> [String] {
        range.compactMap { code in
            guard let s = Unicode.Scalar(code), s.properties.isEmoji else { return nil }
            return String(s)
        }
    }
}
