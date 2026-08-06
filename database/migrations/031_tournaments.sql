-- 031_tournaments.sql — Tournaments ON TOP OF the existing games stack (024/025/026).
--
-- ==================== NOT END-TO-END ENCRYPTED — AND WHY, EXACTLY ====================
-- This file makes NO new exception. It reuses, unchanged, the one 024_games.sql already
-- declared and scoped: the server is the REFEREE, so it must read game state to validate a
-- move, or "server-authoritative" is a word with nothing behind it. A tournament is a
-- grouping key over match rows the server already reads.
--
-- Stated surface by surface, so nobody has to infer it:
--
--   Bracket / seeds / standings ...... SERVER-READABLE. Derived from match rows the server
--                                      already refereed. Nothing new becomes visible.
--   Roster of who registered ......... SERVER-READABLE, and it is the community roster
--                                      filtered — 030_communities.sql already states that a
--                                      community roster is server-visible by construction.
--   Match invites / trash talk ....... E2EE, unchanged. The invite for an ordinary match is a
--                                      normal message on the normal pipe (games.ts:14-17), and
--                                      this file does not touch the message pipe at all.
--
-- Messages, calls, locations and moments are UNAFFECTED. Nothing here is a precedent for
-- weakening any of them.
-- =====================================================================================
--
-- ── A BRACKET PAIRING IS NOT A MESSAGING RIGHT, AND NOT A CONTACT ────────────────
--
-- Being drawn against someone in round 2 creates NO conversation, NO contact row and NO
-- reachability. 020_reachability.sql still defines the only three ways to open a chat, and
-- 030_communities.sql adds exactly one narrow fourth (member -> community OWNER). A tournament
-- adds none. If a future route reads tournament_players to decide whether A may message B,
-- that is the bug 029_creator_profiles.sql:13-23 forbids, wearing a new hat.
--
-- THIS HAS A CONSEQUENCE THE PLAN MISSED, written down here because the route depends on it:
-- docs/research/04_communities_plan.md says bracket "invites flow client-side over E2EE as
-- they already do". They CANNOT. The ordinary invite is an E2EE message, and two strangers
-- drawn against each other in a bracket have no Double-Ratchet session and no right to open
-- one. A bracket match is therefore discovered by PULL — the client reads its own fixtures
-- from the tournament (GET /tournaments/:id/matches) — not by an invite push. The match row
-- is the whole handshake, exactly as it is for the existing `GET /games/invites` banner.
--
-- ── WHAT THIS FILE DELIBERATELY DOES NOT DO ─────────────────────────────────────
--
-- No new match/state storage. Live state stays in Redis under `match:<id>:state` for the
-- reason 024 gives (an arcade match updates 10-15x/second and is worthless 90 seconds later).
-- No prize money, no entry fee: money is 032_events_tickets.sql, and a paid entry fee is an
-- ORDER, never a column on this container — the same rule 030's PHASE-2 HOOKS note sets down
-- for community join prices.

-- ─────────────────────────────────────────────────────────────────────────────────
-- The container
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists tournaments (
    -- Default present, but the CREATE route also accepts a client-supplied id, for the reason
    -- communities.id has no default at all (030:67-72): creating a tournament and seeding it
    -- are separate calls, and a client that retries a timed-out POST must be able to land on
    -- the same row instead of leaving a second, empty tournament in the community's list.
    id            uuid primary key default gen_random_uuid(),

    -- Tournaments only exist INSIDE a community. That is the consent boundary that makes a
    -- shared leaderboard defensible: everyone on it joined the same space on purpose. The
    -- global games leaderboard is deliberately opponent-scoped (games.ts:331-341) precisely
    -- because no such boundary exists there.
    community_id  uuid not null references communities(id) on delete cascade,

    -- restrict, matching game_matches.game_id (024:36): pulling a game from the catalog must
    -- not silently delete the history of every tournament played on it.
    game_id       uuid not null references games(id) on delete restrict,

    name          text not null,

    -- single_elim -> knockout bracket, seeded at start, byes for the top seeds
    -- round_robin -> every registrant plays every other registrant once
    format        text not null default 'single_elim',

    -- open      -> registration is live; no matches exist yet
    -- active    -> seeded; the bracket/fixture list is fixed and matches are being played
    -- finished  -> every fixture decided; winner_user_id set (null only if it ended in a tie
    --              that the tiebreak below could not resolve, which round_robin permits)
    -- cancelled -> abandoned by an organiser; matches are left alone as history
    status        text not null default 'open',

    created_by    uuid not null references users(id) on delete cascade,

    -- Advisory: shown on the card, not enforced. The organiser starts the tournament with an
    -- explicit call, because "start automatically at 19:00" needs a scheduler this codebase
    -- does not have, and a tournament that silently seeded itself with three registrants
    -- would be worse than one that waited.
    starts_at     timestamptz,
    started_at    timestamptz,
    finished_at   timestamptz,

    -- Set when the bracket resolves. Nullable forever: a cancelled tournament has no winner,
    -- and a round_robin can end level. "Finished" and "has a winner" are separate facts, the
    -- same distinction 024:41-43 draws for a drawn match.
    winner_user_id uuid references users(id) on delete set null,

    -- THE SIZE CAP, as a column for the same reason communities.max_members is one (030:114-122):
    -- it is a load decision, so it must be readable by the route rather than typed into it, and
    -- it must have a ceiling no admin UPDATE can raise past what the plumbing survives.
    --
    -- The ceilings differ by format because the COST differs by format, quadratically:
    -- single_elim with N players is N-1 matches; round_robin is N*(N-1)/2. At 64 players that
    -- is 63 matches versus 2,016. The check below enforces the format-specific ceiling, so a
    -- 64-player round robin cannot be created at all rather than being created and then melting
    -- the fixture list. Sixteen is the round-robin ceiling: 120 matches, which is already a lot
    -- of fixtures for a community to actually play.
    max_players   int not null default 32,

    created_at    timestamptz not null default now(),
    updated_at    timestamptz not null default now(),

    constraint tournaments_format_check
        check (format in ('single_elim', 'round_robin')),
    constraint tournaments_status_check
        check (status in ('open', 'active', 'finished', 'cancelled')),
    constraint tournaments_name_len
        check (char_length(name) between 1 and 60),
    -- Format-specific ceiling. Written as one check rather than two so there is a single place
    -- to read the answer to "how big can this get".
    constraint tournaments_max_players_range
        check (
            max_players >= 2
            and case format
                    when 'round_robin' then max_players <= 16
                    else                    max_players <= 64
                end
        ),
    -- A finished tournament has a finish time; a live one does not. Prevents the
    -- two-columns-that-can-disagree shape 030:256-259 rejects for membership state.
    constraint tournaments_finished_coherent
        check ((status = 'finished') = (finished_at is not null))
);

-- The community's tournament list: live ones first, newest first. This is the only listing
-- query the tab makes.
create index if not exists idx_tournaments_community
    on tournaments (community_id, created_at desc);

drop trigger if exists trg_tournaments_updated_at on tournaments;
create trigger trg_tournaments_updated_at before update on tournaments
    for each row execute function set_updated_at();

-- ─────────────────────────────────────────────────────────────────────────────────
-- Registrants
--
-- PRIMARY KEY (tournament_id, user_id) — NULL-FREE, deliberately. Registration is an upsert
-- (register, withdraw, register again), and a NULL anywhere in a unique constraint makes
-- ON CONFLICT never match, which turns the upsert into a silent second INSERT. That bug has
-- already shipped in this repo once; 027_receipt_null_device.sql exists to undo it.
-- ─────────────────────────────────────────────────────────────────────────────────
create table if not exists tournament_players (
    tournament_id      uuid not null references tournaments(id) on delete cascade,
    user_id            uuid not null references users(id) on delete cascade,

    -- Assigned at START, not at registration: seeding is a decision about the whole field, and
    -- it cannot be made while the field is still changing. Null while status='open'.
    seed               int,

    -- Which round knocked them out. Null means "still alive" OR "never started" — the
    -- tournament's own status disambiguates, and duplicating that here would be a second
    -- source of truth for the same fact.
    eliminated_in_round int,

    -- Withdrawal is a state, not a delete, so a seeded bracket does not lose the row it points
    -- at. A withdrawal after seeding forfeits the fixture rather than reshaping the bracket:
    -- re-seeding a live bracket would invalidate matches already played.
    state              text not null default 'registered',

    registered_at      timestamptz not null default now(),

    primary key (tournament_id, user_id),

    constraint tournament_players_state_check
        check (state in ('registered', 'withdrawn')),
    constraint tournament_players_seed_positive
        check (seed is null or seed >= 1)
);

-- Seeded order for the bracket screen, and the "am I in this" probe.
create index if not exists idx_tournament_players_seed
    on tournament_players (tournament_id, seed);
-- "Which tournaments am I in" — the personal fixtures list.
create index if not exists idx_tournament_players_user
    on tournament_players (user_id, tournament_id);

-- ─────────────────────────────────────────────────────────────────────────────────
-- Hang the bracket off the EXISTING match table
--
-- Additive ALTER, not a new match table, and not a fork of the games stack. A tournament match
-- must be exactly the same object as a friendly match: same referee process, same rules module,
-- same Redis live state, same finish path, same result rows. A parallel `tournament_matches`
-- table would mean two of everything and, inevitably, two of them drifting.
-- ─────────────────────────────────────────────────────────────────────────────────
alter table game_matches
    add column if not exists tournament_id      uuid references tournaments(id) on delete set null,
    -- 1-based. In single_elim this is the bracket depth; in round_robin it is the fixture
    -- round from the circle method.
    add column if not exists tournament_round   int,
    -- Position WITHIN the round, 0-based.
    --
    -- NOT IN THE PLAN SKETCH, and load-bearing. The sketch has only (tournament_id, round),
    -- which leaves "pair the winners of round 2 in order" defined by nothing — created_at ties
    -- when four rows are inserted in one statement, and any ordering that depends on insertion
    -- time is an ordering that changes under a retry. The slot makes advancement arithmetic:
    -- the winner of round r slot k plays in round r+1 slot k/2, forever, deterministically.
    add column if not exists tournament_slot    int,
    -- Replay counter for a DRAWN knockout match, 1-based.
    --
    -- The plan does not mention draws. Tic Tac Toe draws constantly (024:41-43 already treats
    -- "finished" and "has a winner" as separate facts), and a drawn knockout match advances
    -- nobody — the bracket simply stops. The fix is a replay in the SAME slot, which means a
    -- slot can hold more than one match row, which means the slot alone cannot be unique.
    -- Hence the attempt number: (tournament, round, slot, attempt) is unique, and the deciding
    -- match for a slot is its highest attempt.
    add column if not exists tournament_attempt int;

-- Every bracket coordinate is present, or none of them is. Without this, a row could carry a
-- tournament_id and a null slot, and the partial unique index below would happily accept two
-- of them — reintroducing exactly the NULL-in-a-unique-key hole this schema keeps closing.
alter table game_matches
    drop constraint if exists game_matches_bracket_coherent;
alter table game_matches
    add constraint game_matches_bracket_coherent
    check (
        tournament_id is null
        or (tournament_round is not null and tournament_round >= 1
            and tournament_slot is not null and tournament_slot >= 0
            and tournament_attempt is not null and tournament_attempt >= 1)
    );

-- IDEMPOTENT ADVANCEMENT, enforced by the database rather than by hoping.
--
-- Two matches in the same round can finish in the same millisecond, in two different processes.
-- Both then observe "every slot in this round is decided" and both try to create round r+1.
-- The application cannot serialise that with a SELECT. This index can: the second insert hits
-- the conflict and the advance routine's ON CONFLICT DO NOTHING makes it a no-op. The partial
-- predicate keeps ordinary friendly matches (tournament_id null) entirely out of the index.
create unique index if not exists idx_game_matches_bracket_slot
    on game_matches (tournament_id, tournament_round, tournament_slot, tournament_attempt)
    where tournament_id is not null;

-- "The fixtures of this tournament", the bracket screen's only query, and the scan the advance
-- routine makes to decide whether a round is complete.
create index if not exists idx_game_matches_tournament
    on game_matches (tournament_id, tournament_round, tournament_slot)
    where tournament_id is not null;

-- ─────────────────────────────────────────────────────────────────────────────────
-- BYES, and why they are match rows rather than a separate concept
--
-- A field of 5 in a bracket of 8 has three byes. A bye is stored as an ordinary game_matches
-- row with a single entry in player_ids, status 'finished' and winner_id set — so the advance
-- routine, the bracket screen and the "is this round complete" check all treat it identically
-- to a played match and none of them needs a special case.
--
-- A bye writes NO game_match_results rows. That is what keeps it out of every score: standings
-- (below) and the existing global leaderboard (games.ts:378-414, which expands player_ids and
-- drops the caller, leaving a one-player match contributing nothing) both read results, never
-- winner_id alone. A bye must never look like a win someone earned.
-- ─────────────────────────────────────────────────────────────────────────────────

-- ─────────────────────────────────────────────────────────────────────────────────
-- Standings
--
-- A VIEW, not a table. There is no state here that is not already implied by the match rows —
-- materialising it would create a second source of truth that a missed UPDATE silently
-- corrupts, and standings are read a few times per tournament, not per frame.
--
-- Reads game_match_results, which is the table 024:57-65 already keeps for exactly this. Points
-- are 3/1/0 (win/draw/loss), the football convention, because it is the one that makes a draw
-- worth something without making it worth as much as a win — which matters for round_robin,
-- where draws decide titles.
-- ─────────────────────────────────────────────────────────────────────────────────
create or replace view tournament_standings as
select m.tournament_id,
       r.user_id,
       count(*)::int                                                  as played,
       count(*) filter (where r.placement = 1)::int                   as wins,
       count(*) filter (where m.winner_id is null)::int               as draws,
       count(*) filter (where r.placement is not null
                          and r.placement <> 1)::int                  as losses,
       coalesce(sum(r.score), 0)::bigint                              as score,
       (count(*) filter (where r.placement = 1) * 3
        + count(*) filter (where m.winner_id is null) * 1)::int        as points
  from game_matches m
  join game_match_results r on r.match_id = m.id
 where m.tournament_id is not null
   and m.status = 'finished'
 group by m.tournament_id, r.user_id;

-- ─────────────────────────────────────────────────────────────────────────────────
-- WHAT THE ROUTES MUST DO THAT THE SCHEMA CANNOT ENFORCE
--
-- Written here rather than only in the route, because a route can be rewritten and a migration
-- header is read by whoever rewrites it:
--
--   * ORGANISER CHECK. Creating, seeding and cancelling a tournament is owner/admin only, read
--     from community_members.role. There is no column here that encodes it, on purpose: the
--     community roster is the single authority on roles (030:245-248).
--   * REGISTRATION CHECK. A registrant must be an ACTIVE member of the tournament's community.
--     'pending' is not eligible — the same rule 030 sets for the host-DM exception. A foreign
--     key cannot express "active member of the community this tournament belongs to".
--   * SEEDING IS ONE TRANSACTION. Assigning seeds, flipping status to 'active' and inserting
--     round 1 must commit together, or a crash leaves a tournament that is 'active' with no
--     fixtures and no way to produce them.
--   * TWO-PLAYER GAMES ONLY. Pairing is 1v1; the catalog row must admit exactly two seats
--     (min_players <= 2 <= max_players). Enforced in the route because it is a join against
--     `games`, which a check constraint cannot do.
-- ─────────────────────────────────────────────────────────────────────────────────
