//! Identity verification (safety numbers).
//!
//! Encryption without identity verification is open to a man-in-the-middle: the
//! server could hand each side a key it controls. A **safety number** lets two
//! users confirm out-of-band (in person, over a trusted channel, by QR scan)
//! that they hold each other's real keys.
//!
//! The number is a deterministic function of BOTH parties' public identity
//! keys AND their stable identifiers, computed symmetrically so both sides see
//! the same digits. The construction follows Signal's fingerprint design:
//!   - a version byte + the party's stable identifier + the RAW key bytes are
//!     run through an iterated hash to produce a per-party "local fingerprint"
//!     (binding the identifier defends against key-substitution/relay tricks);
//!   - the two local fingerprints are concatenated in a fixed (sorted) order;
//!   - the result is rendered as decimal groups.

use sha2::{Digest, Sha512};

/// Number of 5-digit groups in the displayed safety number (60 digits total,
/// matching Signal's format). Each party contributes half.
const GROUPS: usize = 12;
const GROUPS_PER_PARTY: usize = GROUPS / 2;
/// Iterated-hash rounds, to slow brute-force preimage attempts (Signal uses
/// 5200 over SHA-512).
const ITERATIONS: usize = 5200;
/// Domain-separation / version tag. Bump if the construction ever changes so
/// old and new numbers can never silently compare equal.
const VERSION: &[u8] = b"voiid-safety-number-v1";

/// Compute the safety number two users compare to verify they have each other's
/// real identity keys.
///
/// - `our_id` / `their_id`: each party's STABLE identifier (e.g. user/account
///   id) — public, not secret, but binds the number to a specific identity.
/// - `our_fingerprint` / `their_fingerprint`: the base64 Ed25519 keys from
///   `IdentityKeys::fingerprint`.
///
/// Symmetric: swapping (our, their) for (their, our) yields the same number.
pub fn safety_number(
    our_id: &[u8],
    our_fingerprint: &str,
    their_id: &[u8],
    their_fingerprint: &str,
) -> String {
    let a = local_fingerprint(our_id, our_fingerprint);
    let b = local_fingerprint(their_id, their_fingerprint);

    // Sort the two halves so both sides produce the same string regardless of
    // who is "us" and who is "them". Both are equal-length digit strings, so
    // lexicographic order matches numeric order.
    let (first, second) = if a <= b { (a, b) } else { (b, a) };

    let combined = format!("{first}{second}");
    group_digits(&combined)
}

/// Per-party local fingerprint: iterate SHA-512 over
/// `VERSION || identifier || raw_key`, then take the first
/// `GROUPS_PER_PARTY * 5` decimal digits. Falls back to hashing the raw base64
/// bytes if the fingerprint isn't valid base64 (defensive — still deterministic
/// and unique per input).
fn local_fingerprint(identifier: &[u8], fingerprint_b64: &str) -> String {
    let key_bytes =
        vodozemac::base64_decode(fingerprint_b64).unwrap_or_else(|_| fingerprint_b64.as_bytes().to_vec());

    let seed = |h: &mut Sha512| {
        h.update(VERSION);
        h.update((identifier.len() as u64).to_be_bytes()); // length-prefix to avoid ambiguity
        h.update(identifier);
        h.update(&key_bytes);
    };

    let mut hash = {
        let mut h = Sha512::new();
        seed(&mut h);
        h.finalize().to_vec()
    };
    for _ in 0..ITERATIONS {
        let mut h = Sha512::new();
        h.update(&hash);
        seed(&mut h);
        hash = h.finalize().to_vec();
    }
    encode_decimal(&hash, GROUPS_PER_PARTY)
}

/// Encode the first `groups * 5` decimal digits from `bytes`, taking a fresh,
/// non-overlapping 5-byte window per group (big-endian) mod 100000. SHA-512 is
/// 64 bytes, so up to 12 groups fit without reuse; we only need 6.
fn encode_decimal(bytes: &[u8], groups: usize) -> String {
    debug_assert!(bytes.len() >= groups * 5, "hash too short for {groups} groups");
    let mut out = String::with_capacity(groups * 5);
    for g in 0..groups {
        let start = g * 5;
        let window = &bytes[start..start + 5];
        let mut n: u64 = 0;
        for &b in window {
            n = (n << 8) | b as u64;
        }
        out.push_str(&format!("{:05}", n % 100_000));
    }
    out
}

/// Split a digit string into space-separated groups of 5 for display.
fn group_digits(digits: &str) -> String {
    digits
        .as_bytes()
        .chunks(5)
        .map(|c| std::str::from_utf8(c).unwrap_or(""))
        .collect::<Vec<_>>()
        .join(" ")
}
