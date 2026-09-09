# Option A in Voiid iOS — 2026-09-09

The approved Quick design is integrated into the real chat transcript. Long-press
uses `UIContextMenuInteraction`, six quick reactions, native additional palettes,
and system Reply / Forward / Copy / Info / Select / Delete rows. The existing full
emoji picker opens after the native menu finishes dismissing.

Bubble improvements:

- Short text keeps its timestamp inline; long text uses the full available line
  width with metadata below. Body text follows Dynamic Type.
- Quoted replies keep bounded height inside the native preview.
- Reaction badges use native `UIButton` controls with their own layout space and a
  minimum 44-point touch target.
- Each badge announces the emoji, count, ownership and add/remove action.
- Horizontal reply gestures reject vertical motion; the decorative reply indicator
  never receives touches, and its animation respects Reduce Motion.

Reactions retain the existing encrypted wire format and per-user engine map.
The UI now preserves both participants’ reactions, toggles only the current user's
entry, serializes sends per message, and overlays the latest pending choice during
periodic sync. A failed final send restores confirmed state and shows an error.
Pending/failed outgoing messages cannot receive reactions; group reactions remain
unavailable because the current send path is direct-chat only.

Validation is provided by `apps/ios/checks/ChatInteractionQA` and
`apps/ios/checks/MessageReactionsCheck.swift`. The UI harness uses actual production
bubble/menu sources with isolated data. Device-to-device delivery, offline recovery
and media interactions still require two-account QA; no frame-rate claim is made.

Verified on 2026-09-09:

- Signed Debug build of the real Voiid iOS app: passed.
- Production reaction-data checks: passed.
- Three isolated iOS UI tests: passed (native reactions/actions, additional emoji
  palette/sheet, and reply gestures/deleted-message actions).
- Result bundle: `/private/tmp/voiid-chat-qa-native-badges.xcresult`.
- Installed the signed app (`in.voiid.app`) on Nehal’s iPhone 15.
