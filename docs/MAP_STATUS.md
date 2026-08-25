# The Map — what is built, what is not

Living document. Updated as the Map is rebuilt against the Voiid UI reference
("/Users/devacc/Voiid Ui/.../Chat/FriendsMapScreen.swift" and siblings).

---

## The rule this document exists to protect

The reference is a **mockup**. It has a hardcoded Toronto coordinate, four fake
friends, and no networking. Voiid's map has ~1,500 lines of real end-to-end
encryption underneath it.

**The UI is rebuilt from the reference. The engine is not touched.**

Anything below marked ENGINE is load-bearing privacy machinery. If a change
would delete or weaken one of these, it is a product decision that needs an
explicit conversation, not a refactor.

---

## ENGINE — built, working, must survive any UI rewrite

| Piece | File | What it guarantees |
|---|---|---|
| Presence engine | `Networking/MapPresenceEngine.swift` | Mints a fresh 32-byte `mapKey` per visibility session, delivered to each audience member over the 1:1 Double Ratchet. The server never sees it. |
| Ghost Mode | same | A **hard local gate**. While ghosted no fix is emitted, and the provider is stopped so none is even taken. Leaving ghost mints a *fresh* key, so the ghosted period is cryptographically dark. |
| Key store | `Networking/MapKeyStore.swift` | Keychain-held share keys. |
| Presence store | `Storage/MapPresenceStore.swift` | Latest fix per contact. No trail, no history — by design. |
| Location provider | `Networking/MapLocationProvider.swift` | Coarsened fixes (3 dp ≈ 110 m), accuracy floored at 100 m. |
| Share API | `Networking/MapShareAPI.swift` | create / extend / revoke-target / leave / end. |
| Visibility state | `Networking/MapVisibilityState.swift` | The ghost flag other surfaces read. |
| Wire envelope | `Models/MapModels.swift` | `MapEnvelope` — cross-platform with Android. See the decode-throw warnings in that file before touching it. |

### The engine's public surface — the new UI binds to exactly this

```
@Published presences, inboundSenders, audience, outboundShareId,
           outboundExpiresAt, lastError

goVisible(to:)        enterGhost(_:)       leaveGhost()
addToAudience(_:)     removeFromAudience(_:)
extendOutboundShare(by:)  projectedExpiry(adding:)  killSwitch()
state(forSender:now:)  reloadFromStore()
noteBackgrounded()     noteForegrounded()
handleMapControl(kind:fromUserId:shareId:)  configureControlSender()
```

### Honest limits, stated where they live
- **No forward secrecy within a session.** Whoever holds `mapKey` can decrypt
  every fix until it rotates (ghost / revoke / kill). Across sessions it holds,
  because each session mints a fresh random key.
- Fixes are never persisted server-side.

---

## UI — being rebuilt from the reference

| Screen | State |
|---|---|
| Intro | Built. Headline, code-drawn illustration, three privacy promises. Footer pinned outside the ScrollView so nothing clips at 667pt (the reference's own layout does clip). |
| Privacy / permission | Built. "What Voiid does" vs "never does"; names *While Using the App* explicitly because "Allow Once" looks safest and kills the feature by next launch. Handles prior-denial (no prompt shown) instead of hanging. |
| Onboarding flow | Built. Skips the privacy step when already authorised; marks onboarding done on every exit path. |
| Map tab | **Built and wired.** The ported reference screen (`Main/Map/Reference/FriendsMapScreen.swift`) runs on the real engine: `MapStore` in `ReferenceMapModels.swift` is now a live read-only adapter over `MapPresenceEngine` / `MapVisibilityState` / `MapLocationProvider` / `MapMoveEngine` / `UserDirectory`. `MapTabView` stays the shell that owns the sheets, dialogs and navigation. |
| Move | Built. Destination + ETA ride the existing E2EE envelope; server blind. Android envelope updated to match. |
| Map settings | Built. `Main/Map/MapSettingsView.swift`, on the Settings card vocabulary. Ghost Mode (the same binding `PrivacySettingsView` uses — one gate, one shape), who-can-see-me and the active share (both open the existing `MapAudienceSheet(mode: .manage)` rather than duplicating its countdown / add-time / revoke), map style, and the kill switch behind a confirmation. Reached from the search row's `slider.horizontal.3` control, which was an empty closure. |
| Map style | Built. `VoiidMapStyle` in `ReferenceMapModels.swift` — Standard / Hybrid / Satellite, persisted at `voiid.map.style`, shared by the map's layers control and Map settings so both entry points are one setting. Standard keeps `pointsOfInterest: .excludingAll`; MapKit's POI markers are the same size and shape as the friend pins. |
| Map activity (bell) | Built. `Main/Map/MapNotificationsView.swift`. Not a feed — see the NOT-built table below. |

---

## NOT built — and why

Each of these is in the reference and is deliberately absent here. None is an
oversight; all would require inventing data Voiid does not have.

| Reference element | Why not |
|---|---|
| Battery % on the friend card | Not on Voiid's wire. Would be fabricated. **Chip and field both deleted** from the ported card (Aug 2026) so no one re-adds it from the reference. |
| Favourite star | No favourites concept in the directory. The view is kept (signed-off UI) but `isFavourite` is always false, so it never lights up. |
| Call button on the card | The call stack needs a conversation context the card does not carry. Kept in the ported card, routed to the SAME conversation-gated path as Message (opens the chat), and disabled under the same condition. It never dials from the map. |
| Filter chips: Places, Hangouts, Move | No backend for any of the three. All four chips are kept, but the three without a backend draw NO pins and show their own "not available yet" line — never the friends list under another label. |
| Notification bell's "3" badge | **Badge removed (Aug 2026).** There is no notification feed of any kind for the Map — `.voiidMapControlReceived` is transient and consumed by the engine, and `MapPresenceStore` keeps no history by design. The bell now pushes `Main/Map/MapNotificationsView.swift`, which states current Map activity (who is sharing, who is waiting on a first fix, when my own share lapses) rather than pretending to be a feed. Do not re-add the badge unless a real count exists to source it from. |
| Route polyline on the viewer's map | The viewer holds no route. A straight line between two pins shows a path they are not taking. |
| "Notify me on arrival" | Needs a background wake this feature does not have. A toggle that silently never fires is worse than none. |

---

## Open work

1. **`VoiidBrand.lime` holds `#13828C`.** The name is legacy from the Electric
   Lime palette; the value is Peacock teal. A constant called `lime` holding
   teal is a trap for the next reader. Rename when convenient — ~60 call sites.
2. **Move has never been seen running.** It builds and the envelope is
   wire-compatible, but no one has watched a real journey render.
3. **Migrations 047 and 048 are unapplied** (community home, creator
   highlights). Unrelated to the Map, tracked here so it is not forgotten.
