export const encode = (text: string): string => bytesToBase64(new TextEncoder().encode(text));
export const decode = (text: string): string => new TextDecoder('utf-8', { fatal: true }).decode(base64ToBytes(text));
export function bytesToBase64(bytes: Uint8Array): string {
  let text = ''; for (let i = 0; i < bytes.length; i += 8192) text += String.fromCharCode(...bytes.subarray(i, i + 8192));
  return btoa(text);
}
export const base64ToBytes = (text: string): Uint8Array<ArrayBuffer> => Uint8Array.from(atob(text), c => c.charCodeAt(0));
export function encodeWire(wire: string): string {
  const { msg_type, body } = JSON.parse(wire);
  return encode(JSON.stringify({ t: msg_type, b: body }));
}
export function decodeWire(ciphertext: string): string {
  if (ciphertext.length > 3 * 1024 * 1024) throw new Error('Message is too large.');
  const value = JSON.parse(decode(ciphertext));
  if (![0, 1].includes(value.t) || typeof value.b !== 'string') throw new Error('Unsupported encrypted message.');
  return JSON.stringify({ msg_type: value.t, body: value.b });
}
export type Conversation = { id: string; type: string; name: string | null; title?: string; unread_count?: number; members?: { user_id: string; full_name?: string }[] };
export type Message = { id: string; conversation_id: string; sender_id: string; sender_device_id?: string; ciphertext?: string; created_at: string; content_type?: string; text?: string; status?: string; unavailable?: boolean };
export type View = { phase: 'starting' | 'link' | 'ready' | 'blocked' | 'error'; message?: string; qr?: string; expiresAt?: number; verificationCode?: string; userId?: string; conversations?: Conversation[]; messages?: Message[]; selected?: string; online?: boolean };
