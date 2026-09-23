/**
 * The shape of the simulated app.
 *
 * The tour is a real application with a real navigation model, not a slideshow of
 * screens: it has tabs, each tab has its own back stack, and every screen reads
 * from the same store. That is the whole reason for this file — a `destination`
 * string cannot express "I opened Aditi's chat from Chats, started a call from
 * inside it, and Back should take me to the chat rather than to the chat list".
 */

export type TabId = 'chats' | 'moments' | 'map' | 'clips' | 'games';

export type Route =
  | { screen: 'chats' }
  | { screen: 'chat'; chatId: string }
  | { screen: 'call'; chatId: string; video: boolean }
  | { screen: 'moments' }
  | { screen: 'moment'; momentId: string }
  | { screen: 'map' }
  | { screen: 'clips' }
  | { screen: 'games' }
  | { screen: 'game'; gameId: GameId }
  | { screen: 'profile' }
  | { screen: 'privacy' };

/**
 * The catalogue, and only the catalogue.
 *
 * Exactly four games are seeded server-side (024_games.sql, 025, 026) and the
 * /games page says so in as many words. The tour listing a fifth would be this
 * site advertising something a visitor could not then find.
 */
export type GameId = 'tictactoe' | 'rps' | 'cricket' | 'snake';

export type MessageAuthor = 'me' | 'them';

export type Message =
  | { id: string; kind: 'text'; from: MessageAuthor; body: string; time: string }
  | { id: string; kind: 'location'; from: MessageAuthor; minutes: number; time: string }
  | { id: string; kind: 'game'; from: MessageAuthor; game: GameId; time: string }
  | { id: string; kind: 'system'; body: string; time: string };

export type Chat = {
  id: string;
  name: string;
  initial: string;
  /** Which of the avatar gradients this person gets. Fixed per person, never random. */
  tone: 'teal' | 'violet' | 'blue' | 'amber' | 'green';
  group: boolean;
  members?: number;
  presence: string;
  preview: string;
  time: string;
  unread: number;
};

export type Moment = {
  id: string;
  author: string;
  initial: string;
  tone: Chat['tone'];
  time: string;
  caption: string;
  audience: string;
  /** Two stops of a gradient standing in for the photograph. */
  art: [string, string];
};

export type Clip = {
  id: string;
  handle: string;
  caption: string;
  tag: string;
  likes: number;
  comments: number;
  art: [string, string];
};

/** Everything the tour remembers. One object, replaced wholesale by `reset`. */
export type SandboxState = {
  tab: TabId;
  /** One back stack per tab, newest last. The last entry is what is on screen. */
  stacks: Record<TabId, Route[]>;
  /** Which way the last navigation moved, so the screen can animate correctly. */
  direction: 'forward' | 'back' | 'none';
  messages: Record<string, Message[]>;
  /** Chats where the other side is composing a reply right now. */
  typing: string[];
  /** Seconds elapsed on the active call, or null when no call is up. */
  callSeconds: number | null;
  muted: boolean;
  speaker: boolean;
  sharingMinutes: 15 | 60 | 480 | null;
  clipIndex: number;
  clipPlaying: boolean;
  likedClips: string[];
  momentStep: number;
  readReceipts: boolean;
  typingIndicators: boolean;
  /** Which game the visitor has finished at least one round of. */
  playedGames: GameId[];
};

export type SandboxAction =
  | { type: 'select-tab'; tab: TabId }
  | { type: 'push'; route: Route }
  | { type: 'back' }
  | { type: 'send'; chatId: string; body: string }
  | { type: 'receive'; chatId: string; body: string }
  | { type: 'share-location'; chatId: string; minutes: number }
  | { type: 'invite-game'; chatId: string; game: GameId }
  | { type: 'start-call'; chatId: string; video: boolean }
  | { type: 'tick-call' }
  | { type: 'end-call'; chatId: string }
  | { type: 'toggle-mute' }
  | { type: 'toggle-speaker' }
  | { type: 'set-sharing'; minutes: 15 | 60 | 480 | null }
  | { type: 'set-clip'; index: number }
  | { type: 'toggle-clip-playing' }
  | { type: 'toggle-clip-like'; clipId: string }
  | { type: 'set-moment-step'; step: number }
  | { type: 'toggle-setting'; setting: 'readReceipts' | 'typingIndicators' }
  | { type: 'record-game'; game: GameId }
  | { type: 'reset' };
