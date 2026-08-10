# Should the games backend move to its own server?

**Short answer: yes eventually, no right now.** The instinct is correct and the architecture already anticipates it — but moving today buys you almost nothing and costs you a shared-Redis problem you don't currently have.

---

# 1. Where it runs today

`voiid-games` is a pm2 process on **Box A**, alongside `voiid-api`, `voiid-ws`, `voiid-workers` and Redis ([`infrastructure/deployment/deploy-dev.sh:69-73`](../../infrastructure/deployment/deploy-dev.sh#L69-L73)).

The topology in [`../DEPLOYMENT.md`](../DEPLOYMENT.md) §Boxes:

| Box | Runs | Why split |
|---|---|---|
| **Box A** | API + WebSocket + Workers + **Games** + Redis | the app |
| **Box B** | LiveKit SFU only | media-heavy; a group call must not degrade the API |
| Managed | Postgres (Supabase) | — |

So the precedent for "split a noisy service onto its own box" already exists in this system, and it was made for exactly the reason you're thinking about.

---

# 2. Why the instinct is right

Games is the **worst-behaved neighbour** on Box A:

- **It is the only CPU-bound service.** `startLoop` runs a `setInterval` per live arcade match at `tickHz`. Every Snake match is 10 full-world simulations a second — collision over every snake body against every other, plus ~260 food items. CPU scales with *live arcade matches*, and nothing else on Box A scales that way.
- **It is the highest-churn code in the backend.** New games, rules tweaks, tuning. Every deploy restarts it, and it is the service most likely to ship a bug.
- **A busy match loop competes with the event loop that delivers messages.** Node is single-threaded per process — the processes are separate, but the CPU is not. A box saturated by Snake ticks adds latency to chat.
- **Messaging is the core product; games are not.** The whole argument for splitting LiveKit onto Box B applies here almost word for word.

---

# 3. Why not yet

## 3.1 Redis is the actual coupling, and it's on Box A

`backend/games` talks to Redis for **everything**: live match state, the `channel:games:input` subscription, and the `channel:user:<id>` fan-out that pushes `game_state` back to players. Redis is currently a **local process on Box A** and [`../DEPLOYMENT.md`](../DEPLOYMENT.md) calls it "the only stateful piece on Box A."

Move games to Box C and every one of those operations becomes a network round trip — including the ones on the hot path, at 10 Hz per match. You would be trading a CPU-contention problem you can measure for a latency problem you'd have to re-tune the jitter buffer around.

**The prerequisite is managed Redis** (the doc already suggests this for a fully-disposable Box A), not a games box. Do that first, and the split becomes almost free.

## 3.2 Nothing is actually saturated

The split is worth doing when Box A's CPU is genuinely contended. 4 vCPU / 8 GB running a handful of concurrent Snake matches is not close. **Measure before moving:** watch `pm2 monit` CPU for `voiid-games` during peak, and split when it sustains a meaningful fraction of a core.

## 3.3 pm2 restart isolation already gets you most of the safety benefit

The biggest practical risk — "a bad Snake deploy breaks chat" — is *already* mitigated. Games is a separate process with a separate `pm2 restart`, and the deploy script starts it independently. A crash loop in `voiid-games` does not touch `voiid-api`. The remaining exposure is CPU contention, which is §3.2's measurement question.

---

# 4. What to do instead, now

In order:

1. **Instrument it.** Per-match tick duration and a count of live loops, exported from `backend/games`. You cannot make this decision without knowing what a Snake match actually costs. This is the single most useful thing on this page.
2. **Cap concurrent arcade matches** with a clear error when exceeded. Today an unbounded number of Snake matches can be created and each one starts a `setInterval`. That is the failure mode that would take down Box A, and a box move does not fix it — it just relocates it.
3. **Move Redis to managed** when convenient. This is the real prerequisite for any split, and it independently makes Box A disposable, which [`../DEPLOYMENT.md`](../DEPLOYMENT.md) already wants.
4. **Then split games onto Box C** when the numbers from #1 say so.

---

# 5. When you do split it

The move itself is small, because the service was built for it:

- `backend/games` has **no HTTP surface** — it is a pure Redis subscriber. Nothing points a DNS record at it, no Caddy config, no TLS. It just needs `REDIS_URL` and `DATABASE_URL`.
- Both are already environment variables ([`redis.ts:9`](../../backend/games/src/redis.ts#L9), [`db.ts:13`](../../backend/games/src/db.ts#L13)) with no hardcoded hosts.
- The relay does not know or care where the games service lives; it publishes to `channel:games:input` and that is the entire contract.

**Concretely:** provision Box C, install Node, deploy `@voiid/games` with `REDIS_URL` pointing at managed Redis and `DATABASE_URL` at Supabase, `pm2 start`, and remove it from Box A's deploy script. No client change, no API change, no migration.

**Two things to get right:**

- **Redis latency.** Same region, same private network. Games is chatty at 10 Hz and cross-region Redis would be fatal to the tick loop.
- **Only one games process may run a given match's tick loop.** `startLoop` is keyed on match id in the process's own memory. Running two games instances today would double-tick every match. If you ever want more than one, you need loop ownership in Redis first (a lock per match) — this is a horizontal-scaling prerequisite, not a box-move one, but it is the thing that bites when you eventually want two.

---

# 6. Answer

**Good instinct, right eventual destination, wrong first step.** The order that matters is:

> **instrument → cap concurrent matches → managed Redis → then move the box.**

Moving first, while Redis still lives on Box A, converts every tick's state access into a network hop and would likely make Snake feel *worse* — which is the opposite of what you want given [`SNAKE.md`](./SNAKE.md) §2 is still open.
