//! E01 — the documentation must not claim things the repository does not do.
//!
//! Every defect E01 found in this area was a CLAIM, not a cryptographic flaw: a
//! README rule naming a library the code does not use, a SECURITY.md pointing at a
//! CI workflow that did not exist, an ignore list justified by an upstream state
//! that had since changed. Those are exactly the failures that survive code review,
//! because nobody re-reads a settled document — so they are asserted here instead,
//! where drift fails a build.
//!
//! WHAT THIS CANNOT DO. It cannot tell you the cryptography is sound. E01 clauses 4
//! and 5 require an independent protocol review, and no test file substitutes for
//! one. This only keeps the written claims honest.
use std::fs;
use std::path::{Path, PathBuf};

fn repo_root() -> PathBuf {
    // tests/ -> e2e-core -> packages -> repo
    Path::new(env!("CARGO_MANIFEST_DIR"))
        .ancestors()
        .nth(2)
        .expect("repository root")
        .to_path_buf()
}

fn read(rel: &str) -> String {
    let p = repo_root().join(rel);
    fs::read_to_string(&p).unwrap_or_else(|e| panic!("cannot read {}: {e}", p.display()))
}

#[test]
fn readme_does_not_claim_a_crypto_library_we_do_not_use() {
    let readme = read("README.md");
    let manifest = read("packages/e2e-core/Cargo.toml");

    assert!(
        manifest.contains("vodozemac"),
        "this test's premise is stale: the crate no longer depends on vodozemac"
    );

    // The README may DISCUSS the retired claim (it explains why it was wrong), but it
    // must not still present libsignal as what the code uses. Check the golden-rules
    // line specifically rather than the whole file.
    for line in readme.lines() {
        let l = line.to_lowercase();
        if l.contains("libsignal") {
            assert!(
                l.contains("used to say") || l.contains("never happened"),
                "README still presents libsignal as the crypto in use, but the crate is built \
                 on vodozemac/OpenMLS: {line}"
            );
        }
    }
}

#[test]
fn security_md_only_points_at_ci_that_exists() {
    let security = read("packages/e2e-core/SECURITY.md");
    let root = repo_root();

    // Regex over the text, not whitespace tokens: an earlier version split on
    // whitespace and trimmed a fixed character set, which left the trailing comma on
    // "`.github/workflows/ci.yml`," so the path never matched the .yml suffix check
    // and the gate passed against a deliberately broken document. Found by running
    // the anti-vacuity revert, which is the only reason it was found at all.
    let re = regex::Regex::new(r"\.github/workflows/[A-Za-z0-9._-]+\.yml").unwrap();
    let mut checked = 0;
    for m in re.find_iter(&security) {
        checked += 1;
        assert!(
            root.join(m.as_str()).is_file(),
            "SECURITY.md points at {}, which does not exist. A named-but-absent \
             workflow reads as an assurance that is actually running, and is not.",
            m.as_str()
        );
    }
    assert!(
        checked > 0,
        "SECURITY.md no longer names the CI that runs the audit — update this gate"
    );
}

#[test]
fn the_audit_runs_in_ci_with_a_version_that_can_read_the_database() {
    // cargo-audit 0.21 cannot parse CVSS 4.0 and fails to load the ENTIRE advisory
    // database, so it audits nothing. Pinning it back is a silent loss of coverage.
    let mut found = 0;
    for wf in ["ci.yml", "nightly.yml"] {
        let text = read(&format!(".github/workflows/{wf}"));
        if !text.contains("cargo audit") {
            continue;
        }
        found += 1;
        assert!(
            !text.contains("cargo-audit --locked --version ^0.21"),
            "{wf} pins cargo-audit ^0.21, which cannot parse the current advisory database \
             (CVSS 4.0) and therefore scans nothing"
        );
        assert!(
            text.contains("cargo audit --deny warnings"),
            "{wf} runs cargo audit without --deny warnings, so an advisory would not fail it"
        );
    }
    assert!(
        found >= 2,
        "cargo audit must run both per-change and on a schedule; found {found}"
    );
}

#[test]
fn every_suppressed_advisory_carries_its_status() {
    let audit = read("packages/e2e-core/.cargo/audit.toml");
    assert!(
        audit.contains("Reviewed: 2026-09-06"),
        "the ignore list must carry the date it was last reconciled against a real scan"
    );

    // Each ignored ID needs a comment on its own line saying where it stands. An
    // unannotated ID is an unowned exception.
    for line in audit.lines() {
        let t = line.trim();
        if t.starts_with("\"RUSTSEC-") {
            assert!(
                t.contains('#'),
                "suppressed advisory without a status comment: {t}"
            );
            let note = t.split('#').nth(1).unwrap().to_lowercase();
            assert!(
                note.contains("fixed in")
                    || note.contains("no fixed version")
                    || note.contains("no fix")
                    || note.contains("build-time only"),
                "{t} does not say whether a fix exists — an exception nobody re-examines is \
                 how a tracked liability becomes a silent acceptance"
            );
        }
    }
}

#[test]
fn the_unreviewed_pq_combiner_is_still_gated() {
    // E01 clause 3 asks that this compile-time gate be KEPT. A test, because the way
    // it would be lost is somebody removing a cfg they found inconvenient.
    let pqxdh = read("packages/e2e-core/src/pqxdh.rs");
    assert!(
        pqxdh.contains("feature = "),
        "the unreviewed 1:1 PQ combiner must stay behind a compile-time feature gate"
    );
}
