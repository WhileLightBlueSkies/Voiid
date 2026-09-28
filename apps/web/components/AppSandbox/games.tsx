'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import { Glyph } from '../Glyph';
import styles from './app.module.css';

/**
 * The four games, and they all actually play.
 *
 * A screenshot of a game is not evidence that a game exists. Snake runs a real
 * tick loop, Hand Cricket runs real innings, and Tic Tac Toe and Rock Paper
 * Scissors play through to a result — because "you can play a round on the
 * marketing site" is the single most convincing thing this tour can say about a
 * product whose pitch is that games live inside the chat.
 *
 * The opponent is a local stand-in. In the app the server referees the match,
 * which is exactly why game state is not end-to-end encrypted; the screens say so.
 *
 * Both are self-contained: no timers outside their own lifetime, no state that
 * outlives the screen, and every control reachable by keyboard.
 */

/* ---- Snake ---------------------------------------------------------------- */

const COLS = 15;
const ROWS = 20;
const TICK_MS = 150;

type Point = { x: number; y: number };
type Direction = 'up' | 'down' | 'left' | 'right';

const STEP: Record<Direction, Point> = {
  up: { x: 0, y: -1 },
  down: { x: 0, y: 1 },
  left: { x: -1, y: 0 },
  right: { x: 1, y: 0 },
};

const OPPOSITE: Record<Direction, Direction> = {
  up: 'down',
  down: 'up',
  left: 'right',
  right: 'left',
};

const START_SNAKE: Point[] = [
  { x: 7, y: 12 },
  { x: 7, y: 13 },
  { x: 7, y: 14 },
];

function randomFood(snake: Point[]): Point {
  // Small board, short snake: rejection sampling is simpler than maintaining a
  // free-cell list and cannot spin for long.
  for (let attempt = 0; attempt < 200; attempt += 1) {
    const candidate = {
      x: Math.floor(Math.random() * COLS),
      y: Math.floor(Math.random() * ROWS),
    };
    if (!snake.some((part) => part.x === candidate.x && part.y === candidate.y)) return candidate;
  }
  return { x: 0, y: 0 };
}

export function SnakeGame({ onScored }: { onScored: () => void }) {
  const [snake, setSnake] = useState<Point[]>(START_SNAKE);
  const [food, setFood] = useState<Point>({ x: 7, y: 5 });
  const [direction, setDirection] = useState<Direction>('up');
  const [running, setRunning] = useState(false);
  const [dead, setDead] = useState(false);
  const [score, setScore] = useState(0);
  const [best, setBest] = useState(0);

  // The direction the NEXT tick will use. Queued rather than applied immediately
  // so two fast taps cannot turn the snake back into its own neck.
  const queued = useRef<Direction>('up');
  const boardRef = useRef<HTMLDivElement>(null);
  const scoredRef = useRef(false);

  const turn = useCallback((next: Direction) => {
    setDirection((current) => {
      if (OPPOSITE[current] === next) return current;
      queued.current = next;
      return current;
    });
  }, []);

  const start = useCallback(() => {
    setSnake(START_SNAKE);
    setFood(randomFood(START_SNAKE));
    setDirection('up');
    queued.current = 'up';
    setScore(0);
    setDead(false);
    setRunning(true);
    boardRef.current?.focus();
  }, []);

  useEffect(() => {
    if (!running) return undefined;

    const id = window.setInterval(() => {
      setSnake((current) => {
        const heading = queued.current;
        setDirection(heading);
        const step = STEP[heading];
        const head = { x: current[0].x + step.x, y: current[0].y + step.y };

        const hitWall = head.x < 0 || head.y < 0 || head.x >= COLS || head.y >= ROWS;
        const hitSelf = current.some((part) => part.x === head.x && part.y === head.y);
        if (hitWall || hitSelf) {
          setRunning(false);
          setDead(true);
          return current;
        }

        const ate = head.x === food.x && head.y === food.y;
        const next = ate ? [head, ...current] : [head, ...current.slice(0, -1)];
        if (ate) {
          setFood(randomFood(next));
          setScore((value) => {
            const raised = value + 1;
            setBest((high) => Math.max(high, raised));
            if (!scoredRef.current) {
              scoredRef.current = true;
              onScored();
            }
            return raised;
          });
        }
        return next;
      });
    }, TICK_MS);

    return () => window.clearInterval(id);
  }, [running, food, onScored]);

  const onKeyDown = (event: React.KeyboardEvent) => {
    const map: Record<string, Direction> = {
      ArrowUp: 'up',
      ArrowDown: 'down',
      ArrowLeft: 'left',
      ArrowRight: 'right',
      w: 'up',
      s: 'down',
      a: 'left',
      d: 'right',
    };
    const next = map[event.key];
    if (!next) return;
    event.preventDefault();
    turn(next);
  };

  const touchStart = useRef<Point | null>(null);
  const onTouchStart = (event: React.TouchEvent) => {
    const touch = event.touches[0];
    touchStart.current = { x: touch.clientX, y: touch.clientY };
  };
  const onTouchEnd = (event: React.TouchEvent) => {
    const origin = touchStart.current;
    if (!origin) return;
    const touch = event.changedTouches[0];
    const dx = touch.clientX - origin.x;
    const dy = touch.clientY - origin.y;
    if (Math.abs(dx) < 18 && Math.abs(dy) < 18) return;
    turn(Math.abs(dx) > Math.abs(dy) ? (dx > 0 ? 'right' : 'left') : dy > 0 ? 'down' : 'up');
  };

  const cells = Array.from({ length: COLS * ROWS }, (_, index) => {
    const x = index % COLS;
    const y = Math.floor(index / COLS);
    const partIndex = snake.findIndex((part) => part.x === x && part.y === y);
    if (partIndex === 0) return 'head';
    if (partIndex > 0) return 'body';
    if (food.x === x && food.y === y) return 'food';
    return 'empty';
  });

  return (
    <div className={styles.game}>
      <div className={styles.gameScore}>
        <span>
          Score <strong>{score}</strong>
        </span>
        <span>
          Best <strong>{best}</strong>
        </span>
      </div>

      <div
        ref={boardRef}
        className={styles.snakeBoard}
        style={{ gridTemplateColumns: `repeat(${COLS}, 1fr)` }}
        tabIndex={0}
        role="application"
        aria-label={`Snake board. Score ${score}. Use the arrow keys or the on-screen pad to steer.`}
        onKeyDown={onKeyDown}
        onTouchStart={onTouchStart}
        onTouchEnd={onTouchEnd}
      >
        {cells.map((kind, index) => (
          <span key={index} className={styles.snakeCell} data-kind={kind} />
        ))}

        {!running ? (
          <div className={styles.gameOverlay}>
            <p>{dead ? `Out on ${score}.` : 'Steer with the pad, the arrow keys or a swipe.'}</p>
            <button type="button" className={styles.gamePrimary} onClick={start}>
              {dead ? 'Play again' : 'Start Snake'}
            </button>
          </div>
        ) : null}
      </div>

      <div className={styles.dpad} aria-hidden={running ? undefined : 'true'}>
        <button type="button" aria-label="Steer up" onClick={() => turn('up')} disabled={!running}>
          <Glyph name="chevron-left" size={16} style={{ transform: 'rotate(90deg)' }} />
        </button>
        <button type="button" aria-label="Steer left" onClick={() => turn('left')} disabled={!running}>
          <Glyph name="chevron-left" size={16} />
        </button>
        <button type="button" aria-label="Steer down" onClick={() => turn('down')} disabled={!running}>
          <Glyph name="chevron-left" size={16} style={{ transform: 'rotate(-90deg)' }} />
        </button>
        <button type="button" aria-label="Steer right" onClick={() => turn('right')} disabled={!running}>
          <Glyph name="chevron-right" size={16} />
        </button>
      </div>

      <p className={styles.gameNote} role="status">
        {running ? `Playing. Direction: ${direction}.` : dead ? `Game over on ${score}.` : 'Ready.'}
      </p>
    </div>
  );
}

/* ---- Hand Cricket --------------------------------------------------------- */

type CricketPhase = 'batting' | 'bowling' | 'done';

export function CricketGame({ onScored }: { onScored: () => void }) {
  const [phase, setPhase] = useState<CricketPhase>('batting');
  const [yourScore, setYourScore] = useState(0);
  const [theirScore, setTheirScore] = useState(0);
  const [lastYou, setLastYou] = useState<number | null>(null);
  const [lastThem, setLastThem] = useState<number | null>(null);
  const [message, setMessage] = useState('You are batting. Pick a number they will not.');
  const scoredRef = useRef(false);

  const reset = () => {
    setPhase('batting');
    setYourScore(0);
    setTheirScore(0);
    setLastYou(null);
    setLastThem(null);
    setMessage('You are batting. Pick a number they will not.');
  };

  const play = (pick: number) => {
    const them = 1 + Math.floor(Math.random() * 6);
    setLastYou(pick);
    setLastThem(them);

    if (!scoredRef.current) {
      scoredRef.current = true;
      onScored();
    }

    if (phase === 'batting') {
      if (pick === them) {
        setPhase('bowling');
        setMessage(`Out on ${yourScore}. Now bowl — keep them under ${yourScore + 1}.`);
        return;
      }
      const raised = yourScore + pick;
      setYourScore(raised);
      setMessage(`${pick} runs. Keep going.`);
      return;
    }

    if (phase === 'bowling') {
      if (pick === them) {
        setPhase('done');
        setMessage(
          theirScore > yourScore
            ? `They got there first — ${theirScore} to ${yourScore}.`
            : `Bowled them out. You win ${yourScore} to ${theirScore}.`,
        );
        return;
      }
      const raised = theirScore + them;
      setTheirScore(raised);
      if (raised > yourScore) {
        setPhase('done');
        setMessage(`They chased it down. ${raised} to ${yourScore}.`);
        return;
      }
      setMessage(`They took ${them}. ${yourScore - raised + 1} more to defend.`);
    }
  };

  return (
    <div className={styles.game}>
      <div className={styles.cricketBoard}>
        <div className={styles.cricketHand} data-side="you">
          <span className={styles.cricketPick}>{lastYou ?? '–'}</span>
          <small>You</small>
        </div>
        <span className={styles.cricketVs}>vs</span>
        <div className={styles.cricketHand} data-side="them">
          <span className={styles.cricketPick}>{lastThem ?? '–'}</span>
          <small>Rohan</small>
        </div>
      </div>

      <div className={styles.cricketScore}>
        <span>
          You <strong>{yourScore}</strong>
        </span>
        <span>
          Rohan <strong>{theirScore}</strong>
        </span>
      </div>

      <p className={styles.gameNote} role="status">
        {message}
      </p>

      {phase === 'done' ? (
        <button type="button" className={styles.gamePrimary} onClick={reset}>
          Play again
        </button>
      ) : (
        <div className={styles.cricketKeys}>
          {[1, 2, 3, 4, 5, 6].map((value) => (
            <button
              key={value}
              type="button"
              onClick={() => play(value)}
              aria-label={`Play ${value}`}
            >
              {value}
            </button>
          ))}
        </div>
      )}
    </div>
  );
}

/* ---- Tic Tac Toe ---------------------------------------------------------- */

type Mark = 'x' | 'o' | null;

const LINES = [
  [0, 1, 2], [3, 4, 5], [6, 7, 8],
  [0, 3, 6], [1, 4, 7], [2, 5, 8],
  [0, 4, 8], [2, 4, 6],
];

function winnerOf(board: Mark[]): { mark: Mark; line: number[] } | null {
  for (const line of LINES) {
    const [a, b, c] = line;
    if (board[a] && board[a] === board[b] && board[a] === board[c]) {
      return { mark: board[a], line };
    }
  }
  return null;
}

/** Take the win, else block the loss, else the centre, else anywhere. */
function opponentMove(board: Mark[]): number {
  const empty = board.map((cell, index) => (cell ? -1 : index)).filter((i) => i >= 0);
  for (const mark of ['o', 'x'] as const) {
    for (const line of LINES) {
      const values = line.map((i) => board[i]);
      const owned = values.filter((v) => v === mark).length;
      const open = values.filter((v) => v === null).length;
      if (owned === 2 && open === 1) return line[values.indexOf(null)];
    }
  }
  if (board[4] === null) return 4;
  return empty[Math.floor(Math.random() * empty.length)];
}

export function TicTacToeGame({ onScored }: { onScored: () => void }) {
  const [board, setBoard] = useState<Mark[]>(Array(9).fill(null));
  const [message, setMessage] = useState('You are X. Your move.');
  const [over, setOver] = useState(false);
  const scoredRef = useRef(false);

  const result = winnerOf(board);

  const reset = () => {
    setBoard(Array(9).fill(null));
    setMessage('You are X. Your move.');
    setOver(false);
  };

  const play = (index: number) => {
    if (over || board[index]) return;
    if (!scoredRef.current) {
      scoredRef.current = true;
      onScored();
    }

    const next = [...board];
    next[index] = 'x';
    const mine = winnerOf(next);
    if (mine) {
      setBoard(next);
      setOver(true);
      setMessage('Three in a row. You win.');
      return;
    }
    if (next.every(Boolean)) {
      setBoard(next);
      setOver(true);
      setMessage('Drawn. Nobody blinked.');
      return;
    }

    next[opponentMove(next)] = 'o';
    const theirs = winnerOf(next);
    setBoard(next);
    if (theirs) {
      setOver(true);
      setMessage('Rohan got there first.');
      return;
    }
    if (next.every(Boolean)) {
      setOver(true);
      setMessage('Drawn. Nobody blinked.');
      return;
    }
    setMessage('Your move.');
  };

  return (
    <div className={styles.game}>
      <div className={styles.tttBoard} role="group" aria-label="Tic Tac Toe board">
        {board.map((mark, index) => (
          <button
            key={index}
            type="button"
            onClick={() => play(index)}
            disabled={over || mark !== null}
            data-mark={mark ?? undefined}
            data-win={result?.line.includes(index) ? 'true' : undefined}
            aria-label={
              mark
                ? `Square ${index + 1}, ${mark === 'x' ? 'yours' : "Rohan's"}`
                : `Play square ${index + 1}`
            }
          >
            {mark === 'x' ? '✕' : mark === 'o' ? '○' : ''}
          </button>
        ))}
      </div>

      <p className={styles.gameNote} role="status">{message}</p>

      {over ? (
        <button type="button" className={styles.gamePrimary} onClick={reset}>
          Play again
        </button>
      ) : null}
    </div>
  );
}

/* ---- Rock Paper Scissors -------------------------------------------------- */

const THROWS = [
  { id: 'rock', label: 'Rock', beats: 'scissors', glyph: '✊' },
  { id: 'paper', label: 'Paper', beats: 'rock', glyph: '✋' },
  { id: 'scissors', label: 'Scissors', beats: 'paper', glyph: '✌️' },
] as const;

export function RpsGame({ onScored }: { onScored: () => void }) {
  const [yours, setYours] = useState<(typeof THROWS)[number] | null>(null);
  const [theirs, setTheirs] = useState<(typeof THROWS)[number] | null>(null);
  const [score, setScore] = useState({ you: 0, them: 0 });
  const [message, setMessage] = useState('Both sides throw at once. Pick one.');
  const scoredRef = useRef(false);

  const play = (choice: (typeof THROWS)[number]) => {
    const other = THROWS[Math.floor(Math.random() * THROWS.length)];
    setYours(choice);
    setTheirs(other);

    if (!scoredRef.current) {
      scoredRef.current = true;
      onScored();
    }

    if (choice.id === other.id) {
      setMessage('A draw. Again.');
      return;
    }
    if (choice.beats === other.id) {
      setScore((s) => ({ ...s, you: s.you + 1 }));
      setMessage(`${choice.label} beats ${other.label.toLowerCase()}. Yours.`);
      return;
    }
    setScore((s) => ({ ...s, them: s.them + 1 }));
    setMessage(`${other.label} beats ${choice.label.toLowerCase()}. Theirs.`);
  };

  return (
    <div className={styles.game}>
      <div className={styles.cricketBoard}>
        <div className={styles.cricketHand}>
          <span className={styles.cricketPick}>{yours?.glyph ?? '–'}</span>
          <small>You</small>
        </div>
        <span className={styles.cricketVs}>vs</span>
        <div className={styles.cricketHand}>
          <span className={styles.cricketPick}>{theirs?.glyph ?? '–'}</span>
          <small>Rohan</small>
        </div>
      </div>

      <div className={styles.cricketScore}>
        <span>You <strong>{score.you}</strong></span>
        <span>Rohan <strong>{score.them}</strong></span>
      </div>

      <p className={styles.gameNote} role="status">{message}</p>

      <div className={styles.rpsKeys}>
        {THROWS.map((throwOption) => (
          <button
            key={throwOption.id}
            type="button"
            onClick={() => play(throwOption)}
            aria-label={`Throw ${throwOption.label}`}
          >
            <span aria-hidden="true">{throwOption.glyph}</span>
            {throwOption.label}
          </button>
        ))}
      </div>
    </div>
  );
}
