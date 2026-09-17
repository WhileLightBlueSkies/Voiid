/**
 * Server wrapper — see ../page.tsx for why. One emitted shell; the client reads the
 * community id from the URL at runtime.
 */
import Client from './Client';

export function generateStaticParams() {
  return [{ id: 'index' }];
}

export default function CommunityAnalyticsPage() {
  return <Client />;
}
