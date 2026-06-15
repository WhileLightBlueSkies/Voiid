// SMS / OTP provider interface (Section 2.2 portability boundary).
// Firebase is the OTP SENDER ONLY — it does NOT own identity. Swappable to MSG91 / Twilio
// by changing SMS_PROVIDER, with no changes to the auth/identity layer.

export interface SmsProvider {
  /** Send an OTP code to a phone number. Returns provider-side delivery id (optional). */
  sendOtp(phoneNumber: string, code: string): Promise<{ id?: string }>;
}

// Placeholder implementations. Wire real Firebase/MSG91 SDKs in Phase 0 step 3.
class FirebaseSmsProvider implements SmsProvider {
  async sendOtp(phoneNumber: string, _code: string): Promise<{ id?: string }> {
    // TODO(phase0): integrate Firebase Phone Auth send. Firebase = sender only.
    console.warn(`[sms:firebase] (stub) would send OTP to ${phoneNumber}`);
    return {};
  }
}

class Msg91SmsProvider implements SmsProvider {
  async sendOtp(phoneNumber: string, _code: string): Promise<{ id?: string }> {
    // TODO: integrate MSG91 (cheaper in India at volume).
    console.warn(`[sms:msg91] (stub) would send OTP to ${phoneNumber}`);
    return {};
  }
}

export function getSmsProvider(provider = process.env.SMS_PROVIDER ?? 'firebase'): SmsProvider {
  switch (provider) {
    case 'msg91':
      return new Msg91SmsProvider();
    case 'firebase':
    default:
      return new FirebaseSmsProvider();
  }
}
