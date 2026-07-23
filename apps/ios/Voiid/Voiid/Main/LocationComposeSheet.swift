//
//  LocationComposeSheet.swift
//  Voiid
//
//  Compose a location to send into a conversation (docs/LOCATION.md §4, §8). Two modes:
//   • Pin  — one-off coordinate + an optional user-typed label (NEVER geocoded).
//   • Live — time-bounded sharing, 15 min / 1 hour / 8 hours (no indefinite option).
//
//  The audience is named EXPLICITLY above the duration picker, so nobody shares live
//  location without seeing exactly who will receive it. Authorization is requested here,
//  in-context, at the moment of first share — never at onboarding: WhenInUse when the
//  sheet opens, escalating to Always only when a duration > 15 min is chosen.
//

import SwiftUI
import CoreLocation

struct LocationComposeSheet: View {
    let conversationTitle: String
    let isGroup: Bool
    /// How many people will see it (group member count minus you, or 1 for a 1:1).
    let audienceCount: Int

    /// Send a static pin with an optional label.
    var onSendPin: (String?) -> Void
    /// Start a live share for the chosen duration.
    var onStartLive: (ShareDuration) -> Void

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var engine = LocationShareEngine.shared

    enum Mode { case pin, live }
    @State private var mode: Mode = .pin
    @State private var label = ""
    @State private var duration: ShareDuration = .oneHour
    @State private var sending = false

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: VoiidSpacing.lg) {
                    modePicker
                    if mode == .pin { pinSection } else { liveSection }
                    if deniedForBackground { backgroundDeniedNote }
                }
                .padding(VoiidSpacing.lg)
            }
            .background(VoiidColor.background.ignoresSafeArea())
            .navigationTitle("Share location").navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarLeading) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .topBarTrailing) {
                    Button(mode == .pin ? "Send" : "Share") { commit() }
                        .fontWeight(.semibold).disabled(sending || !authorizedEnough)
                }
            }
            .onAppear {
                // In-context WhenInUse prompt the moment the user reaches for location.
                if engine.authorizationStatus == .notDetermined { engine.requestWhenInUse() }
            }
        }
        .preferredColorScheme(.light)
        .tint(VoiidColor.primary)
    }

    private var modePicker: some View {
        Picker("", selection: $mode) {
            Text("Pin").tag(Mode.pin)
            Text("Live").tag(Mode.live)
        }
        .pickerStyle(.segmented)
    }

    // MARK: - Pin

    private var pinSection: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            Text("Send your current location as a pin. It stays fixed — it does not update.")
                .font(VoiidFont.rounded(13, .regular)).foregroundColor(VoiidColor.textSecondary)
            TextField("", text: $label,
                      prompt: Text("Add a label (optional)").foregroundColor(VoiidColor.placeholder))
                .font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
                .padding(.horizontal, VoiidSpacing.md).frame(height: 50)
                .background(VoiidColor.fieldFill)
                .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md).stroke(VoiidColor.fieldBorder, lineWidth: 1))
        }
    }

    // MARK: - Live

    private var liveSection: some View {
        VStack(alignment: .leading, spacing: VoiidSpacing.md) {
            // The audience, named explicitly.
            Text(audienceLine)
                .font(VoiidFont.rounded(14, .medium)).foregroundColor(VoiidColor.textPrimary)
            Text("For how long?")
                .font(VoiidFont.rounded(13, .semibold)).foregroundColor(VoiidColor.textSecondary)
            ForEach(ShareDuration.allCases) { d in
                Button {
                    Haptics.selection(); duration = d
                    // Escalate to Always only for > 15 min so it keeps running in background.
                    if d.needsAlways, engine.authorizationStatus == .authorizedWhenInUse {
                        engine.requestAlways()
                    }
                } label: {
                    HStack {
                        Text(d.label).font(VoiidFont.rounded(16, .regular)).foregroundColor(VoiidColor.textPrimary)
                        Spacer()
                        if duration == d { Image(systemName: "checkmark").foregroundColor(VoiidColor.primary) }
                    }
                    .padding(.horizontal, VoiidSpacing.md).frame(height: 50)
                    .background(duration == d ? VoiidColor.fieldFill : VoiidColor.surfaceCard)
                    .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
                    .overlay(RoundedRectangle(cornerRadius: VoiidRadius.md).stroke(VoiidColor.fieldBorder, lineWidth: 1))
                }
                .buttonStyle(.plain)
            }
            Text("Sharing stops automatically when the timer ends. You can stop it any time from the banner.")
                .font(VoiidFont.rounded(12, .regular)).foregroundColor(VoiidColor.textSecondary)
        }
    }

    private var audienceLine: String {
        if isGroup {
            return "Everyone in \(conversationTitle) (\(audienceCount) \(audienceCount == 1 ? "person" : "people")) will see your live location."
        }
        return "\(conversationTitle) will see your live location."
    }

    // MARK: - Background-denied disclosure

    /// True when a background-capable duration is chosen but Always was denied — the share
    /// will run foreground-only, and we say so rather than let it silently pause.
    private var deniedForBackground: Bool {
        mode == .live && duration.needsAlways && engine.authorizationStatus == .authorizedWhenInUse
    }

    private var backgroundDeniedNote: some View {
        HStack(spacing: VoiidSpacing.sm) {
            Image(systemName: "info.circle").foregroundColor(VoiidColor.warning)
            Text("Live location pauses when you leave Voiid — allow Always in Settings to keep it running in the background.")
                .font(VoiidFont.rounded(12, .regular)).foregroundColor(VoiidColor.textSecondary)
        }
        .padding(VoiidSpacing.md)
        .background(VoiidColor.fieldFill)
        .clipShape(RoundedRectangle(cornerRadius: VoiidRadius.md, style: .continuous))
    }

    // MARK: - Commit

    /// Location works even with reduced accuracy (labelled Approximate elsewhere); the
    /// only hard requirement is that location isn't fully denied.
    private var authorizedEnough: Bool {
        switch engine.authorizationStatus {
        case .authorizedAlways, .authorizedWhenInUse, .notDetermined: return true
        default: return false
        }
    }

    private func commit() {
        sending = true
        Haptics.success()
        switch mode {
        case .pin:  onSendPin(label.trimmingCharacters(in: .whitespaces).isEmpty ? nil
                              : label.trimmingCharacters(in: .whitespaces))
        case .live: onStartLive(duration)
        }
        dismiss()
    }
}
