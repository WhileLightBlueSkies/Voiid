'use client';

import { useEffect, useState } from 'react';
import styles from './ThemeToggle.module.css';

type Theme = 'light' | 'dark';

export function ThemeToggle() {
  const [theme, setTheme] = useState<Theme>('light');

  useEffect(() => {
    setTheme(document.documentElement.dataset.theme === 'dark' ? 'dark' : 'light');
  }, []);

  const toggle = () => {
    const next: Theme = theme === 'light' ? 'dark' : 'light';
    document.documentElement.dataset.theme = next;
    document.documentElement.style.colorScheme = next;
    window.localStorage.setItem('voiid-theme', next);
    document
      .querySelector('meta[name="theme-color"]')
      ?.setAttribute('content', next === 'dark' ? '#07110f' : '#fbfcfc');
    setTheme(next);
  };

  const isDark = theme === 'dark';

  return (
    <button
      type="button"
      className={styles.toggle}
      onClick={toggle}
      aria-label={isDark ? 'Switch to light mode' : 'Switch to dark mode'}
      aria-pressed={isDark}
    >
      <span className={styles.track} aria-hidden="true">
        <svg className={styles.sun} viewBox="0 0 24 24">
          <circle cx="12" cy="12" r="3.2" />
          <path d="M12 2.5v2M12 19.5v2M2.5 12h2M19.5 12h2M5.3 5.3l1.4 1.4M17.3 17.3l1.4 1.4M18.7 5.3l-1.4 1.4M6.7 17.3l-1.4 1.4" />
        </svg>
        <svg className={styles.moon} viewBox="0 0 24 24">
          <path d="M20 15.2A8.3 8.3 0 0 1 8.8 4a8.3 8.3 0 1 0 11.2 11.2Z" />
        </svg>
        <span className={styles.thumb} />
      </span>
    </button>
  );
}
