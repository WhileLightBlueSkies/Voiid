import type { Config } from 'tailwindcss';

//
// Tailwind, configured to Voiid's console palette rather than the stock shadcn theme.
//
// The colour values are NOT new. They are the same tokens this panel already used, which in
// turn mirror the app's Theme.swift — teal #13828C, near-black #080C0E, the Cloudflare-style
// orange reserved for attention. Adopting shadcn's default slate/zinc here would have made
// the console look like a different product from the app it administers.
//
// Radii stay TIGHT (6/8px, not shadcn's 0.5rem default). A data table with marketing-page
// corners reads as a settings sheet; consoles that people work in all day — Cloudflare,
// Linear, Vercel — all run tighter than a landing page does.
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
        ring: 'hsl(var(--accent-hsl))',
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
      },
      borderRadius: {
        lg: '8px',
        md: '6px',
        sm: '4px',
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
