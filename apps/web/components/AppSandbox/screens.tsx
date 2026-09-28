'use client';

import { useEffect, useMemo, useRef, useState, type Dispatch, type FormEvent } from 'react';
import { Glyph, type GlyphName } from '../Glyph';
import { CHATS, CLIPS, GAMES, GAME_NAMES, MOMENTS, REPLIES, chatById, momentById } from './data';
import { CricketGame, RpsGame, SnakeGame, TicTacToeGame } from './games';
import { formatClock } from './state';
import type { Chat, GameId, Route, SandboxAction, SandboxState } from './types';
import styles from './app.module.css';

type Props = { state: SandboxState; dispatch: Dispatch<SandboxAction> };

/* ---- Shared pieces -------------------------------------------------------- */

function Avatar({ chat, size = 'md' }: { chat: Pick<Chat, 'initial' | 'tone' | 'group'>; size?: 'sm' | 'md' | 'lg' }) {
  return (
    <span className={styles.avatar} data-tone={chat.tone} data-size={size} aria-hidden="true">
      {chat.group ? <Glyph name="group" size={18} /> : chat.initial}
    </span>
  );
}

function NavBar({
  title,
  subtitle,
  onBack,
  leading,
  trailing,
}: {
  title: string;
  subtitle?: React.ReactNode;
  onBack?: () => void;
  leading?: React.ReactNode;
  trailing?: React.ReactNode;
}) {
  return (
    <header className={styles.nav}>
      {onBack ? (
        <button type="button" className={styles.navBack} onClick={onBack} aria-label="Back">
          <Glyph name="chevron-left" size={20} />
        </button>
      ) : null}
      {leading}
      <span className={styles.navTitle}>
        <h2>{title}</h2>
        {subtitle ? <small>{subtitle}</small> : null}
      </span>
      {trailing ? <span className={styles.navTrailing}>{trailing}</span> : null}
    </header>
  );
}

/* ---- Chats ---------------------------------------------------------------- */

function ChatsScreen({ state, dispatch }: Props) {
  const [query, setQuery] = useState('');
  const visible = useMemo(() => {
    const needle = query.trim().toLowerCase();
    if (!needle) return CHATS;
    return CHATS.filter(
      (chat) =>
        chat.name.toLowerCase().includes(needle) || chat.preview.toLowerCase().includes(needle),
    );
  }, [query]);

  return (
    <>
      <NavBar
        title="Chats"
        leading={
          <button
            type="button"
            className={styles.navAvatar}
            onClick={() => dispatch({ type: 'push', route: { screen: 'profile' } })}
            aria-label="Your profile and privacy settings"
          >
            <Avatar chat={{ initial: 'Y', tone: 'teal', group: false }} size="sm" />
          </button>
        }
        trailing={
          <span className={styles.navIcon} aria-hidden="true">
            <Glyph name="plus" size={19} />
          </span>
        }
      />

      <div className={styles.scroll}>
        <label className={styles.search}>
          <Glyph name="search" size={15} />
          <input
            type="search"
            value={query}
            placeholder="Search chats"
            aria-label="Search chats"
            onChange={(event) => setQuery(event.target.value)}
          />
        </label>

        <ul className={styles.chatList}>
          {visible.map((chat) => {
            const thread = state.messages[chat.id] ?? [];
            const last = thread[thread.length - 1];
            const preview =
              last?.kind === 'text'
                ? last.body
                : last?.kind === 'location'
                  ? 'Live location'
                  : last?.kind === 'game'
                    ? `${GAME_NAMES[last.game]} invite`
                    : chat.preview;
            return (
              <li key={chat.id}>
                <button
                  type="button"
                  className={styles.chatRow}
                  onClick={() => dispatch({ type: 'push', route: { screen: 'chat', chatId: chat.id } })}
                >
                  <Avatar chat={chat} />
                  <span className={styles.chatRowBody}>
                    <span className={styles.chatRowTop}>
                      <strong>{chat.name}</strong>
                      <small>{chat.time}</small>
                    </span>
                    <span className={styles.chatRowBottom}>
                      <span className={styles.chatPreview}>{preview}</span>
                      {chat.unread ? <em className={styles.unread}>{chat.unread}</em> : null}
                    </span>
                  </span>
                </button>
              </li>
            );
          })}
          {visible.length === 0 ? (
            <li className={styles.empty}>No chat matches “{query}”.</li>
          ) : null}
        </ul>
      </div>
    </>
  );
}

/* ---- One conversation ----------------------------------------------------- */

function ChatScreen({ state, dispatch, chatId }: Props & { chatId: string }) {
  const chat = chatById(chatId);
  const messages = state.messages[chatId] ?? [];
  const isTyping = state.typing.includes(chatId);
  const [draft, setDraft] = useState('');
  const [sheet, setSheet] = useState<'none' | 'location' | 'game'>('none');
  const endRef = useRef<HTMLDivElement>(null);

  // Keep the newest message in view, the way a chat does.
  useEffect(() => {
    endRef.current?.scrollIntoView({ block: 'end' });
  }, [messages.length, isTyping]);

  // The other side answers. A real conversation has a beat between turns, and
  // without one the reply lands before the sent bubble has finished arriving.
  useEffect(() => {
    if (!isTyping) return undefined;
    const id = window.setTimeout(() => {
      dispatch({ type: 'receive', chatId, body: REPLIES[chatId] ?? 'Got it 👍' });
    }, 1100);
    return () => window.clearTimeout(id);
  }, [isTyping, chatId, dispatch]);

  const send = (event: FormEvent) => {
    event.preventDefault();
    const body = draft.trim();
    if (!body) return;
    dispatch({ type: 'send', chatId, body });
    setDraft('');
  };

  return (
    <>
      <NavBar
        title={chat.name}
        subtitle={
          <>
            <Glyph name="lock" size={9} /> {chat.group ? `${chat.members} members · ` : ''}end-to-end
            encrypted
          </>
        }
        onBack={() => dispatch({ type: 'back' })}
        leading={<Avatar chat={chat} size="sm" />}
        trailing={
          <>
            <button
              type="button"
              className={styles.navButton}
              aria-label={`Start an encrypted voice call with ${chat.name}`}
              onClick={() => dispatch({ type: 'start-call', chatId, video: false })}
            >
              <Glyph name="call" size={17} />
            </button>
            <button
              type="button"
              className={styles.navButton}
              aria-label={`Start an encrypted video call with ${chat.name}`}
              onClick={() => dispatch({ type: 'start-call', chatId, video: true })}
            >
              <Glyph name="video" size={17} />
            </button>
          </>
        }
      />

      <div className={styles.thread}>
        <p className={styles.threadNotice}>
          <Glyph name="lock" size={10} />
          Messages and calls in this chat are end-to-end encrypted. Voiid cannot read them.
        </p>

        {messages.map((message) => {
          if (message.kind === 'system') {
            return (
              <p key={message.id} className={styles.systemLine}>
                {message.body}
              </p>
            );
          }
          if (message.kind === 'location') {
            return (
              <span key={message.id} className={`${styles.card} ${styles.mine}`}>
                <span className={styles.cardMap} aria-hidden="true">
                  <span className={styles.cardPin} />
                </span>
                <span className={styles.cardText}>
                  <strong>Live location</strong>
                  <small>{message.minutes} min · only this chat</small>
                </span>
              </span>
            );
          }
          if (message.kind === 'game') {
            return (
              <span key={message.id} className={`${styles.card} ${styles.mine}`}>
                <span className={styles.cardGame} aria-hidden="true">
                  <Glyph name="games" size={18} />
                </span>
                <span className={styles.cardText}>
                  <strong>{GAME_NAMES[message.game]}</strong>
                  <small>Invite sent to this chat</small>
                </span>
              </span>
            );
          }
          return (
            <span
              key={message.id}
              className={`${styles.bubble} ${message.from === 'me' ? styles.mine : styles.theirs}`}
            >
              {message.body}
              <em className={styles.meta}>
                {message.time}
                {message.from === 'me' ? (
                  <b className={state.readReceipts ? styles.read : undefined}>✓✓</b>
                ) : null}
              </em>
            </span>
          );
        })}

        {isTyping && state.typingIndicators ? (
          <span className={`${styles.bubble} ${styles.theirs} ${styles.typing}`} role="status">
            <i /><i /><i />
            <span className={styles.srOnly}>{chat.name} is typing</span>
          </span>
        ) : null}

        <div ref={endRef} />
      </div>

      <div className={styles.composerWrap}>
        {sheet === 'location' ? (
          <div className={styles.sheet} role="group" aria-label="Choose how long to share your location">
            <p>Share your live location for</p>
            <div className={styles.sheetRow}>
              {[15, 60, 480].map((minutes) => (
                <button
                  key={minutes}
                  type="button"
                  onClick={() => {
                    dispatch({ type: 'share-location', chatId, minutes });
                    setSheet('none');
                  }}
                >
                  {minutes === 480 ? '8 hours' : minutes === 60 ? '1 hour' : '15 min'}
                </button>
              ))}
            </div>
          </div>
        ) : null}

        {sheet === 'game' ? (
          <div className={styles.sheet} role="group" aria-label="Choose a game to invite this chat to">
            <p>Invite this chat to</p>
            <div className={styles.sheetRow}>
              {GAMES.map((game) => (
                <button
                  key={game.id}
                  type="button"
                  onClick={() => {
                    dispatch({ type: 'invite-game', chatId, game: game.id });
                    setSheet('none');
                  }}
                >
                  {game.name}
                </button>
              ))}
            </div>
          </div>
        ) : null}

        <div className={styles.chips}>
          <button
            type="button"
            aria-pressed={sheet === 'location'}
            onClick={() => setSheet(sheet === 'location' ? 'none' : 'location')}
          >
            <Glyph name="pin" size={13} /> Share location
          </button>
          <button
            type="button"
            aria-pressed={sheet === 'game'}
            onClick={() => setSheet(sheet === 'game' ? 'none' : 'game')}
          >
            <Glyph name="games" size={13} /> Start a game
          </button>
        </div>

        <form className={styles.composer} onSubmit={send}>
          <input
            value={draft}
            onChange={(event) => setDraft(event.target.value)}
            placeholder="Message"
            aria-label={`Message ${chat.name}`}
          />
          <button type="submit" aria-label="Send message" disabled={!draft.trim()}>
            <Glyph name="send" size={16} />
          </button>
        </form>
      </div>
    </>
  );
}

/* ---- A call --------------------------------------------------------------- */

function CallScreen({ state, dispatch, chatId, video }: Props & { chatId: string; video: boolean }) {
  const chat = chatById(chatId);
  const seconds = state.callSeconds ?? 0;

  useEffect(() => {
    const id = window.setInterval(() => dispatch({ type: 'tick-call' }), 1000);
    return () => window.clearInterval(id);
  }, [dispatch]);

  return (
    <div className={styles.call} data-video={video ? 'true' : undefined}>
      <Avatar chat={chat} size="lg" />
      <strong className={styles.callName}>{chat.name}</strong>
      <span className={styles.callClock} role="timer" aria-label={`Call duration ${seconds} seconds`}>
        {formatClock(seconds)}
      </span>
      <span className={styles.callLock}>
        <Glyph name="lock" size={12} /> End-to-end encrypted
      </span>

      {video ? (
        <span className={styles.selfView} aria-hidden="true">
          <Glyph name="user" size={20} />
        </span>
      ) : null}

      <p className={styles.callStatus} role="status">
        {state.muted ? 'Your microphone is muted.' : 'Microphone on.'}
        {state.speaker ? ' Speaker on.' : ''}
      </p>

      <div className={styles.callControls}>
        <button
          type="button"
          aria-pressed={state.muted}
          aria-label={state.muted ? 'Unmute your microphone' : 'Mute your microphone'}
          onClick={() => dispatch({ type: 'toggle-mute' })}
        >
          <Glyph name={state.muted ? 'mic-off' : 'mic'} size={19} />
        </button>
        <button
          type="button"
          aria-pressed={state.speaker}
          aria-label={state.speaker ? 'Turn the speaker off' : 'Turn the speaker on'}
          onClick={() => dispatch({ type: 'toggle-speaker' })}
        >
          <Glyph name="speaker" size={19} />
        </button>
        <button
          type="button"
          className={styles.hangUp}
          aria-label="End the call"
          onClick={() => dispatch({ type: 'end-call', chatId })}
        >
          <Glyph name="call" size={19} />
        </button>
      </div>
    </div>
  );
}

/* ---- Moments -------------------------------------------------------------- */

function MomentsScreen({ dispatch }: Props) {
  return (
    <>
      <NavBar title="Moments" subtitle="Shared with the people you pick" />
      <div className={styles.scroll}>
        <ul className={styles.momentGrid}>
          {MOMENTS.map((moment) => (
            <li key={moment.id}>
              <button
                type="button"
                className={styles.momentCard}
                style={{ '--from': moment.art[0], '--to': moment.art[1] } as React.CSSProperties}
                onClick={() => {
                  dispatch({ type: 'set-moment-step', step: 0 });
                  dispatch({ type: 'push', route: { screen: 'moment', momentId: moment.id } });
                }}
              >
                <span className={styles.momentTop}>
                  <Avatar chat={{ initial: moment.initial, tone: moment.tone, group: false }} size="sm" />
                  <span>
                    <strong>{moment.author}</strong>
                    <small>{moment.time}</small>
                  </span>
                </span>
                <span className={styles.momentCaption}>{moment.caption}</span>
                <span className={styles.momentAudience}>
                  <Glyph name="lock" size={11} /> {moment.audience}
                </span>
              </button>
            </li>
          ))}
        </ul>
      </div>
    </>
  );
}

function MomentScreen({ state, dispatch, momentId }: Props & { momentId: string }) {
  const moment = momentById(momentId);
  const step = state.momentStep;

  return (
    <div
      className={styles.moment}
      style={{ '--from': moment.art[0], '--to': moment.art[1] } as React.CSSProperties}
    >
      <div className={styles.momentBars} aria-hidden="true">
        {MOMENTS.map((_, barIndex) => (
          <span key={barIndex} data-state={barIndex < step ? 'done' : barIndex === step ? 'live' : 'todo'} />
        ))}
      </div>

      <div className={styles.momentHead}>
        <Avatar chat={{ initial: moment.initial, tone: moment.tone, group: false }} size="sm" />
        <span>
          <strong>{moment.author}</strong>
          <small>{moment.time}</small>
        </span>
        <button type="button" onClick={() => dispatch({ type: 'back' })} aria-label="Close this moment">
          <Glyph name="close" size={16} />
        </button>
      </div>

      <div className={styles.momentTaps}>
        <button
          type="button"
          aria-label="Previous moment"
          disabled={step === 0}
          onClick={() => dispatch({ type: 'set-moment-step', step: Math.max(0, step - 1) })}
        />
        <button
          type="button"
          aria-label="Next moment"
          onClick={() => {
            if (step >= MOMENTS.length - 1) dispatch({ type: 'back' });
            else dispatch({ type: 'set-moment-step', step: step + 1 });
          }}
        />
      </div>

      <div className={styles.momentFoot}>
        <p>{MOMENTS[step]?.caption ?? moment.caption}</p>
        <span>
          <Glyph name="lock" size={12} /> {MOMENTS[step]?.audience ?? moment.audience} · encrypted for
          them only
        </span>
        <small>
          Moment {step + 1} of {MOMENTS.length}
        </small>
      </div>
    </div>
  );
}

/* ---- Map ------------------------------------------------------------------ */

const DURATIONS: Array<{ minutes: 15 | 60 | 480; label: string }> = [
  { minutes: 15, label: '15 min' },
  { minutes: 60, label: '1 hour' },
  { minutes: 480, label: '8 hours' },
];

function MapScreen({ state, dispatch }: Props) {
  const [choice, setChoice] = useState<15 | 60 | 480>(60);
  const sharing = state.sharingMinutes !== null;

  return (
    <>
      <NavBar title="Map" subtitle="Nobody sees you until you say so" />
      <div className={styles.mapWrap}>
        <div className={styles.map} aria-hidden="true">
          <span className={styles.park} />
          <span className={styles.water} />
          <span className={`${styles.road} ${styles.roadA}`} />
          <span className={`${styles.road} ${styles.roadB}`} />
          <span className={`${styles.road} ${styles.roadC}`} />
          <span className={styles.friendPin} data-who="A">
            A
          </span>
          <span className={styles.friendPin} data-who="N">
            N
          </span>
          <span className={styles.you} data-sharing={sharing ? 'true' : undefined} />
        </div>

        <div className={styles.mapSheet}>
          <p className={styles.mapStatus} role="status">
            {sharing
              ? `Sharing your live location for ${state.sharingMinutes === 480 ? '8 hours' : state.sharingMinutes === 60 ? '1 hour' : '15 minutes'}. It stops on its own.`
              : 'Your location is private. Nothing is shared yet.'}
          </p>

          {!sharing ? (
            <div className={styles.segmented} role="group" aria-label="How long to share for">
              {DURATIONS.map((duration) => (
                <button
                  key={duration.minutes}
                  type="button"
                  aria-pressed={choice === duration.minutes}
                  onClick={() => setChoice(duration.minutes)}
                >
                  {duration.label}
                </button>
              ))}
            </div>
          ) : null}

          <button
            type="button"
            className={sharing ? styles.mapStop : styles.mapStart}
            onClick={() => dispatch({ type: 'set-sharing', minutes: sharing ? null : choice })}
          >
            {sharing ? 'Stop sharing' : 'Start sharing'}
          </button>
        </div>
      </div>
    </>
  );
}

/* ---- Clips ---------------------------------------------------------------- */

function ClipsScreen({ state, dispatch }: Props) {
  const clip = CLIPS[state.clipIndex];
  const liked = state.likedClips.includes(clip.id);

  return (
    <div
      className={styles.clip}
      style={{ '--from': clip.art[0], '--to': clip.art[1] } as React.CSSProperties}
    >
      <div className={styles.clipTop}>
        <span className={styles.publicChip}>
          <Glyph name="broadcast" size={12} /> Public
        </span>
      </div>

      <button
        type="button"
        className={styles.clipSurface}
        aria-label={state.clipPlaying ? 'Pause this clip' : 'Play this clip'}
        onClick={() => dispatch({ type: 'toggle-clip-playing' })}
      >
        <span className={styles.clipPlay} data-playing={state.clipPlaying ? 'true' : undefined}>
          <Glyph name={state.clipPlaying ? 'pause' : 'play'} size={22} filled={!state.clipPlaying} />
        </span>
      </button>

      <div className={styles.clipRail}>
        <button
          type="button"
          aria-pressed={liked}
          aria-label={liked ? `Unlike the clip by ${clip.handle}` : `Like the clip by ${clip.handle}`}
          onClick={() => dispatch({ type: 'toggle-clip-like', clipId: clip.id })}
          data-liked={liked ? 'true' : undefined}
        >
          <Glyph name="heart" size={20} filled={liked} />
          <small>{clip.likes + (liked ? 1 : 0)}</small>
        </button>
        <span className={styles.clipStat}>
          <Glyph name="comment" size={20} />
          <small>{clip.comments}</small>
        </span>
      </div>

      <div className={styles.clipFoot}>
        <strong>{clip.handle}</strong>
        <p>{clip.caption}</p>
        <span className={styles.clipNote}>
          Clips are public by design — captions, likes and comments are readable by Voiid.
        </span>
      </div>

      <div className={styles.clipNav}>
        <button
          type="button"
          aria-label="Previous clip"
          disabled={state.clipIndex === 0}
          onClick={() => dispatch({ type: 'set-clip', index: state.clipIndex - 1 })}
        >
          <Glyph name="chevron-left" size={16} style={{ transform: 'rotate(90deg)' }} />
        </button>
        <button
          type="button"
          aria-label="Next clip"
          disabled={state.clipIndex === CLIPS.length - 1}
          onClick={() => dispatch({ type: 'set-clip', index: state.clipIndex + 1 })}
        >
          <Glyph name="chevron-left" size={16} style={{ transform: 'rotate(-90deg)' }} />
        </button>
      </div>
    </div>
  );
}

/* ---- Games ---------------------------------------------------------------- */

function GamesScreen({ dispatch }: Props) {
  return (
    <>
      <NavBar title="Games" subtitle="Play without leaving the conversation" />
      <div className={styles.scroll}>
        <ul className={styles.gameGrid}>
          {GAMES.map((game) => (
            <li key={game.id}>
              <button
                type="button"
                className={styles.gameCard}
                style={{ '--from': game.art[0], '--to': game.art[1] } as React.CSSProperties}
                onClick={() => dispatch({ type: 'push', route: { screen: 'game', gameId: game.id } })}
              >
                <span className={styles.gameArt} aria-hidden="true">
                  <Glyph name="games" size={22} />
                </span>
                <strong>{game.name}</strong>
                <small>{game.blurb}</small>
                <em>{game.players} · playable here</em>
              </button>
            </li>
          ))}
        </ul>
        <p className={styles.gamesNote}>
          Moves and scores run through the server so both sides see the same match. That part is not
          end-to-end encrypted, and we say so here rather than in a footnote.
        </p>
      </div>
    </>
  );
}

function GameScreen({ state, dispatch, gameId }: Props & { gameId: GameId }) {
  const game = GAMES.find((entry) => entry.id === gameId) ?? GAMES[0];
  const record = () => dispatch({ type: 'record-game', game: gameId });

  return (
    <>
      <NavBar
        title={game.name}
        subtitle="Server-refereed · not end-to-end encrypted"
        onBack={() => dispatch({ type: 'back' })}
      />
      <div className={styles.scroll}>
        {gameId === 'tictactoe' ? <TicTacToeGame onScored={record} /> : null}
        {gameId === 'rps' ? <RpsGame onScored={record} /> : null}
        {gameId === 'cricket' ? <CricketGame onScored={record} /> : null}
        {gameId === 'snake' ? <SnakeGame onScored={record} /> : null}

        {state.playedGames.includes(gameId) ? (
          <p className={styles.gamesNote} role="status">
            Nice. In the app this round would post its result straight back into the chat.
          </p>
        ) : null}
      </div>
    </>
  );
}

/* ---- Profile and privacy -------------------------------------------------- */

function ProfileScreen({ state, dispatch }: Props) {
  return (
    <>
      <NavBar title="You" onBack={() => dispatch({ type: 'back' })} />
      <div className={styles.scroll}>
        <div className={styles.profileCard}>
          <Avatar chat={{ initial: 'Y', tone: 'teal', group: false }} size="lg" />
          <strong>Your name</strong>
          <small>@you · joined this tour a minute ago</small>
        </div>

        <ul className={styles.settingsList}>
          <li>
            <button
              type="button"
              role="switch"
              aria-checked={state.readReceipts}
              onClick={() => dispatch({ type: 'toggle-setting', setting: 'readReceipts' })}
            >
              <span>
                <strong>Read receipts</strong>
                <small>Turn them off and you stop seeing others&apos; too.</small>
              </span>
              <em className={styles.switch} data-on={state.readReceipts ? 'true' : undefined} />
            </button>
          </li>
          <li>
            <button
              type="button"
              role="switch"
              aria-checked={state.typingIndicators}
              onClick={() => dispatch({ type: 'toggle-setting', setting: 'typingIndicators' })}
            >
              <span>
                <strong>Typing indicators</strong>
                <small>Show the three dots while you write.</small>
              </span>
              <em className={styles.switch} data-on={state.typingIndicators ? 'true' : undefined} />
            </button>
          </li>
          <li>
            <button
              type="button"
              className={styles.settingsLink}
              onClick={() => dispatch({ type: 'push', route: { screen: 'privacy' } })}
            >
              <span>
                <strong>Privacy at a glance</strong>
                <small>What is encrypted, and what is not.</small>
              </span>
              <Glyph name="chevron-right" size={16} />
            </button>
          </li>
        </ul>
      </div>
    </>
  );
}

const ENCRYPTED = [
  'Messages, groups and chat attachments',
  'Voice and video calls, one-to-one and group',
  'Live location shares and dropped pins',
  'Moments shared with an audience you pick',
];

const SERVER_READABLE = [
  'Clips, captions, follows and comments',
  'Game moves, scores and match results',
  'Delivery and call metadata needed to run the service',
];

function PrivacyScreen({ dispatch }: Props) {
  return (
    <>
      <NavBar title="Privacy at a glance" onBack={() => dispatch({ type: 'back' })} />
      <div className={styles.scroll}>
        <section className={styles.ledger} data-kind="sealed">
          <h3>
            <Glyph name="lock" size={14} /> End-to-end encrypted
          </h3>
          <ul>
            {ENCRYPTED.map((item) => (
              <li key={item}>
                <Glyph name="check" size={13} />
                {item}
              </li>
            ))}
          </ul>
        </section>

        <section className={styles.ledger} data-kind="open">
          <h3>
            <Glyph name="broadcast" size={14} /> Server-readable by design
          </h3>
          <ul>
            {SERVER_READABLE.map((item) => (
              <li key={item}>
                <Glyph name="check" size={13} />
                {item}
              </li>
            ))}
          </ul>
        </section>

        <p className={styles.gamesNote}>
          A public feed and a refereed game cannot work without the server reading them. Drawing the
          line in the open is the point.
        </p>
      </div>
    </>
  );
}

/* ---- The renderer --------------------------------------------------------- */

export function Screen({ state, dispatch, route }: Props & { route: Route }) {
  switch (route.screen) {
    case 'chats':
      return <ChatsScreen state={state} dispatch={dispatch} />;
    case 'chat':
      return <ChatScreen state={state} dispatch={dispatch} chatId={route.chatId} />;
    case 'call':
      return <CallScreen state={state} dispatch={dispatch} chatId={route.chatId} video={route.video} />;
    case 'moments':
      return <MomentsScreen state={state} dispatch={dispatch} />;
    case 'moment':
      return <MomentScreen state={state} dispatch={dispatch} momentId={route.momentId} />;
    case 'map':
      return <MapScreen state={state} dispatch={dispatch} />;
    case 'clips':
      return <ClipsScreen state={state} dispatch={dispatch} />;
    case 'games':
      return <GamesScreen state={state} dispatch={dispatch} />;
    case 'game':
      return <GameScreen state={state} dispatch={dispatch} gameId={route.gameId} />;
    case 'profile':
      return <ProfileScreen state={state} dispatch={dispatch} />;
    case 'privacy':
      return <PrivacyScreen state={state} dispatch={dispatch} />;
  }
}

/**
 * Screens that own the whole display and hide the tab bar.
 *
 * Clips is deliberately NOT here even though it is full-bleed: it is a tab root,
 * and hiding the bar on a tab root strands the visitor on it with no way back —
 * which is exactly what happened the first time. It keeps the bar and gets a dark
 * treatment for it instead (see `isMedia`).
 */
export function isImmersive(route: Route): boolean {
  return route.screen === 'call' || route.screen === 'moment';
}

/** Full-bleed dark surfaces: light status bar, and a tab bar that can sit on media. */
export function isMedia(route: Route): boolean {
  return route.screen === 'clips' || isImmersive(route);
}

export const SCREEN_ICONS: Record<string, GlyphName> = {
  chats: 'chat',
  moments: 'sparkle',
  map: 'map',
  clips: 'clips',
  games: 'games',
};
