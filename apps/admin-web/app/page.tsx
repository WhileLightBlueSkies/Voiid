'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import Shell from '../components/Shell';
import { PageHeader, Stat, Async } from '../components/ui';
import { api } from '../lib/api';

type Stats = {
  users?: number; users_24h?: number;
  clips?: number; clips_removed?: number; clips_24h?: number; comments?: number;
  dpdp_open?: number; dpdp_overdue?: number;
  communities?: number; communities_suspended?: number; communities_24h?: number;
};

export default function Overview() {
  return <Shell>{() => <Body />}</Shell>;
}

function Body() {
  const [s, setS] = useState<Stats | null>(null);
  const [error, setError] = useState<string | null>(null);

  useEffect(() => {
    api<Stats>('/stats')
      .then(setS)
      .catch((e) => setError(e instanceof Error ? e.message : 'could not load the numbers'));
  }, []);

  const n = (v?: number) => v ?? 0;

  return (
    <>
      <PageHeader
        title="Overview"
        subtitle="Everything on Voiid, at a glance."
      />

      <Async loading={!s} error={error} empty={false} emptyText="">
        {s && (
          <div style={{ display: 'grid', gap: 22 }}>
            <Section title="People">
              <Grid>
                <Stat label="Users" value={n(s.users)} />
                <Stat label="New in 24h" value={n(s.users_24h)} />
              </Grid>
            </Section>

            <Section title="Communities" href="/communities">
              <Grid>
                <Stat label="Active" value={n(s.communities)} />
                <Stat label="New in 24h" value={n(s.communities_24h)} />
                <Stat
                  label="Suspended"
                  value={n(s.communities_suspended)}
                  tone={n(s.communities_suspended) > 0 ? 'warning' : undefined}
                />
              </Grid>
            </Section>

            <Section title="Clips" href="/clips">
              <Grid>
                <Stat label="Live" value={n(s.clips)} />
                <Stat label="New in 24h" value={n(s.clips_24h)} />
                <Stat label="Removed" value={n(s.clips_removed)} />
                <Stat label="Comments" value={n(s.comments)} />
              </Grid>
            </Section>

            <Section title="Data requests" href="/dpdp">
              <Grid>
                <Stat label="Open" value={n(s.dpdp_open)} />
                {/* Overdue is the only number on this page that turns red on its own. A DPDP
                    request breaches its period by being FORGOTTEN, not by being refused. */}
                <Stat
                  label="Overdue"
                  value={n(s.dpdp_overdue)}
                  tone={n(s.dpdp_overdue) > 0 ? 'danger' : undefined}
                />
              </Grid>
            </Section>

            <p className="mute" style={{ fontSize: 13, margin: 0, maxWidth: 640 }}>
              Messages and calls are end-to-end encrypted and hold no server-side content, so
              they are absent here by design rather than by omission.
            </p>
          </div>
        )}
      </Async>
    </>
  );
}

function Section({ title, href, children }: {
  title: string; href?: string; children: React.ReactNode;
}) {
  return (
    <section>
      <div className="row" style={{ marginBottom: 10 }}>
        <h2 style={{ flex: 1 }}>{title}</h2>
        {href && <Link href={href} style={{ fontSize: 14 }}>Open →</Link>}
      </div>
      {children}
    </section>
  );
}

function Grid({ children }: { children: React.ReactNode }) {
  return (
    <div style={{ display: 'grid', gap: 12, gridTemplateColumns: 'repeat(auto-fit, minmax(160px, 1fr))' }}>
      {children}
    </div>
  );
}
