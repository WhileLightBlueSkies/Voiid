import Foundation

// Does a mutation that lands DURING the write get its dirty mark eaten?
//
// The old persist() was synchronous, so "mark dirty during the write" was impossible
// on the main actor. Making it async opens that window, and the subtraction that was
// safe before is now subtracting a conversation whose CURRENT contents were never
// written — only an older snapshot of them was.

actor Writer {
    func write(_ batch: [String: [String]]) async -> Set<String> {
        try? await Task.sleep(nanoseconds: 50_000_000)   // the IO
        return Set(batch.keys)
    }
}

@MainActor
final class Engine {
    var store: [String: [String]] = ["c1": ["m1"]]
    var dirty: Set<String> = []
    let writer = Writer()
    var written: [String: [String]] = [:]

    func markDirty(_ c: String) { dirty.insert(c) }

    func persist() async -> Bool {
        let claimed = dirty
        guard !claimed.isEmpty else { return true }
        var batch: [String: [String]] = [:]
        for c in claimed { batch[c] = store[c] ?? [] }
        dirty.subtract(claimed)            // clear BEFORE suspending
        let committed = await writer.write(batch)
        for (c, v) in batch where committed.contains(c) { written[c] = v }
        dirty.formUnion(claimed.subtracting(committed))   // only failures are re-marked
        return committed.count == claimed.count
    }
}

@MainActor func run() async {
    let e = Engine()
    e.markDirty("c1")
    async let p: Bool = e.persist()
    // A message arrives 10ms in — while the write is suspended.
    try? await Task.sleep(nanoseconds: 10_000_000)
    e.store["c1"] = ["m1", "m2-arrived-during-the-write"]
    e.markDirty("c1")
    _ = await p

    print("on disk:      \(e.written["c1"] ?? [])")
    print("in memory:    \(e.store["c1"] ?? [])")
    print("still dirty:  \(e.dirty)")
    let lost = (e.written["c1"] ?? []) != (e.store["c1"] ?? []) && e.dirty.isEmpty
    print(lost
        ? "\nFAIL  m2 is in memory, NOT on disk, and nothing is marked to retry — it is lost at exit"
        : "\nPASS  the conversation is still owed, so the next persist writes m2")
    exit(lost ? 1 : 0)
}
await run()
