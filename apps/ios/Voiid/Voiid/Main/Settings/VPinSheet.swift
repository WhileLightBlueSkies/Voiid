//
//  VPinSheet.swift
//  Voiid
//
//  Set or change the V PIN: choose 8 digits, type them again, save.
//
//  ── WHAT THE PERSON IS TOLD, AND WHY ──────────────────────────────────────────────
//  Three facts, before they choose: it never leaves the phone, 5 wrong tries lock it for
//  24 hours, and the recovery phrase always works. The limit is said up front because it
//  is a rule people plan around — a PIN they would forget is worth choosing differently
//  once they know a few wrong guesses cost a day.
//
//  Saving is slow on purpose (Argon2id locks the key, PBKDF2 makes the proof — about a
//  second together), so the button says what is happening rather than freezing.
//

import SwiftUI

struct VPinSheet: View {
    enum Mode: String, Identifiable { case set, change; var id: String { rawValue } }

    let mode: Mode
    var onSaved: () -> Void = {}

    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var first = ""
    @State private var second = ""
    @State private var busy = false
    @State private var errorText: String?
    @FocusState private var focused: Bool

    private var heading: String {
        if step == 1 { return "Type it again" }
        return mode == .set ? "Choose a V PIN" : "Choose a new V PIN"
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    Text(heading)
                        .font(VoiidFont.title)
                        .foregroundColor(VoiidColor.textPrimary)

                    Text(step == 0
                         ? "8 digits to restore your chats on a new phone — quicker than your recovery phrase."
                         : "So a typo doesn't lock you out of your own backup.")
                        .font(VoiidFont.subhead)
                        .foregroundColor(VoiidColor.textSecondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if step == 0 {
                        PinField(placeholder: "PIN", text: $first, externalFocus: $focused)
                    } else {
                        PinField(placeholder: "Confirm PIN", text: $second, externalFocus: $focused)
                    }

                    if let errorText {
                        Text(errorText)
                            .font(VoiidFont.footnote)
                            .foregroundColor(VoiidColor.error)
                            .fixedSize(horizontal: false, vertical: true)
                    }

                    if step == 0 { facts }
                }
                .padding(VoiidSpacing.lg)
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle(mode == .set ? "V PIN" : "Change V PIN")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    if step == 1, !busy {
                        Button("Back") { step = 0; second = ""; errorText = nil }
                    } else {
                        Button("Cancel") { dismiss() }.disabled(busy)
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                VoiidPrimaryButton(title: buttonTitle, enabled: canContinue) { advance() }
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.bottom, VoiidSpacing.md)
            }
            .onAppear { focused = true }
            .interactiveDismissDisabled(busy)
        }
    }

    private var buttonTitle: String {
        if busy { return "Securing…" }
        return step == 0 ? "Continue" : "Save V PIN"
    }

    private var canContinue: Bool {
        guard !busy else { return false }
        return step == 0 ? first.count == PinRules.maxLen : second.count == PinRules.maxLen
    }

    /// The three things worth knowing before choosing.
    private var facts: some View {
        VStack(alignment: .leading, spacing: 12) {
            fact("iphone", "It never leaves this phone",
                 "Voiid gets a one-way proof of it, never the PIN itself.")
            fact("lock.badge.clock", "5 wrong tries lock it for 24 hours",
                 "Voiid's server counts every try, so nobody can keep guessing.")
            fact("key", "Your recovery phrase always works",
                 "Even while the V PIN is locked.")
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .padding(.top, VoiidSpacing.sm)
    }

    private func fact(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 15))
                .foregroundColor(VoiidColor.accentInk)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(VoiidFont.rounded(14.5, .semibold)).foregroundColor(VoiidColor.textPrimary)
                Text(detail).font(VoiidFont.rounded(12.5)).foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func advance() {
        errorText = nil
        if step == 0 {
            // Refused here rather than after typing it twice: a PIN on the common list is
            // one of the first an attacker would try with their 5 guesses.
            if let reason = PinRules.rejectionReason(first) {
                errorText = reason
                Haptics.error()
                return
            }
            step = 1
            focused = true
            return
        }
        guard second == first else {
            errorText = "Those didn't match. Try again."
            Haptics.error()
            second = ""
            return
        }
        busy = true
        Task {
            defer { busy = false }
            do {
                try await BackupManager.shared.setVPin(first)
                Haptics.success()
                onSaved()
                dismiss()
            } catch {
                errorText = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
                Haptics.error()
            }
        }
    }
}
