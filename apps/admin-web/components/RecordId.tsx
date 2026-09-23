'use client';

//
// The record id for a detail page (/communities/<id>, /users/<id>, /events/<id>), read from
// the ADDRESS BAR.
//
// WHY NOT useParams()
// The panel is a static export. Each dynamic route is emitted once, as a shell whose param
// is literally "index" (see the page.tsx wrappers), and public/_redirects serves every real
// path from that shell. useParams() reports the param the shell was BUILT with, so on the
// deployed panel every detail page asked the API for community "index" and got
// "community id must be a uuid". In `next dev` the route is real, which is why it only ever
// broke once deployed. The address bar is the one place the real id always is.
//
// A malformed id is caught HERE, before any request, and said in words with a way back,
// instead of surfacing as an API validation error.
//

import { useEffect, useState, type ReactElement } from 'react';
import Link from 'next/link';
import { usePathname } from 'next/navigation';
import { ArrowLeft, Link2Off } from 'lucide-react';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

type Section = 'communities' | 'users' | 'events';

const LIST: Record<Section, { href: string; label: string }> = {
  communities: { href: '/communities', label: 'All communities' },
  users: { href: '/users', label: 'All users' },
  events: { href: '/events', label: 'All events' },
};

/** The id segment after `/<section>/` in the current URL, or null. */
function idFromLocation(section: Section): string | null {
  const parts = window.location.pathname.split('/').filter(Boolean);
  const at = parts.indexOf(section);
  if (at < 0 || !parts[at + 1]) return null;
  try { return decodeURIComponent(parts[at + 1]); } catch { return parts[at + 1]; }
}

export function WithRecordId({ section, noun, children }: {
  section: Section;
  /** "community", "user", "event" — for the message when the link is wrong. */
  noun: string;
  children: (id: string) => ReactElement;
}) {
  // Re-read on every client-side navigation: moving from one community to another keeps
  // this component mounted, and the id must follow the address bar.
  const pathname = usePathname();
  const [id, setId] = useState<string | null | undefined>(undefined);

  useEffect(() => { setId(idFromLocation(section)); }, [section, pathname]);

  // Blank for the one frame before the address bar has been read, as the Shell does while
  // it checks the session — a flashed error would be more visible than the wait.
  if (id === undefined) return <></>;

  if (!id || !UUID.test(id)) {
    const back = LIST[section];
    return (
      <div className="mx-auto mt-10 max-w-[460px] rounded-[22px] bg-card p-7 text-center shadow-[var(--shadow-1)] ring-1 ring-black/[0.04]">
        <span className="mx-auto mb-4 grid h-12 w-12 place-items-center rounded-full bg-[var(--surface-2)]">
          <Link2Off size={20} className="text-[var(--text-dim)]" />
        </span>
        <h1 className="text-[20px]">This link doesn&rsquo;t point to a {noun}</h1>
        <p className="m-0 mt-2 text-sm text-[var(--text-dim)]">
          The address should end in the {noun}&rsquo;s ID. It may have been cut short when it
          was copied. Open the {noun} again from the list.
        </p>
        <Link
          href={back.href}
          className="mt-5 inline-flex h-10 items-center gap-2 rounded-full bg-[var(--accent)] px-5 text-sm font-semibold text-white no-underline hover:bg-[var(--accent-hover)] hover:no-underline"
        >
          <ArrowLeft size={15} /> {back.label}
        </Link>
      </div>
    );
  }

  return children(id);
}
