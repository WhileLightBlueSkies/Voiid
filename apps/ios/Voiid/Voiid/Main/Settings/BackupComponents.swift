//
//  BackupComponents.swift
//  Voiid
//
//  Reusable SwiftUI pieces for the backup / recovery flows: numeric PIN entry
//  (choose-with-confirmation and single-entry variants), the 24-word recovery
//  phrase display, and a recovery-phrase input field. The PIN is never logged.
//

import SwiftUI

// MARK: - PIN rules

enum PinRules {
    /// ENTRY floor. Deliberately stays at 4 so a backup wrapped under the old policy
    /// can still be unwrapped — this predicate guards UNLOCKING, and tightening it
    /// would brick existing restores.
    static let minLen = 4
    /// CHOICE floor. The wrap is only as strong as the PIN is unguessable offline
    /// (Argon2id m=19MiB/t=2/p=1 ≈ 300ms/guess/core), and a 4-digit keyspace falls in
    /// minutes once `recovery_keys.wrapped_key` is in hand (audit finding M9). Six
    /// digits moves mass cracking from trivial to expensive; the common-PIN blocklist
    /// below removes the rest of the top of the distribution.
    static let newMinLen = 6
    static let maxLen = 8

    /// The most-chosen short PINs. Not secrecy — a public denylist of the first keys
    /// any attacker tries, so they cost a real Argon2 evaluation like everything else.
    private static let commonPINs: Set<String> = [
        "000000", "111111", "121212", "123123", "123321", "123456", "112233",
        "654321", "666666", "696969", "777777", "888888", "999999", "101010",
        "0000000", "1234567", "1111111", "7777777", "12345678", "87654321",
        "11111111", "12121212",
        // Top repeated-digit / pattern 4-digit PINs padded variants are covered by
        // length; these are the famous 6s.
        "159753", "112358", "147258", "159357",
    ]

    /// Entry/unlock: digits within the legacy length bounds. Never tightened.
    static func valid(_ pin: String) -> Bool {
        pin.count >= minLen && pin.count <= maxLen && pin.allSatisfy(\.isNumber)
    }

    /// Choosing a NEW PIN: the stricter policy. Existing wraps keep unlocking via
    /// `valid`; the next PIN change migrates the wrap up to this standard.
    static func validNew(_ pin: String) -> Bool {
        valid(pin) && pin.count >= newMinLen && !commonPINs.contains(pin)
    }

    /// Human-readable reason a NEW PIN was refused, for inline field errors.
    static func rejectionReason(_ pin: String) -> String? {
        guard pin.count >= minLen && pin.count <= maxLen && pin.allSatisfy(\.isNumber) else {
            return "Use \(minLen)–\(maxLen) digits."
        }
        if pin.count < newMinLen { return "Choose at least \(newMinLen) digits." }
        if commonPINs.contains(pin) { return "That PIN is too easy to guess." }
        return nil
    }
}

// MARK: - Secure numeric PIN field

/// A single secure numeric field, filtered to `PinRules.maxLen` digits. Used as the
/// building block for both PIN entry variants.
private struct PinField: View {
    let placeholder: String
    @Binding var text: String
    @FocusState private var focused: Bool

    var body: some View {
        SecureField("", text: $text, prompt:
            Text(placeholder).foregroundColor(VoiidColor.placeholder))
            .font(VoiidFont.body)
            .keyboardType(.numberPad)
            .textContentType(.oneTimeCode)
            .focused($focused)
            .foregroundColor(VoiidColor.textPrimary)
            .onChange(of: text) { _, v in
                let digits = String(v.filter(\.isNumber).prefix(PinRules.maxLen))
                if digits != text { text = digits }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .frame(height: 61)
            .background(VoiidColor.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                .stroke(focused ? VoiidColor.primary : VoiidColor.fieldBorder, lineWidth: 1))
    }
}

/// Choose a PIN, entered twice for confirmation. Calls `onSubmit(pin)` only when both
/// entries match and satisfy the length rule.
struct PinChooseView: View {
    let title: String
    let subtitle: String
    var errorText: String?
    let onSubmit: (String) -> Void

    @State private var pin = ""
    @State private var confirm = ""
    @State private var mismatch = false

    private var canSubmit: Bool { PinRules.validNew(pin) && pin == confirm }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            Text(title).font(VoiidFont.title).foregroundColor(VoiidColor.textPrimary)
            Text(subtitle).font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)

            PinField(placeholder: "PIN (\(PinRules.newMinLen)–\(PinRules.maxLen) digits)", text: $pin)
            PinField(placeholder: "Confirm PIN", text: $confirm)

            if mismatch { fieldError("PINs don’t match.") }
            if !pin.isEmpty, let reason = PinRules.rejectionReason(pin) { fieldError(reason) }
            if let errorText { fieldError(errorText) }

            Spacer()

            VoiidPrimaryButton(title: "Continue", enabled: canSubmit) {
                guard canSubmit else { mismatch = pin != confirm; return }
                Haptics.tap(); onSubmit(pin)
            }
        }
        .padding(VoiidSpacing.lg)
        .onChange(of: confirm) { _, _ in if mismatch { mismatch = false } }
    }

    private func fieldError(_ t: String) -> some View {
        Text(t).font(VoiidFont.footnote).foregroundColor(VoiidColor.error)
    }
}

/// Enter an existing PIN once (restore path). Calls `onSubmit(pin)` when the length
/// rule is met; `errorText` shows the last failure (e.g. "wrong PIN").
struct PinEntryView: View {
    let title: String
    let subtitle: String
    var errorText: String?
    var busy: Bool = false
    let onSubmit: (String) -> Void

    @State private var pin = ""

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            Text(title).font(VoiidFont.title).foregroundColor(VoiidColor.textPrimary)
            Text(subtitle).font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)

            PinField(placeholder: "PIN", text: $pin)

            if let errorText { Text(errorText).font(VoiidFont.footnote).foregroundColor(VoiidColor.error) }

            Spacer()

            VoiidPrimaryButton(title: busy ? "Checking…" : "Restore", enabled: PinRules.valid(pin) && !busy) {
                Haptics.tap(); onSubmit(pin)
            }
        }
        .padding(VoiidSpacing.lg)
    }
}

// MARK: - Recovery phrase display

/// Renders a 24-word BIP39 phrase in a numbered two-column grid, with a strong
/// warning that it's the only fallback if the PIN is forgotten, and a confirm button.
struct RecoveryPhraseView: View {
    let phrase: String
    var confirmTitle: String = "Done"
    let onConfirm: () -> Void

    private var words: [String] {
        phrase.split(whereSeparator: { $0 == " " || $0 == "\n" }).map(String.init)
    }
    private let columns = [GridItem(.flexible()), GridItem(.flexible())]

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.md) {
                    HStack(spacing: VoiidSpacing.sm) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundColor(VoiidColor.warning)
                        Text("Write these 24 words down and keep them safe. If you forget your PIN, this phrase is the ONLY way to recover your chats. Anyone with it can restore your backup.")
                            .font(VoiidFont.footnote).foregroundColor(VoiidColor.textSecondary)
                    }
                    .padding(VoiidSpacing.md)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))

                    LazyVGrid(columns: columns, spacing: VoiidSpacing.sm) {
                        ForEach(Array(words.enumerated()), id: \.offset) { i, w in
                            HStack(spacing: VoiidSpacing.sm) {
                                Text("\(i + 1)")
                                    .font(VoiidFont.caption).foregroundColor(VoiidColor.textSecondary)
                                    .frame(width: 22, alignment: .trailing)
                                Text(w).font(VoiidFont.callout).foregroundColor(VoiidColor.textPrimary)
                                Spacer(minLength: 0)
                            }
                            .padding(.vertical, 6).padding(.horizontal, VoiidSpacing.sm)
                            .background(VoiidColor.surfaceCard)
                            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.sm, style: .continuous))
                        }
                    }

                    Button {
                        Haptics.tap()
                        UIPasteboard.general.string = phrase
                    } label: {
                        Label("Copy phrase", systemImage: "doc.on.doc")
                            .font(VoiidFont.subhead).foregroundColor(VoiidColor.primary)
                    }
                }
            }
            VoiidPrimaryButton(title: confirmTitle) { Haptics.tap(); onConfirm() }
        }
        .padding(VoiidSpacing.lg)
    }
}

// MARK: - Recovery phrase input (restore path)

/// Multi-line entry for the 24-word recovery phrase. Calls `onSubmit(phrase)` with
/// the whitespace-normalized phrase; validation (BIP39) happens downstream.
struct PhraseEntryView: View {
    var errorText: String?
    var busy: Bool = false
    let onSubmit: (String) -> Void

    @State private var text = ""
    @FocusState private var focused: Bool

    private var normalized: String {
        text.lowercased().split(whereSeparator: { $0 == " " || $0 == "\n" }).joined(separator: " ")
    }
    private var wordCount: Int { normalized.isEmpty ? 0 : normalized.split(separator: " ").count }

    var body: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            Text("Enter recovery phrase").font(VoiidFont.title).foregroundColor(VoiidColor.textPrimary)
            Text("Type or paste your 24-word recovery phrase, separated by spaces.")
                .font(VoiidFont.subhead).foregroundColor(VoiidColor.textSecondary)

            TextEditor(text: $text)
                .font(VoiidFont.body)
                .foregroundColor(VoiidColor.textPrimary)
                .scrollContentBackground(.hidden)
                .focused($focused)
                .frame(height: 140)
                .padding(VoiidSpacing.sm)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous)
                    .stroke(focused ? VoiidColor.primary : VoiidColor.fieldBorder, lineWidth: 1))
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)

            Text("\(wordCount) / 24 words").font(VoiidFont.caption).foregroundColor(VoiidColor.textSecondary)
            if let errorText { Text(errorText).font(VoiidFont.footnote).foregroundColor(VoiidColor.error) }

            Spacer()

            VoiidPrimaryButton(title: busy ? "Checking…" : "Restore", enabled: wordCount == 24 && !busy) {
                Haptics.tap(); onSubmit(normalized)
            }
        }
        .padding(VoiidSpacing.lg)
    }
}
