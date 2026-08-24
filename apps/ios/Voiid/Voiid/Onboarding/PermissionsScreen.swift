//
//  PermissionsScreen.swift
//  Voiid
//
//  Allow Permissions — the onboarding step after Terms.
//
//  Built to the design source (`Voiid Ui/Screens/PermissionsScreen.swift`) through
//  `OnboardingKit`, so the sizes, paddings and weights are the reference's own numbers. The
//  header is the WORDMARK at 34pt, matching Terms — the two screens sit back to back and a
//  header that changes between them reads as a different app.
//
//  ── UNIFORM WITH TERMS ──────────────────────────────────────────────────────────
//  ONE card with hairline dividers, not a card per permission. Every shared shape — header,
//  card, row, footer, primary button — comes from OnboardingKit, so the two screens cannot
//  drift apart. Only what genuinely differs lives here: the rows WRAP their subtitles
//  (`subtitleWraps: true`), which is why the scroll clears 210pt rather than Terms' 190.
//
//  ── THIS SCREEN DOES REQUEST PERMISSIONS ────────────────────────────────────────
//  The design source is a UI pass whose closures are empty seams. The real requests live here
//  and are UNCHANGED by the restyle: contacts, camera, microphone, photos, notifications, in
//  sequence. iOS shows one modal per permission and each needs its own usage string in
//  Info.plist or the app traps on the first ask, so "Allow All" means "ask me for all of them"
//  rather than granting anything at once.
//
//  ── LOCATION IS LISTED BUT NOT REQUESTED HERE, AND THAT IS ON PURPOSE ────────────
//  The design lists Location, so it is shown: hiding it would misrepresent what the app uses.
//  But `MapLocationProvider.requestWhenInUse()` carries an explicit decision in its own doc
//  comment — "In-context, at the moment the user chooses to be visible — never at onboarding" —
//  and asking for someone's location on the first screen, before they have even signed in, is
//  the request most likely to be denied permanently. iOS gives one chance: a denial here is a
//  trip to Settings later.
//
//  So the row explains what Location is for and the Map asks when the user turns visibility on.
//  If the intent really is to prompt upfront, add the call to `requestAll()` and delete this
//  paragraph — but that reverses a deliberate call, so it should be a decision rather than a
//  side effect.
//

import SwiftUI
import Contacts
import AVFoundation
import Photos
import UserNotifications

struct PermissionsScreen: View {
    let onContinue: () -> Void

    @State private var requesting = false

    var body: some View {
        ZStack {
            VoiidBrand.ground.ignoresSafeArea()

            ScrollView {
                VStack(spacing: 0) {
                    OnboardingHeader(
                        title: "Allow ",
                        accent: "Permissions",
                        // Line-broken to match the reference rather than left to wrap. Free
                        // wrapping gave three ragged lines and pushed the sixth row under the
                        // footer; these breaks hold it to three even lines and recover the room.
                        blurb: "To give you the best experience, Voiid needs\na few permissions. You can change these anytime\nin your device settings."
                    )

                    OnboardingKitCard {
                        ForEach(Array(AppPermission.all.enumerated()), id: \.element.id) { index, permission in
                            OnboardingRow(
                                icon: permission.icon,
                                title: permission.title,
                                subtitle: permission.detail,
                                // Wraps, unlike Terms' labels — see OnboardingRow.
                                subtitleWraps: true,
                                // No chevron: these rows are a LIST OF WHAT WILL BE ASKED, not
                                // six things to tap. Nothing opens, and firing one system prompt
                                // out of sequence would spend that permission's single chance —
                                // the whole run belongs to Allow All.
                                showsChevron: false
                            ) {}

                            if index < AppPermission.all.count - 1 {
                                OnboardingRowDivider()
                            }
                        }
                    }
                    .padding(.top, VoiidSpacing.lg)
                }
                .padding(.horizontal, VoiidSpacing.lg)
                // Larger than Terms' 190 despite a shorter footer: these subtitles WRAP, so
                // the card is taller and the last row was landing under the fade. Measured
                // against this screen's own footer, not inherited from the other one.
                .padding(.bottom, 210)
            }
            .scrollIndicators(.hidden)

            VStack(spacing: 0) {
                Spacer(minLength: 0)

                OnboardingFooter {
                    OnboardingKitButton(title: "Allow All", enabled: !requesting) {
                        Task { await requestAll() }
                    }

                    // "Not now" is a real, reachable choice, not a greyed-out afterthought. A
                    // priming screen that hides its decline is a dark pattern — and iOS hands the
                    // user the same refusal in the system prompt anyway, so hiding it buys
                    // nothing but distrust.
                    Button {
                        Haptics.tap()
                        onContinue()
                    } label: {
                        Text("Not now")
                            .font(VoiidFont.rounded(16, .regular))
                            .foregroundColor(VoiidColor.textSecondary)
                            .padding(.vertical, 6)
                            .frame(maxWidth: .infinity)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressableButtonStyle())
                    .disabled(requesting)
                }
            }
            .ignoresSafeArea(edges: .bottom)
        }
        .preferredColorScheme(.dark)
        // The wordmark is the screen's title, so the bar carries no duplicate — only the back
        // button. Inline keeps the bar the height of that control alone.
        .navigationBarTitleDisplayMode(.inline)
        .toolbarBackground(.hidden, for: .navigationBar)
    }

    // MARK: Requests

    /// Ask for each permission in turn. Best-effort — the user may deny any; we continue
    /// regardless and re-ask in-context where a feature needs it.
    private func requestAll() async {
        guard !requesting else { return }
        requesting = true

        await withCheckedContinuation { cont in
            CNContactStore().requestAccess(for: .contacts) { _, _ in cont.resume() }
        }
        _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .video) { cont.resume(returning: $0) }
        }
        _ = await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            AVCaptureDevice.requestAccess(for: .audio) { cont.resume(returning: $0) }
        }
        await withCheckedContinuation { cont in
            PHPhotoLibrary.requestAuthorization(for: .readWrite) { _ in cont.resume() }
        }
        _ = try? await UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound, .badge])

        // Location is deliberately absent — see the header note.

        Haptics.success()
        requesting = false
        onContinue()
    }
}

// MARK: - The permissions

/// The permissions this app primes for, in the order the reference shows them.
///
/// NOT alphabetised, unlike the Terms documents. The order is deliberate: the ones the app leans
/// on most come first, and Contacts — the most personal ask, and the only one marked optional —
/// comes last, where a user who is uneasy has already seen the reasonable ones.
struct AppPermission: Identifiable, Hashable {
    let id: String
    let title: String
    let detail: String
    let icon: String

    static let all: [AppPermission] = [
        // `location`, not `mappin.and.ellipse`. The latter stacks a pin ON an ellipse — two
        // shapes inside a 17pt glyph, which at this size collapses into an unreadable blob.
        // Every other icon in the column is a single shape; this now matches.
        .init(id: "location",
              title: "Location",
              detail: "Shows you relevant content and nearby features.",
              icon: "location"),
        .init(id: "notifications",
              title: "Notifications",
              detail: "Keeps you updated on activity and offers.",
              icon: "bell"),
        .init(id: "camera",
              title: "Camera",
              detail: "Lets you capture and share moments.",
              icon: "camera"),
        .init(id: "microphone",
              title: "Microphone",
              detail: "Enables voice features and audio notes.",
              icon: "mic"),
        .init(id: "photos",
              title: "Photos & Media",
              detail: "Lets you save, upload and share photos.",
              icon: "photo"),
        .init(id: "contacts",
              title: "Contacts",
              detail: "Helps you find and connect with people you know (optional).",
              icon: "person.crop.circle"),
    ]
}
