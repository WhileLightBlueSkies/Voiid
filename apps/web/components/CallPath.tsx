'use client';

import { useId, useRef, useState } from 'react';
import { Glyph, type GlyphName } from './Glyph';
import styles from './CallPath.module.css';

/**
 * The three pieces of call setup, as a route you can inspect.
 *
 * The section claims "three moving pieces, and only one of them touches your
 * audio." Three equal FeatureCards actively work against that sentence — they
 * make all three look equally involved. Selecting a leg and reading what it does
 * AND what it cannot reach is what turns the claim into something checkable.
 *
 * Every leg carries both halves deliberately: what it handles, and what it has no
 * key for. Listing only capabilities would read as a feature tour; the pair is the
 * actual argument.
 *
 * Interaction notes: selection commits on pointer-DOWN so the panel changes on the
 * same frame as the press, rather than waiting out the pointer-up delay. It is a
 * real tablist — roving tabindex, arrow keys, Home/End — because a control that
 * only answers to a mouse is a decoration. Nothing is locked out while the
 * selection animates; pressing another leg retargets it immediately.
 */

type Leg = {
  id: string;
  label: string;
  glyph: GlyphName;
  title: string;
  body: string;
  /** What this piece genuinely does. */
  does: string;
  /** What it structurally cannot do — the half that matters. */
  never: string;
};

const LEGS: Leg[] = [
  {
    id: 'ring',
    label: 'Ringing',
    glyph: 'device',
    title: 'A content-free push wakes the other phone.',
    body:
      'The notification carries routing ids and nothing else — no name, no number, no ' +
      'reason for the call. The phone starts ringing before it knows anything worth ' +
      'protecting, which is the point: there is nothing in the push to intercept.',
    does: 'Carries routing ids so the right device rings',
    never: 'Carries no name, number or reason for the call',
  },
  {
    id: 'path',
    label: 'Finding a path',
    glyph: 'globe',
    title: 'Two devices behind different networks find each other.',
    body:
      'Short-lived TURN credentials let your phone and theirs negotiate a route across ' +
      'networks that cannot see each other directly. When a direct path exists, the media ' +
      'never touches our infrastructure at all — the relay is a fallback, not the default.',
    does: 'Issues short-lived credentials and relays packets',
    never: 'Holds no key for the packets it forwards',
  },
  {
    id: 'media',
    label: 'The media',
    glyph: 'lock',
    title: 'Every frame is sealed on your device.',
    body:
      'Audio and video are encrypted with a per-call key that arrives over your encrypted ' +
      'messages — never over the signaling path, which is what would otherwise hand the ' +
      'server both halves. The badge in the call tells you when both sides have verified.',
    does: 'Encrypts each frame with an on-device key',
    never: 'Never sends that key over the signaling path',
  },
];

export function CallPath() {
  const [active, setActive] = useState(0);
  const uid = useId();
  const legRefs = useRef<(HTMLButtonElement | null)[]>([]);

  const current = LEGS[active]!;

  const onKeyDown = (e: React.KeyboardEvent) => {
    const last = LEGS.length - 1;
    let next: number | null = null;
    if (e.key === 'ArrowRight' || e.key === 'ArrowDown') next = active === last ? 0 : active + 1;
    else if (e.key === 'ArrowLeft' || e.key === 'ArrowUp') next = active === 0 ? last : active - 1;
    else if (e.key === 'Home') next = 0;
    else if (e.key === 'End') next = last;
    if (next === null) return;
    e.preventDefault();
    setActive(next);
    legRefs.current[next]?.focus();
  };

  return (
    <div className={styles.wrap}>
      <div
        role="tablist"
        aria-label="The three pieces of a call"
        className={styles.route}
        onKeyDown={onKeyDown}
      >
        {/* Decorative: the route restates the order the list already carries. */}
        <span className={styles.line} aria-hidden="true" />
        {LEGS.map((l, i) => (
          <button
            key={l.id}
            ref={(el) => {
              legRefs.current[i] = el;
            }}
            type="button"
            role="tab"
            id={`${uid}-tab-${l.id}`}
            aria-selected={i === active}
            aria-controls={`${uid}-panel`}
            tabIndex={i === active ? 0 : -1}
            className={styles.leg}
            onPointerDown={() => setActive(i)}
            onClick={() => setActive(i)}
          >
            <span className={styles.node} aria-hidden="true">
              <Glyph name={l.glyph} size={18} />
            </span>
            <span className={styles.legLabel}>{l.label}</span>
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
        <div key={current.id} className={styles.swap}>
          <h3 className={styles.panelTitle}>{current.title}</h3>
          <p className={styles.panelBody}>{current.body}</p>
          <div className={styles.facts}>
            <p className={styles.fact}>
              <span className={`${styles.factIcon} ${styles.factDoes}`}>
                <Glyph name="check" size={14} />
              </span>
              {current.does}
            </p>
            <p className={styles.fact}>
              <span className={`${styles.factIcon} ${styles.factNever}`}>
                <Glyph name="eye-off" size={14} />
              </span>
              {current.never}
            </p>
          </div>
        </div>
      </div>
    </div>
  );
}
