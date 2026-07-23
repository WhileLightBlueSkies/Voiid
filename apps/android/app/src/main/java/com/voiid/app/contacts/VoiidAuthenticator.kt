package com.voiid.app.contacts

import android.accounts.AbstractAccountAuthenticator
import android.accounts.Account
import android.accounts.AccountAuthenticatorResponse
import android.accounts.NetworkErrorException
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.IBinder

/**
 * A do-nothing account authenticator.
 *
 * WHY THIS EXISTS AT ALL: `ContactsContract` will not accept a RawContact whose
 * `ACCOUNT_TYPE` has no registered authenticator, and a sync adapter cannot be bound to an
 * account type that does not exist. So the "Voiid" rows inside a contact card require a
 * real [Account] — which requires this class, even though Voiid's own authentication is a
 * JWT in [com.voiid.app.net.TokenStore] and has nothing to do with `AccountManager`.
 *
 * Every credential method therefore returns null or throws: we never want the system
 * prompting for a Voiid password, and the account is created by us in
 * [VoiidAccountManager], not by the user through Settings > Add account.
 *
 * USER-VISIBLE CONSEQUENCE, deliberately accepted: a "Voiid" entry appears in
 * Settings > Accounts with a sync toggle. Turning that toggle off is a legitimate way for
 * the user to remove the contact rows, and everything else in the app keeps working.
 */
class VoiidAuthenticator(context: Context) : AbstractAccountAuthenticator(context) {

    /** No properties to edit — the account is a marker, not a credential store. */
    override fun editProperties(response: AccountAuthenticatorResponse?, accountType: String?): Bundle =
        throw UnsupportedOperationException("Voiid accounts are created by the app, not by Settings")

    /** Null suppresses the "add account" flow: Settings > Add account must not offer Voiid. */
    @Throws(NetworkErrorException::class)
    override fun addAccount(
        response: AccountAuthenticatorResponse?,
        accountType: String?,
        authTokenType: String?,
        requiredFeatures: Array<out String>?,
        options: Bundle?,
    ): Bundle? = null

    @Throws(NetworkErrorException::class)
    override fun confirmCredentials(
        response: AccountAuthenticatorResponse?,
        account: Account?,
        options: Bundle?,
    ): Bundle? = null

    @Throws(NetworkErrorException::class)
    override fun getAuthToken(
        response: AccountAuthenticatorResponse?,
        account: Account?,
        authTokenType: String?,
        options: Bundle?,
    ): Bundle? = null

    override fun getAuthTokenLabel(authTokenType: String?): String? = null

    @Throws(NetworkErrorException::class)
    override fun updateCredentials(
        response: AccountAuthenticatorResponse?,
        account: Account?,
        authTokenType: String?,
        options: Bundle?,
    ): Bundle? = null

    @Throws(NetworkErrorException::class)
    override fun hasFeatures(
        response: AccountAuthenticatorResponse?,
        account: Account?,
        features: Array<out String>?,
    ): Bundle = Bundle().apply { putBoolean(android.accounts.AccountManager.KEY_BOOLEAN_RESULT, false) }
}

/**
 * Binds [VoiidAuthenticator] to the `android.accounts.AccountAuthenticator` action so the
 * system can discover our account type. Exported by necessity (AccountManager lives in
 * another process); it exposes nothing but the stub above.
 */
class VoiidAuthenticatorService : Service() {

    private val authenticator by lazy { VoiidAuthenticator(this) }

    override fun onBind(intent: Intent?): IBinder? = authenticator.iBinder
}
