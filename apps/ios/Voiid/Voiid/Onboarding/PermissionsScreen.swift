//
//  PermissionsScreen.swift
//  Voiid
//
//  Upfront permissions (spec: requested at first launch, before login). Built to the brand
//  reference — shares its chrome with WelcomeTermsScreen via OnboardingBrandChrome.
//
//  iOS shows one native dialog per permission, so "Allow Access" requests them in sequence:
//  contacts, camera, microphone, photos, notifications. Best-effort — the user may deny any;
//  we continue regardless and re-ask in-context where a feature needs it.
//
//  ── LOCATION IS LISTED BUT NOT REQUESTED HERE, AND THAT IS ON PURPOSE ────────────
//  The design lists Location as a sixth row, so it is shown: hiding it would misrepresent what
//  the app uses. But `MapLocationProvider.requestWhenInUse()` carries an explicit decision in
//  its own doc comment — "In-context, at the moment the user chooses to be visible — never at
//  onboarding" — and asking for someone's location on the first screen, before they have even
//  signed in, is the request most likely to be denied permanently. iOS gives one chance: a
//  denial here is a trip to Settings later.
//
//  So the row explains what Location is for and the Map asks when the user turns visibility
//  on. If the intent really is to prompt upfront, add the call to `requestAll()` and delete
//  this paragraph — but that reverses a deliberate call, so it should be a decision rather
//  than a side effect.
//

import SwiftUI
import Contacts
import AVFoundation
import Photos
import UserNotifications

struct PermissionsScreen: View {
    let onContinue: () -> Void

    @State private var requesting = false
    @State private var appeared = false

    private struct Row: Identifiable {
        let id: String
        let glyph: String
        let title: String
        let detail: String
    }

    /// Order matches the reference: the two that find people and capture, then media, then the
    /// two that reach out to the user.
    private let rows: [Row] = [
        Row(id: "contacts", glyph: "person.crop.square", title: "Contacts",
            detail: "Find and connect with your friends"),
        Row(id: "camera", glyph: "camera", title: "Camera",
            detail: "Take photos and record videos"),
        Row(id: "mic", glyph: "mic", title: "Microphone",
            detail: "Make voice and video calls"),
        Row(id: "photos", glyph: "photo", title: "Photos & Media",
            detail: "Share photos, videos and documents"),
        Row(id: "notifications", glyph: "bell", title: "Notifications",
            detail: "Stay updated with important alerts"),
        Row(id: "location", glyph: "mappin.and.ellipse", title: "Location",
            detail: "Share your location and discover nearby"),
    ]

    var body: some View {
        ZStack {
            OnboardingBrand.ground.ignoresSafeArea()

            // Scrolls, with the button pinned — see the note in WelcomeTermsScreen. This screen
            // is the worse case of the two: SIX rows at ~72pt each, so the content is well over
            // a small phone's height before the header is counted.
            VStack(spacing: 0) {
                ScrollView(.vertical, showsIndicators: false) {
                  VStack(spacing: 0) {
                    OnboardingBrandHeader(appeared: appeared)
                        .padding(.top, 8)

                    titleBlock

                    permissionsCard
                        .padding(.horizontal, 20)
                        .padding(.top, 20)

                    privacyNote
                        .padding(.horizontal, 24)
                        .padding(.top, 18)
                        .padding(.bottom, 18)
                  }
                }

                OnboardingPrimaryButton(title: "Allow Access", busy: requesting) {
                    Task { await requestAll() }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 10)
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { withAnimation(.easeOut(duration: 0.5)) { appeared = true } }
    }

    // MARK: Title

    private var titleBlock: some View {
        VStack(spacing: 6) {
            OnboardingTitle(accented: "Voiid", trailing: " needs a few permissions")
            Text("These permissions help us give you\nthe best experience.")
                .font(VoiidFont.rounded(17, .regular))
                .foregroundColor(VoiidColor.textSecondary)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Card

    /// Flush rows with hairline dividers, not separate tiles — six tiles at this size would
    /// fill the screen with gaps and the list would lose its shape.
    private var permissionsCard: some View {
        OnboardingCard(flush: true) {
            ForEach(Array(rows.enumerated()), id: \.element.id) { index, row in
                if index > 0 {
                    Rectangle()
                        .fill(OnboardingBrand.hairline)
                        .frame(height: 1)
                }
                permissionRow(row)
            }
        }
    }

    private func permissionRow(_ row: Row) -> some View {
        HStack(spacing: 14) {
            OnboardingGlyphTile(system: row.glyph)

            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(VoiidFont.rounded(17, .semibold))
                    .foregroundColor(VoiidColor.textPrimary)
                Text(row.detail)
                    .font(VoiidFont.rounded(14, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 8)

            // Points forward, not a chevron: these rows are not navigable — nothing opens.
            // The arrow reads as "this will be requested", which is what happens.
            Image(systemName: "arrow.right")
                .font(.system(size: 16, weight: .semibold))
                .foregroundColor(VoiidColor.accent)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 14)
    }

    // MARK: Privacy note

    private var privacyNote: some View {
        OnboardingPrivacyNote(
            system: "lock.shield",
            lines: ["We respect your privacy.",
                    "You can change these permissions anytime",
                    "in your device settings."],
            accentPhrase: "device settings"
        )
    }

    // MARK: Requests

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
