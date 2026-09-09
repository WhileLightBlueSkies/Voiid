/** A signed companion capability limits a linked browser to messaging operations.
 * This is authorization, not an attempt to identify/ban automation by User-Agent. */
export function companionAllows(method: string, path: string, deviceId: string, body?: any): boolean {
  const uuid = '[0-9a-f-]{36}';
  if (method === 'GET') return new RegExp(`^/(?:conversations(?:/${uuid})?|messages/(?:pending/${uuid}|conversation/${uuid})|devices/${uuid}|prekeys/(?:${uuid}|count)|receipts/${uuid}|users/(?:me|${uuid}))/?$`, 'i').test(path);
  if (method === 'DELETE') return path === `/devices/${deviceId}`;
  if (method !== 'POST') return false;
  if (path === '/prekeys/upload' || path === '/prekeys/refresh') return body?.device_id === deviceId;
  return ['/messages/send', '/messages/ack', '/receipts/mark',
    '/media/presign-upload', '/media/presign-download', '/media/confirm', '/linking/socket-ticket'].includes(path);
}
