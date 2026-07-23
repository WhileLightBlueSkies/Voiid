package com.voiid.app.net

import android.app.Activity
import android.os.Bundle

/**
 * "Call back" from the SYSTEM CALL LOG.
 *
 * Android 16.1 replaced [android.telecom.PhoneAccount.EXTRA_LOG_SELF_MANAGED_CALLS] with a
 * unified VoIP call history (`CallLog.Calls.CONTENT_VOIP_URI`). On that path the dialer
 * redials a VoIP entry by firing `android.telecom.action.CALL_BACK` at the app that owns
 * it, with the call's handle as the intent data — and per the platform docs, *declaring*
 * this receiver is itself part of what makes those entries appear.
 *
 * We ship BOTH mechanisms deliberately: the deprecated extra is the only thing that works
 * on the phones people own today, and this is the only thing that will work on Android
 * 16.1+. Neither is guaranteed on every OEM ROM — see the caveat on [TelecomBridge].
 *
 * The action string is used literally rather than via `TelecomManager.ACTION_CALL_BACK`
 * so this compiles against every compileSdk we might build with.
 */
class CallBackActivity : Activity() {

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        // The dialer hands back the handle we put on the call (a tel: Uri when we had the
        // peer's number). Map it to a user through the local directory — the exact reverse of
        // the lookup that produced the handle in the first place.
        val handle = intent?.data
        val number = handle?.schemeSpecificPart
        // A "voiid:" handle carries the user id directly; a "tel:" one needs the reverse
        // number lookup. Anything else came from somewhere we don't recognise.
        when (handle?.scheme?.lowercase()) {
            "voiid" -> ExternalCallStarter.startFromUserId(this, number, video = false)
            else -> ExternalCallStarter.startFromPhone(this, number, video = false)
        }
        // NoDisplay: must finish before onResume completes.
        finish()
    }
}
