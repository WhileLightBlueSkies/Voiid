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
15. Draft/review **Terms & Conditions** + **Privacy Policy** (Terms screen already links to them).
16. **Backup disclaimer:** v1 = "lose device → lose chat history" (by design; we never hold
    decryption keys). Confirm we can/should disclose this to limit liability.
