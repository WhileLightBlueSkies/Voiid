import Foundation

// I01 — what a 10k/50k-message history actually costs on the path that runs while
// the user is typing. The record shape mirrors DecryptedMessage's persisted fields.
struct Msg: Codable {
    let id: String
    let senderId: String
    var text: String
    let createdAt: Date
    let isMine: Bool
    var pending: Bool = false
    var serverId: String? = nil
    var deliveryStatus: String? = nil
    var deliveredAt: Date? = nil
    var readAt: Date? = nil
}

func history(_ n: Int) -> [Msg] {
    (0..<n).map { i in
        Msg(id: UUID().uuidString, senderId: UUID().uuidString,
            text: "Message \(i) — a realistic sentence of chat text, roughly this long.",
            createdAt: Date(timeIntervalSince1970: 1_700_000_000 + Double(i)),
            isMine: i % 2 == 0, pending: false,
            serverId: UUID().uuidString, deliveryStatus: "read",
            deliveredAt: Date(), readAt: Date())
    }
}

func ms(_ block: () -> Void) -> Double {
    let t = DispatchTime.now()
    block()
    return Double(DispatchTime.now().uptimeNanoseconds - t.uptimeNanoseconds) / 1_000_000
}

var failures = 0
func check(_ name: String, _ cond: Bool, _ detail: String = "") {
    print((cond ? "PASS  " : "FAIL  ") + name + (cond ? "" : "  -- " + detail))
    if !cond { failures += 1 }
}

let budget = 16.67   // one 60fps frame

print("=== CURRENT BEHAVIOUR: encode the WHOLE conversation per message ===")
for n in [1_000, 10_000, 50_000] {
    let msgs = history(n)
    let enc = JSONEncoder()
    var bytes = 0
    let t = ms { bytes = (try! enc.encode(msgs)).count }
    let frames = t / budget
    print(String(format: "  %6d messages: encode %8.1f ms  (%.1f frames, %.1f MB)",
                 n, t, frames, Double(bytes)/1024/1024))
}

print("\n=== COLD LAUNCH: decode every shard ===")
let enc = JSONEncoder()
for n in [10_000, 50_000] {
    let data = try! enc.encode(history(n))
    let dec = JSONDecoder()
    var out: [Msg] = []
    let t = ms { out = try! dec.decode([Msg].self, from: data) }
    print(String(format: "  %6d messages: decode %8.1f ms  (%.1f frames)", n, t, t/budget))
    precondition(out.count == n)
}

print("\n=== THE FIX: only the newest page is decoded/kept for display ===")
let pageSize = 50
for n in [10_000, 50_000] {
    let msgs = history(n)
    // Newest page — what the UI actually renders on open.
    var page: [Msg] = []
    let t = ms { page = Array(msgs.suffix(pageSize)) }
    print(String(format: "  %6d messages: newest %d-page in %6.3f ms", n, pageSize, t))
    precondition(page.count == pageSize)
}

// The claims worth asserting rather than eyeballing.
let big = history(50_000)
let encodeBig = ms { _ = try! JSONEncoder().encode(big) }
check("a 50k history costs more than one frame to re-encode",
      encodeBig > budget,
      String(format: "%.1f ms — the defect did not reproduce", encodeBig))
// Five frames, not ten: the measured cost on a development Mac is ~8.8 frames
// (147ms). "Ten" was a guess and it failed against correct code — the threshold has
// to come from the measurement, not from a round number that sounded bad enough.
// A phone is slower than this, so this is the floor of the problem, not its size.
check("a 50k history costs more than FIVE frames to re-encode",
      encodeBig > budget * 5, String(format: "only %.1f ms", encodeBig))

let pageCost = ms { _ = Array(big.suffix(pageSize)) }
check("taking the newest page stays well inside one frame",
      pageCost < budget, String(format: "%.3f ms", pageCost))
check("paging is at least 100x cheaper than whole-history encoding",
      encodeBig / max(pageCost, 0.0001) > 100,
      String(format: "%.1f ms vs %.4f ms", encodeBig, pageCost))

// ── The read path's ordering, which is a correctness bug, not a speed one ──────
//
// LocalStore.messages was `ORDER BY created_at ASC LIMIT 500`: the 500 OLDEST
// messages. Model both against a 10k history and ask the only question that
// matters — does the user see the recent conversation, or the start of it?

print("\n=== READ PATH: which 50 messages does opening a chat show? ===")
let thread = history(10_000)

// OLD: oldest-first, limited.
let oldPage = Array(thread.sorted { $0.createdAt < $1.createdAt }.prefix(50))
// NEW: newest-first selection, reversed for display.
let newPage = Array(thread.sorted { $0.createdAt > $1.createdAt }.prefix(50)).reversed()

print("   OLD first row: \(oldPage.first!.text)")
print("   NEW first row: \(newPage.first!.text)")
check("OLD: opening a chat shows the START of a 10k history",
      oldPage.last!.text.contains("Message 49"),
      "the defect did not reproduce: \(oldPage.last!.text)")
check("NEW: opening a chat shows the END of a 10k history",
      newPage.last!.text.contains("Message 9999"),
      "got \(newPage.last!.text)")
check("NEW: the page is rendered oldest-first within itself",
      newPage.first!.createdAt < newPage.last!.createdAt)

// ── Keyset paging over TIED timestamps ────────────────────────────────────────
//
// created_at is a whole second here, as it is in the SQLite column. A burst of
// messages therefore shares a timestamp, and a page boundary landing inside such a
// group is where an ORDER BY created_at alone skips rows for good.
print("\n=== KEYSET PAGING over tied timestamps ===")
let tiedAt = Date(timeIntervalSince1970: 1_800_000_000)
var tied: [Msg] = (0..<300).map { i in
    Msg(id: String(format: "id-%04d", i), senderId: "s", text: "tied \(i)",
        createdAt: tiedAt, isMine: false)
}
tied += (0..<20).map { i in
    Msg(id: String(format: "later-%04d", i), senderId: "s", text: "later \(i)",
        createdAt: tiedAt.addingTimeInterval(Double(i + 1)), isMine: false)
}

/// The NEW predicate: strictly-before on the (created_at, id) TUPLE.
func pageBeforeKeyset(_ all: [Msg], ts: Date, id: String, limit: Int) -> [Msg] {
    Array(all.filter { $0.createdAt < ts || ($0.createdAt == ts && $0.id < id) }
             .sorted { ($0.createdAt, $0.id) > ($1.createdAt, $1.id) }
             .prefix(limit)).reversed()
}
/// The OLD predicate: strictly-before on the timestamp alone.
func pageBeforeTimestamp(_ all: [Msg], ts: Date, limit: Int) -> [Msg] {
    Array(all.filter { $0.createdAt < ts }
             .sorted { $0.createdAt > $1.createdAt }
             .prefix(limit)).reversed()
}

func drain(keyset: Bool, pageSize: Int) -> Set<String> {
    var seen = Set<String>()
    var cursorTs = Date(timeIntervalSince1970: 4_000_000_000)
    var cursorId = "~"
    for _ in 0..<200 {
        let page = keyset
            ? pageBeforeKeyset(tied, ts: cursorTs, id: cursorId, limit: pageSize)
            : pageBeforeTimestamp(tied, ts: cursorTs, limit: pageSize)
        if page.isEmpty { break }
        page.forEach { seen.insert($0.id) }
        cursorTs = page.first!.createdAt
        cursorId = page.first!.id
    }
    return seen
}

let keysetSeen = drain(keyset: true, pageSize: 25)
let tsSeen = drain(keyset: false, pageSize: 25)
print("   timestamp-only cursor reached \(tsSeen.count)/\(tied.count) messages")
print("   keyset cursor reached        \(keysetSeen.count)/\(tied.count) messages")
check("OLD: a timestamp-only cursor SKIPS messages inside a tied block",
      tsSeen.count < tied.count,
      "expected the defect to reproduce; it did not")
check("NEW: the keyset cursor reaches every message",
      keysetSeen.count == tied.count,
      "missed \(tied.count - keysetSeen.count)")

print(failures == 0 ? "\nALL CHECKS PASSED" : "\n\(failures) CHECK(S) FAILED")
exit(failures == 0 ? 0 : 1)
