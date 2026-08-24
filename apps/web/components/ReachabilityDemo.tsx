'use client';

import { useId, useRef, useState } from 'react';
import { Glyph, type GlyphName } from './Glyph';
import styles from './ReachabilityDemo.module.css';

/**
 * The reachability model, as a control you operate rather than a claim you read.
 *
 * The section's whole argument is that being FINDABLE and being REACHABLE are
 * different things. Three static cards state that. This lets you pick who is
 * trying to reach you and see precisely what Voiid does — the difference between
 * reading a policy and watching it run, and the reason the section earns an
 * interactive element at all rather than having one bolted on for decoration.
 *
 * IMPLEMENTATION NOTES (the interaction rules this follows)
 * --------------------------------------------------------
 * It is a real tablist: roving tabindex, arrow keys, Home/End, and the panel is
 * wired with aria-controls/aria-labelledby. A segmented control that only works
 * with a mouse is a decoration, not a control.
 *
 * Selection is committed on POINTER-DOWN, not on click. Waiting for touch-up to
 * change the panel adds the pointer-up delay to every switch and reads as lag;
 * the press feedback and the state change happen on the same frame. Click still
 * fires for keyboard and assistive tech, and re-selecting is idempotent.
 *
 * Nothing here locks out input while the thumb travels — a second press during
 * the transition retargets it immediately, because the thumb is driven by a
 * transform on a custom property rather than by an animation that has to finish.
 */

type Case = {
  id: string;
  /** The tab label — who is trying to reach you. */
  tab: string;
  glyph: GlyphName;
  /** The outcome, in one word. Paired with an icon and a tint, never tint alone. */
  verdict: string;
  tone: 'opens' | 'asks' | 'blocked';
  verdictGlyph: GlyphName;
  title: string;
  body: string;
  /** What this path requires, and whether this case satisfies it. */
  needs: { label: string; met: boolean }[];
};

const CASES: Case[] = [
  {
    id: 'mutual',
    tab: 'You both saved each other',
    glyph: 'group',
    verdict: 'Chat opens',
    tone: 'opens',
    verdictGlyph: 'check',
    title: 'The chat opens directly.',
    body:
      'Mutual contacts are the one case where both people have already made the decision. ' +
      'There is nothing left to ask, so Voiid does not invent a step to ask it.',
    needs: [
      { label: 'They have your number', met: true },
      { label: 'You have theirs', met: true },
    ],
  },
  {
    id: 'oneway',
    tab: 'Only they have your number',
    glyph: 'note',
    verdict: 'Request first',
    tone: 'asks',
    verdictGlyph: 'shield',
    title: 'It arrives as a request you can accept or decline.',
    body:
      'Having someone’s number is not consent. Treating it as consent is exactly what ' +
      'turns one leaked contact list into spam everywhere else — so the number gets ' +
      'them as far as your requests, and no further.',
    needs: [
      { label: 'They have your number', met: true },
      { label: 'You have theirs', met: false },
    ],
  },
  {
    id: 'username',
    tab: 'They found your @username',
    glyph: 'key',
    verdict: 'PIN required',
    tone: 'blocked',
    verdictGlyph: 'lock',
    title: 'A username alone gets them nowhere.',
    body:
      'They also need your six-digit contact PIN, which you hand out yourself — out ' +
      'loud, on a card, however you like. Even with both, it still only opens a request.',
    needs: [
      { label: 'Your @username', met: true },
      { label: 'Your 6-digit PIN', met: false },
    ],
  },
];

export function ReachabilityDemo() {
  const [active, setActive] = useState(0);
  const uid = useId();
  const tabRefs = useRef<(HTMLButtonElement | null)[]>([]);

  const current = CASES[active]!;

  /** Arrow-key navigation, per the tablist pattern: move focus AND selection. */
  const onKeyDown = (e: React.KeyboardEvent) => {
    const last = CASES.length - 1;
    let next: number | null = null;
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') next = active === last ? 0 : active + 1;
    else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') next = active === 0 ? last : active - 1;
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = last;
    if (next === null) return;
    e.preventDefault();
    setActive(next);
    tabRefs.current[next]?.focus();
  };

  return (
    <div className={styles.wrap}>
      <div
        role="tablist"
        aria-label="Who is trying to reach you"
        className={styles.tabs}
        onKeyDown={onKeyDown}
        // Drives the thumb's transform. One custom property, so switching is a
        // compositor transform rather than a re-layout.
        style={{ '--active': active } as React.CSSProperties}
      >
        <span className={styles.thumb} aria-hidden="true" />
        {CASES.map((c, i) => (
          <button
            key={c.id}
            ref={(el) => {
              tabRefs.current[i] = el;
            }}
            type="button"
            role="tab"
            id={`${uid}-tab-${c.id}`}
            aria-selected={i === active}
            aria-controls={`${uid}-panel`}
            // Roving tabindex: one stop for the whole control, arrows move within.
            tabIndex={i === active ? 0 : -1}
            className={styles.tab}
            // Commit on press, not on release — see the note above.
            onPointerDown={() => setActive(i)}
            onClick={() => setActive(i)}
          >
            <Glyph name={c.glyph} size={15} />
            <span className={styles.tabLabel}>{c.tab}</span>
          </button>
        ))}
      </div>

      <div
        role="tabpanel"
        id={`${uid}-panel`}
        aria-labelledby={`${uid}-tab-${current.id}`}
        tabIndex={0}
        className={styles.panel}
      >
        {/* Keyed on the case id so React remounts it and the entrance replays. */}
        <div key={current.id} className={styles.swap}>
          <span className={[styles.verdict, styles[current.tone]].join(' ')}>
            <Glyph name={current.verdictGlyph} size={13} />
            {current.verdict}
          </span>
          <h3 className={styles.panelTitle}>{current.title}</h3>
          <p className={styles.panelBody}>{current.body}</p>
          <ul className={styles.needs}>
            {current.needs.map((n) => (
              <li
                key={n.label}
                className={[styles.need, n.met ? styles.needMet : ''].filter(Boolean).join(' ')}
              >
                {/* The icon carries met/unmet as well as the tint. */}
                <Glyph name={n.met ? 'check' : 'lock'} size={12} />
                {n.label}
              </li>
            ))}
          </ul>
        </div>
      </div>
    </div>
  );
}
