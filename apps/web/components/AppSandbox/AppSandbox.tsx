'use client';

import { useEffect, useReducer, useRef } from 'react';
import { createPortal } from 'react-dom';
import { Glyph } from '../Glyph';
import { PhoneFrame } from '../PhoneFrame';
import { GAME_NAMES, TABS, chatById } from './data';
import { Screen, isImmersive, isMedia } from './screens';
import { canGoBack, currentRoute, initialSandboxState, sandboxReducer } from './state';
import type { Route, SandboxState, TabId } from './types';
import styles from './AppSandbox.module.css';
import app from './app.module.css';

/**
 * The full-screen tour.
 *
 * It is a shell around a phone, and the phone runs the app: the tabs, the back
 * stack and every control live inside the screen, exactly where a visitor's hands
 * expect them. The panel on the left is a guide, not the navigation — remove it
 * and the app still works, which is the test that it is an app and not a
 * slideshow with a menu bolted to the side.
 */

/** What the guide panel says about wherever the visitor currently is. */
const GUIDE: Record<
  Route['screen'],
  { title: string; body: string; tries: Array<{ label: string; to: Route; tab?: TabId }> }
> = {
  chats: {
    title: 'Your conversations',
    body: 'Chats, groups and everything in them are end-to-end encrypted. Open one and it behaves the way it does on a phone.',
    tries: [{ label: 'Open Aditi’s chat', to: { screen: 'chat', chatId: 'aditi' }, tab: 'chats' }],
  },
  chat: {
    title: 'Inside a chat',
    body: 'Type and send — the other side answers. Share a live location or start a game without leaving the thread, and call from the header.',
    tries: [
      { label: 'Call Aditi', to: { screen: 'call', chatId: 'aditi', video: false }, tab: 'chats' },
      { label: 'Back to all chats', to: { screen: 'chats' }, tab: 'chats' },
    ],
  },
  call: {
    title: 'An encrypted call',
    body: 'Voice and video are sealed between the devices on the call. Mute and speaker work; hanging up drops a note back into the chat.',
    tries: [{ label: 'Go to the map', to: { screen: 'map' }, tab: 'map' }],
  },
  moments: {
    title: 'Moments',
    body: 'Posts for an audience you choose, encrypted for exactly those people. Open one and tap through.',
    tries: [{ label: 'Open a moment', to: { screen: 'moment', momentId: 'terrace' }, tab: 'moments' }],
  },
  moment: {
    title: 'Viewing a moment',
    body: 'Tap the right half to move forward, the left to go back. The audience line is not decoration — it is who holds the keys.',
    tries: [{ label: 'Back to Moments', to: { screen: 'moments' }, tab: 'moments' }],
  },
  map: {
    title: 'The map',
    body: 'Nothing is shared until you start it, every share has an end time, and it stops on its own.',
    tries: [{ label: 'Open Clips', to: { screen: 'clips' }, tab: 'clips' }],
  },
  clips: {
    title: 'Clips',
    body: 'The public half of Voiid. Play, like, move between clips — and read the line that says plainly this surface is not private.',
    tries: [{ label: 'Play a game instead', to: { screen: 'games' }, tab: 'games' }],
  },
  games: {
    title: 'Games',
    body: 'All four games are really playable right here. Games are refereed by the server, which is why they are not end-to-end encrypted.',
    tries: [
      { label: 'Play Snake', to: { screen: 'game', gameId: 'snake' }, tab: 'games' },
      { label: 'Play Tic Tac Toe', to: { screen: 'game', gameId: 'tictactoe' }, tab: 'games' },
    ],
  },
  game: {
    title: 'Playing',
    body: 'Play it through to a result. Snake takes the arrow keys, the on-screen pad or a swipe; the rest are taps. In the app the result posts back into the chat.',
    tries: [{ label: 'See what is private', to: { screen: 'privacy' }, tab: 'chats' }],
  },
  profile: {
    title: 'Your settings',
    body: 'The privacy switches are real: turn read receipts off and the ticks in your chats stop filling in.',
    tries: [{ label: 'Show the privacy ledger', to: { screen: 'privacy' }, tab: 'chats' }],
  },
  privacy: {
    title: 'The boundary',
    body: 'Two lists, no small print. Encrypted on the left of the line, server-readable on the right, and nothing pretending to be the other.',
    tries: [{ label: 'Back to chats', to: { screen: 'chats' }, tab: 'chats' }],
  },
};

function routeKey(route: Route): string {
  return Object.values(route).join(':');
}

export function AppSandbox({ onClose }: { onClose: () => void }) {
  const [state, dispatch] = useReducer(sandboxReducer, initialSandboxState);
  const dialogRef = useRef<HTMLDivElement>(null);
  const closeRef = useRef<HTMLButtonElement>(null);

  const route = currentRoute(state);
  const immersive = isImmersive(route);
  const media = isMedia(route);
  // A pushed screen owns the whole display, the way a conversation or a game does
  // on a phone. Leaving the bar up under a chat thread is the tell that you are
  // looking at a web layout wearing a phone costume.
  const showTabs = !immersive && !canGoBack(state);
  const guide = GUIDE[route.screen];

  useEffect(() => {
    const body = document.body;
    const previousOverflow = body.style.overflow;
    body.dataset.sandboxOpen = 'true';
    body.style.overflow = 'hidden';
    closeRef.current?.focus();

    const onKeyDown = (event: KeyboardEvent) => {
      if (event.key === 'Escape') {
        event.preventDefault();
        onClose();
        return;
      }
      if (event.key !== 'Tab' || !dialogRef.current) return;
      const focusable = Array.from(
        dialogRef.current.querySelectorAll<HTMLElement>(
          'button:not([disabled]), a[href], input, [tabindex]:not([tabindex="-1"])',
        ),
      ).filter((node) => node.offsetParent !== null || node === document.activeElement);
      if (focusable.length === 0) return;
      const first = focusable[0];
      const last = focusable[focusable.length - 1];
      if (event.shiftKey && document.activeElement === first) {
        event.preventDefault();
        last.focus();
      } else if (!event.shiftKey && document.activeElement === last) {
        event.preventDefault();
        first.focus();
      }
    };

    document.addEventListener('keydown', onKeyDown);
    return () => {
      document.removeEventListener('keydown', onKeyDown);
      delete body.dataset.sandboxOpen;
      body.style.overflow = previousOverflow;
    };
  }, [onClose]);

  const jump = (to: Route, tab?: TabId) => {
    if (tab && tab !== state.tab) dispatch({ type: 'select-tab', tab });
    if (to.screen === 'call') {
      dispatch({ type: 'start-call', chatId: to.chatId, video: to.video });
      return;
    }
    const isRoot = TABS.some((entry) => entry.id === to.screen);
    if (isRoot) dispatch({ type: 'select-tab', tab: to.screen as TabId });
    else dispatch({ type: 'push', route: to });
  };

  return createPortal(
    <div className={styles.overlay}>
      <div
        ref={dialogRef}
        className={styles.dialog}
        role="dialog"
        aria-modal="true"
        aria-labelledby="sandbox-title"
      >
        <header className={styles.topbar}>
          <button
            ref={closeRef}
            type="button"
            className={styles.close}
            onClick={onClose}
            aria-label="Close app tour"
          >
            <Glyph name="close" size={18} />
          </button>

          <span className={styles.brand}>
            <span className={styles.wordmark}>voiid</span>
            <span id="sandbox-title">Explore Voiid</span>
          </span>

          <button
            type="button"
            className={styles.reset}
            onClick={() => dispatch({ type: 'reset' })}
          >
            <Glyph name="refresh" size={15} />
            <span>Reset tour</span>
          </button>
        </header>

        <div className={styles.workspace}>
          <aside className={styles.guide} aria-label="About this screen">
            <p className={styles.guideEyebrow}>Interactive preview</p>
            <h2 className={styles.guideTitle}>{guide.title}</h2>
            <p className={styles.guideBody}>{guide.body}</p>

            <p className={styles.guideLabel}>Try this</p>
            <div className={styles.guideTries}>
              {guide.tries.map((attempt) => (
                <button
                  key={attempt.label}
                  type="button"
                  onClick={() => jump(attempt.to, attempt.tab)}
                >
                  {attempt.label}
                  <Glyph name="arrow-right" size={14} />
                </button>
              ))}
            </div>

            <p className={styles.guideFoot}>
              <Glyph name="shield" size={14} />
              Nothing here leaves your browser. No account, no network, no data kept.
            </p>
          </aside>

          <main className={styles.stage}>
            <PhoneFrame
              className={styles.device}
              width="var(--tour-phone-w)"
              time="9:41"
              chrome={media ? 'light' : 'auto'}
              screenClassName={app.screen}
            >
              <div
                className={app.app}
                data-media={media ? 'true' : undefined}
                data-tabs={showTabs ? 'true' : undefined}
              >
                <div
                  key={routeKey(route)}
                  className={app.page}
                  data-direction={state.direction}
                >
                  <Screen state={state} dispatch={dispatch} route={route} />
                </div>

                {showTabs ? (
                  <nav className={app.tabBar} aria-label="App tabs">
                    {TABS.map((tab) => (
                      <button
                        key={tab.id}
                        type="button"
                        onClick={() => dispatch({ type: 'select-tab', tab: tab.id })}
                        aria-current={state.tab === tab.id ? 'page' : undefined}
                      >
                        <Glyph name={tab.icon} size={19} />
                        <small>{tab.label}</small>
                      </button>
                    ))}
                  </nav>
                ) : null}
              </div>
            </PhoneFrame>

            <p className={styles.stageHint} role="status">
              {describe(state, route)}
            </p>
          </main>
        </div>
      </div>
    </div>,
    document.body,
  );
}

/** One plain sentence naming where the visitor is, for screen readers and for anyone who looks down. */
function describe(state: SandboxState, route: Route): string {
  switch (route.screen) {
    case 'chat':
      return `Chat with ${chatById(route.chatId).name}`;
    case 'call':
      return `${route.video ? 'Video' : 'Voice'} call with ${chatById(route.chatId).name}`;
    case 'game':
      return `Playing ${GAME_NAMES[route.gameId]}`;
    default:
      return canGoBack(state)
        ? `${GUIDE[route.screen].title} — use Back inside the app to return`
        : GUIDE[route.screen].title;
  }
}
