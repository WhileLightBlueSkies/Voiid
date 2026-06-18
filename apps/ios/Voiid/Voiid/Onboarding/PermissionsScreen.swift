//
//  PermissionsScreen.swift
//  Voiid
//
//  Upfront permissions (spec: requested at first launch, before login). iOS shows
//  one native dialog per permission, so "Allow access" requests them in sequence:
//  contacts, camera, microphone, photos, notifications. Best-effort — the user may
//  deny any; we continue regardless and re-ask in-context where a feature needs it.
//

import SwiftUI
import Contacts
import AVFoundation
import Photos
import UserNotifications

struct PermissionsScreen: View {
    let onContinue: () -> Void
    @State private var requesting = false

    private let rows: [(icon: String, title: String, desc: String)] = [
        ("person.crop.circle", "Contacts", "Find friends already on Voiid (matched on-device, never uploaded)."),
        ("camera.fill", "Camera", "Take photos and videos for chats and clips."),
        ("mic.fill", "Microphone", "Record voice messages and clips."),
        ("photo.on.rectangle", "Photos & media", "Share images and videos."),
        ("bell.fill", "Notifications", "Get notified about new messages and calls."),
    ]

    var body: some View {
        ZStack {
            VoiidBackground()
            VStack(alignment: .leading, spacing: 0) {
                Spacer().frame(height: 48)
                Text("Enable permissions")
                    .font(VoiidFont.rounded(28, .bold))
                    .foregroundColor(VoiidColor.textPrimary)
                    .padding(.horizontal, VoiidSpacing.lg)
                Text("Voiid needs a few permissions to work. You're always in control.")
                    .font(VoiidFont.rounded(15, .regular))
                    .foregroundColor(VoiidColor.textSecondary)
                    .padding(.horizontal, VoiidSpacing.lg)
                    .padding(.top, 6).padding(.bottom, VoiidSpacing.sm)

                Spacer().frame(height: 16)
                ForEach(rows, id: \.title) { r in
                    HStack(spacing: 14) {
                        Image(systemName: r.icon)
                            .font(.system(size: 22)).foregroundColor(VoiidColor.primary)
                            .frame(width: 28)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(r.title).font(VoiidFont.rounded(16, .semibold)).foregroundColor(VoiidColor.textPrimary)
                            Text(r.desc).font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.textSecondary)
                        }
                    }
                    .padding(.horizontal, VoiidSpacing.lg).padding(.vertical, 10)
                }

                Spacer()

                Button(action: { Task { await requestAll() } }) {
                    Group {
                        if requesting { ProgressView().tint(VoiidColor.textPrimary) }
                        else { Text("Allow access").font(VoiidFont.rounded(18, .medium)) }
                    }
                    .foregroundColor(VoiidColor.textPrimary)
                    .frame(maxWidth: .infinity).frame(height: 64)
                    .background(VoiidColor.accent)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.pill, style: .continuous))
                }
                .buttonStyle(SoftPressStyle())
                .disabled(requesting)
                .padding(.horizontal, VoiidSpacing.lg).padding(.bottom, VoiidSpacing.sm)

                Text("You can change these later in Settings.")
                    .font(VoiidFont.rounded(12, .regular)).foregroundColor(VoiidColor.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.bottom, VoiidSpacing.lg)
            }
        }
        .navigationBarBackButtonHidden(true)
    }

    /// Request each permission in sequence (each shows its own native dialog),
    /// then continue regardless of the choices. Callback-based system APIs are
    /// wrapped in continuations so this compiles reliably.
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

        Haptics.success()
        requesting = false
        onContinue()
    }
}
