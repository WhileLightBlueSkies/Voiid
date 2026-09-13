'use client';

import { useEffect, useState } from 'react';
import Shell, { type Me } from '../../components/Shell';
import { PageHeader, Pill, Async } from '../../components/ui';
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
 */

type Game = {
  id: string; slug: string; name: string; category: string;
  enabled: boolean;
  release_state: 'hidden' | 'announced' | 'live';
  min_app: string | null;
  teaser: string | null;
  game_version: string;
  min_players: number; max_players: number;
};

const STATES: Game['release_state'][] = ['hidden', 'announced', 'live'];

const STATE_HELP: Record<Game['release_state'], string> = {
  hidden: 'Not on the shelf. Nobody sees it.',
  announced: 'A teaser: shown dimmed and not tappable. Use for games with no code shipped yet.',
  live: 'Playable, subject to the minimum app version below.',
};

export default function Games() {
  return <Shell>{(me) => <Body me={me} />}</Shell>;
}

function Body({ me }: { me: Me }) {
  const [games, setGames] = useState<Game[] | null>(null);
  const [loading, setLoading] = useState(true);
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState<string | null>(null);
  const [writeError, setWriteError] = useState<string | null>(null);

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

  useEffect(() => { void load(); }, []);

  /**
   * One field at a time. The endpoint writes only what it is sent, so two people editing
   * different games — or different fields of one game — cannot overwrite each other with a
   * stale row fetched before the other's change.
   */
  async function patch(slug: string, body: Record<string, unknown>) {
    setBusy(slug);
    setWriteError(null);
    try {
      const r = await api<{ game: Game }>(`/games/${slug}`, { method: 'PATCH', json: body });
      setGames((gs) => (gs ?? []).map((g) => (g.slug === slug ? { ...g, ...r.game } : g)));
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'could not save that change');
      // Re-read on failure: the local row may now disagree with the server, and a panel
      // showing a state that was rejected is worse than a moment of loading.
      void load();
    } finally {
      setBusy(null);
    }
  }

  return (
    <>
      <PageHeader
        title="Games"
        subtitle="Every game ships inside the app. This page decides which builds may see it."
      />

      {readOnly && (
        <p style={{ color: 'var(--text-dim)', fontSize: 13, marginBottom: 16 }}>
          You have the moderator role — this page is read-only. Changing a game&rsquo;s release
          state requires the admin role.
        </p>
      )}
      {writeError && (
        <p style={{ color: 'var(--danger)', fontSize: 13, marginBottom: 16 }}>{writeError}</p>
      )}

      <Async loading={loading} error={error} empty={(games?.length ?? 0) === 0}
             emptyText="No games in the catalog.">
        <div style={{ display: 'grid', gap: 12 }}>
          {(games ?? []).map((g) => (
            <GameCard key={g.slug} game={g} readOnly={readOnly}
                      busy={busy === g.slug} onPatch={patch} />
          ))}
        </div>
      </Async>
    </>
  );
}

function GameCard({ game, readOnly, busy, onPatch }: {
  game: Game;
  readOnly: boolean;
  busy: boolean;
  onPatch: (slug: string, body: Record<string, unknown>) => void;
}) {
  // Local echoes of the two text fields, so typing does not fire a request per keystroke.
  // Committed on blur or Enter.
  const [minApp, setMinApp] = useState(game.min_app ?? '');
  const [gameVersion, setGameVersion] = useState(game.game_version);
  const [teaser, setTeaser] = useState(game.teaser ?? '');

  useEffect(() => { setMinApp(game.min_app ?? ''); }, [game.min_app]);
  useEffect(() => { setGameVersion(game.game_version); }, [game.game_version]);
  useEffect(() => { setTeaser(game.teaser ?? ''); }, [game.teaser]);

  const tone: 'ok' | 'danger' | 'warning' | undefined =
    !game.enabled ? 'danger'
    : game.release_state === 'live' ? 'ok'
    : game.release_state === 'announced' ? 'warning' : undefined;

  return (
    <div style={{
      border: '1px solid var(--border)', borderRadius: 14, padding: 16,
      background: 'var(--surface)', opacity: busy ? 0.6 : 1,
    }}>
      <div style={{ display: 'flex', alignItems: 'baseline', gap: 10, flexWrap: 'wrap' }}>
        <strong style={{ fontSize: 16 }}>{game.name}</strong>
        <span style={{ color: 'var(--text-mute)', fontSize: 12 }}>{game.slug}</span>
        <Pill tone={tone}>{game.enabled ? game.release_state : 'disabled'}</Pill>
        <span style={{ color: 'var(--text-dim)', fontSize: 12 }}>v{game.game_version}</span>
      </div>

      <div style={{ display: 'flex', gap: 8, marginTop: 14, flexWrap: 'wrap' }}>
        {STATES.map((s) => (
          <button
            key={s}
            disabled={readOnly || busy || game.release_state === s}
            onClick={() => onPatch(game.slug, { release_state: s })}
            title={STATE_HELP[s]}
            style={{
              padding: '7px 14px', borderRadius: 999, fontSize: 13,
              border: '1px solid ' + (game.release_state === s ? 'var(--accent)' : 'var(--border)'),
              background: game.release_state === s ? 'var(--accent)' : 'transparent',
              color: game.release_state === s ? '#fff' : 'var(--text-dim)',
              cursor: readOnly || busy ? 'default' : 'pointer',
            }}
          >
            {s}
          </button>
        ))}
      </div>
      <p style={{ color: 'var(--text-mute)', fontSize: 12, marginTop: 8 }}>
        {STATE_HELP[game.release_state]}
      </p>

      <div style={{ display: 'grid', gap: 12, marginTop: 14,
                    gridTemplateColumns: 'repeat(auto-fit, minmax(190px, 1fr))' }}>
        <Field
          label="Min app version"
          hint="Builds below this see “Update to play”. Blank = any build that has the game."
          value={minApp}
          placeholder="1.6.0"
          disabled={readOnly || busy}
          onChange={setMinApp}
          onCommit={() => {
            const next = minApp.trim();
            if (next === (game.min_app ?? '')) return;
            onPatch(game.slug, { min_app: next === '' ? null : next });
          }}
        />
        <Field
          label="Game version"
          hint="This game’s own iteration. Never gates anything — it tells you what is live."
          value={gameVersion}
          placeholder="1.0.0"
          disabled={readOnly || busy}
          onChange={setGameVersion}
          onCommit={() => {
            const next = gameVersion.trim();
            if (next === game.game_version || next === '') return;
            onPatch(game.slug, { game_version: next });
          }}
        />
        <Field
          label="Teaser"
          hint="Shown under an announced game. “Coming in October” beats an undated card."
          value={teaser}
          placeholder="Coming soon"
          disabled={readOnly || busy}
          onChange={setTeaser}
          onCommit={() => {
            const next = teaser.trim();
            if (next === (game.teaser ?? '')) return;
            onPatch(game.slug, { teaser: next === '' ? null : next });
          }}
        />
      </div>

      <label style={{ display: 'flex', alignItems: 'center', gap: 8, marginTop: 14,
                      fontSize: 13, color: 'var(--text-dim)' }}>
        <input
          type="checkbox"
          checked={game.enabled}
          disabled={readOnly || busy}
          onChange={(e) => onPatch(game.slug, { enabled: e.target.checked })}
        />
        Enabled — the emergency pull. Unchecking hides this game from every build regardless
        of the state above.
      </label>
    </div>
  );
}

function Field({ label, hint, value, placeholder, disabled, onChange, onCommit }: {
  label: string; hint: string; value: string; placeholder: string;
  disabled: boolean; onChange: (v: string) => void; onCommit: () => void;
}) {
  return (
    <div>
      <label style={{ display: 'block', fontSize: 12, color: 'var(--text-dim)', marginBottom: 4 }}>
        {label}
      </label>
      <input
        value={value}
        placeholder={placeholder}
        disabled={disabled}
        onChange={(e) => onChange(e.target.value)}
        onBlur={onCommit}
        onKeyDown={(e) => { if (e.key === 'Enter') onCommit(); }}
        style={{
          width: '100%', padding: '8px 10px', borderRadius: 8,
          border: '1px solid var(--border)', background: 'var(--surface-2)', color: 'var(--text)',
          fontSize: 13,
        }}
      />
      <p style={{ color: 'var(--text-mute)', fontSize: 11, marginTop: 4 }}>{hint}</p>
    </div>
  );
}
