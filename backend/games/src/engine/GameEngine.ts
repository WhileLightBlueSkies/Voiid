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

  /** Current state as the clients should see it. */
  serialize(): GameStatePayload;

  /** True once the match is over; the runtime stops accepting input. */
  isFinished(): boolean;
}

/** Constructs engines for a game slug — a fresh match, or one resumed from Redis. */
export interface GameFactory {
  slug: string;
  /** Tick rate in Hz for continuous games; omit for turn-based. */
  tickHz?: number;
  create(playerIds: string[]): GameEngine;
  restore(state: GameStatePayload): GameEngine;
}
