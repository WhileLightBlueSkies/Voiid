'use client';

import { useState } from 'react';
import Shell, { type Me } from '../../components/Shell';
import { PageHeader, Pill, when, name } from '../../components/ui';
import { ListTable } from '../../components/List';
import { useList } from '../../components/useList';
import { api } from '../../lib/api';

type Clip = {
  id: string; caption: string | null; created_at: string;
  removed_at: string | null; removed_reason: string | null;
  like_count: number; view_count: number; comment_count: number;
  duration_ms: number | null;
  author_name: string | null; author_username: string | null;
};

export default function Clips() {
  return <Shell>{(me) => <Body me={me} />}</Shell>;
}

function Body({ me }: { me: Me }) {
  const [removed, setRemoved] = useState(false);
  const list = useList<Clip>('/clips', 'clips', { removed: String(removed) });
  const [busy, setBusy] = useState<string | null>(null);
  const [writeError, setWriteError] = useState<string | null>(null);
  /// The clip being watched. A moderator deciding on a takedown has to SEE the thing —
  /// judging a video from its caption is not moderation. Held in state rather than opened in
  /// a tab so the presigned URL never lands in browser history.
  const [playing, setPlaying] = useState<{ id: string; url: string } | null>(null);

  async function watch(id: string) {
    setBusy(id);
    setWriteError(null);
    try {
      const r = await api<{ url: string }>(`/clips/${id}/playback`);
      setPlaying({ id, url: r.url });
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'could not load that clip');
    } finally {
      setBusy(null);
    }
  }

  async function destroy(id: string) {
    // DELETE is not remove. Remove hides a clip and is reversible; this erases the object
    // from storage and cannot be undone, so it asks — and says which of the two it is.
    if (!window.confirm(
      'Permanently delete this clip and its file? Removal is reversible; this is not.',
    )) return;
    setBusy(id);
    setWriteError(null);
    try {
      await api(`/clips/${id}`, { method: 'DELETE' });
      setPlaying(null);
      await list.reload();
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'that did not go through');
    } finally {
      setBusy(null);
    }
  }

  async function act(id: string, path: string, body?: unknown) {
    setBusy(id);
    setWriteError(null);
    try {
      await api(path, { method: 'POST', json: body ?? {} });
      await list.reload();
    } catch (e) {
      setWriteError(e instanceof Error ? e.message : 'that did not go through');
    } finally {
      setBusy(null);
    }
  }

  return (
    <>
      <PageHeader
        title="Clips"
        subtitle="Public short video. Removal is reversible and destroys nothing."
        right={
          <button className="ghost" onClick={() => setRemoved((r) => !r)}>
            {removed ? 'Show live' : 'Show removed'}
          </button>
        }
      />

      {writeError && <div className="notice error" style={{ marginBottom: 16 }}>{writeError}</div>}

      <ListTable
        head={['Clip', 'Author', 'Views', 'Likes', 'Posted', '']}
        loading={list.loading}
        error={list.error}
        empty={list.rows.length === 0}
        emptyText={removed ? 'Nothing has been removed.' : 'No clips yet.'}
        cursor={list.cursor}
        onMore={list.more}
      >
        {list.rows.map((c) => (
          <tr key={c.id}>
            <td style={{ maxWidth: 320 }}>
              <div style={{ overflow: 'hidden', textOverflow: 'ellipsis', whiteSpace: 'nowrap' }}>
                {c.caption || <span className="mute">No caption</span>}
              </div>
              {c.removed_at && (
                <div style={{ marginTop: 4 }}>
                  <Pill tone="danger">Removed</Pill>
                  {c.removed_reason && <span className="mute" style={{ fontSize: 12, marginLeft: 6 }}>{c.removed_reason}</span>}
                </div>
              )}
            </td>
            <td className="muted">{name(c.author_name, c.author_username)}</td>
            <td className="mono">{c.view_count}</td>
            <td className="mono">{c.like_count}</td>
            <td className="muted" style={{ fontSize: 13, whiteSpace: 'nowrap' }}>{when(c.created_at)}</td>
            <td style={{ textAlign: 'right', whiteSpace: 'nowrap' }}>
              <button className="ghost sm" disabled={busy === c.id}
                      onClick={() => void watch(c.id)} style={{ marginRight: 6 }}>
                Watch
              </button>
              {c.removed_at ? (
                <button
                  className="ghost sm" disabled={busy === c.id}
                  onClick={() => void act(c.id, `/clips/${c.id}/restore`)}
                >
                  Restore
                </button>
              ) : (
                <button
                  className="danger sm" disabled={busy === c.id}
                  onClick={() => {
                    // The reason is required by the route and is the only record of WHY a
                    // takedown happened, so it is asked for before the call, not after.
                    const reason = window.prompt('Why is this clip being removed?')?.trim();
                    if (reason) void act(c.id, `/clips/${c.id}/remove`, { reason });
                  }}
                >
                  Remove
                </button>
              )}
            </td>
          </tr>
        ))}
      </ListTable>

      {playing && (
        <div
          onClick={() => setPlaying(null)}
          style={{
            position: 'fixed', inset: 0, zIndex: 50,
            background: 'rgba(0,0,0,0.72)',
            display: 'grid', placeItems: 'center', padding: 24,
          }}
        >
          <div onClick={(e) => e.stopPropagation()}
               style={{ display: 'grid', gap: 12, justifyItems: 'center' }}>
            {/* eslint-disable-next-line jsx-a11y/media-has-caption */}
            <video
              src={playing.url}
              controls
              autoPlay
              style={{ maxWidth: '80vw', maxHeight: '70vh', borderRadius: 'var(--radius-lg)' }}
            />
            <div className="row" style={{ gap: 8 }}>
              <button className="ghost" onClick={() => setPlaying(null)}>Close</button>
              {/* Deletion lives HERE and nowhere else: an irreversible action should not be
                  reachable from a list row, where it sits one mis-click from Remove. */}
              {me.role === 'admin' && (
                <button className="danger" disabled={busy === playing.id}
                        onClick={() => void destroy(playing.id)}>
                  Delete permanently
                </button>
              )}
            </div>
          </div>
        </div>
      )}
    </>
  );
}
