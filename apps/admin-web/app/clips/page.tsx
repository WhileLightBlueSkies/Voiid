'use client';

import { useState } from 'react';
import Shell, { type Me } from '../../components/Shell';
import { PageHeader, Pill, when, name } from '../../components/ui';
import { ListTable } from '../../components/List';
import { useList } from '../../components/useList';
import { api } from '../../lib/api';
import { Button } from '../../components/ui/button';
import { PromptDialog, ConfirmDialog } from '../../components/ui/dialog';

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

  // Which clip each dialog is about, or null when closed. Keyed by id rather than a
  // boolean so the dialog cannot outlive the row it was opened from.
  const [removing, setRemoving] = useState<string | null>(null);
  const [deleting, setDeleting] = useState<string | null>(null);

  async function destroy(id: string) {
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
                <Button variant="destructive" size="sm" disabled={busy === c.id}
                        onClick={() => setRemoving(c.id)}>
                  Remove
                </Button>
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
              <Button variant="ghost" onClick={() => setPlaying(null)}>Close</Button>
              {/* Deletion lives HERE and nowhere else: an irreversible action should not be
                  reachable from a list row, where it sits one mis-click from Remove. */}
              {me.role === 'admin' && (
                <Button variant="destructive" disabled={busy === playing.id}
                        onClick={() => setDeleting(playing.id)}>
                  Delete permanently
                </Button>
              )}
            </div>
          </div>
        </div>
      )}

      <PromptDialog
        open={removing !== null}
        title="Remove this clip?"
        body="It stops being visible to anyone. This is reversible — the file is kept and the clip can be restored."
        label="Why it is being removed"
        placeholder="The rule it breaks, in a sentence."
        confirmLabel="Remove clip"
        destructive
        busy={busy === removing}
        onCancel={() => setRemoving(null)}
        onConfirm={(reason) => {
          const id = removing;
          setRemoving(null);
          if (id) void act(id, `/clips/${id}/remove`, { reason });
        }}
      />

      <ConfirmDialog
        open={deleting !== null}
        title="Delete permanently?"
        body="This erases the clip and its file from storage. Removal is reversible; this is not."
        confirmLabel="Delete permanently"
        destructive
        busy={busy === deleting}
        onCancel={() => setDeleting(null)}
        onConfirm={() => {
          const id = deleting;
          setDeleting(null);
          if (id) void destroy(id);
        }}
      />
    </>
  );
}
