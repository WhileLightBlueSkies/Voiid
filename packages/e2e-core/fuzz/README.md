# Fuzzing the Voiid E2E core

libFuzzer targets for the attacker-facing decrypt/deserialize entry points.
These run untrusted bytes (as if from the relay) through the parsers and assert,
by construction, that the only outcomes are `Ok`/`Err` — never a panic, hang, or
memory-safety violation.

## Targets

| Target | Entry point fuzzed |
|---|---|
| `fuzz_session_decrypt` | `Session::decrypt` (1:1 ratchet message) |
| `fuzz_accept_session` | `accept_session` (session bootstrap from first message) |
| `fuzz_group_decrypt` | `GroupSession::decrypt` (MLS message) |
| `fuzz_media_decrypt` | `decrypt_media` (attachment blob + key) |

## Run

Requires the nightly toolchain and `cargo-fuzz`:

```bash
cargo install cargo-fuzz          # once
cd packages/e2e-core
cargo +nightly fuzz run fuzz_session_decrypt
cargo +nightly fuzz run fuzz_group_decrypt
# ... etc. Add -- -max_total_time=300 to bound a run.
```

A crash writes a reproducer to `fuzz/artifacts/`; re-run that input to debug.

## No cargo-fuzz installed?

`tests/robustness.rs` runs the same entry points against thousands of random and
mutated inputs under plain `cargo test` (deterministic seed), so the no-panic
property is exercised in CI without extra tooling. The libFuzzer targets here
provide deeper, coverage-guided exploration when you want it.
