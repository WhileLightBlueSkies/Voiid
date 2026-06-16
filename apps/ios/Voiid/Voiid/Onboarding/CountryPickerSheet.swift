//
//  CountryPickerSheet.swift
//  Voiid
//
//  Searchable full country-list picker. Custom brand styling (not system List),
//  fixed light appearance so it looks identical in light & dark mode.
//

import SwiftUI

struct CountryPickerSheet: View {
    @Binding var selected: Country
    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [Country] {
        guard !query.isEmpty else { return CountryStore.all }
        return CountryStore.all.filter {
            $0.name.localizedCaseInsensitiveContains(query) || $0.dialCode.contains(query)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select country")
                    .font(VoiidFont.rounded(18, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Spacer()
                Button { dismiss() } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 26))
                        .foregroundColor(VoiidColor.textSecondary.opacity(0.6))
                }
            }
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.top, VoiidSpacing.lg)
            .padding(.bottom, VoiidSpacing.md)

            // Custom search field (brand colors, not system)
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "magnifyingglass").foregroundColor(VoiidColor.placeholder)
                TextField("", text: $query,
                          prompt: Text("Search country or code").foregroundColor(VoiidColor.placeholder))
                    .font(VoiidFont.rounded(16, .regular))
                    .foregroundColor(VoiidColor.textPrimary)
                    .autocorrectionDisabled()
                if !query.isEmpty {
                    Button { query = "" } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(VoiidColor.placeholder)
                    }
                }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .frame(height: 48)
            .background(VoiidColor.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md).stroke(VoiidColor.fieldBorder, lineWidth: 1))
            .padding(.horizontal, VoiidSpacing.lg)
            .padding(.bottom, VoiidSpacing.sm)

            // List (custom scroll, brand background)
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { c in
                        Button {
                            Haptics.selection(); selected = c; dismiss()
                        } label: {
                            HStack(spacing: VoiidSpacing.md) {
                                Text(c.flag).font(.system(size: 24))
                                Text(c.name).font(VoiidFont.rounded(17, .regular))
                                    .foregroundColor(VoiidColor.textPrimary)
                                Spacer()
                                Text(c.dialCode).font(VoiidFont.rounded(16, .regular))
                                    .foregroundColor(VoiidColor.textSecondary)
                                if c.id == selected.id {
                                    Image(systemName: "checkmark")
                                        .font(.system(size: 15, weight: .semibold))
                                        .foregroundColor(VoiidColor.primary)
                                }
                            }
                            .padding(.horizontal, VoiidSpacing.lg)
                            .frame(height: 56)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        Divider().background(VoiidColor.divider.opacity(0.4))
                            .padding(.leading, VoiidSpacing.lg)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .preferredColorScheme(.light)   // fixed appearance — looks the same in light & dark
    }
}
