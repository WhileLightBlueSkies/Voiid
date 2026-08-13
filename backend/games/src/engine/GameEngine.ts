// The contract every game implements (docs/GAMES.md §5).
//
// This interface is the reason adding a game is "one folder + one renderer" rather than a
// networking project. index.ts routes frames, persists results and broadcasts state
// without knowing which game it is holding — it only knows these methods. Tic Tac Toe is
// the first implementation; Snake, Archery and the rest slot in behind the same shape.
//
// TWO KINDS OF GAME, ONE INTERFACE. Turn-based games (Tic Tac Toe, Chess, Sea Battle) are
// purely reactive: state changes only inside applyInput. Continuous games (Snake, Air
// Hockey) also need time to pass on its own, which is what `tick` is for. A turn-based
// engine simply omits `tick`, and the runtime never starts a loop for it — so CPU cost
// scales with live ARCADE matches, not with matches in total. That is why `tick` is
// optional rather than a no-op every board game has to implement.

/** Serialized state a client renders. Opaque to the transport, meaningful to the renderer. */
export type GameStatePayload = Record<string, unknown>;

/** Raw input frame from a client. Untrusted — every engine must validate it. */
export type GameInput = Record<string, unknown>;

export interface GameOutcome {
  /** Null for a draw — "finished" and "has a winner" are separate facts. */
  winnerId: string | null;
  /** Per-player final score, keyed by user id. Written to game_match_results. */
  scores: Record<string, number>;
}

export interface ApplyResult {
  /**
   * False when the input was illegal or out of turn. The caller does NOT broadcast on a
   * rejected input, so a client spamming invalid moves generates no fan-out — the
   * cheapest possible answer to a misbehaving client.
   */
  accepted: boolean;
  /** Set once the game has ended; the runtime persists it and stops the match. */
  outcome?: GameOutcome;
  /**
   * Accepted, but do NOT broadcast for this input alone.
   *
   * Turn-based games leave this unset: a move IS the state change, so it must go out
   * immediately. Continuous games set it, because their input only records intent — a
   * steering frame changes nothing a player can see until the next tick renders it. Without
   * this, a player holding a joystick would trigger a full state fan-out on every input
   * frame ON TOP OF the tick broadcast, multiplying bandwidth for no visible benefit.
   */
  silent?: boolean;
}

export interface GameEngine {
  /**
   * Rebuild from serialized state. Every engine is constructed from a plain object and
   * serializes back to one, because live state lives in Redis as JSON and the process may
   * restart at any time — an engine that held un-serializable state would lose matches.
   */
  applyInput(playerId: string, input: GameInput): ApplyResult;

  /** Advance time. Continuous games only; absent on turn-based engines (see above). */
  tick?(): { changed: boolean; outcome?: GameOutcome };

  /**
   * Complete state. This is the PERSISTENCE shape: the runtime writes it to Redis and hands
   * it straight back to `restore`, so it must contain everything needed to rebuild the match
   * exactly. Omitting a field here silently resets it on the next tick.
   */
  serialize(): GameStatePayload;

  /**
   * What to actually send to clients, when that differs from the full state.
   *
   * Turn-based games omit this: their state is small and every field matters to the client,
   * so the persistence shape and the wire shape are the same object.
   *
   * Continuous games need the split. Snake's food field is ~300 pellets that almost never
   * change, and resending it 12x/sec made it 59% of the payload — but it cannot simply be
   * dropped from `serialize`, because that is what rebuilds the match. So `serialize` stays
   * complete for Redis, and this returns the same state with the unchanged bulk replaced by
   * a delta.
   *
   * Called once per broadcast, AFTER serialize(), and may clear per-frame delta buffers.
   */
  serializeForWire?(): GameStatePayload;

  /**
   * SERVER-ONLY state that must survive between inputs but must NEVER reach a client.
   *
   * Simultaneous-reveal games (RPS, hand cricket) hold each player's choice hidden until both
   * have arrived. `serialize()` deliberately omits those choices — that omission IS the anti-cheat
   * property. But the runtime round-trips serialize()/restore() on every single input, so a
   * secret left out of serialize() was silently dropped a millisecond after being made: the ball
   * could never resolve, and hand cricket looped between the two players forever.
   *
   * So secrets travel on their own channel. It is persisted to Redis alongside the public state
   * and handed back to `restore`, and it is never included in a broadcast frame.
   *
   * Games with nothing to hide omit this entirely.
   */
  serializeSecret?(): GameStatePayload;

  /**
   * The state as ONE specific player may see it.
   *
   * Distinct from serializeForWire(), which is a BANDWIDTH projection sent identically to
   * everyone. This is an INFORMATION projection: your own fleet, your own hand. Hidden-state
   * games (Sea Battle, Voiid Cards) do not exist without it — serializeSecret is server-only
   * and never reaches a client at all, which is right for a hand-cricket pick and wrong for
   * your own ships, because you have to be able to see them.
   *
   * "The client remembers what it placed" is not an alternative. It collapses on rejoin,
   * reinstall, second device, and cold start from a push notification — and for an async
   * game, cold start IS the normal case.
   *
   * CALLED ONCE PER RECIPIENT, SO IT MUST BE PURE. serializeForWire() is explicitly allowed
   * to clear per-frame delta buffers and Snake relies on that; this is explicitly not, because
   * draining a buffer on the first recipient would under-report the change to everyone after
   * them. That is why this is a separate method rather than serializeForWire(playerId?).
   *
   * A spectator, or any caller with no seat, must fall through to serialize()/serializeForWire().
   * Implementations are additive over serialize() — they add a private field, never remove a
   * public one — which is what makes a leak to a spectator structurally impossible rather than
   * merely unwritten: you would have to add one, not forget to prevent one.
   */
  serializeForPlayer?(playerId: string): GameStatePayload;

  /**
   * Epoch ms by which the player to move must act, or null when nothing is pending.
   *
   * Turn-based factories have no tickHz and therefore no clock, by design — so a match with an
   * absent opponent hangs forever (docs/games/CROSS_CUTTING.md §6). Giving them a tickHz to get
   * a timer would be wrong twice over: a per-match interval for a game that changes once a
   * minute, and a setTimeout measured in days that would not survive the next process restart.
   *
   * Instead the runtime keeps ONE Redis sorted set scored by this value, and one interval for
   * the whole process pops what is due. A deadline 72 hours out costs one member in a set.
   *
   * ABSOLUTE TIMESTAMP, NEVER A COUNTDOWN. It is read after arbitrary downtime, and a countdown
   * would silently hand an AFK player a fresh window on every restart.
   */
  deadlineAt?(): number | null;

  /**
   * The deadline passed. Same return shape as applyInput — forfeit, auto-move, or pass.
   *
   * The per-game timeout value and what expiry DOES are not shared: Sea Battle forfeits after
   * 24h, a live game would want 60s, and chess wants a real clock. The sweeper only decides
   * WHEN to call this.
   */
  onTimeout?(): ApplyResult;

  /** True once the match is over; the runtime stops accepting input. */
  isFinished(): boolean;
}

/** Constructs engines for a game slug — a fresh match, or one resumed from Redis. */
export interface GameFactory {
  slug: string;
  /** Tick rate in Hz for continuous games; omit for turn-based. */
  tickHz?: number;
  /**
   * Build a fresh match.
   *
   * [options] is the match's `options` jsonb column — per-game settings chosen at creation,
   * before any state exists (hand cricket's over count, for example). UNTRUSTED: it
   * originates from the client that created the match, so an engine must validate and clamp
   * whatever it reads, exactly as it validates input frames. Games with no settings ignore it.
   */
  create(playerIds: string[], options?: Record<string, unknown>): GameEngine;
  /**
   * Rebuild from the public state plus, if the game has any, the server-only secret returned by
   * [GameEngine.serializeSecret]. Passing the secret back is what lets a simultaneous game
   * remember a pick across the serialize/restore cycle the runtime performs on every input.
   */
  restore(state: GameStatePayload, secret?: GameStatePayload): GameEngine;
}
