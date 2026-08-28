//
//  MuteStore.swift
//  Voiid
//
//  Which conversations are muted, and until when.
//
//  ── WHY THE APP GROUP AND NOT UserDefaults.standard ─────────────────────────────
//  A muted conversation must stay silent when the app is not running — which is exactly
//  when it matters. Incoming messages are decrypted and presented by the NSE, a SEPARATE
//  PROCESS, and that process cannot see the app's private defaults. Storing mute state
//  anywhere else means it works only while the app is in the foreground, which is the one
//  case where the user can already see the message.
//
//  ── EXPIRY IS COMPUTED, NOT SCHEDULED ───────────────────────────────────────────
//  A mute has an end DATE; nothing has to fire when it passes. Scheduling an un-mute would
//  mean a timer that must survive a terminated app, a reboot, and a restore — all to
//  reproduce what a date comparison answers for free. `isMuted` reads the clock.
//

import Foundation

enum MuteStore {

    /// How long a mute lasts. `always` has no end date.
    enum Duration: String, CaseIterable, Identifiable {
        case eightHours, oneDay, oneWeek, always

        var id: String { rawValue }

        var title: String {
            switch self {
            case .eightHours: return "8 hours"
            case .oneDay:     return "24 hours"
            case .oneWeek:    return "1 week"
            case .always:     return "Until I turn it back on"
            }
        }

        var seconds: TimeInterval? {
            switch self {
            case .eightHours: return 8 * 3600
            case .oneDay:     return 24 * 3600
            case .oneWeek:    return 7 * 24 * 3600
            case .always:     return nil
            }
        }
    }

    private static let key = "voiid.muted.conversations"

    /// Shared with the NSE. Falls back to standard defaults only so a mis-provisioned build
    /// still behaves sanely in the foreground rather than crashing.
    private static var store: UserDefaults {
        UserDefaults(suiteName: AppGroup.identifier) ?? .standard
    }

    /// `conversationId -> end timestamp`. A value of 0 means "always".
    private static var table: [String: Double] {
        get { store.dictionary(forKey: key) as? [String: Double] ?? [:] }
        set { store.set(newValue, forKey: key) }
    }

    static func mute(_ conversationId: String, for duration: Duration) {
        var t = table
        t[conversationId] = duration.seconds.map { Date().timeIntervalSince1970 + $0 } ?? 0
        table = t
    }

    static func unmute(_ conversationId: String) {
        var t = table
        t.removeValue(forKey: conversationId)
        table = t
    }

    /// Is this conversation silent right now?
    ///
    /// Expired entries are cleaned up as they are read rather than swept: the read already
    /// has the answer, and a sweep would need somewhere to run from.
    static func isMuted(_ conversationId: String) -> Bool {
        guard let until = table[conversationId] else { return false }
        if until == 0 { return true }                      // always
        if Date().timeIntervalSince1970 < until { return true }
        unmute(conversationId)
        return false
    }

    /// When the mute ends, for the UI to say so. Nil when not muted or muted forever.
    static func mutedUntil(_ conversationId: String) -> Date? {
        guard let until = table[conversationId], until != 0 else { return nil }
        let date = Date(timeIntervalSince1970: until)
        return date > Date() ? date : nil
    }
}
