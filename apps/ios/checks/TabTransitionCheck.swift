import Foundation

// Models the two implementations of "release the stretch after the indicator arrives",
// exercised with the rapid-tap sequence U05's acceptance names (A->B->C->A).
//
// The question is only ever: can a callback scheduled by an EARLIER tap change state
// that belongs to a LATER one?

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print((cond ? "PASS  " : "FAIL  ") + name + (cond ? "" : "  -- " + detail))
    if !cond { failures += 1 }
}

@MainActor
final class OldBar {          // DispatchQueue.main.asyncAfter — uncancellable
    var isSliding = false
    var tab = 0
    func tap(_ t: Int) {
        guard tab != t else { return }
        let distance = abs(t - tab)
        isSliding = true
        tab = t
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.10 + Double(distance) * 0.02) {
            self.isSliding = false          // unconditional: no idea which tap it belongs to
        }
    }
}

@MainActor
final class NewBar {          // cancellable Task owned by the view
    var isSliding = false
    var tab = 0
    private var slideRelease: Task<Void, Never>?
    func tap(_ t: Int) {
        guard tab != t else { return }
        let distance = abs(t - tab)
        isSliding = true
        tab = t
        slideRelease?.cancel()
        slideRelease = Task { @MainActor in
            let ns = UInt64((0.10 + Double(distance) * 0.02) * 1_000_000_000)
            guard (try? await Task.sleep(nanoseconds: ns)) != nil else { return }
            self.isSliding = false
        }
    }
    func disappear() { slideRelease?.cancel(); slideRelease = nil; isSliding = false }
    var hasPendingWork: Bool { slideRelease != nil && slideRelease?.isCancelled == false }
}

@MainActor
func run() async {
    // A->B->C->A, each 30ms apart: well inside the 100-140ms release delays, so every
    // earlier callback is still pending when the next tap happens.
    let old = OldBar()
    old.tap(1); try? await Task.sleep(nanoseconds: 30_000_000)
    old.tap(2); try? await Task.sleep(nanoseconds: 30_000_000)
    old.tap(0)
    // The first tap's timer (0.10 + 1*0.02 = 120ms) fires ~60ms from here, mid-flight
    // for the A tap whose own release is 140ms away.
    try? await Task.sleep(nanoseconds: 90_000_000)
    print("   old bar, 90ms after the final tap: isSliding =", old.isSliding)
    check("OLD: an earlier tap's callback breaks the newest transition",
          old.isSliding == false,
          "expected the defect to reproduce; it did not")

    let new = NewBar()
    new.tap(1); try? await Task.sleep(nanoseconds: 30_000_000)
    new.tap(2); try? await Task.sleep(nanoseconds: 30_000_000)
    new.tap(0)
    try? await Task.sleep(nanoseconds: 90_000_000)
    print("   new bar, 90ms after the final tap: isSliding =", new.isSliding)
    check("NEW: only the newest transition can end its own stretch",
          new.isSliding == true,
          "a superseded callback still fired")

    // ...and it does end, rather than hanging forever.
    try? await Task.sleep(nanoseconds: 120_000_000)
    check("NEW: the newest transition does release its stretch",
          new.isSliding == false, "the stretch never released")

    // Nothing delayed survives disappearance.
    let gone = NewBar()
    gone.tap(3)
    gone.disappear()
    check("NEW: disappearing cancels pending work", !gone.hasPendingWork)
    try? await Task.sleep(nanoseconds: 200_000_000)
    check("NEW: no state change after disappearance", gone.isSliding == false)

    print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
    exit(failures == 0 ? 0 : 1)
}
await run()
