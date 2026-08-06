//
//  ConsentPromptView.swift
//  Voiid
//
//  The backfill prompt: consent capture for accounts that already exist.
//
//  Every account created before this change has no consent record, because the endpoint
//  that would have written one was never called by any client. Those users cannot be
//  retro-fitted by a migration — a row we wrote on their behalf would be a fabricated
//  consent record, which is worse than none — so they are asked, once, on next launch.
//
//  IT MUST BE REFUSABLE. DPDP s.6 requires consent to be free and unconditional, so
//  "Not now" is a real answer: it dismisses for this launch and the prompt returns next
//  time. A modal that cannot be dismissed until you agree is coercion with a checkbox, and
//  the consent it collects is worth nothing. What it is NOT is a "never ask again" —
//  refusing does not silently grant the app permission to keep processing quietly.
//
//  [COUNSEL] What Voiid must do about an existing account whose user keeps declining is
//  unresolved: continuing to process indefinitely on the strength of an old sign-up is not
//  obviously lawful, and suspending the account of someone who simply has not read a modal
//  is not obviously proportionate. Do not resolve this by adding a deadline here.
//

import SwiftUI

@MainActor
struct ConsentPromptView: View {
    /// Dismisses for this launch only.
    let onDefer: () -> Void
    /// Consent recorded successfully.
    let onAccepted: () -> Void

    @State private var presentedDocument: LegalDocument?
    @State private var working = false
    @State private var errorText: String?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                    Text("Before you carry on")
                        .font(.largeTitle.weight(.bold))
                        .foregroundStyle(VoiidColor.textPrimary)

                    Text("""
                         Voiid now asks for your consent before it processes your account \
                         data, and lets you take that consent back at any time. Your account \
                         was created before we did this, so we are asking you once now.
                         """)
                        .font(.body)
                        .foregroundStyle(VoiidColor.textSecondary)

                    VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                        ForEach(LegalDocuments.purposes) { purpose in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(purpose.title)
                                    .font(.body.weight(.medium))
                                    .foregroundStyle(VoiidColor.textPrimary)
                                Text(purpose.detail)
                                    .font(.footnote)
                                    .foregroundStyle(VoiidColor.textSecondary)
                            }
                        }
                    }
                    .padding(VoiidSpacing.md)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                            .fill(VoiidColor.surfaceCard)
                    )

                    // The documents, before the button. A consent flow where the button is
                    // above the thing being consented to is a dark pattern with good
                    // intentions.
                    VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                        ForEach(LegalDocuments.all) { doc in
                            Button {
                                Haptics.tap()
                                presentedDocument = doc
                            } label: {
                                HStack(spacing: VoiidSpacing.sm) {
                                    Text(doc.title)
                                        .font(.body)
                                        .underline()
                                    Image(systemName: "chevron.right").font(.footnote)
                                }
                                .foregroundStyle(VoiidColor.primary)
                            }
                        }
                    }

                    Text("Voiid still cannot read your messages, calls, live location or moments. That does not change, and this consent does not give it that ability.")
                        .font(.footnote)
                        .foregroundStyle(VoiidColor.textSecondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(VoiidSpacing.md)
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .safeAreaInset(edge: .bottom) { actions }
            .navigationBarTitleDisplayMode(.inline)
        }
        .sheet(item: $presentedDocument) { doc in
            NavigationStack { LegalDocumentView(document: doc, showsDoneButton: true) }
        }
        .alert("Couldn't record consent",
               isPresented: Binding(get: { errorText != nil }, set: { if !$0 { errorText = nil } })) {
            Button("OK", role: .cancel) { errorText = nil }
        } message: {
            Text(errorText ?? "")
        }
        // Swipe-to-dismiss is disabled so the choice is deliberate, but "Not now" below is
        // always available — the modal is insistent, not inescapable.
        .interactiveDismissDisabled(true)
    }

    private var actions: some View {
        VStack(spacing: VoiidSpacing.sm) {
            Button {
                Haptics.tap()
                Task { await accept() }
            } label: {
                Text(working ? "Saving…" : "I Agree")
                    .font(VoiidFont.rounded(18, .medium))
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(maxWidth: .infinity, minHeight: 56)
                    .background(VoiidColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.pill, style: .continuous))
            }
            .disabled(working)

            Button("Not now") { onDefer() }
                .font(.body)
                .foregroundStyle(VoiidColor.textSecondary)
                .disabled(working)
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.bottom, VoiidSpacing.md)
        .background(.ultraThinMaterial)
    }

    private func accept() async {
        working = true
        defer { working = false }
        do {
            _ = try await ConsentService.shared.submitConsent(
                purposes: Dictionary(uniqueKeysWithValues: LegalDocuments.purposes.map { ($0.id, true) }),
                givenVia: "backfill_prompt")
            Haptics.success()
            onAccepted()
        } catch {
            errorText = (error as? APIError)?.errorDescription ?? error.localizedDescription
        }
    }
}
