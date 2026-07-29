//
//  ThemePreference.swift
//  Voiid
//
//  Light / Dark / System, persisted per device.
//
//  WHY THIS EXISTS: the app used to be pinned to light via `.preferredColorScheme(.light)` in
//  ContentView and five sheets, because the palette had no dark values to resolve to. Peacock
//  is fully theme-aware (see VoiidColor), so the pin is gone and the choice belongs to the
//  user — matching WhatsApp and Signal, both of which offer exactly these three options.
//
//  System is the default: an OS-level preference the user already expressed is the correct
//  starting point, and it means the app respects a scheduled night mode for free.
//

import SwiftUI
import Combine   // @Published / ObservableObject conformance

@MainActor
final class ThemePreference: ObservableObject {
    static let shared = ThemePreference()

    enum Mode: String, CaseIterable, Identifiable {
        case system, light, dark
        var id: String { rawValue }

        var label: String {
            switch self {
            case .system: return "System"
            case .light:  return "Light"
            case .dark:   return "Dark"
            }
        }

        var icon: String {
            switch self {
            case .system: return "circle.lefthalf.filled"
            case .light:  return "sun.max.fill"
            case .dark:   return "moon.fill"
            }
        }

        /// nil = follow the system. SwiftUI treats a nil `preferredColorScheme` as "inherit",
        /// which is exactly the behaviour we want for `.system`.
        var colorScheme: ColorScheme? {
            switch self {
            case .system: return nil
            case .light:  return .light
            case .dark:   return .dark
            }
        }
    }

    private static let key = "voiid.theme.mode"

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.key) }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? Mode.system.rawValue
        mode = Mode(rawValue: raw) ?? .system
    }
}
