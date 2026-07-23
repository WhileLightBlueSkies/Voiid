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

// --- Coordinate guard (location features) ------------------------------------------
//
// WHY A SECOND GUARD: assertOpaque only knows the four message-body field names. A
// request body carrying `latitude` sails straight past it, and the location routes are
// exactly where a well-meaning change ("just send the coords so the server can show a
// map preview") would otherwise land. Position data is E2E content in VOIID: it is
// encrypted on-device and the server stores only "a share exists between A and B until
// T". So the location routes reject a coordinate STRUCTURALLY rather than relying on
// every future handler remembering not to read one.
//
// Matching is per TOKEN, not substring: a key is split on separators and camelCase
// humps, and each token is compared to the banned set. That catches `lat`, `Latitude`,
// `user_lat`, `lastLon`, `geo`, while leaving innocent keys like `related` or
// `translation` alone (a substring match would reject both).
const BANNED_COORD_TOKENS = new Set([
  'lat', 'lon', 'lng', 'latitude', 'longitude',
  'coord', 'coords', 'coordinate', 'coordinates',
  'accuracy', 'altitude', 'speed', 'heading', 'bearing',
  'geo', 'geolocation', 'position', 'gps',
]);

function coordTokens(key: string): string[] {
  return key
    // camelCase / PascalCase humps -> separate tokens (lastLon -> last Lon)
    .replace(/([a-z0-9])([A-Z])/g, '$1 $2')
    .split(/[^A-Za-z0-9]+/)
    .filter(Boolean)
    .map((t) => t.toLowerCase());
}

/**
 * Guard: reject any request/relay payload that carries a coordinate-shaped FIELD.
 *
 * Recursive over objects and arrays (a coordinate nested one level down is still a
 * coordinate). Depth-limited and cycle-safe so a hostile body cannot turn the guard
 * itself into a DoS. Values are never inspected — only key names — because the whole
 * point is that the server must not be able to interpret the payload at all.
 */
export function assertNoCoordinates(value: unknown, path = 'body', depth = 0, seen = new Set<unknown>()): void {
  if (value == null || typeof value !== 'object') return;
  if (depth > 8) throw new Error('payload nested too deeply');
  if (seen.has(value)) return; // cycle — already validated on the way in
  seen.add(value);

  if (Array.isArray(value)) {
    for (let i = 0; i < value.length; i++) assertNoCoordinates(value[i], `${path}[${i}]`, depth + 1, seen);
    return;
  }

  for (const [key, child] of Object.entries(value as Record<string, unknown>)) {
    for (const token of coordTokens(key)) {
      if (BANNED_COORD_TOKENS.has(token)) {
        throw new Error(
          `location payloads must never contain coordinates; forbidden field "${path}.${key}"`
        );
      }
    }
    assertNoCoordinates(child, `${path}.${key}`, depth + 1, seen);
  }
}
