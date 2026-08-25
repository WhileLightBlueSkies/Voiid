//
//  MapSearchField.swift
//  Voiid
//
//  Owns: the frosted search capsule and the suggestion list beneath it (Feature 4).
//
//  Deliberately NOT here: the decision of WHICH of the two is shown, and what happens when a
//  suggestion is chosen. The shell swaps the suggestion list for the visibility pill (one list
//  at a time) and owns the completer; these views only render and report.
//
//  The focus binding is passed in rather than owned: clearing the field has to drop the
//  keyboard, and so does choosing a suggestion — two views, one focus state, so it lives with
//  the shell that holds both.
//

import SwiftUI
import MapKit

/// Frosted search pill, matching the visibility pill's shape so the top chrome reads as one
/// family. Typing drives `MKLocalSearchCompleter`; clearing it tears the results down.
struct MapSearchField: View {
    @Binding var query: String
    var focused: FocusState<Bool>.Binding
    let onQueryChange: (String) -> Void
    let onClear: () -> Void

    var body: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundColor(VoiidColor.textSecondary)
            TextField("Search places", text: $query)
                .font(VoiidFont.rounded(15))
                .foregroundColor(VoiidColor.textPrimary)
                .textFieldStyle(.plain)
                .submitLabel(.search)
                .focused(focused)
                .autocorrectionDisabled()
                .onChange(of: query) { _, new in onQueryChange(new) }
            if !query.isEmpty {
                Button {
                    onClear()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 15))
                        .foregroundColor(VoiidColor.textSecondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        // Fixed 42pt rather than vertical padding: the field sits in a row of 38–42pt round
        // chrome, and a text-driven height would drift out of step with it.
        .frame(height: 42)
        .background(.regularMaterial)
        .clipShape(Capsule())
        .overlay(Capsule().stroke(VoiidColor.divider, lineWidth: 1))
    }
}

struct MapSuggestionList: View {
    let suggestions: [MKLocalSearchCompletion]
    let onChoose: (MKLocalSearchCompletion) -> Void

    var body: some View {
        VStack(spacing: 0) {
            ForEach(suggestions.prefix(6), id: \.self) { s in
                Button {
                    Haptics.tap()
                    onChoose(s)
                } label: {
                    HStack(spacing: VoiidSpacing.sm) {
                        Image(systemName: "mappin.circle.fill")
                            .font(.system(size: 16))
                            .foregroundColor(VoiidColor.primary)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(s.title)
                                .font(VoiidFont.rounded(14, .medium))
                                .foregroundColor(VoiidColor.textPrimary)
                                .lineLimit(1)
                            if !s.subtitle.isEmpty {
                                Text(s.subtitle)
                                    .font(VoiidFont.rounded(11))
                                    .foregroundColor(VoiidColor.textSecondary)
                                    .lineLimit(1)
                            }
                        }
                        Spacer(minLength: 0)
                    }
                    .padding(.vertical, 9)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
    }
}
