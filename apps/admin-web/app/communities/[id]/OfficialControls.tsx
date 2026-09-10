'use client';

import { useCallback, useEffect, useState } from 'react';
import { useRouter } from 'next/navigation';
import { api } from '../../../lib/api';

type Community = { name: string; description: string | null; discoverable: boolean; join_policy: string; members_can_invite: boolean; posting_policy: string };
type Member = { user_id: string; role: string; state: string; full_name: string | null; username: string | null };
type Entry = { id?: string; token?: string; title?: string; label?: string; value?: string; detail?: string; body?: string; url?: string; expires_at?: string; name?: string; conversation_id?: string; kind?: string };

export default function OfficialControls({ id, community, members, reload }: { id: string; community: Community; members: Member[]; reload: () => Promise<void> }) {
  const router = useRouter();
  const [form, setForm] = useState(community);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);
  const [tab, setTab] = useState('posts');
  const [rows, setRows] = useState<Entry[]>([]);
  const [title, setTitle] = useState('');
  const [body, setBody] = useState('');
  const [link, setLink] = useState('');
  const [memberQuery, setMemberQuery] = useState('');
  const [memberResults, setMemberResults] = useState<Member[] | null>(null);
  const [loading, setLoading] = useState(false);
  const call = useCallback(<T,>(method: string, path: string, payload?: unknown) => api<T>(`/communities/${id}/manage`, { json: { method, path, payload } }), [id]);
  const refresh = useCallback(async () => {
    setLoading(true); setError(null);
    try { const data = await call<Record<string, unknown>>('GET', tab); setRows(tab === 'announcements' ? (data.announcement ? [data.announcement as Entry] : []) : (data[tab] as Entry[] ?? [])); }
    catch (e) { setError(e instanceof Error ? e.message : 'Could not load'); setRows([]); }
    finally { setLoading(false); }
  }, [call, tab]);
  useEffect(() => { setForm(community); }, [community]);
  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => {
    if (!memberQuery.trim()) { setMemberResults(null); return; }
    let active = true;
    const timer = setTimeout(() => {
      void api<{ members: Member[] }>(`/communities/${id}/manage-members?q=${encodeURIComponent(memberQuery.trim())}`)
        .then(result => { if (active) setMemberResults(result.members); })
        .catch(e => { if (active) setError(e instanceof Error ? e.message : 'Could not find member'); });
    }, 250);
    return () => { active = false; clearTimeout(timer); };
  }, [id, memberQuery, members]);
  async function act(method: string, path: string, payload?: unknown) {
    if (busy) return false;
    setBusy(true); setError(null); setNotice(null);
    try {
      const result = await call<{ url?: string }>(method, path, payload);
      setNotice(result.url ?? 'Saved.');
      if (method === 'DELETE' && path === '') { router.push('/communities'); return true; }
      await reload(); await refresh();
      return true;
    } catch (e) { setError(e instanceof Error ? e.message : 'Could not save'); return false; }
    finally { setBusy(false); }
  }
  async function publish() {
    const payload = tab === 'posts' ? { body } : tab === 'announcements' ? { title, body }
      : tab === 'links' ? { label: title, value: link } : tab === 'rules' ? { title, detail: body }
      : tab === 'channels' ? { name: title, kind: 'chat' } : { expires_in_hours: 168, max_uses: 100 };
    if (await act('POST', tab, payload)) { setTitle(''); setBody(''); setLink(''); }
  }
  return <section className="card" style={{ marginBottom: 24 }}>
    <h2>Official community controls</h2>
    <p className="muted">Actions are recorded against your admin account. Posts and announcements publish as the community owner. Encrypted channel chats and private host messages cannot be read from this panel.</p>
    {error && <div className="notice error" role="alert">{error}</div>}
    {notice && <div className="notice" role="status" style={{ overflowWrap: 'anywhere' }}>{notice}</div>}
    <fieldset disabled={busy} style={{ border: 0, padding: 0 }}>
      <div style={{ display: 'grid', gap: 12, margin: '18px 0' }}>
        <label>Name<input maxLength={60} value={form.name} onChange={e => setForm({ ...form, name: e.target.value })} /></label>
        <label>Description<textarea maxLength={500} value={form.description ?? ''} onChange={e => setForm({ ...form, description: e.target.value })} /></label>
        <label>Who can join<select value={form.join_policy} onChange={e => setForm({ ...form, join_policy: e.target.value })}><option value="open">Anyone</option><option value="approval">Approval required</option><option value="invite_only">Invite only</option></select></label>
        <label>Who can publish posts<select value={form.posting_policy} onChange={e => setForm({ ...form, posting_policy: e.target.value })}><option value="members">All members</option><option value="managers">Owner and admins</option></select></label>
        <label><input type="checkbox" checked={form.discoverable} onChange={e => setForm({ ...form, discoverable: e.target.checked })} /> Show in community search</label>
        <label><input type="checkbox" checked={form.join_policy !== 'invite_only' && form.members_can_invite} disabled={form.join_policy === 'invite_only'} onChange={e => setForm({ ...form, members_can_invite: e.target.checked })} /> Members can create invites</label>
        <button disabled={!form.name.trim()} onClick={() => void act('PATCH', '', form)}>Save settings</button>
      </div>
      <h3>Members and requests</h3>
      <input aria-label="Find community member" placeholder="Find by username, name or account ID" value={memberQuery} onChange={e => setMemberQuery(e.target.value)} />
      <p className="muted">Showing up to 200 matches. Use an exact username or account ID to find a specific member.</p>
      <div style={{ overflowX: 'auto', marginBottom: 20 }}><table><thead><tr><th>Member</th><th>Role / state</th><th>Actions</th></tr></thead><tbody>
        {(memberResults ?? members).map(m => <tr key={m.user_id}><td>{m.full_name ?? m.username ?? m.user_id}</td><td>{m.role} · {m.state}</td><td>
          {m.role !== 'owner' && <div className="row" style={{ flexWrap: 'wrap', gap: 6 }}>
            {m.state === 'pending' && <button onClick={() => void act('POST', `members/${m.user_id}/approve`)}>Approve</button>}
            {m.state === 'active' && <button onClick={() => void act('POST', `members/${m.user_id}/role`, { role: m.role === 'admin' ? 'member' : 'admin' })}>{m.role === 'admin' ? 'Make member' : 'Make admin'}</button>}
            {m.state === 'banned' ? <button onClick={() => void act('POST', `members/${m.user_id}/unban`)}>Unban</button> : <>
              <button className="ghost" onClick={() => { if (window.confirm('Remove this member? They may apply to join again.')) void act('POST', `members/${m.user_id}/remove`); }}>Remove</button>
              <button className="danger" onClick={() => { if (window.confirm('Ban this member from rejoining?')) void act('POST', `members/${m.user_id}/ban`); }}>Ban</button>
            </>}
          </div>}
        </td></tr>)}
      </tbody></table></div>
      <h3>Content and invitations</h3>
      <select value={tab} onChange={e => { setTab(e.target.value); setTitle(''); setBody(''); setLink(''); setNotice(null); }}>
        {['posts', 'announcements', 'links', 'rules', 'channels', 'invites'].map(t => <option key={t} value={t}>{t.charAt(0).toUpperCase() + t.slice(1)}</option>)}
      </select>
      <div style={{ display: 'grid', gap: 10, marginTop: 12 }}>
        {!['posts', 'invites'].includes(tab) && <input aria-label="Title" placeholder={tab === 'channels' ? 'Space name' : 'Title'} value={title} maxLength={tab === 'channels' ? 60 : 120} onChange={e => setTitle(e.target.value)} />}
        {['posts', 'announcements', 'rules'].includes(tab) && <textarea aria-label="Body" placeholder={tab === 'rules' ? 'Rule details' : 'Write your message'} value={body} maxLength={tab === 'rules' ? 400 : tab === 'announcements' ? 2000 : 4000} onChange={e => setBody(e.target.value)} />}
        {tab === 'links' && <input type="url" aria-label="Link URL" placeholder="https://…" value={link} onChange={e => setLink(e.target.value)} />}
        <button onClick={() => void publish()}>{tab === 'invites' ? 'Create 7-day invite · 100 joins' : `Add ${tab === 'channels' ? 'Space' : tab.replace(/s$/, '')}`}</button>
      </div>
      {loading ? <p>Loading…</p> : rows.length === 0 ? <p className="muted">No {tab}.</p> : rows.map((row, index) => <div key={row.id ?? row.token ?? row.conversation_id ?? index} style={{ padding: '14px 0', borderBottom: '1px solid var(--border)' }}>
        <strong>{row.title ?? row.label ?? row.name ?? (tab === 'invites' ? `Invite · expires ${row.expires_at?.slice(0, 10) ?? 'never'}` : '')}</strong>
        {row.body && <p style={{ whiteSpace: 'pre-wrap', overflowWrap: 'anywhere' }}>{row.body}</p>}
        {(row.url || row.value || row.detail) && <p>{row.url ?? row.value ?? row.detail}</p>}
        {['posts', 'channels', 'rules'].includes(tab) && <button className="ghost" onClick={() => {
          const value = window.prompt(tab === 'posts' ? 'Edit post' : 'Edit title', row.body ?? row.name ?? row.title ?? '');
          if (value === null || !value.trim()) return;
          const payload = tab === 'posts' ? { body: value } : tab === 'channels' ? { name: value } : { title: value, detail: row.detail ?? '' };
          void act('PATCH', `${tab}/${row.id ?? row.conversation_id}`, payload);
        }}>Edit</button>}
        {!(tab === 'channels' && row.kind === 'announcement') && <button className="danger" onClick={() => { if (window.confirm(`Remove this ${tab.replace(/s$/, '')}?`)) void act('DELETE', `${tab}/${row.id ?? row.token ?? row.conversation_id}`); }}>{tab === 'invites' ? 'Revoke' : 'Remove'}</button>}
      </div>)}
      <hr />
      <button className="danger" onClick={() => {
        const name = window.prompt(`Permanently delete ${community.name}, its memberships, posts, invites and Spaces? Type the exact community name to confirm.`);
        if (name === community.name) void act('DELETE', '', { confirm_name: name });
      }}>Delete this official community</button>
    </fieldset>
  </section>;
}
