# VOIID — Questions for the Software-Licensing Lawyer

> Hand this to a software-licensing / IP lawyer (ideally India-aware). Ordered by priority.
> Status: open. Owner: Nehal Shenoy.

## Priority
- 🔴 **#1 libsignal / E2E crypto licensing** — blocks Phase 2 (E2E). Resolve first.
- 🟠 **#2 fonts, #3 DPDP** — before public launch / Phase 1 client.
- 🟡 **#4 telephony, #5 payments, #6 user docs** — before the relevant features ship.

---

## 1. libsignal / AGPL — the blocker  🔴

**Context:** VOIID is a **closed-source, commercial** E2E messaging app. We want Signal Protocol
encryption. Signal's official library **`libsignal` is AGPL-3.0** (confirmed from their repo; no
commercial license publicly offered). We do **not** want to open-source our apps.

1. If we link `libsignal` into our iOS/Android/Web clients, does AGPL-3.0 force us to release the
   **entire app's source**, or only the modified library? Confirm copyleft scope for *dynamic
   linking* on mobile (Swift/Kotlin bindings) vs. server use.
2. Does AGPL **§13 "network use"** apply to our backend if the server only **relays ciphertext** and
   never links libsignal?
3. Is there any architecture (separate process / IPC / separate binary) that legally isolates the
   AGPL library from our proprietary code — or is that a myth under AGPL?
4. Can we obtain a **commercial license / AGPL exception** directly from the Signal Foundation?
   Realistic process? Advisable?
5. **Protocol vs. code:** The Signal *Protocol* (X3DH, Double Ratchet, Sender Keys) is a free
   published spec. If we use a **permissively-licensed (MIT/Apache) implementation** of the same
   protocol, or write our own from the spec, are there **patent or IP risks** from Signal?
   (i.e., is the *protocol* truly free to implement, separate from their *code*?)
6. **Clean-room build:** Can we implement the Signal Protocol ourselves **from the published
   specification/whitepapers only**, for a closed commercial app, **without touching libsignal's
   AGPL source**? What "clean room" precautions are legally required so our implementation is NOT
   deemed a derivative of libsignal? Are there Signal/WhatsApp **patents** that would block an
   independent implementation?
7. **vodozemac** (Apache-2.0, Matrix Olm/Megolm protocol) is our likely fallback — confirm no
   licensing/patent obstacles for closed commercial use.
8. How did **WhatsApp** legally use the Signal Protocol while staying closed-source, and is that
   path (partnership/permission) realistically available to a company our size?

> Engineering note (for context, not legal): our own master spec FORBIDS hand-rolling crypto
> (§0, §4.14). Reading AGPL source to reimplement risks contamination. Preferred path = an
> already-audited permissive library (vodozemac) OR a Signal commercial license. A clean-room
> build would require a mandatory external security audit before launch.

---

## 2. Fonts  🟠
9. **SF Pro Rounded** (Apple font) — can we legally use/distribute it on **Android and Web**, or is
   it Apple-platforms-only? Do we need a rounded fallback (e.g. Nunito / Varela Round)?
10. **Urbanist** (logo wordmark, OFL) — confirm OFL allows embedding in a commercial app + compliance.

---

## 3. India DPDP Act 2023  🟠
11. What must VOIID implement to comply? Specifically:
    - Lawful **consent capture** at signup (we store a consent timestamp — sufficient?)
    - **Data residency** — must data stay in India? (DB hosted in India region.)
    - **User rights** — access / correction / **erasure** ("delete account" must truly purge).
      Legal standard for "purge"?
    - **Breach notification** process + timelines.
    - Required **privacy policy** contents.
    - Does **messaging metadata** (timestamps, sender/recipient — content is E2E) need a stated
      **retention period**?

---

## 4. Telephony / OTP & intermediary rules  🟡
12. **Firebase Phone Auth** + **MSG91** for SMS OTP to Indian numbers — TRAI / **DLT registration**
    requirements?
13. Does an E2E messaging + calling app trigger Indian **IT Rules 2021 / intermediary** obligations
    (traceability, grievance officer, takedown timelines)? Known tension area for E2E in India.

---

## 5. Payments & commerce (Phase 8)  🟡
14. **Razorpay** in-app shopping — compliance needs (PCI scope, RBI rules)? Payments/orders are
    NOT E2E — what data-handling obligations apply?

---

## 6. User-facing legal documents  🟡
15. Review — and complete — the **Terms of Use** + **Privacy Notice** that now ship inside both
    apps as version `2026-08-01` (`apps/ios/Voiid/Voiid/Legal/LegalDocuments.swift` and its
    Android twin; published in `database/migrations/031_consent_notice.sql`; consent recorded
    against that exact version by `backend/api/src/routes/consent.ts`).
    **These were written by engineering, not by a lawyer.** They describe accurately what the
    system does and does not do — which is the part engineering can answer — and deliberately
    OMIT everything that is a legal determination. Each app renders the omissions to the user
    under a "Still being finalised" heading. What is missing, and needed:
    - the **grievance officer**'s name, address and response SLA (see also #13);
    - whether the stated retention periods (90d security logs, 30d erasure grace, OTP+24h) are
      defensible, and whether IT Rules 2021 set a retention **floor** that conflicts with them;
    - Voiid's **children's-data** position and what "verifiable parental consent" means for a
      phone-number-only signup;
    - where each processor (Firebase, Cloudflare R2, LiveKit, APNs/FCM) physically stores data
      and what its contract must say under DPDP s.8(2)/s.16;
    - whether the notice must be published in **languages other than English**;
    - for the Terms: limitation of liability, warranties, indemnity, governing law and disputes,
      minimum age, and notice-and-takedown timelines — all absent by design, none invented.
    Also for counsel: the v1 notice marks **every purpose as required**, so consent is one tick
    for the bundle. DPDP s.6 wants consent that is specific and unconditional — confirm whether
    bundling service-necessary purposes is acceptable, or whether each needs its own toggle.
    And confirm whether withdrawing consent must **automatically** trigger erasure; today it is
    recorded and the user is pointed at account deletion as a separate, confirmed act.
16. **Backup disclaimer:** v1 = "lose device → lose chat history" (by design; we never hold
    decryption keys). Confirm we can/should disclose this to limit liability.
