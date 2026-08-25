//
//  AvailabilityStatus.swift
//  Voiid
//
//  The availability status a person sets for themselves — `users.status_text`.
//
//  A CLOSED SET, NOT FREE TEXT, and the reason is not tidiness.
//  ------------------------------------------------------------
//  The column has been `text` since migration 001, so free text was available and was
//  deliberately not taken. A status is shown to people the owner may never have met:
//  `GET /users/:id` serves it to anyone the privacy scope allows, so a free-text status is
//  user-generated content facing strangers. That needs a length cap, a moderation queue and
//  a `reports.ts` target type to go with it — none of which exist for this field. `bio`
//  already occupies the "write something about yourself" slot and already travels with the
//  user as a reportable subject; a second free-text surface would buy nothing and cost a
//  moderation surface.
//
//  A closed set is also the only shape that can be localised, ordered, and drawn as a
//  coloured dot beside a name. An arbitrary sentence can be none of those.
//
//  WHAT IT DOES: NOTHING BUT SHOW.
//  -------------------------------
//  No case here changes how a message, call or notification behaves. The push path never
//  reads this column and there is no server code that branches on it. `doNotDisturb` in
//  particular does NOT silence anything — it is a label that asks people to hold off, in the
//  same way a closed office door does.
//
//  That is why `honestFooter` exists and why every surface that offers this control is
//  required to render it. A control named "Do Not Disturb" that does not mute is a lie the
//  name tells on its own; the copy has to take it back explicitly, in the user's own terms,
//  before they rely on it. This app already labels this way everywhere else — paid events
//  answer 501, the lobby's voice toggle is documented as having no transport — and a status
//  that looked like a mute control and wasn't would be the one place it stopped being true.
//

import SwiftUI

/// The four statuses the server accepts. Raw values are the wire vocabulary and MUST stay in
/// step with `STATUS_VALUES` in `backend/api/src/routes/users.ts`, which rejects anything else
/// with a 400 — this enum is a convenience for building the request, never the authority on
/// what is valid.
enum AvailabilityStatus: String, CaseIterable, Identifiable, Hashable {
    case available
    case busy
    case away
    case doNotDisturb = "dnd"

    var id: String { rawValue }

    /// What the user reads. Sentence case, matching every other row on these screens.
    var label: String {
        switch self {
        case .available:    return "Available"
        case .busy:         return "Busy"
        case .away:         return "Away"
        case .doNotDisturb: return "Do not disturb"
        }
    }

    /// The swatch beside the label.
    ///
    /// `warning` for Away rather than a fifth colour: the palette has exactly three status
    /// tones and inventing one for this would put a colour on screen that means nothing
    /// anywhere else in the app.
    var tint: Color {
        switch self {
        case .available:    return VoiidColor.success
        case .busy:         return VoiidColor.error
        case .away:         return VoiidColor.warning
        case .doNotDisturb: return VoiidColor.error
        }
    }

    /// A filled glyph for the row's icon column, where a bare dot would be too quiet.
    var systemImage: String {
        switch self {
        case .available:    return "circle.fill"
        case .busy:         return "minus.circle.fill"
        case .away:         return "moon.fill"
        case .doNotDisturb: return "moon.zzz.fill"
        }
    }

    /// Decode a server value. Unknown strings — a status added by a newer build, or the
    /// arbitrary text some pre-existing row could still hold, since nothing ever validated
    /// this column before now — become nil rather than being rendered raw. Showing a stranger
    /// unvetted text from a column that was never moderated is exactly the risk a closed set
    /// was chosen to avoid, so an unrecognised value shows as no status at all.
    static func from(_ raw: String?) -> AvailabilityStatus? {
        guard let raw, !raw.isEmpty else { return nil }
        return AvailabilityStatus(rawValue: raw)
    }
}

extension AvailabilityStatus {
    /// The sentence that must accompany any control offering these.
    ///
    /// Not optional and not a nicety: see the file header. Kept here, next to the cases, so a
    /// future surface that adds this picker inherits the disclaimer rather than having to
    /// remember it.
    static let honestFooter =
        "Your status is a label other people see on your profile. It doesn't change anything "
        + "else — even Do not disturb still delivers messages, calls and notifications "
        + "normally. Only people who can see your last seen can see your status."
}
