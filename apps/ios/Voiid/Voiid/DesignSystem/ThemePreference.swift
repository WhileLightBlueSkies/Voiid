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
import UIKit    // overrideUserInterfaceStyle — see applyToWindows()

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
        didSet {
            UserDefaults.standard.set(mode.rawValue, forKey: Self.key)
            applyToWindows()
        }
    }

    private init() {
        let raw = UserDefaults.standard.string(forKey: Self.key) ?? Mode.system.rawValue
        mode = Mode(rawValue: raw) ?? .system
    }

    /// Push the choice into the UIKit window.
    ///
    /// THIS IS WHY SWITCHING THEME DID NOT RECOLOUR THE CURRENT SCREEN.
    ///
    /// `.preferredColorScheme` changes SwiftUI's environment, and a view reading
    /// `@Environment(\.colorScheme)` updates immediately. But every VoiidColor token is a
    /// `UIColor { trait in ... }` closure, and those resolve against the UIKIT trait
    /// collection — which still followed the OS. So picking Dark while the phone was in
    /// Light left the whole palette resolving light: backgrounds, cards, bubbles, all of it.
    /// The screens that DID appear to change were the ones using `@Environment(\.colorScheme)`
    /// directly (the map), which is why it looked like some pages updated and others did not.
    ///
    /// Setting `overrideUserInterfaceStyle` on the window makes UIKit agree with SwiftUI, so
    /// both resolution paths land on the same answer and the change is live and total.
    func applyToWindows() {
        let style: UIUserInterfaceStyle = {
            switch mode {
            case .system: return .unspecified
            case .light:  return .light
            case .dark:   return .dark
            }
        }()
        for scene in UIApplication.shared.connectedScenes {
            guard let ws = scene as? UIWindowScene else { continue }
            for window in ws.windows {
                // Animated so the swap reads as a deliberate transition rather than a flash.
                UIView.transition(with: window, duration: 0.25, options: .transitionCrossDissolve) {
                    window.overrideUserInterfaceStyle = style
                }
            }
        }
    }
}
