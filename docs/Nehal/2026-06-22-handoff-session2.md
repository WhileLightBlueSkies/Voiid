# Voiid — Handoff (2026-06-22, session 2)

Branch: `0.0.2` · Backend (dev): `https://api-dev.voiid.app`

Follow-on to [Priyanshu's 2026-06-22-handoff.md](../Priyanshu/2026-06-22-handoff.md). This session implemented
the **app-wiring fixes** from that doc's "Left to do" / "Known issues": media
(image + voice) send/receive is now wired end-to-end in the app, and the
contacts-in-search issue has a concrete fix. Group messaging (MLS) is still open.

---

## ✅ Done this session

### Issue 2 — Media (image + voice) now actually sends/receives
Previously the picker loaded the image bytes then **discarded** them and sent the
literal text "📷 Photo"; voice sent "🎤 Voice message · Ns" with no audio. Both are
now real, on **iOS + Android**:

- **Send:** photo picker reads the real bytes → `ChatStore.sendMedia(...)` →
  `ChatEngine.sendMedia(...)` (already built last session): encrypt on-device →
  upload **ciphertext** to R2 → the media key is packed **inside** the E2EE message
  plaintext (key never leaves E2E). `VMessage` now carries the `MediaRef`.
- **Voice (real capture):** `AVAudioRecorder` (iOS) / `MediaRecorder` (Android)
  record `.m4a` on press-and-hold → `sendMedia(audio/m4a)`. Playback via
  `AVAudioPlayer` / `MediaPlayer`.
- **Receive/render:** image + voice bubbles fetch + decrypt on demand —
  `AsyncMediaImage` / `AsyncVoiceNote` (iOS, in `ChatDetailView.swift`) and
  `MediaViews.kt` (Android), backed by an in-memory decrypted-media cache so
  reopening a chat doesn't re-download.

Files: iOS — `Models/Models.swift` (VMessage.mediaRef), `Models/Stores.swift`
(sendMedia + media mapping in refresh), `Main/ChatDetailView.swift`,
`Main/VoiceNote.swift`. Android — `model/Models.kt`, `model/Stores.kt`,
`main/ChatDetailView.kt`, `main/ChatUI.kt`, `main/VoiceNote.kt`, `main/MediaViews.kt`.

### Issue 3 — Contacts not appearing in NewChat (but did in NewGroup)
Root cause is environmental (the two pickers each call `/contacts/discover`
separately → can race / hit the rate limiter / leave one screen empty). Fix:
**`ContactsService` now caches the discovery result** (process-wide, 120s TTL) so
NewChat + NewGroup reuse one network result. "Try again" force-refreshes.
Files: `Networking/ContactsService.swift`, `net/ContactsService.kt`, + the picker
screens' retry buttons.

---

## 🚧 Still open

### Issue 1 — Group messaging via MLS (NOT done — the bigger lift)
Group sends are still local-echo only (`ChatStore.send` returns early for
non-direct conversations). Real group E2E needs the **OpenMLS `GroupSession`** path
in e2e-core wired on send + receive (group key package exchange, commit handling,
fan-out per the group's conversation_id). This is the main remaining chat feature.

### Blocking media end-to-end (infra — needs Priyanshu)
The app + backend media code is done, but `/media/*` returns **503 until the R2 env
is on the box** (carried over from session 1):
```
R2_ENDPOINT=…  R2_ACCESS_KEY_ID=…  R2_SECRET_ACCESS_KEY=…  R2_BUCKET=voiid-media-dev
```
…on `/opt/voiid/.env` (139.84.209.49) → `pm2 restart voiid-api --update-env`.
Confirm `curl https://api-dev.voiid.app/health` → `"media":{"configured":true}`.
**Also roll the R2 token** (it was pasted in chat — treat as compromised).

### Carried over (unchanged from session 1)
- Safety-number / key-verification UI (anti-MITM pin exists; no UI).
- Push notifications (FCM/APNs) + suppress-when-open toast.
- DummyData still: Clips, AI chat, Calls.
- 1:1 + media **live** send/receive still unverified (needs 2 auth'd test
  accounts: `AUTH_DEV_BYPASS=1` on the box or real OTPs).
- Ops: prod box/DB/Redis split + TestFlight/Play pipelines; per-route async-error wrapping.

---

## Verification status

| Item | Status |
|---|---|
| iOS / Android builds | ⚠️ NOT re-verified this session (no mobile toolchain here) — needs a device build |
| Media send/receive via UI | code complete; needs R2 env on box + a build to verify |
| Contacts cache fix | code complete; needs live repro to confirm Issue 3 resolved |
| Group messaging | NOT implemented (MLS pending) |
