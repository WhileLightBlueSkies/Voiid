//
//  MyQRCodeView.swift
//  Voiid
//
//  Settings → My QR Code. The code someone scans to reach you.
//
//  ── THE CODE IS HALF OF A TWO-GATE FLOW, AND ONLY HALF ──────────────────────────
//  It encodes `https://voiid.app/u/<username>` — your handle, nothing else. Scanning it does
//  NOT open a chat: it lands the scanner on the PIN step, and the message they send arrives
//  as a REQUEST you still have to accept. Two gates, exactly as `ContactPinService` designed
//  them, and a scan replaces neither.
//
//  ── WHY THE PIN IS ON THIS SCREEN BUT NOT IN THE CODE ───────────────────────────
//  A QR is a photograph waiting to happen. Encoding the PIN would mean anyone who ever saw
//  your code — a screenshot, a poster, someone behind you in a queue — could open a request,
//  collapsing two independent gates into one image.
//
//  So the PIN is shown BESIDE the code, as text, to be read out or typed by you. That is not
//  an inconvenience to design around; it is the feature. The QR removes the tedious half
//  (spelling a handle correctly) and leaves the deliberate half intact.
//
//  The copy says this in one line, because a user who does not understand why the code alone
//  is not enough will assume the app is broken when their friend is asked for digits.
//
//  ── THE PIN IS SET IN SF PRO ROUNDED, LIKE EVERYTHING ELSE ──────────────────────
//  It was briefly a true monospaced face, for the fixed advance width that reading digits
//  aloud needs. That was wrong: it would have been the only place in the app where the type
//  changes identity, and it changed it on the screen most likely to be read letter by letter
//  by someone glancing between two phones. `.monospacedDigit()` on the app's own rounded face
//  gives tabular figures without giving up the typeface — the same thing the chat list and
//  call timer already do.
//
//  ── NO USERNAME, NO CODE ────────────────────────────────────────────────────────
//  A QR for an empty handle would encode a link that resolves to nobody. Without a username
//  the screen says so and points at Edit Profile, rather than drawing a code that cannot work.
//

import SwiftUI
import CoreImage.CIFilterBuiltins

@MainActor
struct MyQRCodeView: View {
    @EnvironmentObject private var session: AppSession

    @State private var pinState: ContactPinService.PinState?
    @State private var loadingPin = true
    /// Set briefly after the PIN is copied, so the card confirms it without a toast.
    @State private var copiedPin = false

    private var username: String? {
        let u = session.profile.username?.lowercased()
        return (u?.isEmpty == false) ? u : nil
    }

    private var link: URL? { username.flatMap { ProfileLink.url(for: $0) } }

    var body: some View {
        ScrollView {
            VStack(spacing: VoiidSpacing.md) {
                if let username, let link {
                    codeCard(username: username, link: link)
                    pinCard
                    shareButton(link: link)
                } else {
                    noUsernameCard
                }
            }
            .padding(VoiidSpacing.md)
        }
        .scrollIndicators(.hidden)
        .background(VoiidColor.background.ignoresSafeArea())
        .navigationTitle("My QR Code")
        .navigationBarTitleDisplayMode(.inline)
        .task { await loadPin() }
    }

    // MARK: Code

    private func codeCard(username: String, link: URL) -> some View {
        VStack(spacing: VoiidSpacing.md) {
            // WHITE PLATE, always — never the theme's surface. A QR needs a light quiet zone
            // and dark modules to scan; drawn on a dark card in dark mode it inverts and many
            // scanners refuse it. The plate is the code's own substrate, not app chrome.
            ZStack {
                RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
                    .fill(.white)

                if let image = Self.qr(link.absoluteString) {
                    image
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .padding(VoiidSpacing.md)
                        .accessibilityLabel("QR code for @\(username)")
                } else {
                    Text("Couldn’t draw the code.")
                        .font(VoiidFont.subhead)
                        .foregroundStyle(.black.opacity(0.5))
                }
            }
            .frame(width: 232, height: 232)
            // A real card, not a floating rectangle: the plate sits on the accent at low
            // alpha so the white reads as a deliberate substrate for the code rather than a
            // hole punched in the surface.
            .padding(VoiidSpacing.sm)
            .background(VoiidColor.accent.opacity(0.10))
            .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))

            VStack(spacing: 2) {
                Text("@\(username)")
                    // Larger and tighter than body: this is the one string a person reads
                    // OFF the screen and says out loud, so it gets display treatment. Tracking
                    // goes NEGATIVE as size grows — letters read further apart the bigger they
                    // get, and a handle is scanned as one word, not spelled.
                    .font(VoiidFont.rounded(22, .bold))
                    .tracking(-0.3)
                    .foregroundStyle(VoiidColor.textPrimary)
                    .textSelection(.enabled)

                Text("Scan to find me on Voiid")
                    .font(VoiidFont.rounded(13))
                    .foregroundStyle(VoiidColor.textSecondary)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, VoiidSpacing.lg)
        .background(VoiidColor.surfaceCard)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous)
            .stroke(VoiidColor.divider, lineWidth: 1))
    }

    // MARK: PIN

    private var pinCard: some View {
        VoiidCardSection(
            copiedPin ? "Copied" : "Your Contact PIN",
            footer: "Scanning your code is not enough on its own — they also need these "
                  + "digits, which is why the code does not contain them. Say the PIN out "
                  + "loud or send it separately. You still choose whether to accept."
        ) {
            if loadingPin {
                row { ProgressView().controlSize(.small) }
            } else if let pin = pinState?.pin {
                pinDigits(pin)
            } else if pinState?.has_pin == true {
                row {
                    Text("Set, but not viewable. Rotate it in Privacy & security to get a "
                       + "PIN you can read.")
                        .font(VoiidFont.subhead)
                        .foregroundStyle(VoiidColor.textSecondary)
                }
            } else {
                row {
                    Text("You don’t have one yet. Set it in Privacy & security — without a "
                       + "PIN, people who scan your code can’t reach you.")
                        .font(VoiidFont.subhead)
                        .foregroundStyle(VoiidColor.textSecondary)
                }
            }
        }
    }

    /// The six digits, one tile each.
    ///
    /// SF PRO ROUNDED, like every other glyph in this app — `.monospacedDigit()` gives the
    /// fixed advance width a PIN needs without switching typeface. A true monospaced face was
    /// the first attempt and it was wrong: it is the only place in Voiid where the type would
    /// change identity, and it changes it on the screen whose whole job is to be read aloud
    /// accurately by someone looking at their own app.
    ///
    /// Tiles rather than one tracked string, because the reading task is "say six digits in
    /// order, out loud, to someone who is typing them". Grouping gives the eye a place to
    /// return to after each glance away at the other phone, which tracked-out text does not.
    /// Tabular figures keep the tiles from twitching if the PIN is ever re-fetched.
    private func pinDigits(_ pin: String) -> some View {
        HStack(spacing: 8) {
            ForEach(Array(pin.enumerated()), id: \.offset) { _, digit in
                Text(String(digit))
                    .font(VoiidFont.rounded(24, .semibold))
                    .monospacedDigit()
                    .foregroundStyle(VoiidColor.textPrimary)
                    .frame(maxWidth: .infinity)
                    .frame(height: 52)
                    .background(VoiidColor.fieldFill)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
            }
        }
        .padding(.horizontal, VoiidSpacing.md)
        .padding(.vertical, VoiidSpacing.md)
        // TAP TO COPY. The PIN's whole purpose is to reach another person, and saying it out
        // loud is only one of the two ways to do that — the other is pasting it into whatever
        // app you are already talking to them in.
        .contentShape(Rectangle())
        .onTapGesture {
            UIPasteboard.general.string = pin
            Haptics.success()
            withAnimation(.spring(duration: 0.3, bounce: 0.1)) { copiedPin = true }
            Task {
                try? await Task.sleep(for: .seconds(2))
                withAnimation { copiedPin = false }
            }
        }
        // One element to VoiceOver, read as digits rather than as a number: "four one eight
        // three zero two", not "four hundred eighteen thousand".
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Your Contact PIN")
        .accessibilityValue(pin.map(String.init).joined(separator: " "))
        .accessibilityHint("Double tap to copy")
    }

    private func row<C: View>(@ViewBuilder _ content: () -> C) -> some View {
        content()
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, VoiidSpacing.md)
            .padding(.vertical, VoiidSpacing.md)
    }

    // MARK: Share

    private func shareButton(link: URL) -> some View {
        // Shares the LINK, not an image of the code: a URL survives being pasted into any
        // app, and the recipient's camera is not involved at all.
        ShareLink(item: link) {
            HStack(spacing: VoiidSpacing.sm) {
                Image(systemName: "square.and.arrow.up")
                Text("Share link")
            }
            .font(VoiidFont.rounded(16, .semibold))
            .foregroundStyle(.white)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 15)
            // SOLID, because this is the only action on the screen and a tinted ghost button
            // with nothing to outrank reads as disabled. Everything else here is something to
            // look at or read out; this is the one thing to press.
            .background(VoiidColor.accent)
            .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.lg, style: .continuous))
        }
    }

    private var noUsernameCard: some View {
        VoiidCardSection(
            footer: "A code needs a username to point at. Set one in Edit Profile and it "
                  + "will appear here."
        ) {
            row {
                Text("You haven’t set a username yet.")
                    .font(.body)
                    .foregroundStyle(VoiidColor.textPrimary)
            }
        }
    }

    // MARK: Work

    private func loadPin() async {
        loadingPin = true
        pinState = try? await ContactPinService.shared.state()
        loadingPin = false
    }

    /// Same generator the event tickets use. Correction level H because this is read off a
    /// screen at an angle, in bad light, with glare — and nearest-neighbour upscaling keeps
    /// the modules square, which scans better than a smoothed image.
    private static func qr(_ value: String) -> Image? {
        let context = CIContext()
        let filter = CIFilter.qrCodeGenerator()
        filter.message = Data(value.utf8)
        filter.correctionLevel = "H"
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        guard let cg = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return Image(decorative: cg, scale: 1)
    }
}
