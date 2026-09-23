// Outbound email over SMTP. One job today: the 6-digit code that proves a person holds an
// address at a verified institution's domain (routes/communities.ts, 088).
//
// ── CONFIGURATION ────────────────────────────────────────────────────────────────
//
//   SMTP_HOST, SMTP_PORT (587 default), SMTP_SECURE ("true" for implicit TLS on 465),
//   SMTP_USER, SMTP_PASS, SMTP_FROM (e.g. "Voiid <no-reply@voiid.app>")
//
// Absent config is a SUPPORTED state, the same posture payments/provider.ts takes: the routes
// that need mail answer 503 with a code the apps turn into "email verification isn't available
// yet", rather than pretending a code was sent.
//
// ── WHAT IS NEVER LOGGED ─────────────────────────────────────────────────────────
//
// The code itself, and the recipient address. A log line with both is a working login for a
// college community in anyone's hands who can read the logs.
import nodemailer, { type Transporter } from 'nodemailer';

let transport: Transporter | null = null;

export function mailConfigured(): boolean {
  return !!(process.env.SMTP_HOST?.trim() && process.env.SMTP_FROM?.trim());
}

function smtp(): Transporter {
  if (transport) return transport;
  const port = Number(process.env.SMTP_PORT) || 587;
  transport = nodemailer.createTransport({
    host: process.env.SMTP_HOST!.trim(),
    port,
    // Implicit TLS on 465; STARTTLS (required, not opportunistic) everywhere else.
    secure: process.env.SMTP_SECURE === 'true' || port === 465,
    requireTLS: !(process.env.SMTP_SECURE === 'true' || port === 465),
    auth: process.env.SMTP_USER
      ? { user: process.env.SMTP_USER.trim(), pass: process.env.SMTP_PASS ?? '' }
      : undefined,
  });
  return transport;
}

export async function sendMail(to: string, subject: string, text: string, html?: string): Promise<void> {
  if (!mailConfigured()) throw new Error('mail is not configured');
  try {
    await smtp().sendMail({ from: process.env.SMTP_FROM!.trim(), to, subject, text, html });
  } catch (e) {
    // The provider's reason is useful (auth failed, relay denied); the address is not logged.
    console.error('[mail] send failed:', (e as Error)?.message ?? e);
    throw e;
  }
}

/** The one template: short, plain, and useless to anyone who is not the recipient. */
export function verificationEmail(code: string, communityName: string) {
  const subject = `${code} is your Voiid verification code`;
  const text =
    `Your code to join ${communityName} on Voiid is ${code}.\n\n` +
    `It expires in 10 minutes. If you didn't ask for this, you can ignore this email.`;
  const html =
    `<p>Your code to join <strong>${escapeHtml(communityName)}</strong> on Voiid is</p>` +
    `<p style="font-size:28px;font-weight:700;letter-spacing:4px">${code}</p>` +
    `<p style="color:#666">It expires in 10 minutes. If you didn't ask for this, you can ignore this email.</p>`;
  return { subject, text, html };
}

function escapeHtml(s: string): string {
  return s.replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));
}
