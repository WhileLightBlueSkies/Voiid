import type { Metadata } from 'next';
import type { ReactNode } from 'react';
import { Hero } from '../../components/Hero';
import { Section, Grid, Split } from '../../components/Section';
import { CTA } from '../../components/CTA';
import { Button, ButtonRow } from '../../components/Button';
import { E2EEBadge } from '../../components/E2EEBadge';
import { Callout } from '../../components/Callout';
import { Glyph } from '../../components/Glyph';
import {
  PhoneMockup,
  PhoneAppBar,
  PhoneAvatar,
} from '../../components/PhoneMockup';
import styles from './page.module.css';

/*
 * EVERY CLAIM ON THIS PAGE IS TRACEABLE. The sources, once, so a future edit can be
 * checked against the same files:
 *
 *   catalogue is exactly four   024_games.sql seeds tictactoe + rps, 025 seeds cricket,
 *                               026 seeds snake; backend/games/src/engine/registry.ts
 *                               holds exactly those four factories.
 *   game state is readable      024_games.sql header ("the server is the referee. It must
 *                               read moves to validate them") and routes/games.ts.
 *   the invite is E2EE          routes/games.ts (this router never sees it),
 *                               Networking/GameInvite.swift + net/GameInvite.kt (the
 *                               invite is an ordinary text message carrying a marker),
 *                               pushPayload.ts (the push title is the constant
 *                               "New message"; the device rewrites its own banner).
 *   who may be invited          routes/games.ts reachableOpponents() — both sides must be
 *                               'accepted' in a direct conversation, and the 403 does not
 *                               say which opponent failed.
 *   ten-minute invite window    INVITE_TTL_MS in routes/games.ts, GameInvite.expiryMs.
 *   live state is ephemeral     backend/games/src/redis.ts (match:<id>:state, TTL) and
 *                               matches.ts finishMatch() — the key is deleted at the end.
 *   what outlives a match       game_matches + game_match_results (024_games.sql).
 *   rate limits                 backend/games/src/index.ts — 60/min turn-based, tick-rate
 *                               derived (2x headroom) for continuous games.
 *   per-game numbers            engine/rps (target 3), engine/cricket (MIN_OVERS 1,
 *                               MAX_OVERS 5, BALLS_PER_OVER 6, WICKETS_PER_INNINGS 2,
 *                               picks 0-6), engine/snake (TICK_HZ 10, MATCH_SECONDS 180,
 *                               max_players 6 in 026), engine/tictactoe.
 *   practice                    Games/BotScoreStore.swift + main/games/BotGameState.kt
 *                               (turn-based bots are on-device and never reach the
 *                               server); GamesEngine.createSolo + 026 (Snake's bots run
 *                               server-side, 3/5/8 by difficulty in GamesHomeView).
 *   leaderboard                 routes/games.ts GET /games/leaderboard — scoped to people
 *                               you have finished a match with, draws counted separately.
 *
 * AMBER BUDGET: the page hue IS amber (games borrows --hue-payments), and the single
 * amber component is the "Server-refereed" badge in the hero. No accent Button, no
 * accent CTA, no unread pill. Do not add a second.
 */

export const metadata: Metadata = {
  title: 'Games',
  description:
    'Tic Tac Toe, Rock Paper Scissors, Hand Cricket and Snake, played inside a Voiid ' +
    'chat. The invite is an ordinary end-to-end encrypted message; the match itself is ' +
    'refereed by our server, which therefore reads the moves. Here is exactly what that ' +
    'means and what is kept.',
};

/* =============================================================================
 * Game marks — four authored glyphs, drawn on the same 32-grid and stroke weight
 * as <Glyph>, so the catalogue does not need artwork it cannot ship offline.
 * ========================================================================== */

type MarkName = 'tictactoe' | 'rps' | 'cricket' | 'snake';

function GameMark({ name, size = 34 }: { name: MarkName; size?: number }) {
  return (
    <svg
      className={styles.mark}
      width={size}
      height={size}
      viewBox="0 0 32 32"
      fill="none"
      stroke="currentColor"
      strokeWidth="1.6"
      strokeLinecap="round"
      strokeLinejoin="round"
      aria-hidden="true"
      focusable="false"
    >
      {name === 'tictactoe' ? (
        <>
          <rect x="5" y="5" width="22" height="22" rx="3" opacity="0.55" />
          <path d="M12.3 5.6V26.4M19.7 5.6V26.4M5.6 12.3H26.4M5.6 19.7H26.4" opacity="0.5" />
          <path d="M7.2 7.2 10.4 10.4M10.4 7.2 7.2 10.4" />
          <circle cx="16" cy="16" r="2.5" />
        </>
      ) : null}

      {name === 'rps' ? (
        <>
          {/* rock */}
          <circle cx="9.2" cy="9.4" r="4.3" />
          {/* paper */}
          <path d="M18.4 5.2h8.2v9.6h-8.2z" />
          <path d="M20.6 8.2h3.8M20.6 11.2h3.8" opacity="0.6" />
          {/* scissors */}
          <path d="M11.4 26.6 21 18.6M20.6 26.6 11 18.6" />
          <circle cx="10.6" cy="27.4" r="1.7" />
          <circle cx="21.4" cy="27.4" r="1.7" />
        </>
      ) : null}

      {name === 'cricket' ? (
        <>
          <g transform="rotate(-30 16 16)">
            <path d="M12.4 10.6h6.6v11.2a3.3 3.3 0 0 1-3.3 3.3 3.3 3.3 0 0 1-3.3-3.3z" />
            <path d="M15.7 10.6V5.4" />
          </g>
          <circle cx="24.4" cy="24.6" r="3.6" />
          <path d="M22 23.2q2.4 1.7 4.8-.4" opacity="0.7" />
        </>
      ) : null}

      {name === 'snake' ? (
        <>
          <path d="M4.5 25.5c5 0 4.4-10 9.4-10s4.4 8 9.4 8" />
          <circle cx="26" cy="23" r="2.6" />
          <circle cx="26.6" cy="22.4" r="0.7" fill="currentColor" stroke="none" />
          <circle cx="9.4" cy="8.6" r="2" fill="currentColor" stroke="none" opacity="0.75" />
        </>
      ) : null}
    </svg>
  );
}

/* =============================================================================
 * The referee loop — the page's mechanism drawing.
 *
 * It shows the one thing the copy has to land: a move goes UP to the server in the
 * clear because the server has to judge it, the resulting board comes back DOWN to
 * both players, and the invite that started the whole thing never went that way at
 * all — it crossed between the two phones sealed.
 *
 * Authored SVG + CSS, no library and no external asset. The three travelling chips
 * ride CSS `offset-path` rather than SMIL, because SMIL ignores
 * prefers-reduced-motion; the path data therefore appears twice, once here as
 * geometry and once in page.module.css. Change one, change the other.
 * ========================================================================== */

const MOVE_PATH = 'M96 250 C 130 200, 158 170, 206 154';
const STATE_L_PATH = 'M196 166 C 148 186, 110 214, 78 252';
const STATE_R_PATH = 'M320 160 C 372 182, 412 210, 442 250';

const REFEREE_LABEL =
  'Diagram. Two phones sit at the bottom, one for each player. A move — a single tap, ' +
  'readable — travels up from the left phone to our server, which holds the board and ' +
  'checks the move against it. The resulting board travels back down to both phones. ' +
  'Below, a separate sealed packet passes directly between the two phones: the game ' +
  'invite, which is an ordinary end-to-end encrypted message and never passes through ' +
  'the referee.';

function RefereeLoop({ size = 520 }: { size?: number }) {
  return (
    <svg
      className={styles.loop}
      width={size}
      height={size * 0.81}
      viewBox="0 0 520 420"
      role="img"
      aria-label={REFEREE_LABEL}
    >
      <defs>
        <radialGradient id="games-loop-bloom" cx="50%" cy="50%" r="50%">
          <stop offset="0%" className={styles.bloomIn} />
          <stop offset="100%" className={styles.bloomOut} />
        </radialGradient>
      </defs>

      <ellipse cx="260" cy="150" rx="230" ry="150" fill="url(#games-loop-bloom)" />

      {/* ---- the referee ---------------------------------------------------- */}
      <text x="260" y="26" className={styles.loopLabel} textAnchor="middle">
        our server · the referee
      </text>
      <rect x="170" y="40" width="180" height="106" rx="18" className={styles.refBox} />
      <g className={styles.board}>
        <path d="M196 62h66M196 84h66M196 106h66M196 128h66" opacity="0" />
        <rect x="196" y="62" width="66" height="66" rx="6" />
        <path d="M218 62v66M240 62v66M196 84h66M196 106h66" />
        <path d="M200.5 66.5 213.5 79.5M213.5 66.5 200.5 79.5" className={styles.boardMark} />
        <circle cx="229" cy="95" r="5" className={styles.boardMark} />
      </g>
      <text x="278" y="88" className={styles.loopMicro}>
        holds the board
      </text>
      <text x="278" y="106" className={styles.loopMicro}>
        judges the move
      </text>

      {/* ---- the move, going up in the clear -------------------------------- */}
      <path d={MOVE_PATH} className={styles.wireOpen} />
      <path d="M198 163 206 154 194 152" className={styles.arrowOpen} />
      <text x="126" y="150" className={styles.loopCaption} textAnchor="middle">
        one tap · readable
      </text>

      {/* ---- the board, coming back to both --------------------------------- */}
      <path d={STATE_L_PATH} className={styles.wireState} />
      <path d="M89 248 78 253 80 240" className={styles.arrowState} />
      <path d={STATE_R_PATH} className={styles.wireState} />
      <path d="M441 238 442 250 431 245" className={styles.arrowState} />
      <text x="404" y="150" className={styles.loopCaption} textAnchor="middle">
        the same board · to both
      </text>

      {/* ---- the two phones -------------------------------------------------- */}
      <g className={styles.phone}>
        <rect x="36" y="250" width="76" height="118" rx="15" />
        <rect x="45" y="262" width="58" height="86" rx="7" className={styles.phoneScreen} />
        <line x1="62" y1="256" x2="86" y2="256" strokeWidth="3" />
      </g>
      <text x="74" y="390" className={styles.loopLabel} textAnchor="middle">
        her phone
      </text>

      <g className={styles.phone}>
        <rect x="408" y="250" width="76" height="118" rx="15" />
        <rect x="417" y="262" width="58" height="86" rx="7" className={styles.phoneScreen} />
        <line x1="434" y1="256" x2="458" y2="256" strokeWidth="3" />
      </g>
      <text x="446" y="390" className={styles.loopLabel} textAnchor="middle">
        his phone
      </text>

      {/* ---- the invite: sealed, and it never went via the referee ---------- */}
      <path d="M120 322 H400" className={styles.wireSealed} />
      <g className={styles.sealed} transform="translate(260 322)">
        <rect x="-19" y="-13" width="38" height="26" rx="7" className={styles.sealedBody} />
        <path d="M-19 -8 0 3.5 19 -8" fill="none" />
        <path d="M-6 -13v-6a6 6 0 0 1 12 0v6" fill="none" className={styles.shackle} />
      </g>
      {/* Kept short deliberately: at phone widths a longer caption collides with the
        * two phones either side of it. The aria-label carries the full sentence. */}
      <text x="260" y="356" className={styles.loopCaption} textAnchor="middle">
        the invite · sealed
      </text>

      {/* ---- travelling chips ------------------------------------------------ */}
      <g className={styles.chipMove}>
        <rect x="-15" y="-11" width="30" height="22" rx="6" />
        <text x="0" y="5" className={styles.chipText} textAnchor="middle">
          4
        </text>
      </g>
      <g className={styles.chipStateL}>
        <rect x="-13" y="-10" width="26" height="20" rx="6" />
        <path d="M-6 -3h12M-6 2h7" className={styles.chipLines} />
      </g>
      <g className={styles.chipStateR}>
        <rect x="-13" y="-10" width="26" height="20" rx="6" />
        <path d="M-6 -3h12M-6 2h7" className={styles.chipLines} />
      </g>
    </svg>
  );
}

/* =============================================================================
 * The catalogue — four rows in a table, and no more than that.
 * ========================================================================== */

type CatalogueEntry = {
  mark: MarkName;
  name: string;
  kind: string;
  seats: string;
  specs: string[];
  /** What the server decides that the client is not allowed to. */
  referee: ReactNode;
};

const CATALOGUE: CatalogueEntry[] = [
  {
    mark: 'tictactoe',
    name: 'Tic Tac Toe',
    kind: 'Board',
    seats: '2 players',
    specs: ['Nine cells', 'Whoever invited moves first', 'Seat order fixed at creation'],
    referee: (
      <>
        Your phone sends one thing: <em>I tapped cell four</em>. Out of range, already
        taken, not your turn, game already over — every one of those is refused on the
        server, so a modified app has nothing useful left to lie about.
      </>
    ),
  },
  {
    mark: 'rps',
    name: 'Rock Paper Scissors',
    kind: 'Board',
    seats: '2 players',
    specs: ['First to three round wins', 'Simultaneous throw', 'Ties replay the round'],
    referee: (
      <>
        Both of you throw at the same moment, so your throw is held server-side and left
        out of the state your opponent is sent until theirs arrives. There is nothing to
        wait and see — one round of it is a coin flip, which is why the match runs to
        three.
      </>
    ),
  },
  {
    mark: 'cricket',
    name: 'Hand Cricket',
    kind: 'Board',
    seats: '2 players',
    specs: [
      'One to five overs, set by the inviter',
      'Six balls an over · two wickets an innings',
      'Numbers zero to six — a closed fist is a dot ball',
    ],
    referee: (
      <>
        Match the bowler&rsquo;s number and you are out. Both picks are held and revealed
        in the same frame, for the same reason as Rock Paper Scissors: a player who could
        see the other&rsquo;s number would either take a wicket at will or bat forever.
      </>
    ),
  },
  {
    mark: 'snake',
    name: 'Snake',
    kind: 'Arcade',
    seats: '1 to 6 players',
    specs: [
      'Three-minute match',
      'The arena advances ten times a second',
      'Food and kills build your score',
    ],
    referee: (
      <>
        Your phone sends a heading and whether you are holding boost — that is the entire
        vocabulary. Where you are, how long you are, whether you ate and whether you died
        are all worked out on the server, and the largest score when the clock stops wins.
      </>
    ),
  },
];

/* =============================================================================
 * What the server does with a match.
 * ========================================================================== */

const LEDGER: { term: string; detail: ReactNode }[] = [
  {
    term: 'What it reads',
    detail: (
      <>
        A cell index, a throw, a number from zero to six, a heading and a boost flag.
        That is the whole vocabulary a client can speak — there is no frame that says
        &ldquo;I won&rdquo;.
      </>
    ),
  },
  {
    term: 'What it decides',
    detail: (
      <>
        Whose turn it is, whether a move is legal, when a round resolves and who won.
        The app is a renderer: it draws the state it is sent and never predicts one,
        which is also why a piece never appears and then un-places itself.
      </>
    ),
  },
  {
    term: 'Where the live board lives',
    detail: (
      <>
        In memory, and in a cache entry that expires on its own. It is deleted the
        moment the match ends. Nothing about the run of play — no move list, no board
        history — is written to the database at all.
      </>
    ),
  },
  {
    term: 'What outlives the match',
    detail: (
      <>
        Which game, who played, when it started and ended, who won, and each
        player&rsquo;s score and placement. One row for the match, one for each
        player, and they are what the leaderboard counts.
      </>
    ),
  },
];

/* =============================================================================
 * The page.
 * ========================================================================== */

export default function GamesPage() {
  return (
    <>
      <Hero
        hue="games"
        eyebrow="Games"
        title="Four games, played inside the chats you already have."
        lede={
          <>
            Tic Tac Toe, Rock Paper Scissors, Hand Cricket and Snake. You invite someone
            you already talk to, the invite travels as an ordinary encrypted message —
            and then our server runs the match, because a game with no referee is a game
            you can win by editing the app.
          </>
        }
        badges={
          <>
            <E2EEBadge
              state="refereed"
              size="md"
              detail="Moves, scores and results are readable by us. Refereeing means reading."
            />
            <E2EEBadge
              state="e2ee"
              size="md"
              label="The invite is still encrypted"
              detail="It rides the same message pipe as anything else you send."
            />
          </>
        }
        actions={
          <ButtonRow>
            <Button href="#catalogue" size="lg">
              See all four
            </Button>
            <Button href="#referee" variant="secondary" size="lg">
              Why the server reads moves
            </Button>
          </ButtonRow>
        }
        aside={<RefereeLoop />}
      />

      {/* ---- the catalogue --------------------------------------------------- */}
      <Section
        id="catalogue"
        hue="games"
        eyebrow="The catalogue"
        title="Four games. That is the entire list, and we are not going to pad it."
        lede={
          <>
            The catalogue is a table on the server, not a list compiled into the app, so
            a game can be added or pulled without an app update — and so this page can be
            checked against it. Today it has four rows. When it has five, this page will
            say five.
          </>
        }
      >
        {/* Two up, deliberately: `Grid` auto-fits, which at container width would put
          * three cards on one row and leave Snake stranded on its own. */}
        <Grid columns={2} gap="md" className={styles.catalogueGrid}>
          {CATALOGUE.map((game) => (
            <article key={game.mark} className={styles.gameCard}>
              <header className={styles.gameHead}>
                <span className={styles.gameMark} aria-hidden="true">
                  <GameMark name={game.mark} />
                </span>
                <div className={styles.gameTitles}>
                  <h3 className={styles.gameName}>{game.name}</h3>
                  <p className={styles.gameKind}>
                    {game.kind} · {game.seats}
                  </p>
                </div>
              </header>

              <ul className={styles.specs}>
                {game.specs.map((spec) => (
                  <li key={spec}>
                    <Glyph name="check" size={14} className={styles.specTick} />
                    <span>{spec}</span>
                  </li>
                ))}
              </ul>

              <p className={styles.gameReferee}>{game.referee}</p>
            </article>
          ))}
        </Grid>

        <p className={styles.catalogueNote}>
          Three of the four are strictly two-player. Snake is the exception in both
          directions: it seats up to six, and it is the only one you can start with nobody
          else in it.
        </p>
      </Section>

      {/* ---- how an invite works --------------------------------------------- */}
      <Section
        id="invites"
        hue="games"
        tone="raised"
        eyebrow="Invites"
        title="An invite is a message. That is not a figure of speech."
        lede={
          <>
            There is no separate invite system, no invite server and no second push path.
            An invite is a text message with a marker in it, sent down the pipe your chats
            already use — which is why it wakes a phone, survives being offline, and stays
            unreadable to us.
          </>
        }
      >
        <Split
          reverse
          align="start"
          aside={
            <PhoneMockup
              hue="games"
              size="md"
              tilt="left"
              label="The Games screen in Voiid, showing an incoming invite from Aditi to a three-over game of Hand Cricket, with Join and Decline, above a grid of the four games."
            >
              <PhoneAppBar
                title="Games"
                back={false}
                trailing={<Glyph name="group" size={16} />}
              />
              <div className={styles.phoneBody}>
                <div className={styles.inviteCard}>
                  <div className={styles.inviteTop}>
                    <PhoneAvatar initials="A" size={24} seed={1} />
                    <span className={styles.inviteText}>
                      <strong>Aditi</strong> invited you to <strong>Hand Cricket</strong>
                    </span>
                  </div>
                  <span className={styles.inviteMeta}>3 overs · live for 10 minutes</span>
                  <div className={styles.inviteActions}>
                    <span className={styles.inviteJoin}>Join</span>
                    <span className={styles.inviteDecline}>Decline</span>
                  </div>
                </div>

                <div className={styles.tileGrid}>
                  {CATALOGUE.map((game) => (
                    <span key={game.mark} className={styles.tile}>
                      <GameMark name={game.mark} size={26} />
                      <span className={styles.tileName}>{game.name}</span>
                    </span>
                  ))}
                </div>
              </div>
            </PhoneMockup>
          }
        >
          <ol className={styles.steps}>
            <li>
              <h3>Pick the game, then pick a person.</h3>
              <p>
                The list you pick from is your existing conversations. Both sides have to
                have accepted each other before either can be named in a match — the same
                gate a call has to pass — because naming someone puts a banner with your
                name on their screen. A stranger holding your account id gets a refusal
                that deliberately does not say which part failed.
              </p>
            </li>
            <li>
              <h3>The match is created, and nobody is told yet.</h3>
              <p>
                The server records which game, which two accounts, and anything chosen up
                front — hand cricket needs its over count before an innings can exist. It
                sends no notification of its own, on purpose: an invite should produce one
                alert, not two.
              </p>
            </li>
            <li>
              <h3>Your app sends the invite as an encrypted message.</h3>
              <p>
                A readable line, then a marker carrying the match id. All of it sits
                inside the encryption, which is why the push that leaves us carries the
                constant title &ldquo;New message&rdquo; through Apple, and no banner text
                at all through Google. Their phone decrypts the message and then writes
                its own notification, naming the game and the length.
              </p>
            </li>
            <li>
              <h3>They join, and the referee deals the opening board.</h3>
              <p>
                Their tap does not build the board; the server does, and sends the same
                state to both phones at once. An invite is live for ten minutes. After
                that it is shown as missed rather than quietly vanishing, and either side
                can decline it outright.
              </p>
            </li>
          </ol>

          <Callout tone="note" glyph="key" title="What the invite tells us.">
            <p>
              That a match exists, which game it is, and which two accounts are in it —
              because a row had to be created before anyone could join it. The words in
              the message, including the poster your friend sees, are encrypted like every
              other message you send.
            </p>
          </Callout>
        </Split>
      </Section>

      {/* ---- the referee ------------------------------------------------------ */}
      <Section
        id="referee"
        hue="games"
        eyebrow="The exception, stated plainly"
        title="Our server reads your moves. It has to, and here is the whole of what that costs you."
        lede={
          <>
            Everywhere else in Voiid the server stores things it cannot read. Game state
            is the one deliberate exception in the entire schema: a referee that cannot
            see the moves is not a referee, and &ldquo;server-authoritative&rdquo; would
            be a word we had put on a diagram.
          </>
        }
      >
        <dl className={styles.ledger}>
          {LEDGER.map((row) => (
            <div key={row.term} className={styles.ledgerRow}>
              <dt className={styles.ledgerTerm}>{row.term}</dt>
              <dd className={styles.ledgerDetail}>{row.detail}</dd>
            </div>
          ))}
        </dl>

        {/* ---- the mechanism the refereeing buys you --------------------- */}
        <figure className={styles.reveal}>
          <figcaption className={styles.revealHead}>
            <h3 className={styles.revealTitle}>One ball of hand cricket, from our side</h3>
            <p className={styles.revealLede}>
              This is what a referee is actually for. Both players pick a number at the
              same time, so the server has to hold each pick somewhere the other player
              cannot reach — and then reveal both in a single frame.
            </p>
          </figcaption>

          <ol className={styles.revealSteps}>
            <li className={styles.revealStep}>
              <span className={styles.revealIndex} aria-hidden="true">
                1
              </span>
              <span className={styles.revealCards} aria-hidden="true">
                <span className={[styles.card, styles.cardDown].join(' ')}>
                  <span className={styles.cardHatch} />
                </span>
                <span className={[styles.card, styles.cardEmpty].join(' ')} />
              </span>
              <p className={styles.revealBody}>
                <strong>She picks 4.</strong> It goes into a field that the broadcast does
                not carry. What his phone is told is one bit: <em>she has picked</em>.
              </p>
            </li>
            <li className={styles.revealStep}>
              <span className={styles.revealIndex} aria-hidden="true">
                2
              </span>
              <span className={styles.revealCards} aria-hidden="true">
                <span className={[styles.card, styles.cardDown].join(' ')}>
                  <span className={styles.cardHatch} />
                </span>
                <span className={[styles.card, styles.cardDown].join(' ')}>
                  <span className={styles.cardHatch} />
                </span>
              </span>
              <p className={styles.revealBody}>
                <strong>He picks 4 too.</strong> Still nothing is sent. Neither phone has
                ever held the other&rsquo;s number, so neither app can leak it however it
                is modified.
              </p>
            </li>
            <li className={styles.revealStep}>
              <span className={styles.revealIndex} aria-hidden="true">
                3
              </span>
              <span className={styles.revealCards} aria-hidden="true">
                <span className={[styles.card, styles.cardUp].join(' ')}>4</span>
                <span className={[styles.card, styles.cardUp].join(' ')}>4</span>
              </span>
              <p className={styles.revealBody}>
                <strong>Both turn over in the same frame.</strong> Matched numbers, so
                that is a wicket. The ball is now history and appears in the log both
                phones can see.
              </p>
            </li>
          </ol>
        </figure>

        <Callout title="The exception is scoped to game state, and to nothing else.">
          <p>
            Your messages, your calls, your location shares and your moments are
            unaffected by any of this: they stay ciphertext we hold no key for. Games did
            not weaken that, and the invite proves it — the one part of a match that is a
            message is encrypted like a message.
          </p>
        </Callout>

        <ButtonRow className={styles.refereeActions}>
          <Button href="/privacy" variant="ghost">
            The full list of what we can and cannot see
          </Button>
        </ButtonRow>
      </Section>

      {/* ---- practice + leaderboard ------------------------------------------ */}
      <Section
        id="practice"
        hue="games"
        tone="inset"
        eyebrow="Practice and records"
        title="Playing alone, and the only ranking we keep."
      >
        <div className={styles.pair}>
          <article className={styles.pairCard}>
            <span className={styles.pairGlyph} aria-hidden="true">
              <Glyph name="device" size={20} />
            </span>
            <h3>Practice happens on your phone</h3>
            <p>
              Tic Tac Toe, Rock Paper Scissors and Hand Cricket each ship with an
              opponent that runs entirely on your device, at easy, moderate or hard. None
              of it reaches us: there is no match, no result and no row, and the record it
              keeps lives in your phone&rsquo;s own storage.
            </p>
            <p>
              Snake is the exception, because its rules run on a clock rather than in
              turns. Its bots run on the server and a practice run is a real one-seat
              match — three, five or eight bots depending on the difficulty, all using
              exactly the same physics you do.
            </p>
          </article>

          <article className={styles.pairCard}>
            <span className={styles.pairGlyph} aria-hidden="true">
              <Glyph name="group" size={20} />
            </span>
            <h3>The leaderboard only knows your opponents</h3>
            <p>
              It lists people you have actually finished a match against, and nobody else.
              There is no global ranking, deliberately — putting you in a table with
              strangers would tell you those accounts exist and how often they play, which
              is not information a private messaging app should be handing out.
            </p>
            <p>
              Wins, draws and losses are counted separately rather than folded together.
              Tic Tac Toe draws constantly, and &ldquo;we drew four times&rdquo; is a
              different fact from &ldquo;I lost four times&rdquo;. Practice results are
              never mixed in, because nobody refereed them.
            </p>
          </article>
        </div>
      </Section>

      <CTA
        hue="games"
        title="Games are the one place we are allowed to look."
        lede={
          <>
            We would rather write that sentence on the games page than bury it in a policy
            document. Everything else you do in Voiid — the chats, the calls, the map, the
            moments — is sealed with keys that never leave your devices.
          </>
        }
        actions={
          <ButtonRow align="center">
            <Button href="/privacy" size="lg">
              Read the privacy architecture
            </Button>
            <Button href="/messaging" variant="secondary" size="lg">
              How messaging works
            </Button>
          </ButtonRow>
        }
        note="Games ship on both iOS and Android. Both builds are still in testing, and store links will appear on this site when they exist and not before."
      />
    </>
  );
}
