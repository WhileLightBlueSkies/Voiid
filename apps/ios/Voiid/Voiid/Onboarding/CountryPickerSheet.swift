//
//  CountryPickerSheet.swift
//  Voiid
//
//  The country list, as a searchable sheet.
//
//  ── WHY IT SEARCHES ON MORE THAN THE NAME ───────────────────────────────────────
//  237 entries is past the point where scrolling is a reasonable ask, so the search field is the
//  primary way in — and it matches on NAME, DIAL CODE and ISO CODE together. A user reaching for
//  their own country types one of three things: "India", "+91", or "IN". Matching only the name
//  would fail two of those, and failing a search on a list this long reads as the country being
//  missing.
//
//  Dial-code search deliberately ignores the leading "+", so "91" and "+91" both work.
//
//  ── WHY THE SELECTED ROW IS NOT PINNED TO THE TOP ───────────────────────────────
//  Tempting, and wrong: it would mean the list reorders under the user between openings, so the
//  position they learned last time is not where it is now. It carries a lime check in place, and
//  the list scrolls to it on open instead.
//
//  ── WHY THIS IS NOT A SYSTEM `List` + `.searchable` ─────────────────────────────
//  The design source used both. This keeps the hand-built scroll and search field the live app
//  already had, because they carry the brand tokens (which resolve per theme) and because
//  `.searchable` inside a sheet presented from a `.preferredColorScheme(.dark)` screen renders
//  its own chrome in the system appearance, not the app's. Same behaviour, same layout; the
//  parts that differ are the ones the design source could not know about.
//

import SwiftUI

struct CountryPickerSheet: View {
    @Binding var selected: Country

    /// Called after a NEW country is chosen. Not called when the user picks the one already
    /// selected — nothing changed, so a caller clearing the typed number would be destroying
    /// input for no reason.
    var onChange: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var query = ""

    private var results: [Country] {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return CountryStore.all }

        // Strip "+" so "+91" and "91" behave the same.
        let digits = q.hasPrefix("+") ? String(q.dropFirst()) : q

        return CountryStore.all.filter { c in
            c.name.lowercased().contains(q)
                || c.id.lowercased() == q
                || c.dialCode.dropFirst().hasPrefix(digits)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            searchField

            if results.isEmpty {
                empty
            } else {
                list
            }
        }
        .background(VoiidColor.background.ignoresSafeArea())
        // No colour-scheme pin: the tokens resolve per theme, and a sheet that forced one
        // appearance would be the single mismatched rectangle in the app.
    }

    // MARK: Header

    private var header: some View {
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
            .accessibilityLabel("Close")
        }
        .padding(.horizontal, VoiidSpacing.lg)
        .padding(.top, VoiidSpacing.lg)
        .padding(.bottom, VoiidSpacing.md)
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "magnifyingglass").foregroundColor(VoiidColor.placeholder)
            TextField("", text: $query,
                      prompt: Text("Country, code or +dial").foregroundColor(VoiidColor.placeholder))
                .font(VoiidFont.rounded(16, .regular))
                .foregroundColor(VoiidColor.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill").foregroundColor(VoiidColor.placeholder)
                }
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .frame(height: 48)
        .background(VoiidColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md).stroke(VoiidColor.fieldBorder, lineWidth: 1))
        .padding(.horizontal, VoiidSpacing.lg)
        .padding(.bottom, VoiidSpacing.sm)
    }

    // MARK: List

    private var list: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(results) { c in
                        row(c).id(c.id)
                        Divider().background(VoiidColor.divider.opacity(0.4))
                            .padding(.leading, VoiidSpacing.lg)
                    }
                }
            }
            .scrollDismissesKeyboard(.immediately)
            // Opens ON the current selection rather than at the top of the alphabet, so the user
            // can see what is set without hunting for it.
            //
            // Deferred a runloop: the LazyVStack has not built its rows when `onAppear` fires, so
            // scrolling to an id that does not exist yet is a no-op — which is exactly what the
            // straightforward version does, silently.
            .onAppear {
                guard query.isEmpty else { return }
                Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(50))
                    proxy.scrollTo(selected.id, anchor: .center)
                }
            }
        }
    }

    private func row(_ c: Country) -> some View {
        Button {
            let changed = c.id != selected.id
            Haptics.selection()
            selected = c
            dismiss()
            if changed { onChange() }
        } label: {
            HStack(spacing: VoiidSpacing.md) {
                Text(c.flag).font(.system(size: 24))

                Text(c.name)
                    .font(VoiidFont.rounded(17, .regular))
                    .foregroundColor(VoiidColor.textPrimary)
                    .lineLimit(1)

                Spacer(minLength: VoiidSpacing.sm)

                Text(c.dialCode)
                    .font(VoiidFont.rounded(16, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
                    .monospacedDigit()

                // Holds its width whether or not the check is drawn, so the dial codes stay in
                // a column instead of shifting by 20pt on the one selected row.
                Image(systemName: "checkmark")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundColor(VoiidColor.accent)
                    .opacity(c.id == selected.id ? 1 : 0)
                    .frame(width: 20)
            }
            .padding(.horizontal, VoiidSpacing.lg)
            .frame(height: 56)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(c.id == selected.id ? [.isSelected] : [])
    }

    // MARK: Empty

    private var empty: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 32, weight: .light))
                .foregroundColor(VoiidColor.textSecondary)

            Text("No countries match \u{201C}\(query)\u{201D}")
                .font(VoiidFont.subhead)
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .padding(VoiidSpacing.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
