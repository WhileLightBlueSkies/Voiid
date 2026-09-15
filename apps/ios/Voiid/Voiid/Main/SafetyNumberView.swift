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
import AVFoundation
import CoreImage.CIFilterBuiltins

struct SafetyNumberView: View {
    let peerUserId: String
    let peerName: String

    @Environment(\.dismiss) private var dismiss
    @State private var entries: [Entry] = []
    @State private var state: LoadState = .loading
    /// Which representation of the number is on screen. Defaults to the DIGITS, not the code:
    /// the read-aloud path works everywhere, a scan needs two devices in one room.
    @State private var scanningEntry: Entry?

    /// The card swap and the state crossfade are both opacity-and-scale on a small surface,
    /// so they stay under Reduce Motion — but the spring is dropped, because a settling
    /// overshoot is still motion the setting asks to avoid.
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                    // FOUR STATES THAT USED TO HARD-CUT. Reading keys is fast on a warm
                    // cache and slow on a cold one, so this screen frequently flashes from
                    // spinner to content in a frame — which reads as a glitch, on the one
                    // screen in the app where a glitch undermines the thing being asserted.
                    Group {
                        switch state {
                        case .loading:  loadingBody
                        case .failed:   failedBody
                        case .noKeys:   noKeysBody
                        case .loaded:   loadedBody
                        }
                    }
                    .animation(.easeInOut(duration: 0.22), value: state)
                }
                .padding(.horizontal, 20)
                .padding(.vertical, VoiidSpacing.lg)
            }
            .softTopEdgeEffect()
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
        .sheet(item: $scanningEntry) { entry in
            SafetyCodeScanner(expected: entry.number, peerName: peerName)
        }
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
        VStack(spacing: 24) {
            ProfileAvatarButton(photoURL: UserDirectory.shared.photoURL(peerUserId), name: peerName, size: 64)
            Text(peerName).font(VoiidFont.rounded(22, .semibold)).foregroundStyle(VoiidColor.textPrimary)
            ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                VStack(spacing: 18) {
                    if entries.count > 1 {
                        Text("Device \(index + 1) of \(entries.count)")
                            .font(VoiidFont.rounded(12, .semibold)).foregroundStyle(VoiidColor.textSecondary)
                    }
                    if let qr = qrImage(for: entry.number) {
                        qr.interpolation(.none).resizable().scaledToFit().frame(maxWidth: 220)
                            .padding(16).background(Color.white, in: RoundedRectangle(cornerRadius: 16))
                            .accessibilityLabel("Security code QR")
                    }
                    Text(formattedCode(entry.number))
                        .font(.system(size: 15, weight: .medium, design: .monospaced))
                        .lineSpacing(7).multilineTextAlignment(.center).foregroundStyle(VoiidColor.textPrimary)
                    Button { scanningEntry = entry } label: {
                        Label("Scan QR code", systemImage: "qrcode.viewfinder").frame(minHeight: 44)
                    }.buttonStyle(.borderedProminent)
                    Text("Compare this code on both devices.")
                        .font(VoiidFont.rounded(12)).foregroundStyle(VoiidColor.textSecondary)
                }.padding(20).frame(maxWidth: .infinity)
                    .background(VoiidColor.surfaceCard, in: RoundedRectangle(cornerRadius: 24))
            }
            instructions
        }
    }

    private func formattedCode(_ number: String) -> String {
        let digits = Array(number.filter(\.isNumber))
        return stride(from: 0, to: digits.count, by: 20).map { start in
            stride(from: start, to: min(start + 20, digits.count), by: 5).map {
                String(digits[$0..<min($0 + 5, digits.count)])
            }.joined(separator: " ")
        }.joined(separator: "\n")
    }

    /// The number as a scannable code.
    ///
    /// WHY A QR AT ALL. Reading 60 digits aloud, in sync, without losing your place is a
    /// genuinely unpleasant ritual, and the failure mode is that people skim it — they check
    /// the first group, the last group, and declare a match. That is not verification; it is
    /// a ceremony that manufactures confidence, which the header of this file warns against.
    /// Scanning compares all 60 digits or none.
    ///
    /// THE DIGITS STAY, and they are not secondary. A QR needs a working camera, adequate
    /// light and two devices in the same room; the read-aloud path works on a phone call
    /// where you recognise the voice, which is the other out-of-band channel people actually
    /// have. Both are offered because they fail in different situations.
    ///
    /// Nothing secret is encoded. A safety number is derived from two PUBLIC identity keys —
    /// it is safe to photograph, and an attacker learning it gains nothing they could not
    /// compute themselves.
    private func qrImage(for number: String) -> Image? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(number.filter(\.isNumber).utf8)
        // Highest error correction: this gets pointed at from an angle, in bad light, on a
        // screen with glare. A code that fails to scan sends people back to reading digits.
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        // Nearest-neighbour upscale keeps the modules crisp; a smoothed QR scans worse.
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cg, scale: 1)
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

    private func qrCard(_ qr: Image) -> some View {
        VStack(spacing: VoiidSpacing.sm) {
            qr
                .interpolation(.none)     // keep the modules hard-edged; smoothing hurts scans
                .resizable()
                .scaledToFit()
                .frame(width: 190, height: 190)
                .padding(VoiidSpacing.md)
                // Always LIGHT, in both themes. A QR is read as dark-on-light by every
                // scanner; inverting it in dark mode is the single most common way to ship a
                // code that will not scan.
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))

            Text("Have \(peerName) scan this, or tap to read the digits instead")
                .font(VoiidFont.rounded(12, .regular))
                .foregroundStyle(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoiidSpacing.lg)
        .padding(.horizontal, VoiidSpacing.md)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .accessibilityLabel("Scannable safety code")
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

// Compare the complete QR payload, never a prefix or digits extracted from a URL.
enum SafetyQRComparison {
    enum Result { case match, mismatch, invalid }
    static func compare(_ payload: String, expected: String) -> Result {
        let digits = expected.filter { $0 >= "0" && $0 <= "9" }
        guard payload.utf8.count == 60, payload.utf8.allSatisfy({ $0 >= 48 && $0 <= 57 }),
              digits.count == 60 else { return .invalid }
        return payload == digits ? .match : .mismatch
    }
}

private struct SafetyCodeScanner: View {
    let expected: String
    let peerName: String
    @Environment(\.dismiss) private var dismiss
    @Environment(\.scenePhase) private var scenePhase
    @State private var permission = AVCaptureDevice.authorizationStatus(for: .video)
    @State private var unavailable = false
    @State private var result: SafetyQRComparison.Result?

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Scan \(peerName)’s code from this device pair’s Verify encryption screen.")
                        .multilineTextAlignment(.center)
                    if let result {
                        Image(systemName: result == .match ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                            .font(.system(size: 44))
                        Text(result == .match ? "Codes match" : result == .mismatch ? "Codes don’t match" : "Not a security QR code")
                            .font(VoiidFont.rounded(22, .semibold))
                        Text(result == .match ? "The displayed security codes match for this device pair. Verify other linked devices separately." : result == .mismatch ? "Check that you opened the same conversation and selected the correct device. Compare the codes again before sharing sensitive information." : "Scan the QR shown in Verify encryption, not a profile or community QR.")
                            .multilineTextAlignment(.center)
                        Button("Scan again") { self.result = nil }
                    } else if permission == .authorized && !unavailable {
                        VoiidQRScannerPreview(isScanning: scenePhase == .active, torchOn: false,
                            onCode: { if result == nil { result = SafetyQRComparison.compare($0, expected: expected) } },
                            onUnavailable: { unavailable = true }, onTorchStatus: { _, _ in })
                            .frame(height: 320).clipShape(RoundedRectangle(cornerRadius: 24))
                    } else {
                        Text(unavailable ? "Camera unavailable. You can still compare the digits." : "Allow camera access to scan. You can also compare the digits manually.")
                            .multilineTextAlignment(.center)
                        if permission == .denied {
                            Button("Open Settings") { if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) } }
                        }
                    }
                }.padding(24).frame(maxWidth: .infinity)
            }.softTopEdgeEffect().background(VoiidColor.background)
                .foregroundStyle(VoiidColor.textPrimary)
                .navigationTitle("Scan security QR").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .topBarTrailing) { Button("Done") { dismiss() } } }
        }.tint(VoiidColor.primary)
            .task {
                if permission == .notDetermined { _ = await AVCaptureDevice.requestAccess(for: .video) }
                permission = AVCaptureDevice.authorizationStatus(for: .video)
            }
            .onChange(of: scenePhase) { _, phase in
                if phase == .active { permission = AVCaptureDevice.authorizationStatus(for: .video) }
            }
    }
}
