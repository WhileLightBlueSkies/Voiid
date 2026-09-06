import React, { StrictMode, useState } from 'react';
import { createRoot } from 'react-dom/client';
import { useList } from '../../components/useList';
import Reports from '../../app/reports/page';
import Communities from '../../app/communities/page';
import { SiteHeader } from '../../../web/components/SiteHeader';

window.requests = [];
// Deliberately ignore abort: a response already being parsed can still finish.
window.fetch = (url, init = {}) => new Promise((resolve, reject) => {
  const request = { url, init, resolve: (body) => resolve({ ok: true, status: 200, json: async () => body }), reject };
  window.requests.push(request);
  if (url.endsWith('/me')) request.resolve({ email: 'test@example.invalid', name: 'Test', role: 'admin' });
});
window.finish = (index, body) => window.requests[index].resolve(body);
window.fail = (index, message = 'server failure') => window.requests[index].reject(new Error(message));
sessionStorage.setItem('voiid.admin.token', 'local-test-only');
function ListHarness() {
  const [q, setQ] = useState('A');
  const list = useList('/test', 'items', { q });
  window.list = list;
  return <><input aria-label="query" value={q} onChange={e => setQ(e.target.value)} /><pre id="state">{JSON.stringify(list)}</pre></>;
}
const mode = new URLSearchParams(location.search).get('mode');
window.root = createRoot(document.getElementById('root'));
const content = mode === 'reports' ? <Reports /> : mode === 'communities' ? <Communities /> : mode === 'nav' ? <><SiteHeader /><button id="outside">Outside</button></> : <ListHarness />;
window.root.render(mode === 'plain' ? content : <StrictMode>{content}</StrictMode>);
