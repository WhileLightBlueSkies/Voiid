'use client';

import { useCallback, useEffect, useLayoutEffect, useRef, useState, type FormEvent } from 'react';
import {
  ALL_SCREENS,
  SCREENS,
  TABS,
  TAB_ROOT,
  pct,
  rect,
  src,
  type Action,
  type ScreenId,
  type TabId,
  type Transition,
} from './screens';
import { TabIcon } from './TabIcon';
import styles from './VoiidPhone.module.css';

/**
 * A click-through Voiid on the marketing site.
 *
 * Each screen is a screenshot of the iOS design build; every button that matters has
 * a hotspot laid over it, so the phone behaves like the app without shipping the app.
 * Two things are live rather than pictures: the tab bar (so all seven tabs are
 * reachable even though the app scrolls its bar) and the chat composer, which really
 * sends and gets a reply.
 *
 * NAVIGATION is a stack, the same shape as the app's: `push` and `sheet` go deeper,
 * a back hotspot pops and plays the entry transition backwards, and a tab tap resets
 * the stack to that tab's root.
 */

type Entry = { id: ScreenId; via: Transition };

type Layer = {
  key: number;
  id: ScreenId;
  role: 'idle' | 'enter' | 'exit';
  via: Transition;
  reverse: boolean;
};

type Message = { key: number; side: 'sent' | 'received' | 'typing'; text: string; time: string };

/** A deep link: the whole back stack to land on, so Back still works afterwards. */
export type PhoneJump = { path: ScreenId[]; n: number };

const ZOOMED: ScreenId[] = ['group_call', 'group_video', 'clip_player'];

type Props = {
  initial?: ScreenId;
  /** Open deep in the app with a back stack, e.g. ['chats', 'group_convo', 'group_call']. */
  initialPath?: ScreenId[];
  /** Drive the phone from outside (the scroll story). A new `n` re-applies it. */
  jump?: PhoneJump;
  onScreen?: (id: ScreenId) => void;
  /** Show the one-off "tap anything" coach mark. */
  coach?: boolean;
  label?: string;
  className?: string;
};

const DURATION: Record<Transition, number> = { push: 460, fade: 280, sheet: 480, zoom: 400 };

let layerKey = 1;
let msgKey = 1;

function clock() {
  const d = new Date();
  return d.toLocaleTimeString('en-US', { hour: 'numeric', minute: '2-digit' });
}

export function VoiidPhone({ initial = 'chats', initialPath, jump, onScreen, coach = false, label = 'Voiid app preview', className }: Props) {
  const start = initialPath?.length ? initialPath : [initial];
  const [stack, setStack] = useState<Entry[]>(() =>
    start.map((id, i) => ({ id, via: i === 0 ? 'fade' : ZOOMED.includes(id) ? 'zoom' : 'push' })),
  );
  const [layers, setLayers] = useState<Layer[]>([
    { key: 0, id: start[start.length - 1], role: 'idle', via: 'fade', reverse: false },
  ]);
  const [mapUnlocked, setMapUnlocked] = useState(start.includes('map'));
  const [toast, setToast] = useState<{ text: string; n: number } | null>(null);
  const [flash, setFlash] = useState(0);
  const [likes, setLikes] = useState<number[]>([]);
  const [touched, setTouched] = useState(false);
  const [messages, setMessages] = useState<Partial<Record<ScreenId, Message[]>>>({});

  const current = stack[stack.length - 1].id;
  const screen = SCREENS[current];
  const busy = useRef(false);

  // ---- transitions --------------------------------------------------------

  const show = useCallback((id: ScreenId, via: Transition, reverse: boolean) => {
    setLayers((prev) => {
      const top = prev[prev.length - 1];
      if (top.id === id) return prev;
      return [
        { ...top, role: 'exit', via, reverse },
        { key: layerKey++, id, role: 'enter', via, reverse },
      ];
    });
  }, []);

  // Settle: once the entering layer has finished, it is the only one left.
  useEffect(() => {
    const entering = layers.find((l) => l.role === 'enter');
    if (!entering) return;
    busy.current = true;
    const t = window.setTimeout(() => {
      busy.current = false;
      setLayers((prev) => {
        const last = prev[prev.length - 1];
        return last.key === entering.key ? [{ ...last, role: 'idle' }] : prev;
      });
    }, DURATION[entering.via] + 30);
    return () => window.clearTimeout(t);
  }, [layers]);

  useEffect(() => {
    onScreen?.(current);
  }, [current, onScreen]);

  const navigate = useCallback(
    (next: Entry[], via: Transition, reverse: boolean) => {
      setStack(next);
      show(next[next.length - 1].id, via, reverse);
    },
    [show],
  );

  const goTab = useCallback(
    (tab: TabId) => {
      const root = tab === 'map' && mapUnlocked ? 'map' : TAB_ROOT[tab];
      if (stack.length === 1 && stack[0].id === root) return;
      navigate([{ id: root, via: 'fade' }], 'fade', false);
    },
    [mapUnlocked, navigate, stack],
  );

  const run = useCallback(
    (action: Action) => {
      setTouched(true);
      switch (action.kind) {
        case 'go': {
          const entry = { id: action.to, via: action.via };
          const next = action.replace ? [...stack.slice(0, -1), entry] : [...stack, entry];
          // A replace out of a sheet should not slide the sheet in reverse.
          navigate(next, action.replace ? 'fade' : action.via, false);
          break;
        }
        case 'back': {
          if (stack.length < 2) return;
          const leaving = stack[stack.length - 1];
          navigate(stack.slice(0, -1), leaving.via, true);
          break;
        }
        case 'root':
          goTab(action.tab);
          break;
        case 'unlockMap':
          setMapUnlocked(true);
          navigate([{ id: action.to, via: 'fade' }], 'fade', false);
          break;
        case 'toast':
          setToast({ text: action.text, n: Date.now() });
          break;
        case 'like':
          setLikes((l) => [...l, Date.now()]);
          break;
      }
    },
    [goTab, navigate, stack],
  );

  // External jumps (the scroll story) cross-fade, whatever the depth.
  const lastJump = useRef<number | null>(null);
  useEffect(() => {
    if (!jump || jump.n === lastJump.current) return;
    lastJump.current = jump.n;
    if (jump.path.includes('map')) setMapUnlocked(true);
    const next = jump.path.map((id, i): Entry => ({
      id,
      via: i === 0 ? 'fade' : ZOOMED.includes(id) ? 'zoom' : 'push',
    }));
    navigate(next, 'fade', false);
  }, [jump, navigate]);

  useEffect(() => {
    if (!toast) return;
    const t = window.setTimeout(() => setToast(null), 2400);
    return () => window.clearTimeout(t);
  }, [toast]);

  useEffect(() => {
    if (!likes.length) return;
    const t = window.setTimeout(() => setLikes([]), 1000);
    return () => window.clearTimeout(t);
  }, [likes]);

  // Warm every screen once the page is idle, so the first tap never shows a blank.
  useEffect(() => {
    const warm = () => ALL_SCREENS.forEach((id) => { const i = new Image(); i.src = src(id); });
    const w = window as Window & { requestIdleCallback?: (cb: () => void) => number };
    if (w.requestIdleCallback) w.requestIdleCallback(warm);
    else window.setTimeout(warm, 1200);
  }, []);

  // A tap on nothing shows where the somethings are.
  const onDeadTap = () => {
    setTouched(true);
    setFlash(Date.now());
  };

  // ---- chat ---------------------------------------------------------------

  const send = useCallback(
    (id: ScreenId, text: string) => {
      const chat = SCREENS[id].chat;
      if (!chat) return;
      const sent: Message = { key: msgKey++, side: 'sent', text, time: clock() };
      const typing: Message = { key: msgKey++, side: 'typing', text: '', time: '' };
      setMessages((m) => ({ ...m, [id]: [...(m[id] ?? []), sent] }));
      window.setTimeout(() => setMessages((m) => ({ ...m, [id]: [...(m[id] ?? []), typing] })), 650);
      window.setTimeout(() => {
        setMessages((m) => {
          const list = m[id] ?? [];
          const replies = list.filter((x) => x.side === 'received').length;
          const reply: Message = {
            key: msgKey++,
            side: 'received',
            text: chat.replies[replies % chat.replies.length],
            time: clock(),
          };
          return { ...m, [id]: list.filter((x) => x.key !== typing.key).concat(reply) };
        });
      }, 2000);
    },
    [],
  );

  const tab = screen.tab;

  // ---- full screen ----------------------------------------------------------
  //
  // The real Fullscreen API where it exists: it lifts the element into the top
  // layer, so no ancestor transform (the hero tilt, the reveal animations) can
  // trap it. iPhone Safari has no element fullscreen, so there it becomes a fixed
  // overlay — which a transformed ancestor WOULD trap, hence `freeze()`.
  const shellRef = useRef<HTMLDivElement>(null);
  const [full, setFull] = useState<false | 'native' | 'overlay'>(false);
  const frozen = useRef<{ el: HTMLElement; transform: string; animation: string; filter: string }[]>([]);

  const freeze = () => {
    let el = shellRef.current?.parentElement ?? null;
    while (el && el !== document.body) {
      frozen.current.push({ el, transform: el.style.transform, animation: el.style.animation, filter: el.style.filter });
      el.style.transform = 'none';
      el.style.animation = 'none';
      el.style.filter = 'none';
      el = el.parentElement;
    }
    document.documentElement.style.overflow = 'hidden';
  };
  const thaw = () => {
    frozen.current.forEach(({ el, transform, animation, filter }) => {
      el.style.transform = transform;
      el.style.animation = animation;
      el.style.filter = filter;
    });
    frozen.current = [];
    document.documentElement.style.overflow = '';
  };

  const enterFull = async () => {
    const el = shellRef.current;
    if (!el) return;
    if (document.fullscreenEnabled && el.requestFullscreen) {
      try {
        await el.requestFullscreen();
        setFull('native');
        return;
      } catch {
        /* fall through to the overlay */
      }
    }
    freeze();
    setFull('overlay');
  };

  const exitFull = () => {
    if (full === 'native' && document.fullscreenElement) void document.exitFullscreen();
    if (full === 'overlay') thaw();
    setFull(false);
  };

  // Esc (or the system gesture) leaving native fullscreen must reset our state too.
  useEffect(() => {
    const onChange = () => {
      if (!document.fullscreenElement) setFull((f) => (f === 'native' ? false : f));
    };
    document.addEventListener('fullscreenchange', onChange);
    return () => document.removeEventListener('fullscreenchange', onChange);
  }, []);

  useEffect(() => {
    if (full !== 'overlay') return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') {
        thaw();
        setFull(false);
      }
    };
    document.addEventListener('keydown', onKey);
    return () => document.removeEventListener('keydown', onKey);
  }, [full]);

  useEffect(() => () => thaw(), []);

  return (
    <div ref={shellRef} className={[styles.shell, className].filter(Boolean).join(' ')} data-full={full || undefined}>
    <button
      type="button"
      className={styles.fullBtn}
      onClick={full ? exitFull : enterFull}
      aria-label={full ? 'Exit full screen' : 'Open the app full screen'}
      title={full ? 'Exit full screen (Esc)' : 'Full screen'}
    >
      {full ? (
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M6 6l12 12M18 6L6 18" /></svg>
      ) : (
        <svg viewBox="0 0 24 24" aria-hidden="true"><path d="M4 9V4h5M20 9V4h-5M4 15v5h5M20 15v5h-5" /></svg>
      )}
      <span>{full ? 'Close' : 'Full screen'}</span>
    </button>
    <div className={styles.device} role="group" aria-roledescription="interactive phone" aria-label={label}>
      <div className={styles.screen} data-dark={screen.dark ? 'true' : undefined}>
        {layers.map((layer) => (
          <ScreenLayer
            key={layer.key}
            layer={layer}
            active={layer.role !== 'exit'}
            flash={layer.role !== 'exit' ? flash : 0}
            messages={messages[layer.id] ?? []}
            onAction={run}
            onDeadTap={onDeadTap}
            onSend={(text) => send(layer.id, text)}
          />
        ))}

        <nav className={styles.tabbar} data-hidden={tab ? undefined : 'true'} aria-label="App tabs" inert={!tab}>
          <TabBar current={tab} onPick={(t) => { setTouched(true); goTab(t); }} />
        </nav>

        <span className={styles.island} aria-hidden="true" />

        {toast && (
          <div key={toast.n} className={styles.toast} role="status">
            {toast.text}
          </div>
        )}

        {likes.map((n) => {
          const r = rect(308, 535, 350, 585);
          return (
            <span key={n} className={styles.heart} style={{ left: `${r.left + r.width / 2}%`, top: `${r.top + r.height / 2}%` }} aria-hidden="true">
              ♥
            </span>
          );
        })}

        {coach && !touched && <Coach />}

        <p className="srOnly" aria-live="polite">
          {screen.title}
        </p>
      </div>
      <span className={styles.buttonA} aria-hidden="true" />
      <span className={styles.buttonB} aria-hidden="true" />
      <span className={styles.buttonC} aria-hidden="true" />
    </div>
    </div>
  );
}

// ---- one screen ------------------------------------------------------------

function ScreenLayer({
  layer,
  active,
  flash,
  messages,
  onAction,
  onDeadTap,
  onSend,
}: {
  layer: Layer;
  active: boolean;
  flash: number;
  messages: Message[];
  onAction: (a: Action) => void;
  onDeadTap: () => void;
  onSend: (text: string) => void;
}) {
  const screen = SCREENS[layer.id];
  const image = src(layer.id);

  const anim = layer.role === 'idle' ? undefined : `${layer.via}-${layer.role}${layer.reverse ? '-rev' : ''}`;

  const hotspots = active && (
    <div className={styles.hotspots} data-flash={flash ? 'true' : undefined} key={flash}>
      {screen.hotspots.map((h) => (
        <button
          key={h.label}
          type="button"
          className={styles.hotspot}
          style={{ left: `${h.rect.left}%`, top: `${h.rect.top}%`, width: `${h.rect.width}%`, height: `${h.rect.height}%` }}
          aria-label={h.label}
          onClick={(e) => {
            e.stopPropagation();
            onAction(h.action);
          }}
        />
      ))}
    </div>
  );

  // A sheet is one screenshot doing two jobs: the dimmed parent above, the sheet
  // below. Split it so the dim can fade while the sheet slides.
  if (screen.sheetTop) {
    const cut = pct(screen.sheetTop);
    return (
      <div className={styles.layer} data-anim={anim} data-role={layer.role} onClick={onDeadTap}>
        <img className={styles.sheetDim} src={image} alt="" style={{ clipPath: `inset(0 0 ${100 - cut}% 0)` }} draggable={false} />
        <img className={styles.sheetBody} src={image} alt={screen.title} style={{ clipPath: `inset(${cut}% 0 0 0)` }} draggable={false} />
        {hotspots}
      </div>
    );
  }

  if (screen.chat) {
    return (
      <div className={styles.layer} data-anim={anim} data-role={layer.role} onClick={onDeadTap}>
        <ChatView id={layer.id} image={image} messages={messages} onSend={onSend} active={active} />
        {hotspots}
      </div>
    );
  }

  return (
    <div className={styles.layer} data-anim={anim} data-role={layer.role} onClick={onDeadTap}>
      <img className={styles.shot} src={image} alt={screen.title} draggable={false} />
      {hotspots}
    </div>
  );
}

// ---- a live conversation ---------------------------------------------------

function ChatView({
  id,
  image,
  messages,
  onSend,
  active,
}: {
  id: ScreenId;
  image: string;
  messages: Message[];
  onSend: (text: string) => void;
  active: boolean;
}) {
  const chat = SCREENS[id].chat!;
  const top = pct(chat.top);
  const bottom = pct(chat.bottom);
  const [draft, setDraft] = useState('');
  const listRef = useRef<HTMLDivElement>(null);
  const [lift, setLift] = useState(0);

  // The screenshot's own messages scroll up by exactly the height of the new ones.
  useLayoutEffect(() => {
    const el = listRef.current;
    if (!el) return;
    const measure = () => setLift(el.offsetHeight);
    measure();
    const ro = new ResizeObserver(measure);
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  const submit = (e: FormEvent) => {
    e.preventDefault();
    const text = draft.trim();
    if (!text) return;
    onSend(text);
    setDraft('');
  };

  return (
    <>
      <div className={styles.chatBody} style={{ top: `${top}%`, bottom: `${100 - bottom}%` }}>
        <div className={styles.chatScroll} style={{ transform: `translateY(${-lift}px)` }}>
          <img
            className={styles.chatImage}
            src={image}
            alt=""
            draggable={false}
            style={{
              top: `${(-top / (bottom - top)) * 100}%`,
              height: `${(100 / (bottom - top)) * 100}%`,
              // Only the message rows scroll; the screenshot's own composer must not ride up with them.
              clipPath: `inset(${top}% 0 ${100 - bottom}% 0)`,
            }}
          />
        </div>
        <div ref={listRef} className={styles.messages} aria-live="polite">
          {messages.map((m) =>
            m.side === 'typing' ? (
              <div key={m.key} className={`${styles.bubble} ${styles.received} ${styles.typing}`} aria-label={`${chat.from} is typing`}>
                <i /><i /><i />
              </div>
            ) : (
              <div key={m.key} className={`${styles.bubble} ${m.side === 'sent' ? styles.sent : styles.received}`}>
                <span>{m.text}</span>
                <small>
                  {m.time}
                  {m.side === 'sent' ? ' Seen' : ''}
                </small>
              </div>
            ),
          )}
        </div>
      </div>
      <img className={styles.chatHeader} src={image} alt={SCREENS[id].title} draggable={false} style={{ clipPath: `inset(0 0 ${100 - top}% 0)` }} />
      <img className={styles.chatComposer} src={image} alt="" draggable={false} style={{ clipPath: `inset(${bottom}% 0 0 0)` }} />
      <form className={styles.composer} onSubmit={submit} onClick={(e) => e.stopPropagation()}>
        <input
          className={styles.input}
          value={draft}
          onChange={(e) => setDraft(e.target.value)}
          placeholder="Message"
          aria-label={`Message ${chat.from}`}
          maxLength={120}
          tabIndex={active ? 0 : -1}
          enterKeyHint="send"
          autoComplete="off"
        />
        <button type="submit" className={styles.send} data-ready={draft.trim() ? 'true' : undefined} aria-label="Send" tabIndex={active ? 0 : -1}>
          <svg viewBox="0 0 24 24" aria-hidden="true">
            <path d="M12 19V5M5.5 11.5L12 5l6.5 6.5" fill="none" stroke="currentColor" strokeWidth="2.4" strokeLinecap="round" strokeLinejoin="round" />
          </svg>
        </button>
      </form>
    </>
  );
}

// ---- tab bar ---------------------------------------------------------------

function TabBar({ current, onPick }: { current?: TabId; onPick: (t: TabId) => void }) {
  const rowRef = useRef<HTMLDivElement>(null);

  // Keep the selected tab in view, as the app's scrolling bar does.
  useEffect(() => {
    const row = rowRef.current;
    if (!row || !current) return;
    const el = row.querySelector<HTMLElement>(`[data-tab="${current}"]`);
    if (!el) return;
    const target = el.offsetLeft - (row.clientWidth - el.offsetWidth) / 2;
    row.scrollTo({ left: target, behavior: 'smooth' });
  }, [current]);

  return (
    <div ref={rowRef} className={styles.tabs}>
      {TABS.map((t) => (
        <button
          key={t.id}
          type="button"
          data-tab={t.id}
          className={styles.tab}
          aria-current={current === t.id ? 'page' : undefined}
          onClick={() => onPick(t.id)}
        >
          <span className={styles.tabIcon}>
            <TabIcon tab={t.id} filled={current === t.id} />
          </span>
          <span className={styles.tabLabel}>{t.label}</span>
        </button>
      ))}
    </div>
  );
}

function Coach() {
  const r = rect(136, 150, 232, 245);
  return (
    <span className={styles.coach} style={{ left: `${r.left + r.width / 2}%`, top: `${r.top + r.height / 2}%` }} aria-hidden="true">
      <span className={styles.coachRing} />
      <span className={styles.coachLabel}>Tap to open</span>
    </span>
  );
}
