# Handoff — Messaging reliability, Contact profile, Animations (2026-06-22)

Author: Priyanshu (via Claude Code session)
Branch: `0.0.2`
Backend: deployed to **dev** (`api-dev.voiid.app`) via PR #22.

This documents the two reported bugs ("messages not going through", "profile shows
wrong number"), what was fixed, **what is still NOT fixed and why**, exact test
steps, and the animation-parity work.

---

## TL;DR

| Area | Status | Notes |
|---|---|---|
| Profile shows real name / @username / phone | ✅ Done | Phone only for **saved** contacts (API never returns phone — privacy) |
| Send-failure now visible (error icon, not stuck clock) | ✅ Done | Auto-retries on next flush |
| Stale-device-after-reinstall (the main cause) | ✅ Fixed (backend, deployed) | Takes effect once each peer relaunches the new build |
| Prekey replenishment + monotonic key ids | ✅ Done (client) | Keeps your own pool full so others can message you |
| **Messaging to a genuinely-exhausted OFFLINE peer** | ❌ Not fixed | Needs the **fallback key** (requires Rust/uniffi toolchain — see below) |
| Footer (tab bar) pill **stretch** | ✅ Added | Slide + icon-scale were already there |
| Login shared-element logo glide (splash→Terms) | ✅ Added | Was previously an approximate slide-up |

---

## 1) Why chats can STILL show the error "i" icon

The red error icon you see is the new **send-failure state** (good — it means a send
genuinely failed instead of silently sitting on a clock forever). The underlying
error is almost always:

```
ApiError$Http: peer has no available prekeys   (HTTP 409)
```

### Root cause
1:1 E2E uses **one-time prekeys** (vodozemac/Olm). To start a session, the sender
fetches ONE of the recipient's one-time prekeys; the server **consumes** it. If the
recipient has **zero unconsumed prekeys**, the sender cannot start a session and the
message fails.

A recipient ends up at zero prekeys when:
- They **reinstalled** the app. The old build generated a *new* `registration_id` on
  reinstall, which created a **new device row** server-side and left the **old device
  active** with an exhausted/stale prekey pool. The client picks one device bundle
  (`firstOrNull`) and could land on the dead one → 409. *(This was the main bug.)*
- Their pool was simply **never replenished** after the initial 100 were consumed.

### What was fixed (and is live on dev)
- **Backend** `devices.ts`: on (re)register, **revoke superseded same-platform
  devices** and drop their prekeys → one clean active device per platform.
- **Backend** `prekeys.ts` / `devices.ts`: order lookups **freshest device first**;
  added `GET /prekeys/count`.
- **Client** `ChatEngine.kt`: pick the first bundle that **actually has** a one-time
  key (defensive).
- **Client** `E2EManager.kt`: **replenish** prekeys toward 100 when below 20, with
  **monotonic key ids** (the old `0..N` scheme silently dropped replenished keys on
  DB conflict — replenishment was effectively impossible before).

### ⚠️ The fix only "lands" for a peer after THEY relaunch the new build
The stale-device cleanup + fresh prekey publish happen **when a device registers**,
i.e. on app launch. So:

> **To test messaging, BOTH phones must be on the new APK and have been opened at
> least once** (to re-register and publish fresh prekeys). If one phone is still on
> the old build (or hasn't been reopened), sending to it will still 409.

### What is still NOT fixed
If a peer is **genuinely out of one-time prekeys AND offline** (so they can't
replenish), sending to them still fails. The proper backstop is a **fallback /
last-resort key** (a reusable key Olm hands out when one-time keys are exhausted).

- vodozemac supports this, **but our `e2e-core` Rust crate doesn't expose it** and
  the FFI `start_session(theirIdentityKey, theirOneTimeKey)` requires a one-time key.
- Adding it needs: edit `packages/e2e-core/src/{keys,api,session}.rs`, regenerate the
  uniffi bindings + `.so` via `packages/e2e-core/build-android.sh` (and `build-apple.sh`
  for iOS), then DB + server + client plumbing.
- This requires the **Rust/uniffi/NDK toolchain**, which was **not available** in the
  session environment (`cargo` not installed). → **Deferred.**

See "Follow-ups" for the concrete steps.

---

## 2) Contact profile — real data

Before: the profile header showed a **hardcoded** `+91 91234 56789` and a stub
"About"/media. Now `ContactProfileView.kt`:
- Fetches the real user via `GET /users/{id}` → shows **full name**, **@username**,
  and **bio**.
- Shows, below the contact name, in the same secondary style, one line each:
  **real name · @username · phone number**.
- The **phone number** comes from the on-device contact match (`ContactDirectory`,
  saved during `ContactsService.discover`). The backend **never** returns phone
  numbers (privacy: numbers are matched by hash, never sent raw), so the number is
  only shown for contacts the user has actually **saved** on that device. Unsaved
  contacts show name + @username only.

Files: `ContactProfileView.kt`, `ProfileService.kt` (`fetchUser`), new
`ContactDirectory.kt`, `ContactsService.kt` (writes the directory).

---

## 3) Animations (iOS → Android parity)

Most onboarding/footer animations were already ported. Gaps closed this session:

- **Footer (tab bar) pill stretch** — `RootTabView.kt`. The pill already slid between
  tabs with an icon scale; it now **stretches** during transit (the two edges spring
  with slightly different stiffness), matching the iOS elastic `matchedGeometryEffect`
  capsule.
- **Login shared-element logo glide** — `OnboardingFlow.kt`. The splash→Terms logo
  now uses Compose `SharedTransitionLayout` so the wordmark **glides** from the splash
  center to its Terms position, replacing the previous approximate slide-up + fade.

Already present (no change needed): splash scale/opacity spring, staggered Terms
reveal (fade + slide-up), checkbox fill spring, step slide/fade transitions, tab icon
scale, chat-detail push, clip fullscreen cover.

### Animation parity still open (follow-ups)
- `matchedGeometryEffect` flourishes inside Chats grid / Clips (iOS `DraggableChatGrid`,
  `ClipsFeedView`) are only partially mirrored.
- `repeatForever` ambient effects (e.g. recording pulse in `VoiceNote`) — verify parity.

---

## Test procedure (real devices)

1. Install the new APK on **both** phones; open the app on each once (this
   re-registers + republishes prekeys). APK: `apps/android/app/build/outputs/apk/debug/app-debug.apk`.
2. Phone A → start/open a chat with Phone B → send a message.
   - Expect: message sends (tick), Phone B receives it.
   - If it shows the red error icon: confirm Phone B was opened on the **new** build;
     check `adb logcat | grep VOIID` on the sender for the exact error.
3. Profile: open a chat → tap the contact's name → expect real name, @username, and
   (for saved contacts) the phone number.

---

## Follow-ups / TODO

1. **Fallback key (unblocks offline-exhausted peers)** — the real completion of the
   messaging fix:
   - `e2e-core`: expose vodozemac fallback key (`generate_fallback_key`,
     include in `PublicBundle`, allow `start_session` to use it), regenerate bindings
     (`build-android.sh`, `build-apple.sh`).
   - DB: store the (reusable) fallback key per device; server: return it from
     `GET /prekeys/:id` when no one-time key remains (do **not** consume it).
   - Client: upload the fallback key; use it when `one_time_prekey == null`.
2. **iOS parity** for everything above (this session changed Android + backend only).
   The iOS client has the same prekey/replenishment gap.
3. **Multi-device**: client still assumes one device (`firstOrNull`). Revisit if/when
   multi-device is a product requirement (current backend now enforces single active
   device per platform).
4. Remaining `matchedGeometryEffect` / `repeatForever` animation parity (see above).

---

## Changed files (this session)

Backend: `backend/api/src/routes/devices.ts`, `backend/api/src/routes/prekeys.ts`
Android (E2E/messaging): `net/E2EManager.kt`, `net/ChatEngine.kt`, `model/Stores.kt`
Android (profile): `main/ContactProfileView.kt`, `net/ProfileService.kt`,
`net/ContactsService.kt`, new `net/ContactDirectory.kt`
Android (animations): `main/RootTabView.kt`, `onboarding/OnboardingFlow.kt`
