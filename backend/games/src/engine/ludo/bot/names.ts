import { createHmac } from 'node:crypto';

export const BOT_NAMES = ['Ari', 'Bina', 'Coco', 'Dev', 'Isha', 'Juno', 'Kavi', 'Mira', 'Niko', 'Tara', 'Veda', 'Zoya'] as const;

export function botName(seedHex: string, seat: number, used: ReadonlySet<string>): string {
    const h = createHmac('sha256', Buffer.from(seedHex, 'hex')).update(`ludo-bot-name:${seat}`).digest();
    const start = h.readUInt16BE(0) % BOT_NAMES.length;
    for (let i = 0; i < BOT_NAMES.length; i++) {
        const candidate = BOT_NAMES[(start + i) % BOT_NAMES.length];
        if (!used.has(candidate)) return candidate;
    }
    const base = BOT_NAMES[start];
    for (let suffix = 2; ; suffix++) if (!used.has(`${base} ${suffix}`)) return `${base} ${suffix}`;
}
