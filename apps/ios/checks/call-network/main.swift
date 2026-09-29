// Every case behind "Your network is weak". Run:
//   swiftc -o /tmp/cnc apps/ios/Voiid/Voiid/Networking/CallNetworkVerdict.swift \
//          apps/ios/checks/call-network/main.swift && /tmp/cnc
import Foundation

var failures = 0
func check(_ ok: Bool, _ name: String) {
    print(ok ? "  ✓ \(name)" : "  ✗ \(name)")
    if !ok { failures += 1 }
}
func weak(up: Double?, down: Double?, rtt: Double?) -> Bool? {
    CallNetworkVerdict.ownSideLooksWeak(uplinkLossPct: up, downlinkLossPct: down, rttMs: rtt)
}

print("Whose network is weak — one sample")
check(weak(up: 0, down: 0, rtt: 40) == false,        "clean call: no warning")
check(weak(up: 12, down: 0, rtt: 90) == true,        "MY sent audio being lost (12%): warn me")
check(weak(up: 0, down: 20, rtt: 90) == false,       "only THEIR audio lost reaching me: not me (they get warned)")
check(weak(up: 3, down: 0, rtt: 900) == true,        "900ms round trip + my audio lost: my uplink is queueing")
check(weak(up: 0, down: 0, rtt: 900) == false,       "900ms, no loss either way: can't tell whose — warn nobody")
check(weak(up: 6, down: 15, rtt: 200) == true,       "loss both ways: most likely my connection")
check(weak(up: 7.9, down: 0, rtt: 100) == false,     "just under the uplink threshold: no warning")
check(weak(up: 8, down: 0, rtt: 100) == true,        "exactly at the uplink threshold: warn")
check(weak(up: nil, down: nil, rtt: nil) == nil,     "no reading yet (call just started): undecided")
check(weak(up: nil, down: 30, rtt: nil) == nil,      "downlink only, no RTT/uplink yet: undecided")
check(weak(up: nil, down: 0, rtt: 60) == false,      "RTT but no uplink report yet: no warning")

print("Today's real calls (averages from call_metrics)")
check(weak(up: 10.1, down: 10.1, rtt: 3082) == true,  "3s round trip, 10% loss: warn")
check(weak(up: 58, down: 58, rtt: 567) == true,       "567ms, 58% loss: warn")
check(weak(up: 1.8, down: 1.8, rtt: 131) == false,    "131ms, 1.8% loss — an OK call: no warning")
check(weak(up: 0, down: 0, rtt: 16) == false,         "last night's 16ms calls: no warning")

print("No flicker")
var t = WeakNetworkTracker()
t.record(true); check(t.isWeak == false,              "1 weak sample (a blip): still hidden")
t.record(false); t.record(true)
check(t.isWeak == false,                              "weak, good, weak: never 2 in a row, stays hidden")
t.record(true); check(t.isWeak == true,               "2 weak in a row (~6s): shown")
t.record(false); t.record(false)
check(t.isWeak == true,                               "2 good after: still shown (not settled yet)")
t.record(true)
check(t.isWeak == true,                               "a weak sample mid-recovery restarts the count")
t.record(false); t.record(false); t.record(false)
check(t.isWeak == false,                              "3 good in a row (~9s): hidden")
t.record(nil); t.record(nil)
check(t.isWeak == false,                              "no readings: state unchanged")
t.record(true); t.record(true); t.record(nil)
check(t.isWeak == true,                               "no reading while shown: stays shown")
t.reset(); check(t.isWeak == false,                   "new call: reset")

print(failures == 0 ? "\nALL PASS" : "\n\(failures) FAILED")
exit(failures == 0 ? 0 : 1)
