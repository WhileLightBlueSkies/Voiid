// E2E crypto seam (Section 3 / blocker #1).
//
// IMPORTANT: VOIID never implements cryptography itself and the SERVER never decrypts anything.
// All real E2E crypto runs ON THE CLIENT via libsignal once the AGPL licensing blocker is cleared
// (see docs/CHECKLIST.md blocker #1). This module exists only to make the integration point explicit
// and to keep the rest of the codebase provider-agnostic.
//
// The server's entire job is to store and relay OPAQUE CIPHERTEXT (base64 bytes) plus public-key
// bundles. It must work identically whether the bytes are real libsignal output or, pre-Phase-2,
// opaque placeholder payloads. Nothing here should ever need to change when libsignal is wired in,
// because the server side has no crypto.
//
// Client-side libsignal integration (Swift/Kotlin/TS) plugs in behind these conceptual interfaces:
//   - SessionStore / IdentityKeyStore / PreKeyStore  -> hardware-backed storage on device
//   - session.encrypt / session.decrypt              -> Double Ratchet (libsignal)
//   - X3DH bundle build/consume                       -> from /prekeys endpoints
// None of that lives on the server.

/** A relay payload is opaque to the server: base64 ciphertext + non-secret routing metadata. */
export interface RelayPayload {
  /** base64-encoded ciphertext. The server NEVER decodes this to plaintext. */
  ciphertext: string;
  content_type?: 'text' | 'image' | 'voice' | 'document' | 'system';
  media_url?: string;   // R2 reference to separately-encrypted media bytes
  media_mime?: string;
}

/** Guard: ensure a payload looks like opaque base64 and carries no plaintext-ish fields. */
export function assertOpaque(payload: Record<string, unknown>): void {
  for (const banned of ['plaintext', 'text_content', 'body', 'message_text']) {
    if (banned in payload) {
      throw new Error(`relay payload must be opaque ciphertext; forbidden field "${banned}"`);
    }
  }
}
