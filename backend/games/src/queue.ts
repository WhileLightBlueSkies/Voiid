// Per-match async serialization (LUDO_GAME_SPEC.md §7.3).
//
// Extracted from index.ts so the concurrency guarantee is testable without a Redis
// connection: every input for one match flows through ONE queue entry — compare expectedSeq,
// restore, validate, apply, increment, persist, broadcast — and a second input for the same
// match cannot interleave between the first's load and save.
//
// Node's event loop ordering alone never guaranteed that: `await` inside one handler yields,
// and the next input for the same match ran its load on the PRE handler's state. Two devices
// submitting simultaneously therefore produced two accepted transitions where the contract
// requires exactly one plus one STALE_SEQ.

const queues = new Map<string, Promise<unknown>>();

/** Run `job` exclusively per key; jobs for the same key run in arrival order. */
export function enqueue<T>(key: string, job: () => Promise<T>): Promise<T> {
    const tail = queues.get(key) ?? Promise.resolve();
    const run = tail.then(job, job);
    // The stored tail swallows errors so one throwing job cannot poison the queue.
    queues.set(
        key,
        run.then(
            () => undefined,
            () => undefined,
        ),
    );
    return run;
}

/** Test hook: wait for every queued job of a key to settle. */
export async function drainQueue(key: string): Promise<void> {
    await (queues.get(key) ?? Promise.resolve());
}

/** Test hook: forget all queues. */
export function clearQueues(): void {
    queues.clear();
}
