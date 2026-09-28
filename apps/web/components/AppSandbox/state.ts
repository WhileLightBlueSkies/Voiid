import { INITIAL_MESSAGES } from './data';
import type { Route, SandboxAction, SandboxState, TabId } from './types';

/**
 * The tour's entire behaviour. Pure, synchronous, and separated from every screen
 * so that "does Back go where a person expects" is a question answerable by a
 * unit test rather than by clicking around.
 */

const ROOTS: Record<TabId, Route> = {
  chats: { screen: 'chats' },
  moments: { screen: 'moments' },
  map: { screen: 'map' },
  clips: { screen: 'clips' },
  games: { screen: 'games' },
};

export const initialSandboxState: SandboxState = {
  tab: 'chats',
  stacks: {
    chats: [ROOTS.chats],
    moments: [ROOTS.moments],
    map: [ROOTS.map],
    clips: [ROOTS.clips],
    games: [ROOTS.games],
  },
  direction: 'none',
  messages: INITIAL_MESSAGES,
  typing: [],
  callSeconds: null,
  muted: false,
  speaker: false,
  sharingMinutes: null,
  clipIndex: 0,
  clipPlaying: false,
  likedClips: [],
  momentStep: 0,
  readReceipts: true,
  typingIndicators: true,
  playedGames: [],
};

/** The route currently on screen. */
export function currentRoute(state: SandboxState): Route {
  const stack = state.stacks[state.tab];
  return stack[stack.length - 1];
}

/** True when the current screen was pushed onto something and Back means something. */
export function canGoBack(state: SandboxState): boolean {
  return state.stacks[state.tab].length > 1;
}

function withStack(state: SandboxState, tab: TabId, stack: Route[]): SandboxState {
  return { ...state, stacks: { ...state.stacks, [tab]: stack } };
}

function appendMessage(
  state: SandboxState,
  chatId: string,
  message: SandboxState['messages'][string][number],
): SandboxState {
  return {
    ...state,
    messages: { ...state.messages, [chatId]: [...(state.messages[chatId] ?? []), message] },
  };
}

let sequence = 0;
/** Ids only need to be unique within a session, and must not depend on a clock. */
function nextId(prefix: string) {
  sequence += 1;
  return `${prefix}-${sequence}`;
}

function formatClock(seconds: number) {
  const m = Math.floor(seconds / 60);
  const s = seconds % 60;
  return `${m}:${s.toString().padStart(2, '0')}`;
}

export function sandboxReducer(state: SandboxState, action: SandboxAction): SandboxState {
  switch (action.type) {
    case 'select-tab': {
      // Tapping the tab you are already on pops that tab back to its root, which
      // is what every iOS tab bar does and what a visitor who has wandered three
      // screens deep is reaching for.
      if (action.tab === state.tab) {
        return withStack({ ...state, direction: 'back' }, action.tab, [ROOTS[action.tab]]);
      }
      return { ...state, tab: action.tab, direction: 'none' };
    }

    case 'push':
      return withStack({ ...state, direction: 'forward' }, state.tab, [
        ...state.stacks[state.tab],
        action.route,
      ]);

    case 'back': {
      const stack = state.stacks[state.tab];
      if (stack.length <= 1) return state;
      return withStack({ ...state, direction: 'back' }, state.tab, stack.slice(0, -1));
    }

    case 'send':
      return appendMessage({ ...state, typing: [...state.typing, action.chatId] }, action.chatId, {
        id: nextId('msg'),
        kind: 'text',
        from: 'me',
        body: action.body,
        time: '9:41',
      });

    case 'receive':
      return appendMessage(
        { ...state, typing: state.typing.filter((id) => id !== action.chatId) },
        action.chatId,
        { id: nextId('msg'), kind: 'text', from: 'them', body: action.body, time: '9:41' },
      );

    case 'share-location':
      return appendMessage(state, action.chatId, {
        id: nextId('loc'),
        kind: 'location',
        from: 'me',
        minutes: action.minutes,
        time: '9:41',
      });

    case 'invite-game':
      return appendMessage(state, action.chatId, {
        id: nextId('game'),
        kind: 'game',
        from: 'me',
        game: action.game,
        time: '9:41',
      });

    case 'start-call':
      return withStack({ ...state, callSeconds: 0, direction: 'forward' }, state.tab, [
        ...state.stacks[state.tab],
        { screen: 'call', chatId: action.chatId, video: action.video },
      ]);

    case 'tick-call':
      return state.callSeconds === null ? state : { ...state, callSeconds: state.callSeconds + 1 };

    case 'end-call': {
      const seconds = state.callSeconds ?? 0;
      const ended = appendMessage(state, action.chatId, {
        id: nextId('sys'),
        kind: 'system',
        body: `Encrypted call ended · ${formatClock(seconds)}`,
        time: '9:41',
      });
      const stack = ended.stacks[ended.tab];
      return withStack(
        { ...ended, callSeconds: null, muted: false, speaker: false, direction: 'back' },
        ended.tab,
        stack.length > 1 ? stack.slice(0, -1) : stack,
      );
    }

    case 'toggle-mute':
      return { ...state, muted: !state.muted };

    case 'toggle-speaker':
      return { ...state, speaker: !state.speaker };

    case 'set-sharing':
      return { ...state, sharingMinutes: action.minutes };

    case 'set-clip':
      return { ...state, clipIndex: action.index, clipPlaying: false };

    case 'toggle-clip-playing':
      return { ...state, clipPlaying: !state.clipPlaying };

    case 'toggle-clip-like':
      return {
        ...state,
        likedClips: state.likedClips.includes(action.clipId)
          ? state.likedClips.filter((id) => id !== action.clipId)
          : [...state.likedClips, action.clipId],
      };

    case 'set-moment-step':
      return { ...state, momentStep: action.step };

    case 'toggle-setting':
      return { ...state, [action.setting]: !state[action.setting] };

    case 'record-game':
      return state.playedGames.includes(action.game)
        ? state
        : { ...state, playedGames: [...state.playedGames, action.game] };

    case 'reset':
      return initialSandboxState;
  }
}

export { formatClock };
