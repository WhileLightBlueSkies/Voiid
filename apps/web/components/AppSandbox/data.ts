import type { Chat, Clip, GameId, Message, Moment, TabId } from './types';

/**
 * The content the tour is furnished with.
 *
 * All of it is invented and all of it is honest: nothing here shows a capability
 * the shipping app does not have, and nothing claims encryption for a surface
 * that is public. Clips are captioned as public because they are public.
 */

export const TABS: Array<{ id: TabId; label: string; icon: 'chat' | 'sparkle' | 'map' | 'clips' | 'games' }> = [
  { id: 'chats', label: 'Chats', icon: 'chat' },
  { id: 'moments', label: 'Moments', icon: 'sparkle' },
  { id: 'map', label: 'Map', icon: 'map' },
  { id: 'clips', label: 'Clips', icon: 'clips' },
  { id: 'games', label: 'Games', icon: 'games' },
];

export const CHATS: Chat[] = [
  {
    id: 'aditi',
    name: 'Aditi',
    initial: 'A',
    tone: 'violet',
    group: false,
    presence: 'Online',
    preview: 'Made it. Share your location?',
    time: '9:38',
    unread: 2,
  },
  {
    id: 'weekend',
    name: 'Weekend Warriors',
    initial: 'W',
    tone: 'teal',
    group: true,
    members: 6,
    presence: '6 members',
    preview: 'Rohan: who is bringing the speaker',
    time: '9:12',
    unread: 5,
  },
  {
    id: 'nehal',
    name: 'Nehal',
    initial: 'N',
    tone: 'blue',
    group: false,
    presence: 'Last seen 8:40',
    preview: 'Call me when you land',
    time: '8:41',
    unread: 0,
  },
  {
    id: 'amma',
    name: 'Amma',
    initial: 'A',
    tone: 'amber',
    group: false,
    presence: 'Online',
    preview: 'Photo',
    time: 'Yesterday',
    unread: 0,
  },
  {
    id: 'rohan',
    name: 'Rohan',
    initial: 'R',
    tone: 'violet',
    group: false,
    presence: 'Last seen yesterday',
    preview: 'One more over?',
    time: 'Yesterday',
    unread: 0,
  },
  {
    id: 'flat',
    name: 'Flat 402',
    initial: 'F',
    tone: 'blue',
    group: true,
    members: 3,
    presence: '3 members',
    preview: 'Meera: water tank is fixed',
    time: 'Monday',
    unread: 0,
  },
  {
    id: 'design',
    name: 'Design Squad',
    initial: 'D',
    tone: 'green',
    group: true,
    members: 4,
    presence: '4 members',
    preview: 'You: shipping the new frame today',
    time: 'Yesterday',
    unread: 0,
  },
];

export const INITIAL_MESSAGES: Record<string, Message[]> = {
  aditi: [
    { id: 'a1', kind: 'text', from: 'them', body: 'Reached the station 😄', time: '9:31' },
    { id: 'a2', kind: 'text', from: 'me', body: 'Ten minutes away', time: '9:33' },
    { id: 'a3', kind: 'text', from: 'them', body: 'Made it. Share your location?', time: '9:38' },
  ],
  weekend: [
    { id: 'w1', kind: 'text', from: 'them', body: 'Trek on Sunday then?', time: '9:02' },
    { id: 'w2', kind: 'text', from: 'me', body: 'In. Leaving at six.', time: '9:07' },
    { id: 'w3', kind: 'text', from: 'them', body: 'Rohan: who is bringing the speaker', time: '9:12' },
  ],
  nehal: [
    { id: 'n1', kind: 'text', from: 'them', body: 'Call me when you land', time: '8:41' },
  ],
  amma: [
    { id: 'm1', kind: 'text', from: 'them', body: 'Did you eat?', time: 'Yesterday' },
    { id: 'm2', kind: 'text', from: 'me', body: 'Yes amma 🙂', time: 'Yesterday' },
  ],
  rohan: [
    { id: 'r1', kind: 'text', from: 'them', body: 'One more over?', time: 'Yesterday' },
  ],
  flat: [
    { id: 'f1', kind: 'text', from: 'them', body: 'Meera: water tank is fixed', time: 'Monday' },
  ],
  design: [
    { id: 'd1', kind: 'text', from: 'me', body: 'shipping the new frame today', time: 'Yesterday' },
  ],
};

/**
 * What each person says back when you message them. Deterministic — the same
 * chat always answers the same way, because a demo that improvises is a demo
 * that cannot be written down in a test.
 */
export const REPLIES: Record<string, string> = {
  aditi: 'Got it — see you at the gate 👋',
  weekend: 'Rohan: perfect, bringing it',
  nehal: 'Ha, calling you now',
  amma: 'Good. Call in the evening.',
  design: 'Priya: the corners finally look right',
  rohan: 'Always. Pick your number.',
  flat: 'Meera: thanks for sorting it',
};

export const MOMENTS: Moment[] = [
  {
    id: 'terrace',
    author: 'Aditi',
    initial: 'A',
    tone: 'violet',
    time: '18:42',
    caption: 'Terrace evening, the good kind',
    audience: 'Shared with 4 people',
    art: ['#f0a86b', '#8d4fa8'],
  },
  {
    id: 'trek',
    author: 'Weekend Warriors',
    initial: 'W',
    tone: 'teal',
    time: '07:15',
    caption: 'Six in the morning was worth it',
    audience: 'Shared with the group',
    art: ['#3f9c8e', '#16414a'],
  },
  {
    id: 'filter',
    author: 'You',
    initial: 'Y',
    tone: 'blue',
    time: 'Yesterday',
    caption: 'Filter coffee and nothing else',
    audience: 'Shared with 2 people',
    art: ['#c4753d', '#3a2418'],
  },
];

export const CLIPS: Clip[] = [
  {
    id: 'c1',
    handle: '@maya',
    caption: 'One pan, eleven minutes, zero drama.',
    tag: 'Food',
    likes: 2418,
    comments: 96,
    art: ['#b4633a', '#1d1310'],
  },
  {
    id: 'c2',
    handle: '@thecityruns',
    caption: 'Marine Drive at 5:40am hits different.',
    tag: 'Running',
    likes: 5104,
    comments: 212,
    art: ['#2f6fa8', '#0d1b2a'],
  },
  {
    id: 'c3',
    handle: '@studiofern',
    caption: 'Every plant in this flat has a name.',
    tag: 'Home',
    likes: 1887,
    comments: 64,
    art: ['#4e8a4a', '#12210f'],
  },
];

export const GAMES: Array<{
  id: GameId;
  name: string;
  blurb: string;
  players: string;
  art: [string, string];
}> = [
  {
    id: 'tictactoe',
    name: 'Tic Tac Toe',
    blurb: 'Settled in a minute. Usually.',
    players: '2 players',
    art: ['#13828c', '#0b3b40'],
  },
  {
    id: 'rps',
    name: 'Rock Paper Scissors',
    blurb: 'Both move at once — which is the whole reason a referee exists.',
    players: '2 players',
    art: ['#6b21a8', '#2a1040'],
  },
  {
    id: 'cricket',
    name: 'Hand Cricket',
    blurb: 'Pick a number. Do not pick theirs.',
    players: '2 players',
    art: ['#8a5400', '#33200a'],
  },
  {
    id: 'snake',
    name: 'Snake',
    blurb: 'One tap to start, one wall to regret.',
    players: '1–2 players',
    art: ['#1e40af', '#0d1b3f'],
  },
];

export const GAME_NAMES: Record<GameId, string> = {
  tictactoe: 'Tic Tac Toe',
  rps: 'Rock Paper Scissors',
  cricket: 'Hand Cricket',
  snake: 'Snake',
};

export function chatById(id: string): Chat {
  return CHATS.find((chat) => chat.id === id) ?? CHATS[0];
}

export function momentById(id: string): Moment {
  return MOMENTS.find((moment) => moment.id === id) ?? MOMENTS[0];
}
