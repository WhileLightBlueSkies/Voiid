'use client';

/**
 * Institution name and "Community moderator" tags for one community (087).
 *
 * ── THE TAG IS VOIID'S WORD, NOT THE HOST'S ─────────────────────────────────────────
 *
 * A tag on someone's posts says Voiid has confirmed they speak for this community. So it is
 * granted here, per person, with a reason, and never from the app. A community can carry tags
 * only while it holds the `moderator_badge` capability (switched on in "Paid capabilities"
 * below) or is official; switching that off takes every tag off every past post at once.
 *
 * The institution name is the verified mark on the community's card. It is set here and only
 * here — a host cannot type "IIT Bombay" into their own settings.
 */

import { useCallback, useEffect, useState } from 'react';
import { api } from '../../../lib/api';
import { Card } from '../../../components/ui/card';
import { Button } from '../../../components/ui/button';

type Member = { user_id: string; role: string; state: string; full_name: string | null; username: string | null };
type Tag = {
  id: string; user_id: string; badge: string; note: string; granted_at: string; revoked_at: string | null;
  full_name: string | null; username: string | null; role: string | null; state: string | null;
  granted_by_email: string | null;
};

const who = (m: { full_name: string | null; username: string | null; user_id: string }) =>
  m.full_name ?? (m.username ? `@${m.username}` : m.user_id);

export default function TagsPanel({ id, institutionName, emailDomains, members, reload }: {
  id: string;
  institutionName: string | null;
  emailDomains: string[];
  members: Member[];
  reload: () => Promise<void>;
}) {
  const [tags, setTags] = useState<Tag[]>([]);
  const [allowed, setAllowed] = useState(false);
  const [institution, setInstitution] = useState(institutionName ?? '');
  const savedDomains = (emailDomains ?? []).join(', ');
  const [domains, setDomains] = useState(savedDomains);
  const [pick, setPick] = useState('');
  const [note, setNote] = useState('');
  const [makeAdmin, setMakeAdmin] = useState(true);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [notice, setNotice] = useState<string | null>(null);

  const refresh = useCallback(async () => {
    try {
      const r = await api<{ badges: Tag[]; allowed: boolean }>(`/communities/${id}/badges`);
      setTags(r.badges ?? []);
      setAllowed(r.allowed);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not load tags');
    }
  }, [id]);

  useEffect(() => { void refresh(); }, [refresh]);
  useEffect(() => { setInstitution(institutionName ?? ''); }, [institutionName]);
  useEffect(() => { setDomains(savedDomains); }, [savedDomains]);

  async function run(label: string, fn: () => Promise<unknown>) {
    setBusy(true); setError(null); setNotice(null);
    try {
      await fn();
      setNotice(label);
      await refresh();
      await reload();
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Something went wrong');
    } finally {
      setBusy(false);
    }
  }

  const live = tags.filter(t => !t.revoked_at);
  const tagged = new Set(live.map(t => t.user_id));
  const candidates = members.filter(m => m.state === 'active' && !tagged.has(m.user_id));

  return (
    <Card className="mb-5">
      <div className="border-b border-border px-4 py-3">
        <h2 className="text-sm font-semibold">Institution &amp; moderator tags</h2>
        <p className="m-0 mt-0.5 text-tiny text-[var(--text-mute)]">
          The institution name shows as a verified mark on the community. Tagged members
          show &ldquo;Community moderator&rdquo; on their posts.
        </p>
      </div>

      <div className="grid gap-5 p-4">
        {error && <div role="alert" className="notice error">{error}</div>}
        {notice && <div role="status" className="text-sm" style={{ color: 'var(--ok)' }}>{notice}</div>}

        <div className="grid gap-2">
          <label className="text-tiny text-[var(--text-mute)]" htmlFor="institution">Verified institution</label>
          <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
            <input id="institution" placeholder="e.g. Northstar University" value={institution}
                   maxLength={120} onChange={e => setInstitution(e.target.value)} style={{ maxWidth: 340 }} />
            <Button size="sm" disabled={busy || institution.trim() === (institutionName ?? '') || (institution.trim().length > 0 && institution.trim().length < 2)}
                    onClick={() => void run(institution.trim() ? 'Institution saved.' : 'Institution removed.', () =>
                      api(`/communities/${id}/institution`, { method: 'PATCH', json: { institution_name: institution.trim() || null } }))}>
              {institution.trim() ? 'Save' : 'Remove'}
            </Button>
          </div>
        </div>

        <div className="grid gap-2">
          <label className="text-tiny text-[var(--text-mute)]" htmlFor="domains">Allowed email domains</label>
          <div className="row" style={{ gap: 8, flexWrap: 'wrap' }}>
            <input id="domains" placeholder="e.g. iitb.ac.in, student.iitb.ac.in" value={domains}
                   onChange={e => setDomains(e.target.value)} style={{ maxWidth: 340 }} />
            <Button size="sm" disabled={busy || domains.trim() === savedDomains}
                    onClick={() => void run(domains.trim() ? 'Email domains saved.' : 'Anyone can join again.', () =>
                      api(`/communities/${id}/institution`, { method: 'PATCH', json: { email_domains: domains } }))}>
              Save
            </Button>
          </div>
          <p className="m-0 text-tiny text-[var(--text-mute)]">
            When set, people must confirm an email at one of these domains (a code is emailed to them)
            before they can join. Subdomains count. Leave empty to let anyone join. Existing members are not affected.
          </p>
        </div>

        <div className="grid gap-2">
          <h3 className="m-0 text-sm font-semibold">Tagged members</h3>
          {!allowed && (
            <p className="m-0 text-sm text-[var(--text-mute)]">
              Switch on <strong>moderator_badge</strong> under Paid capabilities to give tags in this community.
            </p>
          )}
          {live.length === 0 && allowed && <p className="m-0 text-sm text-[var(--text-mute)]">Nobody is tagged yet.</p>}
          {live.map(t => (
            <div key={t.id} className="row" style={{ gap: 10, alignItems: 'center' }}>
              <span style={{ flex: 1 }}>
                {who(t)} <span className="text-tiny text-[var(--text-mute)]">· {t.role ?? 'not a member'} · {t.note}</span>
              </span>
              <Button variant="outline" size="sm" disabled={busy}
                      onClick={() => {
                        const reason = window.prompt('Why is this tag being removed?');
                        if (!reason?.trim()) return;
                        void run('Tag removed.', () =>
                          api(`/communities/${id}/badges/${t.id}/revoke`, { json: { note: reason.trim() } }));
                      }}>
                Remove tag
              </Button>
            </div>
          ))}
        </div>

        {allowed && (
          <div className="grid gap-2">
            <h3 className="m-0 text-sm font-semibold">Tag a member</h3>
            <div className="row" style={{ gap: 8, flexWrap: 'wrap', alignItems: 'center' }}>
              <select aria-label="Member" value={pick} onChange={e => setPick(e.target.value)} style={{ maxWidth: 260 }}>
                <option value="">Choose a member…</option>
                {candidates.map(m => <option key={m.user_id} value={m.user_id}>{who(m)}{m.role !== 'member' ? ` (${m.role})` : ''}</option>)}
              </select>
              <input placeholder="Reason, e.g. Student council president" value={note} maxLength={500}
                     onChange={e => setNote(e.target.value)} style={{ minWidth: 260, flex: 1 }} />
              <label className="text-sm" style={{ display: 'flex', gap: 6, alignItems: 'center' }}>
                <input type="checkbox" checked={makeAdmin} onChange={e => setMakeAdmin(e.target.checked)} />
                Also make admin
              </label>
              <Button size="sm" disabled={busy || !pick || !note.trim()}
                      onClick={() => void run('Tag added.', async () => {
                        await api(`/communities/${id}/badges`, { json: { user_id: pick, note: note.trim(), make_admin: makeAdmin } });
                        setPick(''); setNote('');
                      })}>
                Add tag
              </Button>
            </div>
            {members.length > 0 && candidates.length === 0 && (
              <p className="m-0 text-sm text-[var(--text-mute)]">Every active member already has a tag.</p>
            )}
          </div>
        )}
      </div>
    </Card>
  );
}
