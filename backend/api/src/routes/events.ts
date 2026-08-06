// Community events, orders and tickets — the free-RSVP half of Phase 2, with the paid half
// wired but deliberately switched off until somebody chooses a payment provider.
//
// ── THE E2EE POSTURE, STATED PLAINLY ─────────────────────────────────────────────
//
// Everything this router touches is SERVER-READABLE, and 032_events_tickets.sql makes that a
// scoped, reasoned exception in the same voice as 022_clips.sql. The short version: an order
// has a counterparty who is not the user (a bank, an accountant, a chargeback referee months
// later), a ticket has to be judged at a door by a volunteer, and an event listing is an
// advertisement whose entire purpose is to reach people who have not joined yet. None of those
// can be ciphertext.
//
// Messages, calls, location shares and moments are untouched and still unreadable by this
// server. `community_events.location_text` IS FREE TEXT AND IS NOT A LOCATION SHARE — it must
// never be wired to 018_location_shares.sql or presented as if it were.
//
// ── A TICKET GRANTS NO MESSAGING RIGHT AND NO MEMBERSHIP ─────────────────────────
//
// Buying entry to one evening writes no row in community_members, and therefore does not open
// the member->host exception in 020_reachability.sql. A follow, a join and a ticket all grant
// nothing on the message pipe. If you find code reading event_tickets to decide whether A may
// message B, that is the bug 029_creator_profiles.sql forbids for follows.
//
// ── FREE FIRST, ON PURPOSE ───────────────────────────────────────────────────────
//
// With no provider configured, a zero-price event works end to end — order, ticket, QR, door —
// and a priced event is refused at creation with a 501. That is what makes "ship free RSVP
// before wiring money" a property of the code rather than a line in a plan.
import { Router } from 'express';
import { randomUUID } from 'crypto';
import { pool, query } from '../db';
import { requireAuth } from '../auth';
import { rateLimit } from '../security';
import { asyncHandler } from '../util';
import { communityAccess } from '../communityRoles';
import { activeProvider, FREE_PROVIDER } from '../payments/provider';
import {
  newTicketNonce,
  signTicketCode,
  ticketSigningAvailable,
  verifyTicketCode,
} from '../payments/tickets';

const router = Router();

const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Postgres unique-violation. Used to turn a lost race into a re-read rather than a 500. */
const PG_UNIQUE_VIOLATION = '23505';

interface EventRow {
  id: string;
  community_id: string;
  title: string;
  description: string | null;
  starts_at: Date;
  ends_at: Date | null;
  location_text: string | null;
  capacity: number | null;
  price_minor: string;
  currency: string;
  status: string;
  created_by: string;
  created_at: Date;
}

/**
 * `price_minor` and `amount_minor` are bigint, which the pg driver returns as a STRING — it
 * will not silently narrow a 64-bit integer into a float64 and lose precision. Every amount is
 * well inside Number range at this scale, so they are converted at the edges, once, here, and
 * never compared as strings.
 */
const minor = (v: unknown): number => Number(v ?? 0);

function eventCard(e: EventRow) {
  return {
    id: e.id,
    community_id: e.community_id,
    title: e.title,
    description: e.description,
    starts_at: e.starts_at,
    ends_at: e.ends_at,
    location_text: e.location_text,
    capacity: e.capacity,
    price_minor: minor(e.price_minor),
    currency: e.currency,
    status: e.status,
    created_by: e.created_by,
    created_at: e.created_at,
    is_free: minor(e.price_minor) === 0,
  };
}

async function loadEvent(id: string): Promise<EventRow | undefined> {
  return (await query<EventRow>(`select * from community_events where id = $1`, [id]))[0];
}

/**
 * Resolve an event and prove the caller may see it, in one place — the same shape the
 * tournaments router uses, and for the same reason: one definition of "may this person look at
 * this", which no individual endpoint can quietly relax.
 *
 * A DRAFT IS VISIBLE ONLY TO ORGANISERS. It is an unfinished poster; showing it to the
 * community would make "draft" mean nothing.
 */
async function openEvent(
  id: unknown,
  userId: string,
  needsAdmin: boolean
): Promise<
  | { ok: true; event: EventRow; isOrganiser: boolean }
  | { ok: false; status: number; error: string }
> {
  if (typeof id !== 'string' || !UUID_RE.test(id)) {
    return { ok: false, status: 400, error: 'event id must be a uuid' };
  }
  const event = await loadEvent(id);
  if (!event) return { ok: false, status: 404, error: 'no such event' };

  const access = await communityAccess(event.community_id, userId, needsAdmin);
  if (!access.ok) return { ok: false, status: access.status, error: access.error };

  if (event.status === 'draft' && !access.isOrganiser) {
    // 404, not 403: a member has no business knowing that an unpublished event exists.
    return { ok: false, status: 404, error: 'no such event' };
  }
  return { ok: true, event, isOrganiser: access.isOrganiser };
}

// ─────────────────────────────────────────────────────────────────────────────────
// POST /communities/:id/events — create.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/communities/:id/events',
  requireAuth,
  rateLimit({ max: 30, windowSeconds: 3600, bucket: 'event-create' }),
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const communityId = String(req.params.id ?? '');
    if (!UUID_RE.test(communityId)) return res.status(400).json({ error: 'community id must be a uuid' });

    const access = await communityAccess(communityId, userId, true);
    if (!access.ok) return res.status(access.status).json({ error: access.error });

    const { title, description, starts_at, ends_at, location_text, capacity, price_minor, currency, publish } =
      req.body ?? {};

    if (typeof title !== 'string' || title.trim().length < 1 || title.trim().length > 120) {
      return res.status(400).json({ error: 'title must be 1-120 characters' });
    }
    const startsAt = new Date(starts_at);
    if (Number.isNaN(startsAt.getTime())) return res.status(400).json({ error: 'starts_at is required' });

    let endsAt: Date | null = null;
    if (ends_at != null) {
      endsAt = new Date(ends_at);
      if (Number.isNaN(endsAt.getTime())) return res.status(400).json({ error: 'ends_at is not a date' });
      if (endsAt <= startsAt) return res.status(400).json({ error: 'ends_at must be after starts_at' });
    }

    const cap = capacity == null ? null : Number(capacity);
    if (cap !== null && (!Number.isInteger(cap) || cap < 1)) {
      return res.status(400).json({ error: 'capacity must be a positive whole number' });
    }

    // MINOR UNITS, INTEGER. A float price is the bug that makes a ledger stop adding up, and it
    // is not recoverable after the fact — so a non-integer is rejected rather than rounded.
    const price = price_minor == null ? 0 : Number(price_minor);
    if (!Number.isInteger(price) || price < 0) {
      return res.status(400).json({ error: 'price_minor must be a whole number of minor units' });
    }

    const cur = typeof currency === 'string' ? currency.toUpperCase() : 'INR';
    if (!/^[A-Z]{3}$/.test(cur)) return res.status(400).json({ error: 'currency must be an ISO-4217 code' });

    // THE PAYWALL THAT ISN'T BUILT YET, refused honestly.
    //
    // 501 rather than 400: there is nothing wrong with what the organiser asked for, the server
    // simply cannot take money yet. Creating a priced event that silently admitted everyone for
    // free would be far worse than this refusal, and creating one that could not be paid for
    // would leave the organiser with a broken listing they could not diagnose.
    if (price > 0 && !activeProvider()) {
      return res.status(501).json({
        error: 'paid events are not available yet — set a price of 0 to take free RSVPs',
      });
    }

    const rows = await query<EventRow>(
      `insert into community_events
         (community_id, title, description, starts_at, ends_at, location_text,
          capacity, price_minor, currency, status, created_by)
       values ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11)
       returning *`,
      [
        communityId,
        title.trim(),
        typeof description === 'string' ? description : null,
        startsAt,
        endsAt,
        typeof location_text === 'string' ? location_text : null,
        cap,
        price,
        cur,
        publish === true ? 'published' : 'draft',
        userId,
      ]
    );

    res.status(201).json({ event: eventCard(rows[0]) });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// GET /communities/:id/events — the event tab.
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/communities/:id/events',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const communityId = String(req.params.id ?? '');
    if (!UUID_RE.test(communityId)) return res.status(400).json({ error: 'community id must be a uuid' });

    const access = await communityAccess(communityId, userId, false);
    if (!access.ok) return res.status(access.status).json({ error: access.error });

    // Drafts are filtered in SQL rather than after the fetch: an unpublished event must not
    // cross the process boundary at all for a non-organiser, because the next person to add a
    // field to this response should not have to remember to re-filter it.
    const rows = await query<EventRow & { your_order_status: string | null; ticket_count: string }>(
      `select e.*,
              o.status as your_order_status,
              (select count(*) from event_tickets t
                where t.event_id = e.id and t.state = 'valid')::text as ticket_count
         from community_events e
         left join event_orders o
                on o.event_id = e.id and o.buyer_id = $2
               and o.status in ('pending', 'paid')
        where e.community_id = $1
          and ($3::boolean or e.status <> 'draft')
        order by e.starts_at
        limit 200`,
      [communityId, userId, access.isOrganiser]
    );

    res.json({
      events: rows.map((r) => ({
        ...eventCard(r),
        your_order_status: r.your_order_status,
        tickets_issued: Number(r.ticket_count),
      })),
    });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// GET /events/:id
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/events/:id',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openEvent(req.params.id, userId, false);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    const counts = (
      await query<{ committed: string; issued: string }>(
        `select coalesce((select sum(quantity) from event_orders
                           where event_id = $1 and status in ('pending', 'paid')), 0)::text as committed,
                (select count(*) from event_tickets
                  where event_id = $1 and state = 'valid')::text as issued`,
        [opened.event.id]
      )
    )[0];

    const yours = await query(
      `select o.id as order_id, o.status as order_status, o.quantity,
              t.id as ticket_id, t.state as ticket_state, t.checked_in_at
         from event_orders o
         left join event_tickets t on t.order_id = o.id
        where o.event_id = $1 and o.buyer_id = $2
        order by o.created_at desc`,
      [opened.event.id, userId]
    );

    res.json({
      event: eventCard(opened.event),
      is_organiser: opened.isOrganiser,
      // "Committed" counts pending orders as well as paid ones, because a pending order is
      // holding a seat — see the note on capacity in the order route.
      seats_committed: Number(counts.committed),
      tickets_issued: Number(counts.issued),
      seats_left:
        opened.event.capacity == null ? null : Math.max(0, opened.event.capacity - Number(counts.committed)),
      your_orders: yours,
    });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// PATCH /events/:id — edit. Organiser only.
//
// PRICE AND CURRENCY ARE NOT EDITABLE ONCE AN ORDER EXISTS. An order snapshots what it cost
// (032), so changing the price does not corrupt history — but it would mean two people paid
// different amounts for the same listing with no explanation visible to either, and a refund
// dispute would turn on a number nobody can see any more.
// ─────────────────────────────────────────────────────────────────────────────────
router.patch(
  '/events/:id',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openEvent(req.params.id, userId, true);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    const { title, description, starts_at, ends_at, location_text, capacity, price_minor } = req.body ?? {};

    const sets: string[] = [];
    const params: unknown[] = [opened.event.id];
    const push = (col: string, value: unknown) => {
      params.push(value);
      sets.push(`${col} = $${params.length}`);
    };

    if (title !== undefined) {
      if (typeof title !== 'string' || title.trim().length < 1 || title.trim().length > 120) {
        return res.status(400).json({ error: 'title must be 1-120 characters' });
      }
      push('title', title.trim());
    }
    if (description !== undefined) push('description', typeof description === 'string' ? description : null);
    if (location_text !== undefined) {
      push('location_text', typeof location_text === 'string' ? location_text : null);
    }
    if (starts_at !== undefined) {
      const d = new Date(starts_at);
      if (Number.isNaN(d.getTime())) return res.status(400).json({ error: 'starts_at is not a date' });
      push('starts_at', d);
    }
    if (ends_at !== undefined) {
      if (ends_at === null) push('ends_at', null);
      else {
        const d = new Date(ends_at);
        if (Number.isNaN(d.getTime())) return res.status(400).json({ error: 'ends_at is not a date' });
        push('ends_at', d);
      }
    }
    if (capacity !== undefined) {
      const cap = capacity === null ? null : Number(capacity);
      if (cap !== null && (!Number.isInteger(cap) || cap < 1)) {
        return res.status(400).json({ error: 'capacity must be a positive whole number' });
      }
      // Lowering capacity below what is already sold is allowed and does NOT revoke anybody's
      // ticket. The organiser reduced the door count; the people already through the funnel
      // keep what they bought. `seats_left` clamps at zero, so the listing stops selling.
      push('capacity', cap);
    }
    if (price_minor !== undefined) {
      const orders = (
        await query<{ n: string }>(`select count(*)::text as n from event_orders where event_id = $1`, [
          opened.event.id,
        ])
      )[0];
      if (Number(orders.n) > 0) {
        return res.status(409).json({ error: 'the price cannot change once orders exist' });
      }
      const price = Number(price_minor);
      if (!Number.isInteger(price) || price < 0) {
        return res.status(400).json({ error: 'price_minor must be a whole number of minor units' });
      }
      if (price > 0 && !activeProvider()) {
        return res.status(501).json({ error: 'paid events are not available yet' });
      }
      push('price_minor', price);
    }

    if (sets.length === 0) return res.json({ event: eventCard(opened.event) });

    const rows = await query<EventRow>(
      `update community_events set ${sets.join(', ')} where id = $1 returning *`,
      params
    );
    res.json({ event: eventCard(rows[0]) });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /events/:id/publish  and  POST /events/:id/cancel
//
// Cancelling does NOT delete orders or tickets, and does not refund anything. A refund moves
// money and money moves through the provider, so it belongs to the payments router and to a
// human decision — a cancel button that silently issued refunds would be an organiser
// accidentally moving other people's money with one tap.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/events/:id/publish',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openEvent(req.params.id, userId, true);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    const rows = await query<EventRow>(
      `update community_events set status = 'published'
        where id = $1 and status = 'draft'
        returning *`,
      [opened.event.id]
    );
    if (rows.length === 0) return res.status(409).json({ error: 'this event is not a draft' });
    res.json({ event: eventCard(rows[0]) });
  })
);

router.post(
  '/events/:id/cancel',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openEvent(req.params.id, userId, true);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    const rows = await query<EventRow>(
      `update community_events set status = 'cancelled'
        where id = $1 and status in ('draft', 'published')
        returning *`,
      [opened.event.id]
    );
    if (rows.length === 0) return res.status(409).json({ error: 'this event is already cancelled' });
    res.json({ event: eventCard(rows[0]), note: 'existing tickets are untouched; refunds are separate' });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /events/:id/orders — RSVP, or start a checkout.
//
// ONE ENDPOINT FOR BOTH, on purpose. A free RSVP and a paid ticket differ only in whether a
// provider is involved; giving them separate endpoints would mean the free path never
// exercises the shape the paid path needs, which is exactly the de-risking free RSVP exists to
// do (04_communities_plan.md §4 Phase 2).
//
// CAPACITY COUNTS PENDING ORDERS. A pending order is holding a seat — if it did not, an event
// with ten seats could accept a hundred checkouts and disappoint ninety people after they had
// paid. The cost of that choice is that abandoned checkouts hold seats until they are
// cancelled; see the note at the end of this handler.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/events/:id/orders',
  requireAuth,
  rateLimit({ max: 60, windowSeconds: 3600, bucket: 'event-order' }),
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openEvent(req.params.id, userId, false);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });
    const event = opened.event;

    if (event.status !== 'published') {
      return res.status(409).json({ error: 'this event is not open for registration' });
    }

    const quantity = req.body?.quantity == null ? 1 : Number(req.body.quantity);
    if (!Number.isInteger(quantity) || quantity < 1 || quantity > 10) {
      return res.status(400).json({ error: 'quantity must be between 1 and 10' });
    }

    // ── An order already in flight is THE answer, not a conflict.
    //
    // 032 puts a partial unique index on (event_id, buyer_id) for live orders precisely so this
    // is well-defined: a double-tapped RSVP and a returning abandoned checkout both land here
    // and get their own order back instead of a second one to pay for.
    const live = (
      await query<{ id: string; status: string; quantity: number; provider: string }>(
        `select id, status, quantity, provider from event_orders
          where event_id = $1 and buyer_id = $2 and status in ('pending', 'paid')`,
        [event.id, userId]
      )
    )[0];
    if (live) {
      return res.status(200).json({
        order: { id: live.id, status: live.status, quantity: live.quantity, provider: live.provider },
        existed: true,
      });
    }

    const price = minor(event.price_minor);
    const amount = price * quantity;

    // ── PAID: refuse honestly until a provider exists.
    if (amount > 0) {
      const provider = activeProvider();
      if (!provider) {
        return res.status(501).json({ error: 'paid events are not available yet' });
      }

      // The order id is minted BEFORE the checkout, because the provider needs something stable
      // to echo back and `provider_ref` is NOT NULL on the row we are about to write. If the
      // insert below then loses the unique race, the checkout we just opened at the provider is
      // abandoned rather than charged — no money moves without a webhook, and the webhook
      // handler will not find an order for that reference and will record the delivery as
      // unplaced (032's payment_webhook_events.order_id is nullable for exactly this).
      const orderId = randomUUID();
      const handle = await provider.createCheckout({
        orderId,
        amountMinor: amount,
        currency: event.currency,
        // The event title, and nothing else. A provider's page and a bank statement are seen
        // by third parties, so nothing from inside the app goes into this string.
        description: event.title,
        notes: { order_id: orderId, event_id: event.id },
      });

      try {
        const rows = await query<{ id: string; status: string }>(
          `insert into event_orders
             (id, event_id, buyer_id, quantity, unit_price_minor, amount_minor, currency,
              provider, provider_ref, status)
           values ($1, $2, $3, $4, $5, $6, $7, $8, $9, 'pending')
           returning id, status`,
          [orderId, event.id, userId, quantity, price, amount, event.currency, provider.name, handle.providerRef]
        );
        return res.status(201).json({
          order: { id: rows[0].id, status: rows[0].status, quantity, provider: provider.name },
          checkout: handle.clientPayload,
          existed: false,
        });
      } catch (e) {
        // Lost the (event_id, buyer_id) race against another device. Hand back the winner
        // rather than a 500 — both requests were the same intent.
        if ((e as { code?: string }).code !== PG_UNIQUE_VIOLATION) throw e;
        const winner = (
          await query<{ id: string; status: string; quantity: number; provider: string }>(
            `select id, status, quantity, provider from event_orders
              where event_id = $1 and buyer_id = $2 and status in ('pending', 'paid')`,
            [event.id, userId]
          )
        )[0];
        if (!winner) return res.status(409).json({ error: 'order changed, retry' });
        return res.status(200).json({ order: winner, existed: true });
      }
    }

    // ── FREE: order and tickets in one transaction, no provider involved.
    const client = await pool.connect();
    try {
      await client.query('begin');

      // LOCK THE EVENT ROW, THEN COUNT. "How many seats are taken" is a question about other
      // tables, which no CHECK constraint can ask, so the serialisation has to be explicit:
      // without the lock two people both read "one seat left" and both take it. Locking the
      // event rather than the orders works because the row being contended for does not exist
      // yet — the same shape the tournament registration route uses.
      const locked = (
        await client.query<{ capacity: number | null; status: string }>(
          `select capacity, status from community_events where id = $1 for update`,
          [event.id]
        )
      ).rows[0];
      if (!locked || locked.status !== 'published') {
        await client.query('rollback');
        return res.status(409).json({ error: 'this event is not open for registration' });
      }

      if (locked.capacity !== null) {
        const taken = Number(
          (
            await client.query<{ n: string }>(
              `select coalesce(sum(quantity), 0)::text as n from event_orders
                where event_id = $1 and status in ('pending', 'paid')`,
              [event.id]
            )
          ).rows[0].n
        );
        if (taken + quantity > locked.capacity) {
          await client.query('rollback');
          return res.status(409).json({ error: 'this event is full' });
        }
      }

      // provider_ref is the order's own id. NOT NULL is satisfied without inventing a nullable
      // column, and (provider, provider_ref) stays unique for free orders as well as paid ones.
      const orderId = randomUUID();
      await client.query(
        `insert into event_orders
           (id, event_id, buyer_id, quantity, unit_price_minor, amount_minor, currency,
            provider, provider_ref, status, settled_at)
         values ($1, $2, $3, $4, 0, 0, $5, $6, $1::text, 'paid', now())`,
        [orderId, event.id, userId, quantity, event.currency, FREE_PROVIDER]
      );

      const nonces = Array.from({ length: quantity }, () => newTicketNonce());
      for (const nonce of nonces) {
        // holder = buyer. A transfer flow later changes event_tickets.holder_id and nothing
        // else, which is why the column exists rather than the door reading the order's buyer.
        await client.query(
          `insert into event_tickets (order_id, event_id, holder_id, qr_nonce)
           values ($1, $2, $3, $4)`,
          [orderId, event.id, userId, nonce]
        );
      }

      await client.query('commit');
      return res.status(201).json({
        order: { id: orderId, status: 'paid', quantity, provider: FREE_PROVIDER },
        tickets_issued: quantity,
        existed: false,
      });
    } catch (e) {
      await client.query('rollback');
      if ((e as { code?: string }).code === PG_UNIQUE_VIOLATION) {
        return res.status(409).json({ error: 'you already have an order for this event' });
      }
      throw e;
    } finally {
      client.release();
    }

    // A NOTE ON ABANDONED PENDING ORDERS, left here rather than pretended away: because pending
    // orders hold seats, a checkout that is never completed holds one until it is cancelled.
    // Expiring them wants a scheduled sweep, and this codebase has no scheduler (the same gap
    // 031_tournaments.sql records for `starts_at`). Until one exists the organiser can see
    // pending orders on GET /events/:id/orders, and the buyer can release theirs by cancelling.
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /events/:id/orders/:orderId/cancel
//
// A free RSVP that is withdrawn becomes 'refunded', not some sixth state. Refunding zero is
// zero, and 032's transition trigger allows exactly one move out of 'paid'. Inventing a
// 'withdrawn' state for the free case would give every consumer of order status a special case
// to forget.
//
// A PAID order is only cancellable while it is pending. Once money has moved, giving it back is
// a refund, which goes through the provider and is not a button on a list row.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/events/:id/orders/:orderId/cancel',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openEvent(req.params.id, userId, false);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    const orderId = String(req.params.orderId ?? '');
    if (!UUID_RE.test(orderId)) return res.status(400).json({ error: 'order id must be a uuid' });

    const order = (
      await query<{ id: string; buyer_id: string; status: string; provider: string }>(
        `select id, buyer_id, status, provider from event_orders where id = $1 and event_id = $2`,
        [orderId, opened.event.id]
      )
    )[0];
    if (!order) return res.status(404).json({ error: 'no such order' });
    if (order.buyer_id !== userId && !opened.isOrganiser) {
      return res.status(403).json({ error: 'not your order' });
    }

    if (order.status === 'pending') {
      await query(`update event_orders set status = 'cancelled' where id = $1 and status = 'pending'`, [
        order.id,
      ]);
      return res.json({ ok: true, status: 'cancelled' });
    }

    if (order.status === 'paid' && order.provider === FREE_PROVIDER) {
      const client = await pool.connect();
      try {
        await client.query('begin');
        await client.query(
          `update event_orders set status = 'refunded' where id = $1 and status = 'paid'`,
          [order.id]
        );
        // The tickets die with the order. Voided rather than deleted: a door that scanned it an
        // hour ago should still be able to explain what happened, and the row is the only
        // record that it ever existed.
        await client.query(`update event_tickets set state = 'void' where order_id = $1`, [order.id]);
        await client.query('commit');
        return res.json({ ok: true, status: 'refunded' });
      } catch (e) {
        await client.query('rollback');
        throw e;
      } finally {
        client.release();
      }
    }

    return res.status(409).json({ error: 'a paid order must be refunded through the payment provider' });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// GET /events/:id/orders — the organiser's list.
//
// Returns names and order state. It does NOT return anything from a payment provider beyond
// the reference — an organiser has no business seeing a buyer's payment instrument, and the
// server never stores one.
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/events/:id/orders',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openEvent(req.params.id, userId, true);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    const rows = await query(
      `select o.id, o.buyer_id, u.full_name, u.username, o.quantity,
              o.amount_minor::text as amount_minor, o.currency, o.status,
              o.provider, o.created_at, o.settled_at,
              (select count(*) from event_tickets t
                where t.order_id = o.id and t.state = 'valid')::int as tickets,
              (select count(*) from event_tickets t
                where t.order_id = o.id and t.checked_in_at is not null)::int as checked_in
         from event_orders o
         left join users u on u.id = o.buyer_id
        where o.event_id = $1
        order by o.created_at desc
        limit 500`,
      [opened.event.id]
    );
    res.json({ orders: rows.map((r: any) => ({ ...r, amount_minor: minor(r.amount_minor) })) });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// GET /my/event-tickets — everything the caller can walk through a door with.
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/my/event-tickets',
  requireAuth,
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const rows = await query(
      `select t.id, t.event_id, t.state, t.checked_in_at, t.created_at,
              e.title, e.starts_at, e.ends_at, e.location_text, e.status as event_status,
              e.community_id, o.status as order_status
         from event_tickets t
         join community_events e on e.id = t.event_id
         join event_orders o on o.id = t.order_id
        where t.holder_id = $1
        order by e.starts_at desc
        limit 200`,
      [userId]
    );
    res.json({ tickets: rows });
  })
);

/** The holder's own ticket, or an explanation of why it is not usable. */
async function loadOwnTicket(ticketId: unknown, userId: string) {
  if (typeof ticketId !== 'string' || !UUID_RE.test(ticketId)) {
    return { ok: false as const, status: 400, error: 'ticket id must be a uuid' };
  }
  const t = (
    await query<{
      id: string;
      event_id: string;
      holder_id: string;
      qr_nonce: string;
      state: string;
      order_status: string;
      event_status: string;
    }>(
      `select t.id, t.event_id, t.holder_id, t.qr_nonce, t.state,
              o.status as order_status, e.status as event_status
         from event_tickets t
         join event_orders o on o.id = t.order_id
         join community_events e on e.id = t.event_id
        where t.id = $1`,
      [ticketId]
    )
  )[0];
  if (!t || t.holder_id !== userId) {
    // 404 for someone else's ticket as well as a missing one: confirming that a ticket id
    // exists would make this endpoint an enumeration oracle.
    return { ok: false as const, status: 404, error: 'no such ticket' };
  }
  return { ok: true as const, ticket: t };
}

// ─────────────────────────────────────────────────────────────────────────────────
// GET /event-tickets/:id/code — mint the QR the phone displays.
//
// Minted per request and SHORT-LIVED, rather than stored. A stored code is a permanent bearer
// token that survives a screenshot forever; a ten-minute one makes a forwarded screenshot a
// stale image. See payments/tickets.ts for the rest of the reasoning.
// ─────────────────────────────────────────────────────────────────────────────────
router.get(
  '/event-tickets/:id/code',
  requireAuth,
  rateLimit({ max: 120, windowSeconds: 3600, bucket: 'ticket-code' }),
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const found = await loadOwnTicket(req.params.id, userId);
    if (!found.ok) return res.status(found.status).json({ error: found.error });
    const t = found.ticket;

    if (t.state !== 'valid') return res.status(409).json({ error: 'this ticket is no longer valid' });
    if (t.order_status !== 'paid') return res.status(409).json({ error: 'this order is not paid' });
    if (t.event_status === 'cancelled') return res.status(409).json({ error: 'this event was cancelled' });

    const signed = signTicketCode(t.id, t.event_id, t.qr_nonce);
    if (!signed) {
      // No signing key. 503 and a loud log rather than an unsigned code: an unsigned code is a
      // bearer uuid, which is exactly what the signature exists to not be.
      console.error('[events] ticket code requested but no signing key is configured');
      return res.status(503).json({ error: 'ticket codes are temporarily unavailable' });
    }
    res.json({ code: signed.code, expires_at: signed.expiresAt, ticket_id: t.id, event_id: t.event_id });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /event-tickets/:id/rotate — invalidate every code minted so far.
//
// The answer to "I screenshotted my ticket into a group chat". Rotating the stored nonce means
// every previously issued code fails verification, without touching anybody else's ticket and
// without rotating the server key.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/event-tickets/:id/rotate',
  requireAuth,
  rateLimit({ max: 20, windowSeconds: 3600, bucket: 'ticket-rotate' }),
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const found = await loadOwnTicket(req.params.id, userId);
    if (!found.ok) return res.status(found.status).json({ error: found.error });
    if (found.ticket.state !== 'valid') {
      return res.status(409).json({ error: 'this ticket is no longer valid' });
    }

    const nonce = newTicketNonce();
    // Conditional on checked_in_at being null: rotating a ticket that has already walked
    // through the door achieves nothing and would only confuse the record.
    const rows = await query<{ id: string }>(
      `update event_tickets set qr_nonce = $2
        where id = $1 and checked_in_at is null and state = 'valid'
        returning id`,
      [found.ticket.id, nonce]
    );
    if (rows.length === 0) return res.status(409).json({ error: 'this ticket has already been used' });

    const signed = signTicketCode(found.ticket.id, found.ticket.event_id, nonce);
    if (!signed) return res.status(503).json({ error: 'ticket codes are temporarily unavailable' });
    res.json({ code: signed.code, expires_at: signed.expiresAt });
  })
);

// ─────────────────────────────────────────────────────────────────────────────────
// POST /events/:id/check-in — the door.
//
// Organiser only, and every check is done here rather than trusted from the code. A valid
// signature says "the server minted this"; it does not say "let this person in". The two are
// collapsed by every door system that has ever honoured a revoked ticket.
//
// SINGLE USE IS A CONDITIONAL UPDATE, not read-then-write. Two volunteers with two phones at
// two doors is a database race, and the `where checked_in_at is null` predicate is the only
// thing that decides it.
// ─────────────────────────────────────────────────────────────────────────────────
router.post(
  '/events/:id/check-in',
  requireAuth,
  rateLimit({ max: 600, windowSeconds: 3600, bucket: 'event-checkin' }),
  asyncHandler(async (req, res) => {
    const { user_id: userId } = (req as any).auth;
    const opened = await openEvent(req.params.id, userId, true);
    if (!opened.ok) return res.status(opened.status).json({ error: opened.error });

    if (!ticketSigningAvailable()) {
      console.error('[events] check-in attempted but no ticket signing key is configured');
      return res.status(503).json({ error: 'ticket validation is temporarily unavailable' });
    }

    const check = verifyTicketCode(req.body?.code);
    if (!check.ok) {
      // The reason is returned because the person holding the scanner needs it — "expired, ask
      // them to refresh" and "this is not one of ours" are different conversations at a door.
      // It reveals nothing: an attacker submitting codes already knows which one they sent.
      return res.status(400).json({ ok: false, reason: check.reason });
    }

    // THE CODE'S EVENT MUST BE THE EVENT BEING SCANNED. Without this, a valid ticket for last
    // month's event would open this month's door, since the signature says nothing about which
    // door is asking.
    if (check.eventId !== opened.event.id) {
      return res.status(400).json({ ok: false, reason: 'wrong_event' });
    }

    const ticket = (
      await query<{
        id: string;
        state: string;
        qr_nonce: string;
        checked_in_at: Date | null;
        holder_id: string;
        order_status: string;
        full_name: string | null;
        username: string | null;
      }>(
        `select t.id, t.state, t.qr_nonce, t.checked_in_at, t.holder_id,
                o.status as order_status, u.full_name, u.username
           from event_tickets t
           join event_orders o on o.id = t.order_id
           left join users u on u.id = t.holder_id
          where t.id = $1 and t.event_id = $2`,
        [check.ticketId, opened.event.id]
      )
    )[0];
    if (!ticket) return res.status(404).json({ ok: false, reason: 'not_found' });

    // THE NONCE MUST BE THE CURRENT ONE. This is what makes rotation actually revoke: a code
    // signed against a superseded nonce verifies cryptographically and is still refused here.
    if (ticket.qr_nonce !== check.nonce) return res.status(409).json({ ok: false, reason: 'superseded' });
    if (ticket.state !== 'valid') return res.status(409).json({ ok: false, reason: 'void' });
    if (ticket.order_status !== 'paid') return res.status(409).json({ ok: false, reason: 'unpaid' });

    const claimed = await query<{ checked_in_at: Date }>(
      `update event_tickets
          set checked_in_at = now(), checked_in_by = $2
        where id = $1 and checked_in_at is null and state = 'valid'
        returning checked_in_at`,
      [ticket.id, userId]
    );
    if (claimed.length === 0) {
      // Already through. Reported with the original time, because the useful answer at a door
      // is "this was used at 19:42", not "no".
      return res.status(409).json({
        ok: false,
        reason: 'already_checked_in',
        checked_in_at: ticket.checked_in_at,
      });
    }

    res.json({
      ok: true,
      ticket_id: ticket.id,
      holder_id: ticket.holder_id,
      holder_name: ticket.full_name ?? ticket.username ?? null,
      checked_in_at: claimed[0].checked_in_at,
    });
  })
);

export default router;
