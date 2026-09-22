'use client';

import { useCallback, useEffect, useRef, useState } from 'react';
import Link from 'next/link';
import { Glyph, type GlyphName } from '../Glyph';
import { VoiidPhone, type PhoneJump } from './VoiidPhone';
import type { ScreenId } from './screens';
import styles from './Home.module.css';

type Stance = 'e2ee' | 'public' | 'preview';

type Chapter = {
  id: string;
  label: string;
  glyph: GlyphName;
  title: string;
  body: string;
  stance: Stance;
  path: ScreenId[];
  tryIt: string;
  href?: string;
};

/*
 * Stances follow the schema, not the marketing: messages, calls, location and
 * moments are E2EE; clips and live game state are server-readable by design.
 * Communities and AI are in the design build but not shipped, so they say so.
 */
const CHAPTERS: Chapter[] = [
  {
    id: 'chats',
    label: 'Chats',
    glyph: 'chat',
    title: 'Say it. Only they can read it.',
    body: 'One-to-one and group chats, sealed on your phone for every device on the other end. Voice notes, photos, replies and the pin to the café all travel the same way.',
    stance: 'e2ee',
    path: ['chats', 'convo'],
    tryIt: 'Type a message and hit send',
    href: '/messaging',
  },
  {
    id: 'calls',
    label: 'Calls',
    glyph: 'call',
    title: 'Group calls we route and never hear.',
    body: 'Voice and video for the whole group, encrypted frame by frame. We keep the log (a missed call has to be a record of something), never the call.',
    stance: 'e2ee',
    path: ['chats', 'group_convo', 'group_call'],
    tryIt: 'Leave the call, then start a video one',
    href: '/calls',
  },
  {
    id: 'map',
    label: 'Map',
    glyph: 'map',
    title: 'A live map that forgets on schedule.',
    body: 'Share with everyone, a few people, or nobody at all with Ghost Mode. Every share has an expiry, so you never have to remember to turn it off.',
    stance: 'e2ee',
    path: ['map'],
    tryIt: 'Tap a friend on the map',
    href: '/map',
  },
  {
    id: 'moments',
    label: 'Moments',
    glyph: 'sparkle',
    title: 'Moments, for the people you pick.',
    body: 'Post the concert, the Goa trip, the birthday. Your audience gets the key; nobody else does, including us. Voiid brings the old ones back on the day.',
    stance: 'e2ee',
    path: ['moments'],
    tryIt: 'Scroll through your year',
  },
  {
    id: 'communities',
    label: 'Communities',
    glyph: 'group',
    title: 'Communities with real tools.',
    body: 'Spaces, events, a shop and an admin inbox for the groups that outgrew a group chat, plus the numbers to run them.',
    stance: 'preview',
    path: ['communities', 'community_detail'],
    tryIt: 'Head back and open another',
  },
  {
    id: 'games',
    label: 'Games',
    glyph: 'games',
    title: 'Games that live inside your chats.',
    body: 'Hand Cricket, Snake and friends, one tap from the conversation. The server referees each match, so it sees the moves. That way a tampered app can’t cheat.',
    stance: 'public',
    path: ['games'],
    tryIt: 'Play Hand Cricket, call the toss',
    href: '/games',
  },
  {
    id: 'clips',
    label: 'Clips',
    glyph: 'clips',
    title: 'Clips, and we say they’re public.',
    body: 'Short video for an audience that hasn’t signed up yet. Public means public, so clips aren’t encrypted, and your Clips profile is separate from your chat number.',
    stance: 'public',
    path: ['clips'],
    tryIt: 'Open a clip and double-tap the heart',
    href: '/clips',
  },
  {
    id: 'ai',
    label: 'Voiid AI',
    glyph: 'sparkle',
    title: 'Catch up in one line.',
    body: 'Summaries of what you missed, a draft for the reply you’ve been avoiding, and translation. It’s being designed now and will ask before it reads anything.',
    stance: 'preview',
    path: ['ai', 'ai_chat'],
    tryIt: 'Go back and try “Draft a reply”',
  },
];

const STANCE: Record<Stance, { text: string; glyph: GlyphName }> = {
  e2ee: { text: 'End-to-end encrypted', glyph: 'lock' },
  public: { text: 'Public by design', glyph: 'broadcast' },
  preview: { text: 'In the design build', glyph: 'sparkle' },
};

export function Story() {
  const [active, setActive] = useState(0);
  const [jump, setJump] = useState<PhoneJump>({ path: CHAPTERS[0].path, n: 0 });
  const refs = useRef<(HTMLElement | null)[]>([]);
  const lock = useRef(0);
  const activeRef = useRef(0);

  // Scrolling back onto the chapter already showing must not reset what the
  // visitor has tapped into; an explicit click always re-applies it.
  const select = useCallback((i: number, fromScroll = false) => {
    if (fromScroll && activeRef.current === i) return;
    activeRef.current = i;
    setActive(i);
    setJump({ path: CHAPTERS[i].path, n: Date.now() });
  }, []);

  // Desktop: whichever chapter crosses the middle of the viewport drives the phone.
  useEffect(() => {
    const mq = window.matchMedia('(min-width: 960px)');
    if (!mq.matches) return;
    const io = new IntersectionObserver(
      (entries) => {
        if (Date.now() < lock.current) return;
        for (const e of entries) {
          if (e.isIntersecting) {
            const i = Number((e.target as HTMLElement).dataset.index);
            select(i, true);
          }
        }
      },
      { rootMargin: '-45% 0px -45% 0px' },
    );
    refs.current.forEach((el) => el && io.observe(el));
    return () => io.disconnect();
  }, [select]);

  const chapter = CHAPTERS[active];

  return (
    <div className={styles.story}>
      <div className={styles.storyPhoneCol}>
        <div className={styles.storyPhoneSticky}>
          <div className={styles.storyTabs} role="tablist" aria-label="Pick a feature">
            {CHAPTERS.map((c, i) => (
              <button
                key={c.id}
                type="button"
                role="tab"
                aria-selected={i === active}
                className={styles.storyTab}
                onClick={() => {
                  lock.current = Date.now() + 900;
                  select(i);
                  const el = refs.current[i];
                  if (el && window.matchMedia('(min-width: 960px)').matches) {
                    el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                  }
                }}
              >
                <Glyph name={c.glyph} size={15} />
                {c.label}
              </button>
            ))}
          </div>

          <div className={styles.storyPhone}>
            <VoiidPhone jump={jump} initial={CHAPTERS[0].path[0]} label={`Voiid app — ${chapter.label}. Interactive.`} />
          </div>

          <p className={styles.storyHint} key={chapter.id}>
            <span className={styles.pulseDot} aria-hidden="true" />
            Try it: {chapter.tryIt}
          </p>

          {/* Phones get the active chapter's words under the phone instead of a long scroll. */}
          <div className={styles.storyMobileCopy} key={`m-${chapter.id}`}>
            <StanceBadge stance={chapter.stance} />
            <h3>{chapter.title}</h3>
            <p>{chapter.body}</p>
          </div>
        </div>
      </div>

      <ol className={styles.storySteps}>
        {CHAPTERS.map((c, i) => (
          <li
            key={c.id}
            ref={(el) => { refs.current[i] = el; }}
            data-index={i}
            data-active={i === active ? 'true' : undefined}
            className={styles.storyStep}
          >
            <span className={styles.stepIndex}>{String(i + 1).padStart(2, '0')}</span>
            <StanceBadge stance={c.stance} />
            <h3 className={styles.stepTitle}>{c.title}</h3>
            <p className={styles.stepBody}>{c.body}</p>
            <div className={styles.stepActions}>
              <button
                type="button"
                className={styles.stepTry}
                onClick={() => {
                  lock.current = Date.now() + 900;
                  select(i);
                }}
              >
                Show me on the phone
              </button>
              {c.href && (
                <Link href={c.href} className={styles.stepMore}>
                  How it works <Glyph name="arrow-right" size={13} />
                </Link>
              )}
            </div>
          </li>
        ))}
      </ol>
    </div>
  );
}

function StanceBadge({ stance }: { stance: Stance }) {
  const s = STANCE[stance];
  return (
    <span className={styles.stance} data-stance={stance}>
      <Glyph name={s.glyph} size={12} />
      {s.text}
    </span>
  );
}
