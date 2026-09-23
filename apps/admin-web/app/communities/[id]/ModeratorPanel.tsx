'use client';

/**
 * Post to an official community as Voiid Moderator, and grant manager rights.
 *
 * ── WHY THE AUTHOR IS AN ACCOUNT, NOT A LABEL ───────────────────────────────────────
 *
 * The backend writes these posts with `author_id` set to the Voiid Moderator user row
 * (077_official_moderator.sql). That means the post travels the ordinary read path, and both
 * apps render the name, avatar and official badge with no client changes. A label applied at
 * render time would have put "who wrote this" in two places and let them drift.
 *
 * ── SCHEDULING IS A TIMESTAMP, NOT A JOB ────────────────────────────────────────────
 *
 * A scheduled post is written immediately with a future `scheduled_at`, and the public feed
 * filters on the clock. Nothing has to run for it to appear, so there is no job that can
 * fail and leave a post half-published. The queue below shows pending posts because the
 * public feed deliberately cannot.
 */

import { useCallback, useEffect, useState } from 'react';
import { api } from '../../../lib/api';

type Post = {
  id: string;
  body: string;
  created_at: string;
  scheduled_at: string | null;
  removed_at: string | null;
  pending: boolean;
  channel_id: string | null;
  channel_name: string | null;
};

type Space = { id: string; name: string | null; kind: string };

type Member = { user_id: string; role: string; full_name: string | null; username: string | null };

export default function ModeratorPanel({
  id,
  members,
  reload,
}: {
  id: string;
  members: Member[];
  reload: () => Promise<void>;
}) {
  const [posts, setPosts] = useState<Post[]>([]);
  const [body, setBody] = useState('');
  const [scheduledAt, setScheduledAt] = useState('');
  // '' is Home; otherwise a Space id. Posting into a Space puts the post in that Space's feed.
  const [spaceId, setSpaceId] = useState('');
  const [spaces, setSpaces] = useState<Space[]>([]);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    setError(null);
    try {
      const data = await api<{ posts: Post[] }>(`/communities/${id}/moderator-posts`);
      setPosts(data.posts ?? []);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not load posts');
    }
  }, [id]);

  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => {
    void api<{ spaces: Space[] }>(`/communities/${id}/spaces`)
      .then(r => setSpaces(r.spaces ?? []))
      .catch(() => setSpaces([]));
  }, [id]);

  async function publish() {
    if (!body.trim()) return;
    setBusy(true); setError(null); setNotice(null);
    try {
      await api(`/communities/${id}/moderator-post`, {
        json: {
          body: body.trim(),
          // An empty field means "now". Sent as ISO because the column is timestamptz and
          // the browser's local-time string would otherwise be read as UTC.
          scheduled_at: scheduledAt ? new Date(scheduledAt).toISOString() : null,
          channel_id: spaceId || null,
        },
      });
      setBody(''); setScheduledAt('');
      const where = spaceId ? `in ${spaces.find(s => s.id === spaceId)?.name ?? 'the Space'}` : 'on Home';
      setNotice(scheduledAt ? `Scheduled ${where}.` : `Posted as Voiid Moderator ${where}.`);
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not post');
    } finally {
      setBusy(false);
    }
  }

  async function remove(postId: string, pending: boolean) {
    if (!window.confirm(pending ? 'Cancel this scheduled post?' : 'Remove this post from the feed?')) return;
    setBusy(true); setError(null);
    try {
      await api(`/communities/${id}/moderator-post/${postId}`, { method: 'DELETE' });
      await refresh();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not remove');
    } finally {
      setBusy(false);
    }
  }

  async function setRole(userId: string, role: 'admin' | 'member') {
    setBusy(true); setError(null); setNotice(null);
    try {
      await api(`/communities/${id}/moderators`, { json: { user_id: userId, role } });
      setNotice(role === 'admin' ? 'Moderator added.' : 'Moderator removed.');
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not change role');
    } finally {
      setBusy(false);
    }
  }

  // The owner is listed but never actionable: ownership has its own transfer flow, and
  // offering a button here that the API refuses would be a lie in the interface.
  const owner = members.filter(m => m.role === 'owner');
  const moderators = members.filter(m => m.role === 'admin');
  const others = members.filter(m => m.role === 'member');

  return (
    <section style={{ display: 'grid', gap: 18 }}>
      <div>
        <h3 style={{ margin: '0 0 4px' }}>Post as Voiid Moderator</h3>
        <p style={{ margin: '0 0 10px', opacity: 0.7, fontSize: 13 }}>
          Appears in the community feed under the Voiid Moderator account, with the official badge.
        </p>
        <textarea
          aria-label="Post body"
          placeholder="Write your message"
          value={body}
          maxLength={5000}
          rows={4}
          onChange={e => setBody(e.target.value)}
          style={{ width: '100%' }}
        />
        <div style={{ display: 'flex', gap: 10, alignItems: 'center', marginTop: 8, flexWrap: 'wrap' }}>
          <label style={{ fontSize: 13, opacity: 0.8 }}>
            Post to{' '}
            <select aria-label="Post to" value={spaceId} onChange={e => setSpaceId(e.target.value)}>
              <option value="">Home</option>
              {spaces.map(s => <option key={s.id} value={s.id}>{s.name ?? 'Untitled Space'}</option>)}
            </select>
          </label>
          <label style={{ fontSize: 13, opacity: 0.8 }}>
            Schedule{' '}
            <input
              type="datetime-local"
              aria-label="Schedule for"
              value={scheduledAt}
              onChange={e => setScheduledAt(e.target.value)}
            />
          </label>
          <span style={{ fontSize: 12, opacity: 0.6 }}>Leave empty to post now</span>
          <button disabled={busy || !body.trim()} onClick={() => void publish()}>
            {scheduledAt ? 'Schedule post' : 'Post now'}
          </button>
        </div>
      </div>

      {error && <p role="alert" style={{ color: '#b3261e', margin: 0 }}>{error}</p>}
      {notice && <p style={{ color: '#146c2e', margin: 0 }}>{notice}</p>}

      <div>
        <h3 style={{ margin: '0 0 8px' }}>Moderator posts</h3>
        {posts.length === 0 && <p style={{ opacity: 0.6, fontSize: 13 }}>Nothing posted yet.</p>}
        <div style={{ display: 'grid', gap: 8 }}>
          {posts.map(p => (
            <div key={p.id} style={{ display: 'flex', gap: 10, alignItems: 'flex-start', opacity: p.removed_at ? 0.45 : 1 }}>
              <div style={{ flex: 1 }}>
                <div style={{ fontSize: 14, whiteSpace: 'pre-wrap' }}>{p.body}</div>
                <div style={{ fontSize: 12, opacity: 0.65, marginTop: 2 }}>
                  {p.channel_name ? `${p.channel_name} · ` : 'Home · '}
                  {p.removed_at
                    ? 'Removed'
                    : p.pending
                      ? `Scheduled for ${new Date(p.scheduled_at!).toLocaleString()}`
                      : `Posted ${new Date(p.created_at).toLocaleString()}`}
                </div>
              </div>
              {!p.removed_at && (
                <button disabled={busy} onClick={() => void remove(p.id, p.pending)}>
                  {p.pending ? 'Cancel' : 'Remove'}
                </button>
              )}
            </div>
          ))}
        </div>
      </div>

      <div>
        <h3 style={{ margin: '0 0 8px' }}>Moderators</h3>
        <div style={{ display: 'grid', gap: 6 }}>
          {owner.map(m => (
            <div key={m.user_id} style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
              <span style={{ flex: 1 }}>{m.full_name ?? m.username ?? m.user_id}</span>
              <span style={{ fontSize: 12, opacity: 0.6 }}>Owner</span>
            </div>
          ))}
          {moderators.map(m => (
            <div key={m.user_id} style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
              <span style={{ flex: 1 }}>{m.full_name ?? m.username ?? m.user_id}</span>
              <button disabled={busy} onClick={() => void setRole(m.user_id, 'member')}>Remove moderator</button>
            </div>
          ))}
          {moderators.length === 0 && <p style={{ opacity: 0.6, fontSize: 13, margin: 0 }}>No moderators yet.</p>}
        </div>

        {others.length > 0 && (
          <details style={{ marginTop: 10 }}>
            <summary style={{ cursor: 'pointer', fontSize: 13 }}>Add a moderator ({others.length} members)</summary>
            <div style={{ display: 'grid', gap: 6, marginTop: 8, maxHeight: 260, overflowY: 'auto' }}>
              {others.map(m => (
                <div key={m.user_id} style={{ display: 'flex', gap: 10, alignItems: 'center' }}>
                  <span style={{ flex: 1 }}>{m.full_name ?? m.username ?? m.user_id}</span>
                  <button disabled={busy} onClick={() => void setRole(m.user_id, 'admin')}>Make moderator</button>
                </div>
              ))}
            </div>
          </details>
        )}
      </div>
    </section>
  );
}
