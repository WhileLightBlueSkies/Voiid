//
//  DateFormatting.swift
//  Voiid
//
//  Chat timestamp + date-separator helpers (WhatsApp/iMessage-style).
//

import Foundation

enum VoiidDate {
    private static let time: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()
    private static let full: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "d MMM yyyy"; return f
    }()
    private static let weekday: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "EEEE"; return f
    }()

    /// Bubble timestamp, e.g. "9:41 AM".
    static func bubbleTime(_ date: Date) -> String { time.string(from: date) }

    /// Date separator tag inside the chat: Today / Yesterday / Monday / 12 Jun 2026.
    static func separator(_ date: Date) -> String {
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "Today" }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        if let days = cal.dateComponents([.day], from: date, to: .now).day, days < 7 {
            return weekday.string(from: date)
        }
        return full.string(from: date)
    }

    /// Chat-list preview time: time if today, "Yesterday", else date.
    static func listPreview(_ date: Date?) -> String {
        guard let date else { return "" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return time.string(from: date) }
        if cal.isDateInYesterday(date) { return "Yesterday" }
        return full.string(from: date)
    }
}
