/**
 * SERVER WRAPPER, so the client page can stay a client component.
 *
 * `output: 'export'` needs generateStaticParams, and Next forbids a `'use client'` module
 * from exporting it. The real screen lives in Client.tsx untouched; this file exists only to
 * declare what the export should emit.
 *
 * ONE SHELL, NOT A PAGE PER RECORD. There is no server here to enumerate every event,
 * nor should there be: the list would go stale the moment a row is created, and baking real
 * ids into a static build would publish them to anyone who fetched the manifest. The client
 * reads its id from the URL at runtime; public/_redirects rewrites real paths onto this
 * shell with a 200, which keeps that id in the address bar.
 */
import Client from './Client';

export function generateStaticParams() {
  return [{ id: 'index' }];
}

export default function EventDetailPage() {
  return <Client />;
}
