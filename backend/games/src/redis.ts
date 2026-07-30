// Redis connections for the games service.
//
// Three separate clients, deliberately: a connection in subscriber mode cannot issue
// ordinary commands, so the subscription needs its own. `state` and `pub` are split for
// the same reason the API splits `redis`/`publisher` — a slow state read must not sit
// behind a fan-out publish.
import Redis from 'ioredis';

const url = process.env.REDIS_URL ?? 'redis://localhost:6379';

export const sub = new Redis(url);
export const pub = new Redis(url);
export const state = new Redis(url);

/** Channel the WS relay forwards game_input frames onto. */
export const GAMES_INPUT_CHANNEL = 'channel:games:input';

/**
 * Live match state. TTL-refreshed on every write and NOT durable by design: an
 * in-progress match lost to a restart is an acceptable trade (docs/GAMES.md §5), the same
 * one the app already makes for live location fixes. The final result is what gets
 * written to Postgres, and that happens once, at the end.
 */
export const stateKey = (matchId: string) => `match:${matchId}:state`;

/** Long enough to outlive a slow turn-based game; short enough that abandoned matches reap themselves. */
export const STATE_TTL_SECONDS = Number(process.env.VOIID_GAME_STATE_TTL_SECONDS) || 3600;
