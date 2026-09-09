/** The browser's long-lived JWT never belongs in a socket URL. Redeem a short-lived
 * ticket atomically, and only from the configured messenger origin. */
export async function redeemWebTicket(ticket: string, origin: string | undefined, expectedOrigin: string | undefined,
  store: { getdel(key: string): Promise<string | null> }): Promise<string | null> {
  if (ticket.length !== 43 || !/^[A-Za-z0-9_-]+$/.test(ticket) || !expectedOrigin || origin !== expectedOrigin) return null;
  return store.getdel(`web:socket-ticket:${ticket}`);
}
