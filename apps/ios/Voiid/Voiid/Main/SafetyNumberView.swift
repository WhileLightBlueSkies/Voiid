//
//  SafetyNumberView.swift
//  Voiid
//
//  VERIFY THAT NOBODY IS IN THE MIDDLE.
//
//  End-to-end encryption guarantees that only the holder of the other private key can read
//  your messages. It does NOT, by itself, tell you WHOSE key that is. If the server handed
//  you an attacker's key instead of your contact's, every message would still be encrypted —
//  to the attacker, who would relay it on and read everything in between. That is the
//  machine-in-the-middle attack, and it is the one thing encryption alone cannot rule out.
//
//  The safety number closes it. Both sides derive the SAME 60-digit number from the two
//  identity keys (see e2e-core/verify.rs — iterated SHA-512, sorted so both parties compute
//  an identical string regardless of who is "us"). If your number matches theirs, read aloud
//  or scanned in person, then the keys you each hold are genuinely each other's and there is
//  nobody in between. If it does NOT match, something is wrong and messages should stop.
//
//  WHY THIS IS COMPARED OUT OF BAND. The number is only meaningful over a channel the
//  attacker does not control — in person, or on a call where you recognise the voice.
//  Sending it through Voiid itself proves nothing: an attacker relaying your messages would
//  simply rewrite the number in transit. The screen says so, because a verification ritual
//  performed over the compromised channel is worse than none — it manufactures confidence.
//
//  MULTI-DEVICE. A safety number is per DEVICE PAIR, not per person: each device has its own
//  identity key. A contact with a phone and a tablet has two numbers, and both must match.
//  Collapsing them into one would mean a screen that reads "verified" while an unverified
//  second device sits silently on the account.
//

import SwiftUI

struct SafetyNumberView: View {
    let peerUserId: String
    let peerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var state: LoadState = .loading

    private enum LoadState { case loading, loaded, failed, noKeys }

    /// One device pair: the peer device, and the number we share with it.
    private struct Entry: Identifiable {
        let id: String          // peer device id
        let number: String      // grouped safety-number digits
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: VoiidSpacing.lg) {
                    switch state {
                    case .loading:  loadingBody
                    case .failed:   failedBody
                    case .noKeys:   noKeysBody
                    case .loaded:   loadedBody
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, VoiidSpacing.lg)
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Verify encryption")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { dismiss() }.foregroundStyle(VoiidColor.primary)
                }
            }
        }
        .tint(VoiidColor.primary)
        .task { await load() }
    }

    // MARK: - States

    private var loadingBody: some View {
        VStack(spacing: VoiidSpacing.md) {
            ProgressView()
            Text("Reading keys…")
                .font(VoiidFont.rounded(14, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, VoiidSpacing.xxl)
    }

    private var failedBody: some View {
        stateMessage(
            icon: "wifi.exclamationmark",
            title: "Couldn't load keys",
            body: "Check your connection and try again.",
            action: ("Retry", { Task { await load() } })
        )
    }

    /// A peer with no registered device keys. Real: an account that signed up but has not
    /// completed key setup, or one that logged out everywhere.
    private var noKeysBody: some View {
        stateMessage(
            icon: "key.slash",
            title: "No keys to verify yet",
            body: "\(peerName) hasn't set up encryption keys on any device. There is nothing "
                + "to compare until they do.",
            action: nil
        )
    }

    private func stateMessage(icon: String, title: String, body: String,
                              action: (String, () -> Void)?) -> some View {
        VStack(spacing: VoiidSpacing.sm) {
            Image(systemName: icon)
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(VoiidColor.textSecondary)
                .padding(.bottom, 4)
            Text(title)
                .font(VoiidFont.rounded(17, .semibold))
                .foregroundStyle(VoiidColor.textPrimary)
            Text(body)
                .font(VoiidFont.rounded(14, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
            if let action {
                Button(action.0) { Haptics.tap(); action.1() }
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundStyle(VoiidColor.primary)
                    .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.top, VoiidSpacing.xl)
    }

    private var loadedBody: some View {
        VStack(spacing: VoiidSpacing.lg) {
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                VStack(alignment: .leading, spacing: VoiidSpacing.sm) {
                    // Only labelled when there is more than one — "Device 1 of 1" is noise.
                    if entries.count > 1 {
                        Text("Device \(index + 1) of \(entries.count)")
                            .font(VoiidFont.rounded(12, .semibold))
                            .kerning(0.6)
                            .foregroundStyle(VoiidColor.textSecondary)
                            .padding(.horizontal, VoiidSpacing.xs)
                    }
                    numberCard(entry.number)
                }
            }

            instructions
        }
    }

    /// The digits.
    ///
    /// MONOSPACED and in 5-digit groups, because this number exists to be READ ALOUD and
    /// checked character by character. Proportional digits make 1 and 7 and 4 similar widths
    /// and the eye loses its place; grouping is what lets two people stay in sync while
    /// reading. Selectable so it can be copied into a call where that is the safest channel
    /// available.
    private func numberCard(_ number: String) -> some View {
        Text(number)
            .font(.system(size: 19, weight: .medium, design: .monospaced))
            .kerning(1.5)
            .lineSpacing(7)
            .foregroundStyle(VoiidColor.textPrimary)
            .multilineTextAlignment(.center)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity)
            .padding(.vertical, VoiidSpacing.lg)
            .padding(.horizontal, VoiidSpacing.md)
            .background(VoiidColor.surfaceCard)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
            .accessibilityLabel("Safety number: " + number.map(String.init).joined(separator: " "))
    }

    private var instructions: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            step(1, "Compare in person or on a call",
                 "Ask \(peerName) to open this same screen. Read the numbers to each other, "
                 + "or check them side by side.")

            step(2, "If they match, you're verified",
                 "Nobody is intercepting this chat. Your messages, photos, videos, voice "
                 + "notes and calls can only be read by the two of you.")

            step(3, "If they don't match, stop",
                 "The keys are not each other's. Don't send anything sensitive, and try "
                 + "again on a different device or connection.")

            // THE LOAD-BEARING CAVEAT. Comparing the number inside Voiid proves nothing — an
            // attacker relaying your messages would rewrite it in transit. Saying this
            // plainly is the difference between a real check and a reassuring ritual.
            HStack(alignment: .top, spacing: VoiidSpacing.sm) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(VoiidColor.warning)
                    .padding(.top, 2)
                Text("Don't send this number over Voiid or any other chat. It only proves "
                     + "something if you compare it somewhere an attacker can't change it.")
                    .font(VoiidFont.rounded(12, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(VoiidSpacing.md)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(VoiidColor.warning.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
        }
    }

    private func step(_ n: Int, _ title: String, _ body: String) -> some View {
        HStack(alignment: .top, spacing: VoiidSpacing.md) {
            Text("\(n)")
                .font(VoiidFont.rounded(13, .semibold))
                .foregroundStyle(VoiidColor.textOnPrimary)
                .frame(width: 24, height: 24)
                .background(Circle().fill(VoiidColor.primary))

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(VoiidFont.rounded(15, .semibold))
                    .foregroundStyle(VoiidColor.textPrimary)
                Text(body)
                    .font(VoiidFont.rounded(13, .regular))
                    .foregroundStyle(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: - Load

    private func load() async {
        state = .loading

        // OUR fingerprint comes from the local identity — never from the server. Asking the
        // server for our own key would let a malicious server feed us a number that matches
        // whatever it told the peer, which is exactly the attack this screen detects.
        guard let identity = E2EManager.shared.identity,
              let myId = TokenStore.shared.userId else {
            state = .failed
            return
        }
        let myFingerprint = identity.fingerprint()

        do {
            let peers = try await ChatEngine.shared.peerIdentities(userId: peerUserId)
            guard !peers.isEmpty else { state = .noKeys; return }

            entries = peers.map { peer in
                Entry(
                    id: peer.id,
                    number: safetyNumber(
                        ourId: Data(myId.utf8),
                        ourFingerprint: myFingerprint,
                        theirId: Data(peerUserId.utf8),
                        theirFingerprint: peer.identityKey
                    )
                )
            }
            state = .loaded
        } catch {
            NSLog("[VOIID] safety number load failed: \(error.localizedDescription)")
            state = .failed
        }
    }
}
