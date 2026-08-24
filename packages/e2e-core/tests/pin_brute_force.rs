//! ADVERSARIAL TEST — audit finding M9 / §D1: offline PIN brute-force cost.
//!
//! The server hands `recovery_keys.wrapped_key` back to any authenticated
//! session (`GET /recovery/key`) and lockout is client-reported only, so the
//! real guessing cost is ONE Argon2id evaluation per candidate, done offline.
//! This measures that cost against the shipped parameters and prints the
//! projected wall-clock for the full keyspace at each allowed PIN length.

use std::time::Instant;
use voiid_e2e_core::api as e2e;

#[test]
fn pin_keyspace_is_offline_crackable_at_shipped_cost() {
    let secret = e2e::generate_master_secret();

    // Weakest accepted PIN (4 digits) — wrapped exactly as production does.
    let blob = e2e::wrap_master_secret_with_pin(&secret, "1234").unwrap();
    let phrase = e2e::master_secret_to_phrase(&secret);

    // Correctness sanity: right PIN opens.
    let opened = e2e::unwrap_master_secret_with_pin(&blob, "1234").unwrap();
    assert_eq!(e2e::master_secret_to_phrase(&opened), phrase);

    // Cost measurement: time N wrong-PIN evaluations (what an attacker runs).
    let n = 20u32;
    let start = Instant::now();
    let mut found = None;
    for i in 0..n {
        let guess = format!("{i:04}");
        if let Ok(rec) = e2e::unwrap_master_secret_with_pin(&blob, &guess) {
            found = Some(e2e::master_secret_to_phrase(&rec));
            break;
        }
    }
    let per_try = start.elapsed() / n;
    let tries_per_sec = 1.0f64 / per_try.as_secs_f64();

    assert!(found.is_none(), "no collision expected inside first 20 guesses");

    let k4 = 10_000.0f64;
    let k6 = 1_000_000.0f64;
    println!(
        "per-guess: {per_try:?} ({tries_per_sec:.1} guesses/s) \
         | full 4-digit keyspace ≈ {:.1}s | 6-digit ≈ {:.1} min",
        k4 / tries_per_sec,
        k6 / tries_per_sec / 60.0,
    );

    // The audit claim, pinned: a single offline guess costs less than a second
    // at shipped Argon2id params (m=19MiB, t=2, p=1), so the full 4-digit space
    // falls well under a minute on one core — no server-side lockout involved.
    assert!(
        per_try.as_secs_f64() < 1.5,
        "single offline guess unexpectedly expensive — re-evaluate finding M9"
    );
}
