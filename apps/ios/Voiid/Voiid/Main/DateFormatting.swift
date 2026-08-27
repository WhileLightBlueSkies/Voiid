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

    /// Relative "last seen" phrasing: "just now", "5m ago", "today at 9:41 AM",
    /// "yesterday", else a date.
    static func relative(_ date: Date) -> String {
        let secs = Date().timeIntervalSince(date)
        if secs < 60 { return "just now" }
        if secs < 3600 { return "\(Int(secs / 60))m ago" }
        let cal = Calendar.current
        if cal.isDateInToday(date) { return "today at \(time.string(from: date))" }
        if cal.isDateInYesterday(date) { return "yesterday" }
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

/// Display-name shortening.
///
/// Lives here rather than in each screen because three files had already grown their own
/// copy of `split(separator: " ").first` and they were starting to disagree about the edge
/// cases below.
enum VoiidName {

    /// The first name, for surfaces where the full name will not fit.
    ///
    /// A chat grid tile is ~110pt wide, so "Priyanshu Bhattacharya" either wrapped to two
    /// lines and crowded out the photo, or shrank to an unreadable size. The first name is
    /// what people actually call each other anyway.
    ///
    /// Four cases the naive `split(" ").first` gets wrong, and why each is handled:
    ///
    ///  * **A group or Note to Self.** These are titles, not people — "Design Team" must not
    ///    become "Design". The caller decides by passing `isPerson: false`.
    ///  * **A phone number or @handle.** "+91 98765 43210" would truncate to "+91", which
    ///    identifies nobody. Anything that does not start with a letter is returned whole.
    ///  * **A one-word name.** Returned unchanged — the guard exists so the result is never
    ///    empty.
    ///  * **A leading title.** "Dr Nehal" reads better shortened to "Dr Nehal" than to "Dr",
    ///    so a very short first token is kept with the one after it.
    static func short(_ full: String, isPerson: Bool = true) -> String {
        let trimmed = full.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isPerson, !trimmed.isEmpty else { return trimmed }

        // Not a person's name in the usual sense: a number, a handle, an emoji-led label.
        guard let first = trimmed.unicodeScalars.first,
              CharacterSet.letters.contains(first) else { return trimmed }

        let parts = trimmed.split(separator: " ", omittingEmptySubsequences: true)
        guard let head = parts.first else { return trimmed }

        // "Dr", "Mr", "Sr" — a two-letter opener is a title, not a name.
        if head.count <= 2, parts.count > 1 {
            return "\(head) \(parts[1])"
        }
        return String(head)
    }
}
