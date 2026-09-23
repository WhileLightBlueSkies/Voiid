import type { Config } from 'tailwindcss';

//
// Tailwind, configured to Voiid's console palette rather than the stock shadcn theme.
//
// The console is LIGHT: soft-grey page, white rounded cards, black primary controls and a
// single mint-green signal colour. Tokens live in globals.css; this file only names them.
//
export default {
  darkMode: ['class'],
  content: [
    './app/**/*.{ts,tsx}',
    './components/**/*.{ts,tsx}',
  ],
  theme: {
    extend: {
      colors: {
        // Mapped onto the CSS variables in globals.css so BOTH systems read one source of
        // truth. A page still using `var(--surface)` and a shadcn component using
        // `bg-card` resolve to the same pixel, which is what makes an incremental
        // migration safe rather than a two-theme mess.
        border: 'hsl(var(--border-hsl))',
        input: 'hsl(var(--border-hsl))',
        ring: 'hsl(var(--tide-light-hsl))',
        background: 'hsl(var(--bg-hsl))',
        foreground: 'hsl(var(--text-hsl))',
        primary: {
          DEFAULT: 'hsl(var(--accent-hsl))',
          foreground: 'hsl(var(--text-hsl))',
        },
        secondary: {
          DEFAULT: 'hsl(var(--surface-2-hsl))',
          foreground: 'hsl(var(--text-hsl))',
        },
        destructive: {
          DEFAULT: 'hsl(var(--danger-hsl))',
          foreground: 'hsl(var(--text-hsl))',
        },
        muted: {
          DEFAULT: 'hsl(var(--surface-2-hsl))',
          foreground: 'hsl(var(--text-mute-hsl))',
        },
        accent: {
          DEFAULT: 'hsl(var(--surface-3-hsl))',
          foreground: 'hsl(var(--text-hsl))',
        },
        popover: {
          DEFAULT: 'hsl(var(--surface-2-hsl))',
          foreground: 'hsl(var(--text-hsl))',
        },
        card: {
          DEFAULT: 'hsl(var(--surface-hsl))',
          foreground: 'hsl(var(--text-hsl))',
        },
        // Semantic states, kept addressable by name. Status in this console is never
        // carried by hue alone — there is always a word too — but the hue still has to be
        // the right one.
        ok: 'hsl(var(--ok-hsl))',
        warning: 'hsl(var(--warning-hsl))',
        attention: 'hsl(var(--attention-hsl))',
        info: 'hsl(var(--info-hsl))',
        tide: 'hsl(var(--tide-light-hsl))',
      },
      borderRadius: {
        // Soft and generous: cards at 20, controls at 12, chips at 8. Primary buttons go
        // further still, to a full pill, in button.tsx.
        lg: '20px',
        md: '12px',
        sm: '8px',
      },
      fontSize: {
        // A console reads at 13/14px, not 16. These are the sizes the panel already used;
        // naming them stops each new component re-deciding.
        micro: ['11px', { lineHeight: '1.4' }],
        tiny: ['12px', { lineHeight: '1.5' }],
        sm: ['13px', { lineHeight: '1.55' }],
        base: ['14px', { lineHeight: '1.6' }],
      },
      keyframes: {
        'accordion-down': {
          from: { height: '0' },
          to: { height: 'var(--radix-accordion-content-height)' },
        },
        'accordion-up': {
          from: { height: 'var(--radix-accordion-content-height)' },
          to: { height: '0' },
        },
      },
      animation: {
        'accordion-down': 'accordion-down 0.2s ease-out',
        'accordion-up': 'accordion-up 0.2s ease-out',
      },
    },
  },
  plugins: [require('tailwindcss-animate')],
} satisfies Config;
