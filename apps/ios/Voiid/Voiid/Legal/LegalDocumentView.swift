//
//  LegalDocumentView.swift
//  Voiid
//
//  Renders a `LegalDocument`. Native text, not a WKWebView pointed at a URL, for the
//  reason the document model's header gives: the notice must be readable on the first
//  screen of onboarding, offline, before an account exists.
//
//  It follows the Settings typography contract (SettingsChrome.swift): semantic font
//  styles only, `.fontDesign(.rounded)` inherited from the environment, so a legal
//  document — the single most reading-heavy surface in the app — scales with Dynamic Type
//  all the way up. Fixed-point `VoiidFont.*` here would cap a privacy notice at 13pt for
//  someone who set their phone to accessibility sizes, which is a way of not providing it.
//

import SwiftUI

struct LegalDocumentView: View {
    let document: LegalDocument

    /// Presented as a sheet from onboarding (where there is no navigation stack to push
    /// onto), so it needs its own dismiss affordance in that context only.
    var showsDoneButton: Bool = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                header
                Text(document.summary)
                    .font(.body.weight(.medium))
                    .foregroundStyle(VoiidColor.textPrimary)

                ForEach(document.sections) { section in
                    VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                        Text(section.heading)
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(VoiidColor.textPrimary)
                        ForEach(Array(section.body.enumerated()), id: \.offset) { _, para in
                            paragraph(para)
                        }
                    }
                }

                if !document.pendingCounselOrBuild.isEmpty { pending }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, VoiidSpacing.lg)
            // Selectable: someone who wants to quote a line of a privacy notice back at
            // us — or paste it to a lawyer — should not have to retype it.
            .textSelection(.enabled)
        }
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle(document.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            if showsDoneButton {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }
                        .fontWeight(.semibold)
                        .foregroundStyle(VoiidColor.primary)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.xs) {
            Text(document.title)
                .font(.largeTitle.weight(.bold))
                .foregroundStyle(VoiidColor.textPrimary)
            // The version is not decoration. Consent is recorded against this exact
            // string, so the screen has to show which string it is showing.
            Text("Version \(document.version) · Effective \(document.effectiveDate)")
                .font(.footnote)
                .foregroundStyle(VoiidColor.textSecondary)
        }
    }

    /// A bullet keeps its marker but gets a hanging indent, so wrapped lines line up under
    /// the text rather than under the dot.
    @ViewBuilder
    private func paragraph(_ text: String) -> some View {
        if text.hasPrefix("• ") {
            HStack(alignment: .firstTextBaseline, spacing: VoiidSpacing.sm) {
                Text("•").font(.body).foregroundStyle(VoiidColor.textSecondary)
                Text(String(text.dropFirst(2)))
                    .font(.body)
                    .foregroundStyle(VoiidColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(.leading, VoiidSpacing.sm)
        } else {
            Text(text)
                .font(.body)
                .foregroundStyle(VoiidColor.textSecondary)
        }
    }

    /// The unfinished list, rendered rather than hidden.
    ///
    /// Shipping a legal document with holes in it is bad. Shipping one with the holes
    /// papered over by text an engineer invented is worse, and it is the specific failure
    /// this whole change exists to avoid — so the holes are on screen, named, in a block
    /// that is visually distinct from the notice itself. When counsel supplies the real
    /// answers, `pendingCounselOrBuild` empties and this block disappears on its own.
    private var pending: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
            Label("Still being finalised", systemImage: "exclamationmark.triangle")
                .font(.headline)
                .foregroundStyle(VoiidColor.warning)
            ForEach(Array(document.pendingCounselOrBuild.enumerated()), id: \.offset) { _, line in
                paragraph(line)
            }
        }
        .padding(VoiidSpacing.md)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .fill(VoiidColor.surfaceCard)
        )
        .overlay(
            RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .stroke(VoiidColor.warning.opacity(0.4), lineWidth: 1)
        )
    }
}
