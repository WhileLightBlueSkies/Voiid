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
    /// EXACTLY EIGHT, for choosing and for entering alike.
    ///
    /// The wrap is only as strong as the PIN is unguessable offline (Argon2id
    /// m=19MiB/t=2/p=1 ≈ 300ms/guess/core). A 4-digit keyspace falls in minutes once
    /// `recovery_keys.wrapped_key` is in hand (audit finding M9), and 6 digits is
    /// expensive rather than infeasible. Eight is 100 million candidates — at ~300ms a
    /// guess per core that is years on commodity hardware, which is the point at which
    /// the phrase, not the PIN, becomes the weakest way in.
    ///
    /// THE ENTRY FLOOR MOVED TOO, which is the part worth understanding. It used to sit
    /// at 4 so a backup wrapped under an older policy could still be unwrapped, and
    /// raising it would have bricked those restores. There are none: `recovery_keys` is
    /// empty, so no wrap exists that a shorter PIN could open. If that ever stops being
    /// true, this needs a migration path — not a quiet loosening back to 4.
    static let minLen = 8
    static let newMinLen = 8
    static let maxLen = 8

    /// The most-chosen short PINs. Not secrecy — a public denylist of the first keys
    /// any attacker tries, so they cost a real Argon2 evaluation like everything else.
    /// EIGHT-DIGIT ENTRIES ONLY, now that nothing shorter can be chosen. The old list was
    /// mostly 6s and 7s, which `valid` rejects on length before this is ever consulted —
    /// keeping them would have looked like protection that no longer did anything.
    private static let commonPINs: Set<String> = [
        // Runs and reverses.
        "12345678", "87654321", "01234567", "76543210", "23456789", "98765432",
        // Single repeated digit.
        "00000000", "11111111", "22222222", "33333333", "44444444",
        "55555555", "66666666", "77777777", "88888888", "99999999",
        // Two- and four-digit patterns tiled to length — what someone reaches for when
        // told "eight digits" and wanting something they can remember.
        "12121212", "21212121", "10101010", "13131313", "69696969",
        "11223344", "12341234", "43214321", "11112222", "12312312",
        // Dates people actually use: years doubled, and common DDMMYYYY anchors.
        "19801980", "19901990", "20002000", "20202020", "01011990",
        "01012000", "01011980", "31121999",
        // Keypad shapes.
        "14725836", "15935748", "11235813",
    ]

    /// Entry/unlock: exactly eight digits.
    static func valid(_ pin: String) -> Bool {
        pin.count == maxLen && pin.allSatisfy(\.isNumber)
    }

    /// Choosing a NEW PIN: the same length, plus the blocklist.
    static func validNew(_ pin: String) -> Bool {
        valid(pin) && !commonPINs.contains(pin)
    }

    /// Human-readable reason a NEW PIN was refused, for inline field errors.
    static func rejectionReason(_ pin: String) -> String? {
        guard pin.allSatisfy(\.isNumber) else { return "Digits only." }
        guard pin.count == maxLen else { return "Your PIN must be exactly \(maxLen) digits." }
        if commonPINs.contains(pin) { return "That PIN is too easy to guess." }
        return nil
    }
}

// MARK: - Secure numeric PIN field

/// A single secure numeric field, filtered to `PinRules.maxLen` digits. Used as the
/// building block for both PIN entry variants.
struct PinField: View {
    let placeholder: String
    @Binding var text: String
    var externalFocus: FocusState<Bool>.Binding? = nil
    @FocusState private var focused: Bool
    private var focus: FocusState<Bool>.Binding { externalFocus ?? $focused }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(placeholder == "Confirm PIN" ? "Confirm 8-digit PIN" : "8-digit PIN")
                    .font(VoiidFont.rounded(14, .medium))
                Spacer()
                Text("\(text.count) / \(PinRules.maxLen)").font(VoiidFont.rounded(13)).monospacedDigit()
            }
            .foregroundColor(VoiidColor.textSecondary)
        SecureField("", text: $text, prompt:
            Text("Enter 8 digits").foregroundColor(VoiidColor.placeholder))
            .font(VoiidFont.rounded(24, .semibold))
            .keyboardType(.numberPad)
            .textContentType(.password)
            .privacySensitive()
            .multilineTextAlignment(.center)
            .toolbar {
                ToolbarItemGroup(placement: .keyboard) {
                    if focus.wrappedValue {
                        Spacer()
                        Button("Done") { focus.wrappedValue = false }.tint(VoiidColor.accent)
                    }
                }
            }
            .focused(focus)
            .foregroundColor(VoiidColor.textPrimary)
            .onChange(of: text) { _, v in
                let digits = String(v.filter { $0 >= "0" && $0 <= "9" }.prefix(PinRules.maxLen))
                if digits != text { text = digits }
                if digits.count == PinRules.maxLen { focus.wrappedValue = false }
            }
            .padding(.horizontal, VoiidSpacing.md)
            .frame(height: 64)
            .background(VoiidColor.fieldFill)
            .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(focus.wrappedValue ? VoiidColor.primary : VoiidColor.fieldBorder, lineWidth: focus.wrappedValue ? 1.5 : 1))
            HStack(spacing: 6) {
                ForEach(0..<PinRules.maxLen, id: \.self) { index in
                    Capsule().fill(index < text.count ? VoiidColor.accent : VoiidColor.fieldBorder).frame(height: 3)
                }
            }
            .accessibilityHidden(true)
        }
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
        ScrollView {
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
            .softTopEdgeEffect()
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
