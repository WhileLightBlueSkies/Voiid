# Killed / Background State Calls — Provisioning Checklist

Goal: an incoming call rings and **connects** when the callee's app is backgrounded,
locked, or force-killed — on both platforms.

Three independent things must all be true. A call fails differently depending on which
one is missing, so the "symptom" column is how you tell them apart:

| Layer | If missing, symptom |
|---|---|
| 1. Push credentials | No ring at all when backgrounded/killed |
| 2. Offer delivery | Rings, then hangs on **"Connecting"** forever |
| 3. ICE / TURN relay | Rings, connects, then **no audio/video** across networks |

Layer 2 is fixed in code (see §2). Layers 1 and 3 are yours to provision.

---

## 1. Push credentials — makes it RING

### 1a. Apple: VoIP push (required for killed-state iOS)

PushKit is the only mechanism that resumes a **force-killed** iOS app fast enough to
report to CallKit. A normal alert push cannot do this.

- [ ] In the Apple Developer portal, create an **APNs Auth Key (.p8)** under
      Certificates, Identifiers & Profiles → Keys, with **Apple Push Notifications
      service (APNs)** enabled. Download it **once** — Apple will not let you
      re-download it.
- [ ] Record the **Key ID** (10 chars, on the key) and your **Team ID** (top-right of
      the portal). Both are needed; the provider JWT is signed with the key and carries
      the Team ID as its issuer.
- [ ] Confirm the App ID `com.voiid.app` has **Push Notifications** capability enabled.

> One `.p8` covers both the alert topic (`com.voiid.app`) and the VoIP topic
> (`com.voiid.app.voip`) — you do **not** need a separate legacy VoIP Services
> certificate. The distinction is made by request headers, not by credential:
> `apns-push-type: voip` + `apns-topic: com.voiid.app.voip`
> (see [pushPayload.ts:138-139](../backend/api/src/pushPayload.ts#L138-L139)).

**Set on the API server** — these are the exact names the code reads
([push.ts:59-64](../backend/api/src/push.ts#L59-L64)); a typo here fails **silently**:

```bash
APNS_KEY_ID=ABCD123456
APNS_TEAM_ID=CV7L84G776          # must match DEVELOPMENT_TEAM in the Xcode project
APNS_BUNDLE_ID=com.voiid.app     # plain bundle id; ".voip" is appended automatically
APNS_KEY_P8="-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----"
# ...or point at a file instead of inlining:
# APNS_KEY_PATH=/etc/voiid/AuthKey_ABCD123456.p8
APNS_ENV=sandbox                 # development builds; 'production' for TestFlight/App Store
```

- [ ] **`APNS_ENV` matches how the app was built.** A development build registers a
      *sandbox* device token, and sandbox tokens are rejected by the production APNs
      host (and vice versa) with `BadDeviceToken`. This is the single most common
      "it works on my machine" failure.
- [ ] **`APNS_TEAM_ID` matches the team the app is signed with.** Currently
      `CV7L84G776`. If the app is signed by team X and the `.p8` belongs to team Y,
      every push is rejected with `InvalidProviderToken` (403).

### 1b. Google: FCM (Android)

- [ ] `google-services.json` in `apps/android/app/` (gitignored — add locally / via CI).
- [ ] Firebase Admin service-account JSON on the API server, as
      `FIREBASE_SERVICE_ACCOUNT` (inline JSON) or `FIREBASE_SERVICE_ACCOUNT_PATH`.
- [ ] Ring pushes must be **high priority data messages** to wake a Doze-mode device.

### 1c. Verify credentials are live

- [ ] `GET /health` reports `firebase.configured: true`.
- [ ] Place a call to a **backgrounded** device. It should ring. If it doesn't, check
      the API log for `[push] APNs VoIP not configured; skipping VoIP ring`
      ([push.ts](../backend/api/src/push.ts#L329)) — that line means the env above is
      incomplete and **no VoIP push was even attempted**.

---

## 2. Offer delivery — makes it CONNECT

**Status: fixed in code, needs deploy.**

Call signaling was relayed over Redis pub/sub, which has no persistence. An offer
published while the callee had no live WebSocket was **discarded permanently**. The push
would wake the app and ring, the user would answer, and the client would wait forever for
an offer that no longer existed — the "Connecting" hang.

[backend/websocket/src/index.ts](../backend/websocket/src/index.ts) now parks each
`call_offer` in a short-lived per-user Redis hash and flushes it the moment that user's
socket attaches. The buffer is deleted as soon as the call is answered, declined, hung up,
or reported busy.

- [ ] Deploy the **websocket** service (not just the API) — the fix lives there.
- [ ] Optional tuning: `VOIID_CALL_OFFER_TTL_SECONDS` (default `60`). Keep it tight —
      SDP carries host IPs and an offer older than a minute is a call nobody is
      still waiting on.

No client changes are required: iOS already tolerates a late or duplicate offer
([CallService.swift:831-862](../apps/ios/Voiid/Voiid/Networking/CallService.swift#L831-L862)).

---

## 3. ICE / TURN — makes MEDIA flow

Without a relay candidate, calls connect only when a direct peer-to-peer path exists.
They will work on the same Wi-Fi and fail on cellular or behind symmetric NAT.

- [ ] Set **both** Cloudflare TURN vars on the API server. Note the word order —
      `TURN` comes before `CLOUDFLARE` ([turn.ts:64-65](../backend/api/src/turn.ts#L64-L65)):

```bash
VOIID_TURN_CLOUDFLARE_KEY_ID=...
VOIID_TURN_CLOUDFLARE_API_TOKEN=...
```

> `backend/.env` had these transposed as `VOIID_CLOUDFLARE_TURN_*`, which silently
> disabled TURN. Fixed on 2026-07-22, but **re-check whatever provisioned the deployed
> box** — it was likely copied from the same source.

- [ ] Verify with an authenticated `GET /calls/turn`: the response must have
      `turn_configured: true` and include actual `turn:` / `turns:` URLs.
      `false` means it silently fell back to STUN-only
      ([turn.ts:121-122](../backend/api/src/turn.ts#L121-L122)) — no error is logged.
- [ ] Test across networks: one device on Wi-Fi, the other on cellular with Wi-Fi off.
      A same-Wi-Fi test passes even with TURN completely broken, so it proves nothing.

---

## 4. End-to-end acceptance test

Run each with the callee's app **force-killed** (swipe up from the app switcher), not
merely backgrounded:

- [ ] iOS → Android
- [ ] Android → iOS  ← the case that was failing
- [ ] iOS → iOS
- [ ] Repeat all three with the two devices on **different networks** (one cellular).
- [ ] Decline a call from the lock screen; confirm the caller sees it end promptly.
- [ ] Answer, then hand off Wi-Fi → cellular mid-call; audio should recover (ICE restart).

---

## 5. Known gaps not covered here

- **Caller name shows as a UUID.** The ring push deliberately carries no `caller_name`
  ([calls.ts:86-91](../backend/api/src/routes/calls.ts#L86-L91)) — sending one would
  leak the caller's identity to Apple and Google, which the privacy model forbids. The
  fix is to resolve the name **locally** on the callee's device from `caller_id`, which
  needs a persistent contact-name store the app does not yet have. Tracked separately.
- **Group calls** need `LIVEKIT_URL`, `LIVEKIT_API_KEY`, `LIVEKIT_API_SECRET` on the API
  server or `/calls/group/token` returns 503. See [LIVEKIT_SETUP.md](LIVEKIT_SETUP.md).
