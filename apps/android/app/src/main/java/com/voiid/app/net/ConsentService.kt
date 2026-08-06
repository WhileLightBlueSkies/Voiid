package com.voiid.app.net

import android.content.Context
import com.voiid.app.legal.LegalDocuments
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import kotlinx.serialization.Serializable
import kotlinx.serialization.json.JsonPrimitive
import kotlinx.serialization.json.buildJsonObject
import kotlinx.serialization.json.put

/**
 * The client half of DPDP consent capture. Twin of iOS `ConsentService.swift`.
 *
 * Until this file existed the backend had a consent endpoint that no client had ever
 * called, so `consent_given_at` was null for every account that has ever been created.
 * An endpoint is not a consent flow.
 *
 * THE SEQUENCING PROBLEM, AND WHY THERE IS A PENDING RECORD
 * ---------------------------------------------------------
 * The affirmative action happens on the FIRST screen of onboarding: before a phone number,
 * before an OTP, before a JWT. The server cannot record consent for an account that does
 * not exist yet, and asking after sign-in would mean processing the phone number first and
 * asking permission afterwards — the inversion DPDP s.5 ("notice at or before") forbids.
 *
 * So the tick is recorded LOCALLY the instant it happens and posted as soon as there is an
 * account to attach it to. The stored timestamp is deliberately NOT sent to the server: an
 * evidence record whose timestamp is client-supplied is one an attacker can backdate. It
 * exists here only to tell a stale pending record (an abandoned sign-up from three weeks
 * ago) from a live one.
 *
 * WITHDRAWAL IS AS EASY AS GIVING (s.6(4))
 * ----------------------------------------
 * [withdraw] takes no arguments, needs no version, and is wired to a single control in
 * Settings → Privacy & Legal. That symmetry is the requirement: a flow where consent is
 * one tap and withdrawal is a support email does not satisfy s.6(4).
 */

// ── Wire models ────────────────────────────────────────────────────────────────────
//
// Every field is nullable with a default. `ignoreUnknownKeys` handles fields the server
// adds; defaults handle fields it omits. Between them a response shape change degrades
// into a missing value rather than a thrown decode — and a thrown decode here reads to the
// user as "consent could not be recorded", which is the one wrong answer.

@Serializable
data class ConsentPurposeInfo(
    val key: String? = null,
    val required: Boolean? = null,
    val summary: String? = null,
)

@Serializable
data class ConsentNoticeInfo(
    val version: String? = null,
    val language: String? = null,
    val url: String? = null,
    val published_at: String? = null,
    val content_sha256: String? = null,
    val purposes: List<ConsentPurposeInfo>? = null,
)

@Serializable
data class ConsentRecordInfo(
    val notice_version: String? = null,
    val language: String? = null,
    val purposes: Map<String, Boolean>? = null,
    val given_at: String? = null,
    val given_via: String? = null,
)

@Serializable
data class ConsentStatus(
    val consents: List<ConsentRecordInfo>? = null,
    val current_notice_version: String? = null,
    val needs_consent: Boolean? = null,
)

@Serializable
private data class ConsentEnvelope(val consent: ConsentRecordInfo? = null)

@Serializable
private data class WithdrawEnvelope(val withdrawn: List<ConsentRecordInfo>? = null)

// ── Service ────────────────────────────────────────────────────────────────────────

object ConsentService {

    private const val PREFS = "voiid_consent"
    private const val KEY_VERSION = "pending_version"
    private const val KEY_LANGUAGE = "pending_language"
    private const val KEY_GIVEN_AT = "pending_given_at"
    private const val KEY_PURPOSES = "pending_purposes"

    /**
     * A pending record older than this is discarded rather than posted. Someone who ticked
     * the box, abandoned sign-up and came back a month later did not consent a month ago to
     * whatever the notice says today — and the version they ticked may since have been
     * retired, in which case the server would reject it anyway.
     */
    private const val PENDING_MAX_AGE_MS = 7L * 24 * 60 * 60 * 1000

    private val _status = MutableStateFlow<ConsentStatus?>(null)
    val status: StateFlow<ConsentStatus?> = _status.asStateFlow()

    /** True when an authenticated account holds no live consent to the current notice.
     *  Drives the one-time backfill prompt for accounts created before capture existed. */
    private val _needsBackfill = MutableStateFlow(false)
    val needsBackfill: StateFlow<Boolean> = _needsBackfill.asStateFlow()

    private fun prefs(context: Context) =
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    // ── Local pending record ───────────────────────────────────────────────────────

    /**
     * Record the affirmative action taken on the onboarding Terms screen.
     *
     * Called from the checkbox, not from the Continue button: the consent IS the tick, a
     * user who ticks and then abandons the flow still ticked, and a process death between
     * the two must not lose the record.
     */
    fun recordLocalConsent(
        context: Context,
        purposes: Map<String, Boolean>,
        version: String = LegalDocuments.NOTICE_VERSION,
        language: String = LegalDocuments.LANGUAGE,
    ) {
        prefs(context).edit()
            .putString(KEY_VERSION, version)
            .putString(KEY_LANGUAGE, language)
            .putLong(KEY_GIVEN_AT, System.currentTimeMillis())
            // Serialised as "key=true,key=false": a SharedPreferences string SET cannot
            // express a false value, and storing only the true keys would silently turn a
            // declined optional purpose into an absent one when a future notice has any.
            .putString(KEY_PURPOSES, purposes.entries.joinToString(",") { "${it.key}=${it.value}" })
            .apply()
    }

    /**
     * The user un-ticked the box before continuing. Drop the record — a retracted tick
     * before sign-up is an ABSENCE of consent, not a withdrawal, and posting it later would
     * manufacture agreement that was taken back.
     */
    fun clearLocalConsent(context: Context) {
        prefs(context).edit()
            .remove(KEY_VERSION).remove(KEY_LANGUAGE).remove(KEY_GIVEN_AT).remove(KEY_PURPOSES)
            .apply()
    }

    fun hasPendingConsent(context: Context): Boolean =
        prefs(context).getString(KEY_VERSION, null) != null

    // ── Server calls ──────────────────────────────────────────────────────────────

    /**
     * Which notice the server currently publishes. Used to detect that this build's bundled
     * text is older than what the server expects, in which case the honest move is "update
     * the app" rather than recording consent to text we cannot render.
     */
    suspend fun fetchCurrentNotice(
        context: Context,
        language: String = LegalDocuments.LANGUAGE,
    ): ConsentNoticeInfo =
        ApiClient(TokenStore.get(context))
            .requestAs("GET", "consent/notice?language=$language", auth = false)

    /**
     * Post consent for the signed-in account. [givenVia] must be one of the values the
     * server's CHECK constraint allows: app_onboarding, app_settings, backfill_prompt.
     *
     * Body built with [buildJsonObject] rather than a `@Serializable` request class on
     * purpose. The project's Json is configured with `explicitNulls = false` and no
     * `encodeDefaults`, so a data class field left at its default is OMITTED from the wire
     * — which is how a request that looks correct in Kotlin arrives at the server missing
     * the very fields it is about. Building the object explicitly cannot have that bug.
     */
    suspend fun submitConsent(
        context: Context,
        purposes: Map<String, Boolean>? = null,
        givenVia: String,
        version: String = LegalDocuments.NOTICE_VERSION,
        language: String = LegalDocuments.LANGUAGE,
    ): ConsentRecordInfo? {
        val body = buildJsonObject {
            put("notice_version", version)
            put("language", language)
            put("given_via", givenVia)
            if (purposes != null) {
                put("purposes", buildJsonObject {
                    purposes.forEach { (k, v) -> put(k, JsonPrimitive(v)) }
                })
            }
        }
        val env: ConsentEnvelope = ApiClient(TokenStore.get(context))
            .requestAs("POST", "consent", jsonBody = body.toString())
        refreshStatus(context)
        return env.consent
    }

    /**
     * Flush the onboarding tick once an account exists.
     *
     * Idempotent on both sides: the server upserts against a partial unique index, and the
     * local record is cleared only after a success, so a failed post is retried next launch
     * instead of being lost. Never throws — a transient network failure at sign-up must not
     * block a user from reaching the app, and the record is still on disk.
     */
    suspend fun submitPendingConsent(context: Context) {
        if (TokenStore.get(context).jwt == null) return
        val p = prefs(context)
        val version = p.getString(KEY_VERSION, null) ?: return

        val givenAt = p.getLong(KEY_GIVEN_AT, 0L)
        if (givenAt > 0 && System.currentTimeMillis() - givenAt > PENDING_MAX_AGE_MS) {
            clearLocalConsent(context)
            return
        }

        val language = p.getString(KEY_LANGUAGE, null) ?: LegalDocuments.LANGUAGE
        val purposes = p.getString(KEY_PURPOSES, null)
            ?.split(",")
            ?.mapNotNull { entry ->
                val parts = entry.split("=")
                if (parts.size == 2) parts[0] to (parts[1] == "true") else null
            }
            ?.toMap()

        try {
            submitConsent(context, purposes, givenVia = "app_onboarding",
                version = version, language = language)
            clearLocalConsent(context)
        } catch (e: ApiError.Http) {
            // A 400 means the server will never accept this record (unknown or retired
            // notice version). Retrying forever would keep the backfill prompt suppressed
            // behind a pending record that cannot land, so drop it and let the backfill
            // path ask again with a version the server does publish.
            if (e.status == 400) clearLocalConsent(context)
        } catch (e: Exception) {
            // Transport failure: keep the record, try next launch.
        }
    }

    /** Withdraw every live consent. One call, no arguments — see the header. */
    suspend fun withdraw(context: Context, via: String = "app_settings"): Int {
        val body = buildJsonObject { put("withdrawn_via", via) }
        val env: WithdrawEnvelope = ApiClient(TokenStore.get(context))
            .requestAs("POST", "consent/withdraw", jsonBody = body.toString())
        refreshStatus(context)
        return env.withdrawn?.size ?: 0
    }

    /** Refresh [status] and [needsBackfill]. Safe to call when signed out (it no-ops). */
    suspend fun refreshStatus(context: Context) {
        if (TokenStore.get(context).jwt == null) {
            _status.value = null
            _needsBackfill.value = false
            return
        }
        try {
            val fresh: ConsentStatus = ApiClient(TokenStore.get(context))
                .requestAs("GET", "consent/me?language=${LegalDocuments.LANGUAGE}")
            _status.value = fresh
            // Suppressed while a pending onboarding record is still waiting to be posted:
            // prompting someone who ticked the box thirty seconds ago, because the post has
            // not landed yet, is the app calling the user a liar.
            _needsBackfill.value = (fresh.needs_consent ?: false) && !hasPendingConsent(context)
        } catch (e: Exception) {
            // Leave the previous answer in place. Guessing "needs consent" on a network
            // error would put a blocking prompt in front of every user during an outage.
        }
    }

    /** One call for app launch: flush anything pending, then ask where we stand. */
    suspend fun syncOnLaunch(context: Context) {
        submitPendingConsent(context)
        refreshStatus(context)
    }
}
