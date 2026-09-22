import type { TabId } from './screens';

/**
 * Stand-ins for the SF Symbols the app's tab bar uses. Drawn at 24 on a 24 grid
 * with a 1.7 stroke so they sit at the same optical weight as the screenshots.
 */
export function TabIcon({ tab, filled }: { tab: TabId; filled: boolean }) {
  const common = {
    width: '100%',
    height: '100%',
    viewBox: '0 0 24 24',
    fill: 'none',
    stroke: 'currentColor',
    strokeWidth: 1.7,
    strokeLinecap: 'round' as const,
    strokeLinejoin: 'round' as const,
    'aria-hidden': true,
  };
  const fill = filled ? 'currentColor' : 'none';

  switch (tab) {
    case 'ai':
      return (
        <svg {...common}>
          <path fill={fill} d="M10 3.5l1.6 4.4c.3.9 1 1.6 1.9 1.9l4.4 1.6-4.4 1.6c-.9.3-1.6 1-1.9 1.9L10 19.3l-1.6-4.4c-.3-.9-1-1.6-1.9-1.9L2.1 11.4l4.4-1.6c.9-.3 1.6-1 1.9-1.9z" />
          <path fill={fill} d="M18.5 2.5l.6 1.6 1.6.6-1.6.6-.6 1.6-.6-1.6-1.6-.6 1.6-.6zM18 16.5l.5 1.3 1.3.5-1.3.5-.5 1.3-.5-1.3-1.3-.5 1.3-.5z" />
        </svg>
      );
    case 'chats':
      return (
        <svg {...common}>
          <path fill={fill} d="M3 5.5A2.5 2.5 0 015.5 3h8A2.5 2.5 0 0116 5.5v5a2.5 2.5 0 01-2.5 2.5H8l-3.5 3v-3.2A2.5 2.5 0 013 10.5z" />
          <path fill={fill} d="M18.5 8.2A2.5 2.5 0 0121 10.7v4.8a2.5 2.5 0 01-1.5 2.3V21l-3.4-3h-4.6a2.5 2.5 0 01-2.4-1.8" />
        </svg>
      );
    case 'moments':
      return (
        <svg {...common}>
          <circle cx="12" cy="12" r="9" />
          <circle cx="12" cy="12" r="4.2" fill={fill} />
        </svg>
      );
    case 'communities':
      return (
        <svg {...common}>
          <circle cx="12" cy="8" r="3" fill={fill} />
          <circle cx="5" cy="9.5" r="2.3" fill={fill} />
          <circle cx="19" cy="9.5" r="2.3" fill={fill} />
          <path fill={fill} d="M6.8 19c0-3 2.3-5.3 5.2-5.3s5.2 2.3 5.2 5.3zM1.5 18.5c0-2.3 1.6-4 3.6-4 .8 0 1.5.2 2.1.6M22.5 18.5c0-2.3-1.6-4-3.6-4-.8 0-1.5.2-2.1.6" />
        </svg>
      );
    case 'map':
      return (
        <svg {...common}>
          <path fill={fill} d="M3 6.2l5.5-2.2 7 2.4L21 4.2v13.6l-5.5 2.2-7-2.4L3 19.8z" />
          <path d="M8.5 4v13.6M15.5 6.4V20" stroke={filled ? 'var(--tab-bg)' : 'currentColor'} />
        </svg>
      );
    case 'games':
      return (
        <svg {...common}>
          <path fill={fill} d="M7 7h10a5 5 0 014.8 6.4l-.9 3.2a2.7 2.7 0 01-4.5 1.1L14.3 16H9.7l-2.1 1.7a2.7 2.7 0 01-4.5-1.1l-.9-3.2A5 5 0 017 7z" />
          <path d="M7.5 10.2v3M6 11.7h3M15.8 11h.01M17.6 12.8h.01" stroke={filled ? 'var(--tab-bg)' : 'currentColor'} strokeWidth={2} />
        </svg>
      );
    case 'clips':
      return (
        <svg {...common}>
          <rect x="3" y="4.5" width="18" height="15" rx="3" fill={fill} />
          <path d="M10 9.2v5.6l4.6-2.8z" fill={filled ? 'var(--tab-bg)' : 'currentColor'} stroke="none" />
        </svg>
      );
  }
}
