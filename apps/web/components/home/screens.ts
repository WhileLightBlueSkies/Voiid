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

export type TabId = 'ai' | 'chats' | 'moments' | 'communities' | 'map' | 'games' | 'clips';

export type ScreenId =
  | 'chats'
  | 'convo'
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
  | 'game_setup'
  | 'game_toss'
  | 'game_won_toss'
  | 'game_play'
  | 'game_out'
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
      { rect: rect(136, 150, 232, 245), label: 'Open chat with Ananya Sharma', action: go('convo', 'push') },
      { rect: rect(249, 150, 345, 245), label: 'Open Weekend Warriors group', action: go('group_convo', 'push') },
      { rect: rect(22, 375, 118, 470), label: 'Open Voiid AI', action: go('ai_chat', 'push') },
    ],
  },
  convo: {
    id: 'convo',
    title: 'Chat with Ananya',
    hotspots: [
      { rect: rect(20, 65, 78, 122), label: 'Back to chats', action: back },
      {
        rect: rect(280, 77, 313, 110),
        label: 'Voice call',
        action: { kind: 'toast', text: 'Try a group call — open Weekend Warriors' },
      },
      {
        rect: rect(320, 77, 353, 110),
        label: 'Video call',
        action: { kind: 'toast', text: 'Try a group call — open Weekend Warriors' },
      },
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
      { rect: rect(20, 65, 78, 122), label: 'Back to chats', action: back },
      { rect: rect(280, 77, 313, 110), label: 'Start a group voice call', action: go('group_call', 'zoom') },
      { rect: rect(320, 77, 353, 110), label: 'Start a group video call', action: go('group_video', 'zoom') },
      { rect: rect(98, 232, 270, 260), label: 'Encryption details', action: { kind: 'toast', text: 'Sealed on your phone. Opened only on theirs.' } },
    ],
    chat: {
      top: 128,
      bottom: 708,
      from: 'Riya',
      replies: ['Love it 🙌 bringing the frisbee', 'Booked the court for 5 🏸', "Arjun's driving, obviously 🚗"],
    },
  },
  group_call: {
    id: 'group_call',
    title: 'Group voice call',
    dark: true,
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
      { rect: rect(153, 720, 213, 780), label: 'End call', action: back },
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
      { rect: rect(16, 268, 352, 405), label: 'Open Voiid Designers', action: go('community_detail', 'push') },
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
      { rect: rect(15, 645, 353, 695), label: 'Continue', action: go('map_privacy', 'push') },
      { rect: rect(312, 58, 360, 88), label: 'Skip', action: { kind: 'unlockMap', to: 'map' } },
    ],
  },
  map_privacy: {
    id: 'map_privacy',
    title: 'Your location, your choice',
    hotspots: [
      { rect: rect(8, 63, 42, 97), label: 'Back', action: back },
      { rect: rect(15, 645, 353, 695), label: 'Allow location access', action: { kind: 'unlockMap', to: 'map' } },
      { rect: rect(140, 698, 228, 722), label: 'Not now', action: { kind: 'unlockMap', to: 'map' } },
    ],
  },
  map: {
    id: 'map',
    title: 'Map',
    tab: 'map',
    hotspots: [
      { rect: rect(40, 255, 100, 315), label: 'Ava Johnson', action: { kind: 'toast', text: 'Ava is sharing for 1 more hour' } },
      { rect: rect(296, 285, 346, 345), label: 'Noah Patel', action: { kind: 'toast', text: 'Noah is sharing until he turns it off' } },
      { rect: rect(160, 380, 206, 440), label: 'You', action: { kind: 'toast', text: 'Visible to All Friends · 1 hour' } },
    ],
  },
  ai: {
    id: 'ai',
    title: 'Voiid AI',
    tab: 'ai',
    hotspots: [
      { rect: rect(15, 178, 353, 244), label: 'Catch me up', action: go('ai_chat', 'push') },
      { rect: rect(15, 254, 353, 321), label: 'Draft a reply', action: go('ai_chat', 'push') },
    ],
  },
  ai_chat: {
    id: 'ai_chat',
    title: 'Voiid AI chat',
    hotspots: [{ rect: rect(6, 63, 40, 97), label: 'Back', action: back }],
  },
  games: {
    id: 'games',
    title: 'Games',
    tab: 'games',
    hotspots: [
      { rect: rect(15, 114, 353, 161), label: 'Continue Hand Cricket', action: go('game_setup', 'sheet') },
      { rect: rect(15, 325, 353, 508), label: 'Play Hand Cricket', action: go('game_setup', 'sheet') },
    ],
  },
  game_setup: {
    id: 'game_setup',
    title: 'Hand Cricket setup',
    sheetTop: 340,
    hotspots: [
      { rect: rect(0, 0, 368, 335), label: 'Close', action: back },
      { rect: rect(22, 672, 346, 720), label: 'Start game', action: go('game_toss', 'fade', true) },
      { rect: rect(130, 722, 238, 748), label: 'Not now', action: back },
    ],
  },
  game_toss: {
    id: 'game_toss',
    title: 'The coin toss',
    dark: true,
    hotspots: [
      { rect: rect(22, 514, 177, 559), label: 'Call heads', action: go('game_won_toss', 'fade', true) },
      { rect: rect(190, 514, 346, 559), label: 'Call tails', action: go('game_won_toss', 'fade', true) },
    ],
  },
  game_won_toss: {
    id: 'game_won_toss',
    title: 'You won the toss',
    dark: true,
    hotspots: [
      { rect: rect(22, 543, 178, 589), label: 'Bat first', action: go('game_play', 'fade', true) },
      { rect: rect(190, 543, 346, 589), label: 'Bowl first', action: go('game_play', 'fade', true) },
    ],
  },
  game_play: {
    id: 'game_play',
    title: 'Hand Cricket',
    hotspots: [
      { rect: rect(6, 61, 42, 97), label: 'Leave the match', action: { kind: 'root', tab: 'games' } },
      { rect: rect(20, 690, 348, 758), label: 'Show your fingers', action: go('game_out', 'fade', true) },
    ],
  },
  game_out: {
    id: 'game_out',
    title: 'Bowled!',
    hotspots: [
      { rect: rect(6, 61, 42, 97), label: 'Leave the match', action: { kind: 'root', tab: 'games' } },
      { rect: rect(20, 690, 348, 758), label: 'Play the next ball', action: go('game_play', 'fade', true) },
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
      { rect: rect(6, 60, 42, 94), label: 'Close clip', action: back },
      { rect: rect(308, 535, 350, 585), label: 'Like', action: { kind: 'like' } },
    ],
  },
};

export const TAB_ROOT: Record<TabId, ScreenId> = {
  ai: 'ai',
  chats: 'chats',
  moments: 'moments',
  communities: 'communities',
  map: 'map_intro',
  games: 'games',
  clips: 'clips',
};

export const ALL_SCREENS = Object.keys(SCREENS) as ScreenId[];

export const src = (id: ScreenId) => `/app/${id}.webp`;
