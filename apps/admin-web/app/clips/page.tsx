'use client';

import { useCallback, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import Link from 'next/link';
import { api, getToken } from '@/lib/api';

interface Clip {
  id: string;
  author_id: string;
  author_name: string | null;
  author_username: string | null;
  caption: string | null;
  thumb_url: string | null;
  duration_ms: number | null;
  like_count: number;
  view_count: number;
  comment_count: number;
  created_at: string;
  removed_at: string | null;
  removed_reason: string | null;
}

export default function ClipsPage() {
  const router = useRouter();
  const [clips, setClips] = useState<Clip[]>([]);
  const [cursor, setCursor] = useState<string | null>(null);
  const [showRemoved, setShowRemoved] = useState(false);
  const [loading, setLoading] = useState(true);
  const [playing, setPlaying] = useState<string | null>(null);

  const load = useCallback(async (reset: boolean) => {
    setLoading(true);
    const qs = new URLSearchParams({ removed: String(showRemoved) });
    if (!reset && cursor) qs.set('cursor', cursor);
    try {
      const res = await api<{ clips: Clip[]; next_cursor: string | null }>(`/clips?${qs}`);
      setClips((prev) => (reset ? res.clips : [...prev, ...res.clips]));
      setCursor(res.next_cursor);
    } finally {
      setLoading(false);
    }
  }, [cursor, showRemoved]);

  useEffect(() => {
    if (!getToken()) { router.replace('/login'); return; }
    // Reset on filter change: keeping the old cursor would page into the wrong list.
    setCursor(null);
    load(true);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [showRemoved]);

  async function remove(id: string) {
    // A reason is REQUIRED, not optional. "Why was this taken down" is the question that
    // arrives later, and an empty audit entry cannot answer it.
    const reason = window.prompt('Reason for removing this clip?');
    if (reason === null) return;
    if (!reason.trim()) { alert('A reason is required.'); return; }
    await api(`/clips/${id}/remove`, { method: 'POST', json: { reason } });
    setClips((prev) => prev.filter((c) => c.id !== id));
  }

  async function restore(id: string) {
    await api(`/clips/${id}/restore`, { method: 'POST' });
    setClips((prev) => prev.filter((c) => c.id !== id));
  }

  async function play(id: string) {
    const res = await api<{ url: string }>(`/clips/${id}/playback`);
    setPlaying(res.url);
  }

  return (
    <main style={{ maxWidth: 1000, margin: '0 auto', padding: 32 }}>
      <header style={{ display: 'flex', alignItems: 'center', gap: 16, marginBottom: 24 }}>
        <Link href="/"><button className="ghost">← Back</button></Link>
        <h1 style={{ margin: 0, fontSize: 22 }}>{showRemoved ? 'Removed clips' : 'Clips'}</h1>
        <div style={{ marginLeft: 'auto' }}>
          <button className="ghost" onClick={() => setShowRemoved((v) => !v)}>
            {showRemoved ? 'Show live' : 'Show removed'}
          </button>
        </div>
      </header>

      {clips.length === 0 && !loading && (
        <p style={{ color: 'var(--text-dim)' }}>
          {showRemoved ? 'Nothing has been removed.' : 'No clips yet.'}
        </p>
      )}

      <div style={{ display: 'grid', gap: 12 }}>
        {clips.map((c) => (
          <div key={c.id} className="card" style={{ display: 'flex', gap: 14, padding: 12 }}>
            {/* The thumbnail is the whole point of a moderation queue — a list of ids and
                captions cannot be moderated. */}
            <div
              onClick={() => play(c.id)}
              style={{
                width: 72, height: 96, borderRadius: 8, flexShrink: 0, cursor: 'pointer',
                background: c.thumb_url ? `center/cover url(${c.thumb_url})` : 'var(--border)',
              }}
              title="Play"
            />
            <div style={{ minWidth: 0, flex: 1 }}>
              <div style={{ fontWeight: 600 }}>
                {c.author_name ?? 'Unknown'}
                {c.author_username && (
                  <span style={{ color: 'var(--text-dim)', fontWeight: 400 }}> @{c.author_username}</span>
                )}
              </div>
              <div style={{ color: 'var(--text-dim)', fontSize: 13, margin: '2px 0 6px' }}>
                {c.caption || <em>no caption</em>}
              </div>
              <div style={{ color: 'var(--text-dim)', fontSize: 12 }}>
                {c.view_count} views · {c.like_count} likes · {c.comment_count} comments ·{' '}
                {new Date(c.created_at).toLocaleString()}
              </div>
              {c.removed_reason && (
                <div style={{ color: 'var(--danger)', fontSize: 12, marginTop: 4 }}>
                  Removed: {c.removed_reason}
                </div>
              )}
            </div>
            <div style={{ display: 'flex', alignItems: 'center' }}>
              {c.removed_at
                ? <button className="ghost" onClick={() => restore(c.id)}>Restore</button>
                : <button className="danger" onClick={() => remove(c.id)}>Remove</button>}
            </div>
          </div>
        ))}
      </div>

      {cursor && (
        <button className="ghost" onClick={() => load(false)} disabled={loading}
                style={{ marginTop: 16 }}>
          {loading ? 'Loading…' : 'Load more'}
        </button>
      )}

      {playing && (
        <div
          onClick={() => setPlaying(null)}
          style={{
            position: 'fixed', inset: 0, background: 'rgba(0,0,0,.8)',
            display: 'grid', placeItems: 'center', padding: 24,
          }}
        >
          {/* stopPropagation so clicking the video itself does not close the overlay. */}
          <video
            src={playing} controls autoPlay
            onClick={(e) => e.stopPropagation()}
            style={{ maxHeight: '85vh', maxWidth: '100%', borderRadius: 12 }}
          />
        </div>
      )}
    </main>
  );
}
