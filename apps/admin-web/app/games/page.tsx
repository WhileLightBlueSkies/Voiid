'use client';

import { useEffect, useRef, useState } from 'react';
import {
  Check, CircleDot, CircleHelp, Dices, Eye, EyeOff, Gamepad2, Grid3x3, Hand, Megaphone, Power, Ship, Swords,
  Trophy, Users, Volleyball, WholeWord, Worm, AlertTriangle,
} from 'lucide-react';
import type { LucideIcon } from 'lucide-react';
import Shell, { type Me } from '../../components/Shell';
import { PageHeader, Async } from '../../components/ui';
import { ConfirmDialog } from '../../components/ui/dialog';
import { api } from '../../lib/api';

/**
 * Game release control.
 *
 * ── WHAT THIS PAGE IS FOR ────────────────────────────────────────────────────────
 * Native game code cannot be delivered out of band on iOS (App Store Guideline 2.5.2), so
 * every game ships inside the app and this page decides which of them a build may see. A
 * game is written, released hidden, polished, and turned on from here — no App Store
 * submission, no review, and reversible in one click if it goes wrong.
 *
 * ── THE TWO FIELDS THAT ARE EASY TO CONFUSE ──────────────────────────────────────
 * They answer different questions and the copy on this page says so, because getting them
 * the wrong way round is the one mistake that reaches users:
 *
 *   Min app version — WHICH BUILD may play this. A quality gate, not a presence gate: it is
 *     the version where the game became good enough to show, which is often later than the
 *     version its code first shipped in. Users below it see "Update to play", including
 *     users who already have the game sitting unused in their binary.
 *
 *   Game version — WHICH ITERATION this is. Descriptive only, never gated on. Games iterate
 *     on their own clock — Snake can have four visual passes while the app ships twice — and
 *     this is what makes a bug report legible.
 *
 * ── WHAT ASKS FIRST ──────────────────────────────────────────────────────────────
 * Anything that takes a PLAYABLE game away from people — the emergency pull, or moving a
 * live game back to hidden or announced — goes through a confirmation. Everything else
 * applies on the spot, because it is reversible from the same control.
 */

type ReleaseState = 'hidden' | 'announced' | 'live';

type Game = {
  id: string; slug: string; name: string; category: string;
  icon_key?: string | null;
  enabled: boolean;
  release_state: ReleaseState;
  min_app: string | null;
  teaser: string | null;
  game_version: string;
  min_players: number; max_players: number;
};

type Stats = { game_lobbies?: number; game_lobbies_24h?: number; tournaments?: number };

type Filter = 'all' | ReleaseState | 'pulled';

const STATES: { value: ReleaseState; label: string; icon: LucideIcon; help: string }[] = [
  { value: 'hidden', label: 'Hidden', icon: EyeOff, help: 'Not on the shelf. Nobody sees it.' },
  { value: 'announced', label: 'Announced', icon: Megaphone, help: 'A teaser: shown dimmed and not tappable. For games with no code shipped yet.' },
  { value: 'live', label: 'Live', icon: Eye, help: 'Playable, subject to the minimum app version.' },
];

/** The shelf art lives in the apps; the panel only needs a recognisable mark per game. */
const ICONS: Record<string, LucideIcon> = {
  snake: Worm, tictactoe: Grid3x3, rps: Hand, cricket: Volleyball,
  seabattle: Ship, ludo: Dices, carrom: CircleDot, word: WholeWord, quiz: CircleHelp,
};

const SEMVER = /^[0-9]+\.[0-9]+\.[0-9]+$/;

export default function Games() {
  return <Shell>{(me) => <Body me={me} />}</Shell>;
}

function Body({ me }: { me: Me }) {
  const [games, setGames] = useState<Game[] | null>(null);
  const [stats, setStats] = useState<Stats | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [writeError, setWriteError] = useState<string | null>(null);
  const [filter, setFilter] = useState<Filter>('all');
  const [confirm, setConfirm] = useState<{
    slug: string; body: Record<string, unknown>; title: string; text: string; label: string;
  } | null>(null);

  const readOnly = me.role !== 'admin';

  async function load() {
    setLoading(true);
    setError(null);
    try {
      const r = await api<{ games: Game[] }>('/games');
      setGames(r.games);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'could not load games');
    } finally {
      setLoading(false);
    }
  }

  useEffect(() => {
    void load();
    // Activity is context, not the page's job: a failure here leaves the summary blank
    // rather than blocking the release controls.
    api<Stats>('/stats').then(setStats).catch(() => setStats(null));
  }, []);

  /**
   * One field at a time. The endpoint writes only what it is sent, so two people editing
   * different games — or different fields of one game — cannot overwrite each other with a
   * stale row fetched before the other's change. Resolves true when the server accepted it.
   */
  async function patch(slug: string, body: Record<string, unknown>): Promise<boolean> {
    setBusy(slug);
    setWriteError(null);
    try {
      const r = await api<{ game: Game }>(`/games/${slug}`, { method: 'PATCH', json: body });
      setGames((gs) => (gs ?? []).map((g) => (g.slug === slug ? { ...g, ...r.game } : g)));
      return true;
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'could not save that change');
      // Re-read on failure: the local row may now disagree with the server, and a panel
      // showing a state that was rejected is worse than a moment of loading.
      void load();
      return false;
    } finally {
      setBusy(null);
    }
  }

  /** Routes a change through the confirmation when it takes a playable game away. */
  function change(game: Game, body: Record<string, unknown>) {
    const playable = game.enabled && game.release_state === 'live';
    if (playable && body.enabled === false) {
      setConfirm({
        slug: game.slug, body, label: `Pull ${game.name}`,
        title: `Pull ${game.name} from every build?`,
        text: 'It disappears from the games shelf immediately, for everyone, whatever its release state. Matches already running are not ended. You can switch it back on from here.',
      });
      return;
    }
    if (playable && body.release_state && body.release_state !== 'live') {
      const to = STATES.find((s) => s.value === body.release_state)!;
      setConfirm({
        slug: game.slug, body, label: `Move to ${to.label.toLowerCase()}`,
        title: `Take ${game.name} out of live?`,
        text: `${to.help} People who play it today will no longer be able to start a game.`,
      });
      return;
    }
    return patch(game.slug, body);
  }

  const all = games ?? [];
  const count = (f: Filter) => all.filter((g) => matches(g, f)).length;
  const shown = all.filter((g) => matches(g, filter));

  return (
    <>
      <PageHeader
        title="Games"
        subtitle="Every game ships inside the app. This page decides which builds may see it."
      />

      {/* ── Summary ─────────────────────────────────────────────────────────────── */}
      <div className="mb-5 grid gap-3 sm:grid-cols-2 xl:grid-cols-5">
        <Tile label="Live" value={games ? count('live') : null} icon={Eye} tone="live" />
        <Tile label="Announced" value={games ? count('announced') : null} icon={Megaphone} />
        <Tile label="Hidden" value={games ? count('hidden') : null} icon={EyeOff} />
        <Tile
          label="Lobbies"
          value={stats?.game_lobbies ?? null}
          sub={stats ? `+${(stats.game_lobbies_24h ?? 0).toLocaleString()} in 24h` : undefined}
          icon={Swords}
        />
        <Tile label="Tournaments" value={stats?.tournaments ?? null} icon={Trophy} />
      </div>

      {readOnly && (
        <div className="notice info mb-4 flex items-center gap-2.5">
          <EyeOff size={15} className="shrink-0" />
          You have the moderator role, so this page is read-only. Changing a release needs the admin role.
        </div>
      )}
      {writeError && (
        <div className="notice error mb-4 flex items-center gap-2.5" role="alert">
          <AlertTriangle size={15} className="shrink-0" />
          {writeError}
        </div>
      )}

      {/* ── Filter ──────────────────────────────────────────────────────────────── */}
      <div className="mb-4 flex flex-wrap gap-2" role="tablist" aria-label="Filter games">
        {(['all', 'live', 'announced', 'hidden', 'pulled'] as Filter[]).map((f) => (
          <button
            key={f}
            role="tab"
            aria-selected={filter === f}
            onClick={() => setFilter(f)}
            className={[
              'inline-flex h-9 items-center gap-2 rounded-full px-4 text-sm font-semibold',
              filter === f
                ? 'bg-[var(--accent)] text-white hover:bg-[var(--accent)]'
                : 'bg-card text-[var(--text-dim)] shadow-[var(--shadow-1)] ring-1 ring-[var(--border)] hover:bg-card hover:text-[var(--text)]',
            ].join(' ')}
          >
            {f === 'all' ? 'All' : f === 'pulled' ? 'Pulled' : STATES.find((s) => s.value === f)!.label}
            {games && (
              <span className={`num tabular text-tiny ${filter === f ? 'text-white/60' : 'text-[var(--text-mute)]'}`}>
                {count(f)}
              </span>
            )}
          </button>
        ))}
      </div>

      <Async loading={loading && !games} error={error} empty={all.length === 0}
             emptyText="No games in the catalog.">
        {shown.length === 0 ? (
          <div className="empty rounded-[22px] bg-card">No game matches this filter.</div>
        ) : (
          <div className="grid gap-4 xl:grid-cols-2">
            {shown.map((g) => (
              <GameCard key={g.slug} game={g} readOnly={readOnly}
                        busy={busy === g.slug} onChange={change} />
            ))}
          </div>
        )}
      </Async>

      <ConfirmDialog
        open={confirm !== null}
        title={confirm?.title ?? ''}
        body={confirm?.text}
        confirmLabel={confirm?.label ?? ''}
        destructive
        busy={confirm ? busy === confirm.slug : false}
        onCancel={() => setConfirm(null)}
        onConfirm={async () => {
          if (!confirm) return;
          await patch(confirm.slug, confirm.body);
          setConfirm(null);
        }}
      />
    </>
  );
}

function matches(g: Game, f: Filter): boolean {
  if (f === 'all') return true;
  if (f === 'pulled') return !g.enabled;
  return g.enabled && g.release_state === f;
}

function Tile({ label, value, sub, icon: Icon, tone }: {
  label: string; value: number | null; sub?: string; icon: LucideIcon; tone?: 'live';
}) {
  return (
    <div className="flex items-center gap-3.5 rounded-[22px] bg-card p-4 shadow-[var(--shadow-1)] ring-1 ring-black/[0.04]">
      <span className={`grid h-11 w-11 shrink-0 place-items-center rounded-full ${
        tone === 'live' ? 'bg-[var(--tide-light)] text-[var(--text)]' : 'bg-[var(--surface-2)] text-[var(--text)]'
      }`}>
        <Icon size={18} strokeWidth={2.1} />
      </span>
      <div className="min-w-0 leading-tight">
        <div className="num text-[26px] font-normal !tracking-[-0.035em]">
          {value === null ? '—' : value.toLocaleString()}
        </div>
        <div className="truncate text-tiny text-[var(--text-mute)]">{label}</div>
        {sub && <div className="num truncate text-micro text-[var(--accent-ink)]">{sub}</div>}
      </div>
    </div>
  );
}

function GameCard({ game, readOnly, busy, onChange }: {
  game: Game;
  readOnly: boolean;
  busy: boolean;
  onChange: (game: Game, body: Record<string, unknown>) => Promise<boolean> | void;
}) {
  const Icon = ICONS[game.slug] ?? Gamepad2;
  const pulled = !game.enabled;
  const state = STATES.find((s) => s.value === game.release_state)!;
  const disabled = readOnly || busy;
  const players = game.min_players === game.max_players
    ? `${game.max_players} player${game.max_players === 1 ? '' : 's'}`
    : `${game.min_players}–${game.max_players} players`;

  const commit = (body: Record<string, unknown>) => Promise.resolve(onChange(game, body)).then((ok) => ok !== false);

  return (
    <article
      aria-busy={busy}
      className={`flex flex-col rounded-[22px] bg-card p-5 shadow-[var(--shadow-1)] ring-1 transition-opacity ${
        pulled ? 'ring-[rgba(217,58,58,0.25)]' : 'ring-black/[0.04]'
      } ${busy ? 'opacity-70' : ''}`}
    >
      {/* ── Identity ── */}
      <header className="flex items-start gap-3.5">
        <span className={`grid h-12 w-12 shrink-0 place-items-center rounded-[16px] ${
          pulled ? 'bg-[var(--surface-2)] text-[var(--text-mute)]' : 'bg-[var(--accent)] text-white'
        }`}>
          <Icon size={22} strokeWidth={2} />
        </span>
        <div className="min-w-0 flex-1">
          <div className="flex flex-wrap items-center gap-2">
            <h2 className="text-[17px] font-semibold">{game.name}</h2>
            <StatusBadge game={game} />
          </div>
          <div className="mt-1 flex flex-wrap items-center gap-x-3 gap-y-1 text-tiny text-[var(--text-mute)]">
            <span className="mono">{game.slug}</span>
            <span className="capitalize">{game.category}</span>
            <span className="inline-flex items-center gap-1"><Users size={12} />{players}</span>
            <span className="num tabular">v{game.game_version}</span>
          </div>
        </div>
      </header>

      {/* ── Release state ── */}
      <div className="mt-5">
        <div className="mb-2 text-tiny font-semibold text-[var(--text-dim)]">Release</div>
        <div role="radiogroup" aria-label={`${game.name} release state`}
             className="grid grid-cols-3 gap-1 rounded-full bg-[var(--surface-2)] p-1">
          {STATES.map((s) => {
            const on = game.release_state === s.value;
            return (
              <button
                key={s.value}
                role="radio"
                aria-checked={on}
                disabled={disabled || on}
                onClick={() => onChange(game, { release_state: s.value })}
                title={s.help}
                className={[
                  'inline-flex h-9 items-center justify-center gap-1.5 rounded-full px-2 text-sm font-semibold transition-colors',
                  'disabled:cursor-default disabled:opacity-100',
                  on
                    ? 'bg-[var(--accent)] text-white shadow-[var(--shadow-1)] hover:bg-[var(--accent)]'
                    : 'bg-transparent text-[var(--text-dim)] hover:bg-card hover:text-[var(--text)]',
                  !on && disabled ? 'opacity-50' : '',
                ].join(' ')}
              >
                <s.icon size={14} className={on && s.value === 'live' ? 'text-white' : ''} />
                {s.label}
              </button>
            );
          })}
        </div>
        <p className="m-0 mt-2 text-tiny text-[var(--text-mute)]">
          {pulled ? 'Pulled — hidden from every build regardless of this setting.' : state.help}
        </p>
      </div>

      {/* ── Versions and teaser ── */}
      <div className="mt-4 grid gap-3 sm:grid-cols-2">
        <Field
          label="Min app version"
          hint="Builds below this see “Update to play”. Blank = any build that has the game."
          value={game.min_app ?? ''}
          placeholder="1.6.0"
          disabled={disabled}
          validate={(v) => (v === '' || SEMVER.test(v) ? null : 'Use X.Y.Z, e.g. 1.6.0 — or leave blank')}
          onCommit={(v) => commit({ min_app: v === '' ? null : v })}
        />
        <Field
          label="Game version"
          hint="This game’s own iteration. Never gates anything; it tells you what is live."
          value={game.game_version}
          placeholder="1.0.0"
          disabled={disabled}
          validate={(v) => (SEMVER.test(v) ? null : 'Use X.Y.Z, e.g. 1.2.0')}
          onCommit={(v) => commit({ game_version: v })}
        />
        <div className="sm:col-span-2">
          <Field
            label="Teaser"
            hint={game.release_state === 'announced'
              ? 'Shown under the dimmed card. “Coming in October” beats an undated card.'
              : 'Only shown while the game is announced.'}
            value={game.teaser ?? ''}
            placeholder="Coming soon"
            maxLength={120}
            disabled={disabled}
            validate={(v) => (v.length <= 120 ? null : '120 characters at most')}
            onCommit={(v) => commit({ teaser: v === '' ? null : v })}
          />
        </div>
      </div>

      {/* ── Emergency pull ── */}
      <div className={`mt-4 flex items-center gap-3 rounded-[16px] p-3.5 ${
        pulled ? 'bg-[rgba(217,58,58,0.07)]' : 'bg-[var(--surface-2)]'
      }`}>
        <Power size={16} className={pulled ? 'text-[var(--danger)]' : 'text-[var(--text-dim)]'} />
        <div className="min-w-0 flex-1 leading-snug">
          <div className="text-sm font-semibold">{pulled ? 'Pulled from every build' : 'Available'}</div>
          <div className="text-micro text-[var(--text-mute)]">
            The emergency pull. Off hides this game everywhere, whatever the release state.
          </div>
        </div>
        <Switch
          checked={game.enabled}
          disabled={disabled}
          label={`${game.name} available`}
          onChange={(v) => onChange(game, { enabled: v })}
        />
      </div>
    </article>
  );
}

function StatusBadge({ game }: { game: Game }) {
  const [text, cls, dot] = !game.enabled
    ? ['Pulled', 'bg-[rgba(217,58,58,0.09)] text-[var(--danger)]', 'bg-[var(--danger)]']
    : game.release_state === 'live'
      ? ['Live', 'bg-[var(--tide-soft)] text-[var(--accent-ink)]', 'bg-[var(--tide)]']
      : game.release_state === 'announced'
        ? ['Announced', 'bg-[rgba(185,132,7,0.1)] text-[var(--warning)]', 'bg-[var(--warning)]']
        : ['Hidden', 'bg-[var(--surface-2)] text-[var(--text-dim)]', 'bg-[var(--text-mute)]'];
  return (
    <span className={`inline-flex items-center gap-1.5 rounded-full px-2.5 py-0.5 text-tiny font-semibold ${cls}`}>
      <span aria-hidden className={`h-1.5 w-1.5 rounded-full ${dot}`} />
      {text}
      {game.enabled && game.release_state === 'live' && game.min_app && (
        <span className="num font-medium opacity-70">· {game.min_app}+</span>
      )}
    </span>
  );
}

/**
 * A text field that saves on blur or Enter, never per keystroke. It validates BEFORE the
 * request — the server checks too, but an operator should learn "1.6" is not a version from
 * the field, not from a round trip — and says "Saved" briefly once the server has it.
 * Escape puts the saved value back.
 */
function Field({ label, hint, value, placeholder, disabled, validate, onCommit, maxLength }: {
  label: string; hint: string; value: string; placeholder: string; disabled: boolean;
  validate: (v: string) => string | null;
  onCommit: (v: string) => Promise<boolean>;
  maxLength?: number;
}) {
  const [draft, setDraft] = useState(value);
  const [saved, setSaved] = useState(false);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);
  useEffect(() => { setDraft(value); }, [value]);
  useEffect(() => () => { if (timer.current) clearTimeout(timer.current); }, []);

  const next = draft.trim();
  const error = next === value ? null : validate(next);

  async function commit() {
    if (next === value || error) return;
    if (await onCommit(next)) {
      setSaved(true);
      if (timer.current) clearTimeout(timer.current);
      timer.current = setTimeout(() => setSaved(false), 1800);
    }
  }

  return (
    <label className="block">
      <span className="mb-1.5 flex items-center gap-2 text-tiny font-semibold text-[var(--text-dim)]">
        {label}
        {saved && (
          <span className="inline-flex items-center gap-1 font-medium text-[var(--accent-ink)] animate-in fade-in-0">
            <Check size={12} strokeWidth={3} /> Saved
          </span>
        )}
      </span>
      <input
        value={draft}
        placeholder={placeholder}
        disabled={disabled}
        maxLength={maxLength}
        aria-invalid={!!error}
        onChange={(e) => setDraft(e.target.value)}
        onBlur={() => void commit()}
        onKeyDown={(e) => {
          if (e.key === 'Enter') void commit();
          if (e.key === 'Escape') setDraft(value);
        }}
        className={`h-10 text-sm disabled:opacity-60 ${error ? '!border-[var(--danger)] focus:!shadow-[0_0_0_4px_rgba(217,58,58,0.12)]' : ''}`}
      />
      <span className={`mt-1 block text-micro ${error ? 'text-[var(--danger)]' : 'text-[var(--text-mute)]'}`}>
        {error ?? hint}
      </span>
    </label>
  );
}

function Switch({ checked, disabled, label, onChange }: {
  checked: boolean; disabled: boolean; label: string; onChange: (v: boolean) => void;
}) {
  return (
    <button
      role="switch"
      aria-checked={checked}
      aria-label={label}
      disabled={disabled}
      onClick={() => onChange(!checked)}
      className={[
        'relative h-7 w-12 shrink-0 rounded-full p-0 transition-colors duration-200',
        checked ? 'bg-[var(--tide)] hover:bg-[var(--tide)]' : 'bg-[var(--border-strong)] hover:bg-[var(--border-strong)]',
      ].join(' ')}
    >
      <span
        aria-hidden
        className="absolute top-1 h-5 w-5 rounded-full bg-white shadow-[0_1px_3px_rgba(0,0,0,0.2)] transition-[left] duration-200"
        style={{ left: checked ? 26 : 4 }}
      />
    </button>
  );
}
