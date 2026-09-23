// Cashfree — the payment gateway (PG), Easy Split vendor payouts, and Secure ID verification.
//
// ── WHAT THIS FILE IS ALLOWED TO DO ──────────────────────────────────────────────
//
// The PaymentProvider half does exactly what razorpay.ts does: open a checkout, and translate
// a signed webhook into 'paid' | 'failed' | 'refunded'. Idempotency, the underpayment guard
// and ticket minting stay in routes/payments.ts and payments/inbox.ts.
//
// The other two halves are thin HTTP wrappers used by routes/kyc.ts:
//   * Secure ID — PAN Lite and bank-account (penny-drop) verification.
//   * Easy Split — a VENDOR per verified host, so an order can split at source: the host's
//     share settles to their bank account and Voiid's commission to ours.
//
// ── AMOUNTS ──────────────────────────────────────────────────────────────────────
//
// Cashfree speaks RUPEES WITH DECIMALS (`order_amount: 499.00`). Everything in this codebase
// is integer MINOR units. The conversion happens here and only here, and the webhook amount
// is rounded back from the RAW payload's decimal — JSON.parse of a two-decimal number is exact
// enough for `Math.round(x * 100)` and is never re-serialised.
//
// ── WEBHOOK SIGNATURE ────────────────────────────────────────────────────────────
//
// base64( HMAC-SHA256( x-webhook-timestamp + rawBody, clientSecret ) ), compared to
// x-webhook-signature. Over the RAW bytes — see routes/payments.ts for why that matters.
//
// ── WHY A FAILED ATTEMPT IS NOT A FAILED ORDER ───────────────────────────────────
//
// A Cashfree order accepts several payment ATTEMPTS: a declined card followed by a UPI payment
// on the same session is normal. inbox.ts marks an order 'failed' on a 'failed' outcome and
// then (correctly) refuses to settle a failed order — so mapping PAYMENT_FAILED to 'failed'
// would let a buyer's successful retry take money and mint no ticket. Failed and dropped
// attempts are therefore RECORDED with no outcome; the order stays pending and resumable
// until it is paid or its session expires.
//
// ── CHECKOUT ON THE PHONE ────────────────────────────────────────────────────────
//
// Neither app embeds Cashfree's SDK. `clientPayload` carries a `checkout_url` on this API
// (routes/payments.ts serves it) that loads Cashfree's own hosted checkout; the app opens it
// in an in-app browser and polls the order, which is server-authoritative regardless.
import { createHash, createHmac, timingSafeEqual } from 'node:crypto';
import type {
  CheckoutHandle, CheckoutRequest, PaymentProvider, WebhookVerdict,
} from './provider';

/** Pinned: the webhook payload shape follows the API version, and ours is written for this. */
const API_VERSION = '2025-01-01';

export type CashfreeEnv = 'sandbox' | 'production';

function pgBase(env: CashfreeEnv): string {
  return env === 'production' ? 'https://api.cashfree.com/pg' : 'https://sandbox.cashfree.com/pg';
}
function verificationBase(env: CashfreeEnv): string {
  return env === 'production'
    ? 'https://api.cashfree.com/verification'
    : 'https://sandbox.cashfree.com/verification';
}

/** Rupees-with-decimals → integer paise. */
export function toMinor(major: unknown): number | undefined {
  const n = typeof major === 'number' ? major : typeof major === 'string' ? Number(major) : NaN;
  return Number.isFinite(n) ? Math.round(n * 100) : undefined;
}
/** Integer paise → the two-decimal number Cashfree expects. */
export function toMajor(minor: number): number {
  return Math.round(minor) / 100;
}

/** Cashfree order ids: 3-45 chars of [A-Za-z0-9_-]. Ours are `vo_` + a dashless uuid. */
export const CASHFREE_REF_RE = /^vo_[0-9a-f]{32}$/;
export function cashfreeRefFor(orderId: string): string {
  return 'vo_' + orderId.replace(/-/g, '').toLowerCase();
}

/**
 * The 10-digit Indian number Cashfree requires. It insists on a phone per customer; ours are
 * E.164 (`+919876543210`), and anything that does not reduce to ten digits falls back to a
 * placeholder rather than failing a checkout the buyer can still complete.
 */
function tenDigitPhone(phone: string | undefined): string {
  const digits = (phone ?? '').replace(/\D/g, '');
  return digits.length >= 10 ? digits.slice(-10) : '9999999999';
}

export class CashfreeProvider implements PaymentProvider {
  readonly name = 'cashfree';

  constructor(
    private readonly clientId: string,
    private readonly clientSecret: string,
    readonly env: CashfreeEnv,
    /** Public origin of this API, for the checkout page and the return URL. */
    private readonly publicBase: string,
  ) {}

  private headers(): Record<string, string> {
    return {
      'content-type': 'application/json',
      'x-api-version': API_VERSION,
      'x-client-id': this.clientId,
      'x-client-secret': this.clientSecret,
    };
  }

  checkoutUrl(providerRef: string): string {
    return `${this.publicBase}/payments/checkout/cashfree/${providerRef}`;
  }

  async createCheckout(req: CheckoutRequest): Promise<CheckoutHandle> {
    const ref = cashfreeRefFor(req.orderId);
    const body: Record<string, unknown> = {
      order_id: ref,
      order_amount: toMajor(req.amountMinor),
      order_currency: req.currency,
      customer_details: {
        // Opaque to Cashfree and stable per buyer; never a phone number or a name.
        customer_id: (req.customer?.id ?? 'guest').replace(/[^A-Za-z0-9_-]/g, '').slice(0, 50) || 'guest',
        customer_phone: tenDigitPhone(req.customer?.phone),
      },
      order_meta: {
        return_url: `${this.publicBase}/payments/return?order=${ref}`,
        notify_url: `${this.publicBase}/payments/webhook/cashfree`,
      },
      // 3-200 chars. The event title only — a bank statement is seen by third parties.
      order_note: req.description.slice(0, 200).padEnd(3, '.'),
      order_tags: Object.fromEntries(
        Object.entries(req.notes).slice(0, 15).map(([k, v]) => [k, String(v).slice(0, 255)])
      ),
    };
    // Easy Split: the host's share settles straight to their verified bank account. Omitted
    // when there is no vendor — the whole amount then settles to Voiid, and the order still
    // records the organiser's share for a manual payout.
    if (req.splits && req.splits.length > 0) {
      body.order_splits = req.splits.map((s) => ({ vendor_id: s.vendorId, amount: toMajor(s.amountMinor) }));
    }

    const res = await fetch(`${pgBase(this.env)}/orders`, {
      method: 'POST',
      headers: { ...this.headers(), 'x-idempotency-key': req.orderId },
      body: JSON.stringify(body),
    });
    if (!res.ok) {
      // Gateway bodies can carry account detail; log the status and Cashfree's own error code.
      const err = await res.json().catch(() => ({})) as { code?: string };
      console.error(`[cashfree] create order failed: HTTP ${res.status} ${err.code ?? ''}`);
      throw new Error('could not open a checkout');
    }
    const order = (await res.json()) as { order_id?: string; payment_session_id?: string };
    if (order.order_id !== ref || !order.payment_session_id) throw new Error('cashfree returned no session');

    return { providerRef: ref, clientPayload: this.clientPayload(ref, req.amountMinor, req.currency) };
  }

  /** What the app needs: where to open the checkout. The session id is fetched by that page. */
  private clientPayload(ref: string, amountMinor: number, currency: string): Record<string, unknown> {
    return {
      provider: 'cashfree',
      order_ref: ref,
      checkout_url: this.checkoutUrl(ref),
      amount: amountMinor,
      currency,
    };
  }

  resumeCheckout(providerRef: string, amountMinor: number, currency: string): Record<string, unknown> {
    if (!CASHFREE_REF_RE.test(providerRef) || !Number.isSafeInteger(amountMinor) || amountMinor <= 0) {
      throw new Error('invalid saved checkout');
    }
    return this.clientPayload(providerRef, amountMinor, currency);
  }

  /** The live session for an order, or null when it is paid, expired or unknown. */
  async paymentSession(providerRef: string): Promise<string | null> {
    const res = await fetch(`${pgBase(this.env)}/orders/${encodeURIComponent(providerRef)}`, {
      headers: this.headers(),
    });
    if (!res.ok) return null;
    const order = (await res.json()) as { order_status?: string; payment_session_id?: string };
    return order.order_status === 'ACTIVE' && order.payment_session_id ? order.payment_session_id : null;
  }

  verifyWebhook(rawBody: Buffer, headers: Record<string, unknown>): WebhookVerdict {
    const sent = String(headers['x-webhook-signature'] ?? '');
    const timestamp = String(headers['x-webhook-timestamp'] ?? '');
    if (!sent || !timestamp) return { ok: false };

    const expected = createHmac('sha256', this.clientSecret)
      .update(timestamp)
      .update(rawBody)
      .digest('base64');
    const a = Buffer.from(expected, 'utf8');
    const b = Buffer.from(sent, 'utf8');
    if (a.length !== b.length || !timingSafeEqual(a, b)) return { ok: false };

    let payload: any;
    try {
      payload = JSON.parse(rawBody.toString('utf8'));
    } catch {
      return { ok: false };
    }

    const eventType = String(payload?.type ?? '');
    if (!eventType) return { ok: false };
    // Cashfree sends no per-delivery id header. A retry re-sends the SAME bytes, so a hash of
    // the signed body identifies this delivery exactly — and a different event about the same
    // order (a refund after a payment) hashes differently, which is the property 032 needs.
    const eventId = createHash('sha256').update(rawBody).digest('hex');

    const data = payload?.data ?? {};
    const refund = data.refund;
    const payment = data.payment;
    const order = data.order;

    let outcome: WebhookVerdict['outcome'];
    let providerRef: string | undefined;
    let amountMinor: number | undefined;
    let currency: string | undefined;

    if (eventType.includes('REFUND')) {
      providerRef = refund?.order_id ?? order?.order_id;
      // Only a COMPLETED refund moves the order; a pending or cancelled one is just recorded.
      if (refund?.refund_status === 'SUCCESS') outcome = 'refunded';
      currency = refund?.refund_currency ?? order?.order_currency;
    } else {
      providerRef = order?.order_id;
      if (eventType === 'PAYMENT_SUCCESS_WEBHOOK' && payment?.payment_status === 'SUCCESS') {
        outcome = 'paid';
        // What was PAID, for the underpayment guard — not what the order asked for.
        amountMinor = toMinor(payment?.payment_amount);
        currency = payment?.payment_currency ?? order?.order_currency;
      }
      // PAYMENT_FAILED / PAYMENT_USER_DROPPED: recorded, no outcome. See the header.
    }

    return {
      ok: true,
      eventId,
      eventType,
      providerRef: providerRef && CASHFREE_REF_RE.test(providerRef) ? providerRef : providerRef || undefined,
      outcome,
      reason: payment?.payment_message ?? undefined,
      amountMinor,
      currency,
      payload,
    };
  }

  // ── Easy Split ──────────────────────────────────────────────────────────────────

  /**
   * Register a verified host as a vendor. The bank details go to Cashfree and are NOT kept
   * here — Voiid stores the vendor id and the last four digits, nothing a leak could spend.
   */
  async createVendor(v: VendorInput): Promise<{ vendorId: string; status: string }> {
    const res = await fetch(`${pgBase(this.env)}/easy-split/vendors`, {
      method: 'POST',
      headers: this.headers(),
      body: JSON.stringify({ vendor_id: v.vendorId, ...vendorBody(v) }),
    });
    const out = await res.json().catch(() => ({})) as { vendor_id?: string; status?: string; code?: string; message?: string };
    if (!res.ok || !out.vendor_id) {
      console.error(`[cashfree] create vendor failed: HTTP ${res.status} ${out.code ?? ''}`);
      throw new CashfreeError(out.message ?? 'could not register the payout account', res.status);
    }
    return { vendorId: out.vendor_id, status: out.status ?? 'UNKNOWN' };
  }

  /**
   * A host who re-submits (a rejected application, a changed bank) already has a vendor —
   * vendor ids are permanent at Cashfree — so the new details replace the old ones in place.
   */
  async updateVendor(v: VendorInput): Promise<{ vendorId: string; status: string }> {
    const res = await fetch(`${pgBase(this.env)}/easy-split/vendors/${encodeURIComponent(v.vendorId)}`, {
      method: 'PATCH',
      headers: this.headers(),
      body: JSON.stringify(vendorBody(v)),
    });
    const out = await res.json().catch(() => ({})) as { vendor_id?: string; status?: string; code?: string; message?: string };
    if (!res.ok) {
      console.error(`[cashfree] update vendor failed: HTTP ${res.status} ${out.code ?? ''}`);
      throw new CashfreeError(out.message ?? 'could not update the payout account', res.status);
    }
    return { vendorId: v.vendorId, status: out.status ?? 'UNKNOWN' };
  }
}

/**
 * Where a host is paid: a bank account, or a UPI ID. Easy Split takes either — exactly one is
 * sent, and the other key is left out rather than sent as null.
 */
export type VendorInput = {
  vendorId: string; name: string; email: string; phone: string; pan: string; accountHolder: string;
} & ({ method: 'bank'; accountNumber: string; ifsc: string } | { method: 'upi'; vpa: string });

function vendorBody(v: VendorInput): Record<string, unknown> {
  return {
    status: 'ACTIVE',
    name: v.name,
    email: v.email,
    phone: tenDigitPhone(v.phone),
    verify_account: true,
    dashboard_access: false,
    schedule_option: 1,
    ...(v.method === 'bank'
      ? { bank: { account_number: v.accountNumber, account_holder: v.accountHolder, ifsc: v.ifsc } }
      : { upi: { vpa: v.vpa, account_holder: v.accountHolder } }),
    kyc_details: { account_type: 'INDIVIDUAL', business_type: 'Education', pan: v.pan },
  };
}

export class CashfreeError extends Error {
  constructor(message: string, readonly status: number) { super(message); }
}

// ── Secure ID ───────────────────────────────────────────────────────────────────────

export interface PanResult {
  valid: boolean;
  /** Name on the PAN per the Income Tax Department — what payouts must match. */
  registeredName?: string;
  nameMatch?: boolean;
  referenceId?: string;
}

export interface BankResult {
  valid: boolean;
  nameAtBank?: string;
  /** Cashfree's DIRECT_MATCH / GOOD_PARTIAL_MATCH / MODERATE_PARTIAL_MATCH / POOR_PARTIAL_MATCH / NO_MATCH. */
  nameMatchResult?: string;
  statusCode?: string;
  referenceId?: string;
  bankName?: string;
}

/** Name-match results strong enough to pay out against without a human looking. */
export const AUTO_ACCEPT_NAME_MATCH = new Set(['DIRECT_MATCH', 'GOOD_PARTIAL_MATCH']);

export class CashfreeVerification {
  constructor(
    private readonly clientId: string,
    private readonly clientSecret: string,
    readonly env: CashfreeEnv,
  ) {}

  private async post(path: string, body: unknown): Promise<any> {
    const res = await fetch(`${verificationBase(this.env)}${path}`, {
      method: 'POST',
      headers: {
        'content-type': 'application/json',
        'x-client-id': this.clientId,
        'x-client-secret': this.clientSecret,
      },
      body: JSON.stringify(body),
    });
    const out = await res.json().catch(() => ({}));
    if (!res.ok) {
      // Never log the request: it carries the PAN or the account number.
      console.error(`[cashfree-secureid] ${path} failed: HTTP ${res.status} ${(out as any)?.code ?? ''}`);
      throw new CashfreeError((out as any)?.message ?? 'verification service unavailable', res.status);
    }
    return out;
  }

  async verifyPan(verificationId: string, pan: string, name: string): Promise<PanResult> {
    const out = await this.post('/pan-lite', { verification_id: verificationId, pan, name });
    return {
      valid: out?.status === 'VALID',
      registeredName: out?.name ?? out?.registered_name,
      nameMatch: out?.name_match === 'Y' ? true : out?.name_match === 'N' ? false : undefined,
      referenceId: out?.reference_id != null ? String(out.reference_id) : undefined,
    };
  }

  private async get(path: string): Promise<any> {
    const res = await fetch(`${verificationBase(this.env)}${path}`, {
      headers: { 'x-client-id': this.clientId, 'x-client-secret': this.clientSecret },
    });
    const out = await res.json().catch(() => ({}));
    if (!res.ok) {
      console.error(`[cashfree-secureid] GET ${path.split('?')[0]} failed: HTTP ${res.status} ${(out as any)?.code ?? ''}`);
      throw new CashfreeError((out as any)?.message ?? 'verification service unavailable', res.status);
    }
    return out;
  }

  /**
   * DigiLocker: a link the host opens to sign in to DigiLocker (Aadhaar + OTP on DigiLocker's
   * own page) and consent to share their Aadhaar. Lives 10 minutes. `redirectUrl` is where
   * DigiLocker sends them afterwards.
   */
  async createDigilocker(verificationId: string, redirectUrl: string): Promise<{ url: string }> {
    const out = await this.post('/digilocker', {
      verification_id: verificationId,
      document_requested: ['AADHAAR'],
      redirect_url: redirectUrl,
      user_flow: 'signup',
    });
    if (typeof out?.url !== 'string') throw new CashfreeError('DigiLocker returned no link', 502);
    return { url: out.url };
  }

  /** PENDING | AUTHENTICATED | EXPIRED | CONSENT_DENIED. */
  async digilockerStatus(verificationId: string): Promise<string> {
    const out = await this.get(`/digilocker?verification_id=${encodeURIComponent(verificationId)}`);
    return String(out?.status ?? 'PENDING');
  }

  /**
   * The Aadhaar DigiLocker shared. `uid` arrives MASKED ("xxxxxxxx5647"); only its last four
   * digits and the name leave this function — the photo, address and XML are dropped here.
   */
  async digilockerAadhaar(verificationId: string): Promise<{ last4: string | null; name: string | null }> {
    const out = await this.get(`/digilocker/document/AADHAAR?verification_id=${encodeURIComponent(verificationId)}`);
    const digits = String(out?.uid ?? '').replace(/\D/g, '');
    return { last4: digits.length >= 4 ? digits.slice(-4) : null, name: typeof out?.name === 'string' ? out.name : null };
  }

  /**
   * UPI penny drop: ₹1 to the VPA, and the bank returns the holder's name. Synchronous.
   * `user_consent` is required by the API — the host gives it by submitting the form, which
   * says a ₹1 check will be made.
   */
  async verifyUpi(verificationId: string, vpa: string, name: string): Promise<BankResult> {
    const out = await this.post('/upi/penny-drop', {
      verification_id: verificationId,
      vpa,
      name,
      user_consent: {
        obtained: true, type: 'EXPLICIT', timestamp: new Date().toISOString(),
        purpose: 'Verify payout account for event ticket sales',
      },
    });
    return {
      valid: out?.status === 'VALID' || out?.status === 'SUCCESS',
      nameAtBank: out?.name_at_bank,
      nameMatchResult: out?.name_match_result,
      statusCode: out?.status,
      referenceId: out?.reference_id != null ? String(out.reference_id) : undefined,
      bankName: out?.ifsc_details?.bank ?? out?.ifsc_details?.bank_name,
    };
  }

  async verifyBankAccount(account: string, ifsc: string, name: string): Promise<BankResult> {
    const out = await this.post('/bank-account/sync', { bank_account: account, ifsc, name });
    return {
      valid: out?.account_status === 'VALID',
      nameAtBank: out?.name_at_bank,
      nameMatchResult: out?.name_match_result,
      statusCode: out?.account_status_code,
      referenceId: out?.reference_id != null ? String(out.reference_id) : undefined,
      bankName: out?.bank_name ?? out?.ifsc_details?.bank,
    };
  }
}

// ── From the environment ──────────────────────────────────────────────────────────

function envName(): CashfreeEnv {
  return process.env.CASHFREE_ENV?.trim() === 'production' ? 'production' : 'sandbox';
}

export function apiPublicBase(): string {
  return (process.env.VOIID_API_PUBLIC_URL?.trim() || 'https://api-dev.voiid.app').replace(/\/+$/, '');
}

/** Both or nothing — a half-configured gateway would offer paid events it cannot verify. */
export function cashfreeFromEnv(): CashfreeProvider | null {
  const id = process.env.CASHFREE_PG_CLIENT_ID?.trim();
  const secret = process.env.CASHFREE_PG_CLIENT_SECRET?.trim();
  if (!id || !secret) {
    if (id || secret) {
      console.error('[cashfree] partially configured — need CASHFREE_PG_CLIENT_ID and ' +
        'CASHFREE_PG_CLIENT_SECRET. Not registering; paid events stay disabled.');
    }
    return null;
  }
  return new CashfreeProvider(id, secret, envName(), apiPublicBase());
}

/**
 * Secure ID is a separate Cashfree product and usually has its own keys. When those are not
 * set, the PG keys are tried — some accounts have one key pair for both.
 */
export function cashfreeVerificationFromEnv(): CashfreeVerification | null {
  const id = process.env.CASHFREE_SECUREID_CLIENT_ID?.trim() || process.env.CASHFREE_PG_CLIENT_ID?.trim();
  const secret = process.env.CASHFREE_SECUREID_CLIENT_SECRET?.trim() || process.env.CASHFREE_PG_CLIENT_SECRET?.trim();
  if (!id || !secret) return null;
  return new CashfreeVerification(id, secret, envName());
}
