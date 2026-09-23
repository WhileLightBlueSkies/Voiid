'use client';

/**
 * Create a community FOR someone — an institution, usually.
 *
 * The server builds it through the same function the app's create flow uses, so it gets the
 * same Spaces, roster and handle rules; the owner then runs it from their phone like any host.
 * Naming an institution marks it verified and switches on moderator tags in the same step.
 */

import { useState } from 'react';
import Link from 'next/link';
import { useRouter } from 'next/navigation';
import Shell from '../../../components/Shell';
import { PageHeader } from '../../../components/ui';
import { Card } from '../../../components/ui/card';
import { Button } from '../../../components/ui/button';
import { api } from '../../../lib/api';

const CATEGORIES = ['Education', 'Design', 'Tech', 'Gaming', 'Music', 'Sport', 'Local', 'Business'];
const JOIN = [
  { value: 'open', label: 'Open to all' },
  { value: 'approval', label: 'Request to join' },
  { value: 'invite_only', label: 'Invite only' },
];
// The server's rule (HANDLE_RE), so a bad handle is caught before the round trip.
const HANDLE_RE = /^[a-z][a-z0-9_]{2,19}$/;

export default function NewCommunity() {
  return <Shell>{(me) => me.role === 'admin' ? <Body /> : <p>Only admins can create communities.</p>}</Shell>;
}

function Body() {
  const router = useRouter();
  const [owner, setOwner] = useState('');
  const [name, setName] = useState('');
  const [handle, setHandle] = useState('');
  const [description, setDescription] = useState('');
  const [category, setCategory] = useState('Education');
  const [joinPolicy, setJoinPolicy] = useState('open');
  const [institution, setInstitution] = useState('');
  const [domains, setDomains] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  const handleOk = HANDLE_RE.test(handle);
  const ready = owner.trim() && name.trim() && handleOk && !busy;

  async function create() {
    setBusy(true); setError(null);
    try {
      const r = await api<{ community: { id: string } }>('/communities', {
        json: {
          owner: owner.trim(), name: name.trim(), handle,
          description: description.trim() || undefined,
          category, join_policy: joinPolicy,
          institution_name: institution.trim() || undefined,
          email_domains: domains.trim() || undefined,
        },
      });
      router.push(`/communities/${r.community.id}`);
    } catch (e) {
      setError(e instanceof Error ? e.message : 'Could not create the community');
      setBusy(false);
    }
  }

  return (
    <>
      <div style={{ marginBottom: 14 }}>
        <Link href="/communities" style={{ fontSize: 14 }}>← Communities</Link>
      </div>
      <PageHeader title="Create community"
                  subtitle="Set up a community for an institution or partner. The owner runs it from the Voiid app." />

      <Card className="mb-5" style={{ maxWidth: 640 }}>
        <div className="grid gap-4 p-4">
          <Field label="Owner" hint="Their @username or user id. They become the host.">
            <input value={owner} onChange={e => setOwner(e.target.value)} placeholder="@northstar_official" />
          </Field>
          <Field label="Name">
            <input value={name} maxLength={60} onChange={e => {
              setName(e.target.value);
              // Follow the name until the handle is edited by hand.
              if (!handle || handle === suggest(name)) setHandle(suggest(e.target.value));
            }} placeholder="Northstar University" />
          </Field>
          <Field label="Handle" hint={handle && !handleOk ? '3-20 characters, starting with a letter: a-z, 0-9 and _' : `voiid.app/c/${handle || '…'}`}>
            <input value={handle} maxLength={20}
                   onChange={e => setHandle(e.target.value.toLowerCase().replace(/[^a-z0-9_]/g, ''))} />
          </Field>
          <Field label="Description" hint="Optional. The owner can change it later.">
            <textarea rows={3} maxLength={500} value={description} onChange={e => setDescription(e.target.value)} />
          </Field>
          <div className="row" style={{ gap: 12, flexWrap: 'wrap' }}>
            <Field label="Category">
              <select value={category} onChange={e => setCategory(e.target.value)}>
                {CATEGORIES.map(c => <option key={c}>{c}</option>)}
              </select>
            </Field>
            <Field label="Who can join">
              <select value={joinPolicy} onChange={e => setJoinPolicy(e.target.value)}>
                {JOIN.map(j => <option key={j.value} value={j.value}>{j.label}</option>)}
              </select>
            </Field>
          </div>
          <Field label="Verified institution" hint="Optional. Shows a verified mark and switches on moderator tags.">
            <input value={institution} maxLength={120} onChange={e => setInstitution(e.target.value)}
                   placeholder="Northstar University" />
          </Field>

          <Field label="Allowed email domains" hint="Optional. Only people who confirm an email at these domains can join, e.g. iitb.ac.in">
            <input value={domains} onChange={e => setDomains(e.target.value)} placeholder="northstar.edu" />
          </Field>

          {error && <div role="alert" className="notice error">{error}</div>}
          <div>
            <Button disabled={!ready} onClick={() => void create()}>{busy ? 'Creating…' : 'Create community'}</Button>
          </div>
        </div>
      </Card>
    </>
  );
}

function suggest(name: string): string {
  let h = name.normalize('NFD').replace(/\p{Mn}/gu, '').toLowerCase().replace(/[^a-z0-9]/g, '');
  const digits = h.match(/^\d+/)?.[0] ?? '';
  h = h.slice(digits.length) + digits;
  if (!/^[a-z]/.test(h)) return '';
  if (h.length < 3) h += 'community';
  return h.slice(0, 20);
}

function Field({ label, hint, children }: { label: string; hint?: string; children: React.ReactNode }) {
  return (
    <label className="grid gap-1" style={{ minWidth: 200 }}>
      <span className="text-tiny text-[var(--text-mute)]">{label}</span>
      {children}
      {hint && <span className="text-tiny text-[var(--text-mute)]">{hint}</span>}
    </label>
  );
}
