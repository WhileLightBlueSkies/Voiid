/**
 * The clickable phone's screen map.
 *
 * Every screen is a real screenshot of the Voiid iOS design build (the Voiid-Ui
 * project), captured on an iPhone 17 Pro simulator at 1206×2622 and served at half
 * size from /public/app. Nothing here is drawn — the phone is a click-through
 * prototype laid over those images.
 *
 * HOTSPOT COORDINATES ARE IN "PREVIEW PIXELS": the screenshot scaled to 368×800.
 * That is the size the captures were measured at, so a rect can be checked by
 * opening the image at that size and reading the numbers off. `rect()` converts
 * them to percentages, which is what the phone lays out with, so they hold at any
 * rendered size.
 */

export type TabId = 'ai' | 'calls' | 'chats' | 'moments' | 'communities' | 'map' | 'games' | 'clips';

export type ScreenId =
  | 'chats'
  | 'groups'
  | 'calls'
  | 'convo'
  | 'call'
  | 'video_call'
  | 'group_convo'
  | 'group_call'
  | 'group_video'
  | 'moments'
  | 'communities'
  | 'community_detail'
  | 'map_intro'
  | 'map_privacy'
  | 'map'
  | 'ai'
  | 'ai_chat'
  | 'games'
  | 'carrom_setup'
  | 'carrom'
  | 'ludo_setup'
  | 'ludo'
  | 'clips'
  | 'clip_player';

/** How a screen arrives. `pop` plays the entry transition backwards. */
export type Transition = 'push' | 'fade' | 'sheet' | 'zoom';

export type Action =
  | { kind: 'go'; to: ScreenId; via: Transition; replace?: boolean }
  | { kind: 'back' }
  | { kind: 'root'; tab: TabId }
  | { kind: 'unlockMap'; to: ScreenId }
  | { kind: 'toast'; text: string }
  | { kind: 'like' };

export type Rect = { left: number; top: number; width: number; height: number };

export type Hotspot = { rect: Rect; label: string; action: Action };

export type ChatConfig = {
  /** Where the message list starts and the composer begins, in preview px. */
  top: number;
  bottom: number;
  from: string;
  replies: string[];
};

export type Screen = {
  id: ScreenId;
  title: string;
  /** Which tab the bar highlights; absent means the bar is hidden. */
  tab?: TabId;
  hotspots: Hotspot[];
  chat?: ChatConfig;
  /** The top of a sheet, for screens that slide up over a dimmed parent. */
  sheetTop?: number;
  dark?: boolean;
};

const W = 368;
const H = 800;

export function rect(x1: number, y1: number, x2: number, y2: number): Rect {
  return {
    left: (x1 / W) * 100,
    top: (y1 / H) * 100,
    width: ((x2 - x1) / W) * 100,
    height: ((y2 - y1) / H) * 100,
  };
}

export const pct = (y: number) => (y / H) * 100;

const go = (to: ScreenId, via: Transition, replace = false): Action => ({ kind: 'go', to, via, replace });
const back: Action = { kind: 'back' };

export const TABS: { id: TabId; label: string }[] = [
  { id: 'ai', label: 'AI' },
  { id: 'calls', label: 'Calls' },
  { id: 'chats', label: 'Chats' },
  { id: 'moments', label: 'Moments' },
  { id: 'communities', label: 'Communities' },
  { id: 'map', label: 'Map' },
  { id: 'games', label: 'Games' },
  { id: 'clips', label: 'Clips' },
];

export const SCREENS: Record<ScreenId, Screen> = {
  chats: {
    id: 'chats',
    title: 'Chats',
    tab: 'chats',
    hotspots: [
      { rect: rect(135, 211, 232, 308), label: 'Open chat with Ananya Sharma', action: go('convo', 'push') },
      { rect: rect(135, 325, 232, 422), label: 'Open Voiid AI', action: go('ai_chat', 'push') },
      { rect: rect(184, 150, 368, 192), label: 'Show groups', action: go('groups', 'fade', true) },
    ],
  },
  groups: {
    id: 'groups',
    title: 'Groups',
    tab: 'chats',
    hotspots: [
      { rect: rect(22, 211, 119, 308), label: 'Open Weekend Warriors group', action: go('group_convo', 'push') },
      { rect: rect(0, 150, 184, 192), label: 'Show chats', action: go('chats', 'fade', true) },
    ],
  },
  calls: {
    id: 'calls',
    title: 'Calls',
    tab: 'calls',
    hotspots: [
      { rect: rect(15, 200, 313, 250), label: 'Call Ananya Sharma back', action: go('call', 'zoom') },
      { rect: rect(15, 652, 313, 702), label: 'Rejoin Weekend Warriors call', action: go('group_call', 'zoom') },
    ],
  },
  convo: {
    id: 'convo',
    title: 'Chat with Ananya',
    hotspots: [
      { rect: rect(14, 57, 56, 98), label: 'Back to chats', action: back },
      { rect: rect(266, 60, 306, 96), label: 'Voice call', action: go('call', 'zoom') },
      { rect: rect(313, 60, 353, 96), label: 'Video call', action: go('video_call', 'zoom') },
    ],
    chat: {
      top: 132,
      bottom: 708,
      from: 'Ananya',
      replies: ['Haha yes 😄 see you at 1!', 'Perfect, the rooftop it is ☀️', 'Sending you the pin again 📍'],
    },
  },
  group_convo: {
    id: 'group_convo',
    title: 'Weekend Warriors',
    hotspots: [
      { rect: rect(14, 57, 56, 98), label: 'Back to groups', action: back },
      { rect: rect(266, 60, 306, 96), label: 'Start a group voice call', action: go('group_call', 'zoom') },
      { rect: rect(313, 60, 353, 96), label: 'Start a group video call', action: go('group_video', 'zoom') },
      { rect: rect(98, 232, 270, 260), label: 'Encryption details', action: { kind: 'toast', text: 'Sealed on your phone. Opened only on theirs.' } },
    ],
    chat: {
      top: 128,
      bottom: 708,
      from: 'Riya',
      replies: ['Love it 🙌 bringing the frisbee', 'Booked the court for 5 🏸', "Arjun's driving, obviously 🚗"],
    },
  },
  call: {
    id: 'call',
    title: 'Voice call with Ananya',
    dark: true,
    hotspots: [
      { rect: rect(14, 62, 52, 100), label: 'Back to the chat', action: back },
      { rect: rect(154, 692, 214, 752), label: 'End call', action: back },
    ],
  },
  video_call: {
    id: 'video_call',
    title: 'Video call with Ananya',
    dark: true,
    hotspots: [
      { rect: rect(14, 62, 52, 100), label: 'Back to the chat', action: back },
      { rect: rect(116, 697, 252, 754), label: 'End call', action: back },
    ],
  },
  group_call: {
    id: 'group_call',
    title: 'Group voice call',
    hotspots: [
      { rect: rect(15, 64, 49, 98), label: 'Back to the chat', action: back },
      { rect: rect(157, 686, 211, 744), label: 'Leave call', action: back },
    ],
  },
  group_video: {
    id: 'group_video',
    title: 'Group video call',
    dark: true,
    hotspots: [
      { rect: rect(15, 44, 53, 82), label: 'Back to the chat', action: back },
      { rect: rect(155, 720, 213, 779), label: 'End call', action: back },
    ],
  },
  moments: {
    id: 'moments',
    title: 'Moments',
    tab: 'moments',
    hotspots: [
      {
        rect: rect(15, 355, 360, 530),
        label: 'Recent moments',
        action: { kind: 'toast', text: 'Moments are end-to-end encrypted to who you pick' },
      },
    ],
  },
  communities: {
    id: 'communities',
    title: 'Communities',
    tab: 'communities',
    hotspots: [
      { rect: rect(15, 267, 353, 405), label: 'Open Voiid Designers', action: go('community_detail', 'push') },
    ],
  },
  community_detail: {
    id: 'community_detail',
    title: 'Voiid Designers',
    tab: 'communities',
    hotspots: [{ rect: rect(13, 51, 49, 87), label: 'Back to communities', action: back }],
  },
  map_intro: {
    id: 'map_intro',
    title: 'Find friends on the map',
    tab: 'map',
    hotspots: [
      { rect: rect(15, 647, 354, 695), label: 'Continue', action: go('map_privacy', 'push') },
      { rect: rect(312, 55, 360, 90), label: 'Skip', action: { kind: 'unlockMap', to: 'map' } },
    ],
  },
  map_privacy: {
    id: 'map_privacy',
    title: 'Your location, your choice',
    hotspots: [
      { rect: rect(4, 60, 44, 98), label: 'Back', action: back },
      { rect: rect(15, 646, 354, 694), label: 'Allow location access', action: { kind: 'unlockMap', to: 'map' } },
      { rect: rect(140, 696, 228, 724), label: 'Not now', action: { kind: 'unlockMap', to: 'map' } },
    ],
  },
  map: {
    id: 'map',
    title: 'Map',
    tab: 'map',
    hotspots: [
      { rect: rect(36, 250, 88, 310), label: 'Ava Johnson', action: { kind: 'toast', text: 'Ava is sharing for 1 more hour' } },
      { rect: rect(294, 280, 346, 340), label: 'Noah Patel', action: { kind: 'toast', text: 'Noah is sharing until he turns it off' } },
      { rect: rect(162, 378, 206, 440), label: 'You', action: { kind: 'toast', text: 'Visible to All Friends · 1 hour' } },
    ],
  },
  ai: {
    id: 'ai',
    title: 'Voiid AI',
    tab: 'ai',
    hotspots: [
      { rect: rect(15, 176, 354, 244), label: 'Catch me up', action: go('ai_chat', 'push') },
      { rect: rect(15, 253, 354, 321), label: 'Draft a reply', action: go('ai_chat', 'push') },
    ],
  },
  ai_chat: {
    id: 'ai_chat',
    title: 'Voiid AI chat',
    hotspots: [{ rect: rect(4, 62, 40, 100), label: 'Back', action: back }],
  },
  // Games → pick a game → "How do you want to play?" sheet → the match, as in the app.
  games: {
    id: 'games',
    title: 'Games',
    tab: 'games',
    hotspots: [
      { rect: rect(15, 114, 353, 161), label: 'Continue Carrom', action: go('carrom_setup', 'sheet') },
      { rect: rect(15, 325, 353, 506), label: 'Play Carrom', action: go('carrom_setup', 'sheet') },
      { rect: rect(15, 518, 353, 700), label: 'Play Ludo', action: go('ludo_setup', 'sheet') },
    ],
  },
  carrom_setup: {
    id: 'carrom_setup',
    title: 'Play Carrom',
    sheetTop: 272,
    hotspots: [
      { rect: rect(0, 0, 368, 268), label: 'Close', action: back },
      { rect: rect(21, 674, 346, 720), label: 'Start game', action: go('carrom', 'zoom', true) },
      { rect: rect(140, 722, 228, 746), label: 'Not now', action: back },
    ],
  },
  carrom: {
    id: 'carrom',
    title: 'Carrom',
    hotspots: [
      { rect: rect(9, 62, 42, 95), label: 'Leave the match', action: back },
      { rect: rect(256, 715, 353, 759), label: 'Strike', action: { kind: 'toast', text: 'Pocketed!' } },
    ],
  },
  ludo_setup: {
    id: 'ludo_setup',
    title: 'Play Ludo',
    sheetTop: 272,
    hotspots: [
      { rect: rect(0, 0, 368, 268), label: 'Close', action: back },
      { rect: rect(21, 674, 346, 720), label: 'Start game', action: go('ludo', 'zoom', true) },
      { rect: rect(140, 722, 228, 746), label: 'Not now', action: back },
    ],
  },
  ludo: {
    id: 'ludo',
    title: 'Ludo',
    dark: true,
    hotspots: [
      { rect: rect(10, 130, 46, 166), label: 'Leave the match', action: back },
      { rect: rect(283, 604, 355, 641), label: 'Roll the dice', action: { kind: 'toast', text: 'Rolled a 6!' } },
    ],
  },
  clips: {
    id: 'clips',
    title: 'Clips',
    tab: 'clips',
    hotspots: [{ rect: rect(15, 104, 353, 660), label: 'Play a clip', action: go('clip_player', 'zoom') }],
  },
  clip_player: {
    id: 'clip_player',
    title: 'Clip player',
    dark: true,
    hotspots: [
      { rect: rect(4, 57, 44, 97), label: 'Close clip', action: back },
      { rect: rect(308, 561, 358, 605), label: 'Like', action: { kind: 'like' } },
    ],
  },
};

export const TAB_ROOT: Record<TabId, ScreenId> = {
  ai: 'ai',
  calls: 'calls',
  chats: 'chats',
  moments: 'moments',
  communities: 'communities',
  map: 'map_intro',
  games: 'games',
  clips: 'clips',
};

export const ALL_SCREENS = Object.keys(SCREENS) as ScreenId[];

export const src = (id: ScreenId) => `/app/${id}.webp`;
