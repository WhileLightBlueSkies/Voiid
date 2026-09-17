# Navigation: back behaviour, stacks and transitions

> **Date:** 16 Sep 2026
> **Baseline:** `main` at `9fc79f3`
> **Scope:** how users move between screens on both apps: back button, back swipe, tabs, deep links, modals, transitions, and what happens to a screen you return to.
> **Reported:** (1) going back from a community Space chat lands on the main Chats grid instead of the community; (2) the back swipe on Android closes the app.
> **Both reproduced in source.** Causes below, with fixes.

---

## Summary

**iOS navigation is sound. Android navigation is the problem.**

iOS uses SwiftUI's real navigation (73 `NavigationStack`s, `navigationDestination`, swipe-back preserved deliberately — there is even a dedicated file to keep the back swipe alive when a custom back button hides it). Its issues are minor.

Android has **no navigation library at all**. No `NavHost`, no `navController`, no back stack. Every screen is a separate boolean or nullable variable in one 1,261-line composable, and "navigating" means setting a variable. There are about 20 such variables in `RootTabView` alone.

Two consequences, and they are exactly the two bugs reported:

1. **The back swipe closes the app** because Android's back gesture only knows about the Activity. Nothing tells it a screen is open, so it finishes the Activity. Only 8 screens in the whole app handle back; **39 screens have a back button but no system-back handling.**
2. **Back from a Space chat lands on the Chats grid** because opening a Space chat *switches the tab to Chats* first. Back then correctly returns you to the tab you were placed in. iOS does not do this — it pushes the chat inside the community's own stack.

The fix for both is the same piece of work: give Android one real back stack. Details in §4.

### Severity

**P0** loses the user's place or exits the app · **P1** wrong destination or no way back · **P2** inconsistent or unpolished · **P3** cosmetic.

| ID | Sev | Platform | Issue |
|---|---|---|---|
| [NV-01](#nv-01) | P0 | Android | Back swipe/button closes the app from almost every screen |
| [NV-02](#nv-02) | P0 | Android | Back from a community Space chat lands on the Chats grid |
| [NV-03](#nv-03) | P0 | Android | No back stack: navigation is ~20 loose variables |
| [NV-04](#nv-04) | P1 | Android | Back from a community exits the app instead of returning to the list |
| [NV-05](#nv-05) | P1 | Android | Navigation state is lost if the app is killed in the background |
| [NV-06](#nv-06) | P1 | Android | Deep links and notifications push you into a tab you didn't choose |
| [NV-07](#nv-07) | P2 | Android | Transitions are inconsistent: some screens animate, some appear instantly |
| [NV-08](#nv-08) | P2 | Android | No predictive-back support (Android 14+ shows no preview) |
| [NV-09](#nv-09) | P2 | Both | Scroll position and inner state reset when you return to a screen |
| [NV-10](#nv-10) | P3 | iOS | Most stacks can't be popped programmatically or deep-linked into |

---

## 1. Your first bug: back from a Space chat goes to the Chats grid

**Confirmed. Android only — iOS is correct.**

**What happens.** In a community, Spaces → open a Space chat → back. You land on the main Chats grid, not the community.

**Why.** Opening any conversation from the Communities tab changes the tab first:

```kotlin
Tab.COMMUNITIES -> CommunitiesHomeView(
    onOpenConversation = { conversationId ->
        chat.conversationById(conversationId)?.let {
            tab = Tab.CHAT; openConversation = it     // ← the bug
        }
    },
)
```
[RootTabView.kt:381-390](../../apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt#L381-L390)

Back then clears `openConversation` ([RootTabView.kt:455](../../apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt#L455)) and reveals whatever tab is selected — now Chats. Back did its job; the tab switch was the mistake. The same line appears in the Map tab ([RootTabView.kt:428](../../apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt#L428)).

The code comment says this was intentional for the **host inbox** ("Host-inbox taps land in the Chats tab like any other conversation"), and that is defensible for a host thread. But every Space chat now goes through the same callback, so a Space — which lives *inside* the community — is treated as if it were a chat you opened from the Chats list.

**How iOS gets it right.** The community pushes the chat onto its own stack:

```swift
.navigationDestination(item: $openConversation) { ChatDetailView(conversation: $0) }
```
[CommunityDetailView.swift:131](../../apps/ios/Voiid/Voiid/Main/CommunityDetailView.swift#L131)

Back pops to the community, because that is where the chat was pushed from. No tab changes.

**Fix.** Two parts:
1. Remove `tab = Tab.CHAT` from the Communities callback. Present the chat over the community, so back returns there.
2. Decide the host-inbox case separately (see the question below) — a host thread may legitimately belong in Chats.

With a real back stack (NV-03) this is automatic: `push(ChatRoute(id))` from wherever you are, and back pops to that place.

**Decision needed.** Should a **host-inbox** thread open inside the community (back → community) or in the Chats tab (back → Chats)? Space chats should clearly return to the community; the host inbox is arguable.

---

## 2. Your second bug: the back swipe closes the app

**Confirmed. Android only.**

**What happens.** On most screens, swiping from the edge (or pressing back) closes the app instead of going back one screen.

**Why.** Android's back gesture goes to the Activity unless a composable claims it with `BackHandler`. `MainActivity` never overrides back ([MainActivity.kt](../../apps/android/app/src/main/java/com/voiid/app/MainActivity.kt)), and `RootTabView` — which hosts every overlay — **has no `BackHandler` anywhere in its body**. So from any screen that has no handler of its own, the system finishes the Activity: the app closes.

Only **8 files** handle back today: the chat detail, call log, location detail, contact profile, group info, QR preview, onboarding and the modal navigator. Meanwhile **39 screens have a back button on screen but no `BackHandler`**, including:

`SettingsScreen` · `PrivacySettingsScreen` · `ProfileSettingsScreens` · `StorageSettingsScreen` · `LinkedDevicesScreen` · `BackupRecoveryScreen` · `BlockedContactsScreen` · `NewChatScreen` · `NewGroupScreen` · `SafetyNumberScreen` · `ScanQrCodeScreen` · `CommunitySettingsScreen` · `CommunityHostInboxView` · `EventManagementScreens` · `LegalScreen` · `LegalDocumentScreen` · `HelpAndSupportScreen` · `AboutScreen` · `ReachabilityScreens` · `ConsentPromptScreen` …

On those screens the on-screen back button works and the system back gesture kills the app. That mismatch is the user-visible bug.

**Fix (immediate, ~1 hour).** Add a single handler at the root of `RootTabView` that closes whatever is open, innermost first:

```kotlin
BackHandler(enabled = anyOverlayOpen) {
    when {
        openClip != null       -> openClip = null
        openCreator != null    -> openCreator = null
        openConversation != null -> openConversation = null
        // …each overlay, innermost first
        tab != Tab.CHAT        -> tab = Tab.CHAT   // or: last tab
        else                   -> { /* let the system close the app */ }
    }
}
```

That stops the app closing unexpectedly. It is a patch, not a cure — the ordering has to be maintained by hand every time a screen is added, which is why NV-03 is the real fix.

---

<a id="nv-03"></a>
## 3. The root cause: Android has no back stack

**Evidence.** Searching the whole Android source for `NavHost`, `rememberNavController` or `navController` returns **nothing**. Navigation is ~20 independent variables in one composable:

```kotlin
var tab by remember { mutableStateOf(Tab.CHAT) }
var openConversation by remember { mutableStateOf<VConversation?>(null) }
var openClip by remember { mutableStateOf<ClipPagerSource?>(null) }
var showNewClip by remember { mutableStateOf(false) }
var showMyClips by remember { mutableStateOf(false) }
var openCreator by remember { mutableStateOf<String?>(null) }
var openStoryContext by remember { mutableStateOf<Int?>(null) }
var showStoryComposer by remember { mutableStateOf(false) }
var openGameMatch by remember { mutableStateOf<Pair<String, String>?>(null) }
var setupGame by remember { … }   var lobby by remember { … }
var botGame by remember { … }     var showLeaderboard by remember { … }
… ~20 in total
```
[RootTabView.kt:175-253](../../apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt#L175-L253)

**Why this produces every bug in this document.** With no stack, there is no answer to "where did I come from?", so:
- back has nothing to pop (NV-01)
- "going somewhere" means setting a variable, and a caller can set the wrong one — such as the tab (NV-02)
- nothing is saved when the process dies (NV-05)
- each screen invents its own transition, or none (NV-07)
- the system cannot preview the back destination (NV-08)

Note there *is* a small hand-rolled stack for Settings — `VoiidModalNavigator` with a real push/pop and a proper `BackHandler` ([VoiidModalNavigator.kt:55-88](../../apps/android/app/src/main/java/com/voiid/app/ui/components/VoiidModalNavigator.kt#L55-L88)). It is used in exactly one place ([ChatsHomeView.kt:177](../../apps/android/app/src/main/java/com/voiid/app/main/ChatsHomeView.kt#L177)). It proves the team already knows the shape of the fix; it just was not applied app-wide.

---

<a id="nv-04"></a>
## 4. NV-04 · P1 · Back from inside a community exits the app

Opening a community replaces the list with the detail view and returns early:

```kotlin
open?.let { card ->
    CommunityDetailView(card = card, …, onBack = { open = null; … })
    return
}
```
[CommunitiesHomeView.kt:108-116](../../apps/android/app/src/main/java/com/voiid/app/main/CommunitiesHomeView.kt#L108-L116)

The only `BackHandler` in that file is for the discover/search overlay ([CommunitiesHomeView.kt:165](../../apps/android/app/src/main/java/com/voiid/app/main/CommunitiesHomeView.kt#L165)). So while viewing a community, system back closes the app instead of returning to the community list — and the same is true of the community's own sub-screens (settings, admin, host inbox), each of which is another boolean inside the detail view ([CommunitiesHomeView.kt:285-294](../../apps/android/app/src/main/java/com/voiid/app/main/CommunitiesHomeView.kt#L285-L294)).

**Fix.** Covered by NV-01's root handler as a stopgap; properly fixed by NV-03.

---

<a id="nv-05"></a>
## 5. NV-05 · P1 · Navigation state is lost when Android kills the app

Across the Android UI there are **731 `remember {}`** and only **16 `rememberSaveable`**. `remember` does not survive process death, and Android routinely kills backgrounded apps.

Rotation is safe — `MainActivity` declares `configChanges` for orientation and size ([AndroidManifest.xml:105](../../apps/android/app/src/main/AndroidManifest.xml#L105)) — so this is specifically about returning to the app after the system reclaimed it: the user lands back on the Chats tab with every open screen gone.

**Fix.** With a real back stack, the library saves and restores it. Keep `rememberSaveable` for in-screen state worth preserving (drafts, scroll position, search text).

**Decision needed.** After the app is killed and reopened, should the user return to exactly where they were, or to the Chats tab? (Most messaging apps restore the conversation list, not the deepest screen.)

---

<a id="nv-06"></a>
## 6. NV-06 · P1 · Deep links push you into a tab you didn't choose

Opening a notification calls `DeepLinkRouter.open(conversationId)` ([DeepLinkRouter.kt:33-37](../../apps/android/app/src/main/java/com/voiid/app/net/DeepLinkRouter.kt#L33-L37)), and the root reacts by setting the tab and the conversation together ([RootTabView.kt:337-340](../../apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt#L337-L340)).

Because there is no stack, back from a notification-opened chat drops you on the Chats tab even if you were deep in Games or a community when the notification arrived. Your place is gone.

**Fix.** With a stack, a deep link pushes onto the current stack (or resets to a defined one), and back follows the documented rule.

**Decision needed.** After opening a chat from a notification, should back return to (a) where you were before, or (b) the Chats list? Android's convention for an external entry point is (b) — a "synthetic" back stack — while in-app taps use (a). Worth deciding explicitly.

---

<a id="nv-07"></a>
## 7. NV-07 · P2 · Transitions are inconsistent

You asked for smooth and a little animated. Today it depends on the screen:

| Screen | Transition | Where |
|---|---|---|
| Chat detail | Slides in from the right, fades — correct | [RootTabView.kt:447-451](../../apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt#L447-L451) |
| Clip player | Zooms out of the tapped thumbnail — deliberate and good | [RootTabView.kt:484-490](../../apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt#L484-L490) |
| Games, stories, composers | Slide up from the bottom | [RootTabView.kt:663-805](../../apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt#L663-L805) |
| **Creator profile** | **None — appears and vanishes instantly** | [RootTabView.kt:466-475](../../apps/android/app/src/main/java/com/voiid/app/main/RootTabView.kt#L466-L475) |
| **Community detail** | **None — replaces the list instantly** | [CommunitiesHomeView.kt:108-116](../../apps/android/app/src/main/java/com/voiid/app/main/CommunitiesHomeView.kt#L108-L116) |
| **Settings and its sub-screens** | **None — `Dialog`, no transition** | [VoiidModalNavigator.kt:63-88](../../apps/android/app/src/main/java/com/voiid/app/ui/components/VoiidModalNavigator.kt#L63-L88) |

So the two screens the user visits most after chats — a community and Settings — are the two that snap.

**Fix.** One shared set of transitions, applied by the navigation host rather than per screen:
- **Push:** new screen slides in from the right; the old one moves left ~30% and dims slightly (the iOS-style parallax) — 300 ms, standard easing.
- **Pop:** the reverse, and interruptible so a back swipe can track the finger.
- **Modal:** slides up from the bottom, 250 ms.
- Keep the clip zoom as the deliberate exception.

**Decision needed.** Confirm the push style: iOS-style parallax slide (recommended, matches your iOS app) or Material's shared-axis fade-through?

---

<a id="nv-08"></a>
## 8. NV-08 · P2 · No predictive back

Android 14+ can show a live preview of the screen you're about to return to while your finger is still down. It requires `android:enableOnBackInvokedCallback="true"` in the manifest and back handlers that support it. The manifest has no such flag, and every handler uses the older `BackHandler`.

Result: the back swipe is an all-or-nothing jump, never the smooth tracked animation the OS now offers.

**Fix.** Enable the flag and adopt predictive-back APIs. Compose's navigation supports this with little extra work once NV-03 lands, and it is the single biggest "feels smooth" upgrade for the back gesture.

---

<a id="nv-09"></a>
## 9. NV-09 · P2 · Returning to a screen resets it

Because screens are recreated from scratch when their variable flips back, returning to a list generally means: scroll position lost, search text cleared, data refetched.

On Android this follows from `remember` (NV-05). On iOS the same happens for anything presented as a sheet or cover rather than pushed — there are 132 `sheet`/`fullScreenCover` uses.

**Fix.** With a back stack, screens keep their state while on it. For lists, hold scroll position in `rememberSaveable`; for data, prefer a cached store over a refetch on every appearance.

---

<a id="nv-10"></a>
## 10. NV-10 · P3 · iOS stacks can't be driven programmatically

iOS has 73 `NavigationStack {}` without a path binding and only 6 with one. A pathless stack can only be pushed by user taps: nothing can deep-link two levels in, or pop to root after finishing a flow.

This is not currently causing a bug, but it is why a future "open this community's settings from a notification" will be awkward.

**Fix.** Give a path binding to the stacks that deep links target (chats, communities, settings). Leave the rest.

---

## 11. Recommended fix plan

**Phase 1 — stop the bleeding (about a day).** Ships the two reported bugs fixed.
1. Add the root `BackHandler` to `RootTabView` (§2).
2. Remove `tab = Tab.CHAT` from the Communities conversation callback (§1).
3. Add `BackHandler` to the community detail view and its sub-screens.

**Phase 2 — one real back stack (the actual fix).** Adopt Navigation Compose (or extend the existing `VoiidModalNavigator` pattern app-wide):
1. Define routes for every screen currently held in a variable.
2. Replace the ~20 variables in `RootTabView` with one `NavHost`, one back stack per tab.
3. Move deep links onto it.
4. Delete the per-screen `BackHandler`s — the host handles back once, correctly.

**Phase 3 — make it feel right.**
1. One shared push/pop/modal transition set (§7).
2. Enable predictive back (§8).
3. Preserve scroll and inner state (§9).

**Phase 4 — iOS polish.** Path bindings for deep-linkable stacks (§10).

---

## 12. Decisions needed before implementing

1. **Host-inbox threads:** open inside the community, or in the Chats tab? (Space chats: inside the community — that is the bug fix.)
2. **After the app is killed and reopened:** restore the exact screen, or return to Chats?
3. **Back from a notification-opened chat:** return to where you were, or to the Chats list?
4. **Push transition:** iOS-style parallax slide, or Material shared-axis?
5. **Phase 2 scope:** adopt Navigation Compose (a well-trodden library, some migration work) or extend your own `VoiidModalNavigator` (no dependency, but you maintain save/restore and predictive back yourself)? My recommendation is Navigation Compose, because saved state and predictive back come with it.
6. **Tab back behaviour:** from a non-Chats tab with nothing open, should back switch to Chats first, or exit the app? (Android convention: return to the start tab, then exit.)

---

## 13. What this audit checked

**Read:** Android `RootTabView` (all 1,261 lines), `MainActivity`, `AndroidManifest`, `VoiidModalNavigator`, `DeepLinkRouter`, `CommunitiesHomeView`, `CommunityTabs`, `ChatDetailView` and every file containing a back callback; iOS `RootTabView`, `CommunityDetailView`, `CommunityTabs`, `ChatsHomeView`, `InteractiveSwipeBack` and all `NavigationStack` sites.

**Counted:** `BackHandler` usage (8 files), screens with a back callback but no handler (39), `NavHost` (0), `remember` vs `rememberSaveable` (731 vs 16), iOS stacks with and without paths (6 vs 73), iOS sheets/covers (132).

**Not done:** neither app was run, so the transition timings are read from code, not measured on a device. Both reported bugs were traced to specific lines rather than reproduced on hardware.
