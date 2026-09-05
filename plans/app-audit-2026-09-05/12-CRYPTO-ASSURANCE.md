# 12 — Encryption assurance and dependency evidence

Baseline: `a2e24e5` · 2026-09-05 · All tasks TODO; fixes specified, not implemented.

## E01 — Reconcile crypto assurances with current code and executable gates

**Priority:** P1 · **Evidence:** Confirmed assurance gap; exploitability unverified · **Dependencies:** S04, Q02, A02/I03

**Location:** `packages/e2e-core/Cargo.toml:18`, `:40`, `:58`; `src/pqxdh.rs:140`; `.cargo/audit.toml:17`; `SECURITY.md:73`; repository `.github/workflows/` contains only two deployment workflows in this snapshot. Root README still names libsignal while current implementation uses vodozemac/OpenMLS.

The crate has valuable tests and explicit protocol limitations, but its security document claims an `e2e-core-audit.yml` workflow that is absent. Its advisory ignore list contains ten IDs including an unmaintained tooling dependency. These are recorded liabilities, not proof of a newly demonstrated exploit. No fresh advisory-database scan or independent cryptographic review was run here.

**Fix:**
1. Run a fresh advisory audit over the full locked dependency tree using the current official advisory database, retain the complete report, and reconcile every ignore with an owner, affected path, current upstream status and review date. Do not infer current versions/fix availability from historical comments.
2. Restore automated locked Rust tests, dependency audit and periodic fuzz/soak execution in CI. Keep reports even when an approved exception exists; never broadly suppress future advisories.
3. Reconcile README/security/product claims: classic 1:1 Olm ratchet versus MLS group properties, private content versus public Clips, and the recovery threat model. Keep the compile-time gate on the unreviewed 1:1 PQ combiner.
4. Commission an independent protocol/integration review covering identity verification, malicious key directory, fallback rotation, MLS credential binding/member removal, nonce generation, pickle/backup storage, crash consistency, FFI panic/error handling and call-media encryption. Existing test success does not replace this review.
5. Any protocol/dependency migration needs mixed-version compatibility fixtures, account/session/group recovery tests and a documented upgrade boundary. Verify generated Swift/Kotlin bindings and packaged native binaries correspond to the reviewed Rust commit.

**Done when:** current scan evidence and exception ownership are recorded, missing CI exists and runs, documentation accurately matches shipped behavior, and changes requiring cryptographic review have that evidence. Do not implement novel cryptography merely to mark this task done.

**Strengths to preserve:** standard cryptographic libraries; explicit unreviewed-PQ activation block; randomized robustness/fuzz and cross-device tests; content-free push payload builders; no need to replace the entire encryption core as a visual-performance project.
