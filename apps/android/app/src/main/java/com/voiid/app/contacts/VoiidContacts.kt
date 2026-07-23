package com.voiid.app.contacts

/**
 * The identifiers that tie the four halves of contact-card integration together: the
 * account authenticator (`res/xml/authenticator.xml`), the sync adapter
 * (`res/xml/contacts_sync_adapter.xml`), the row declarations
 * (`res/xml/contacts.xml`) and the `ACTION_VIEW` activity that makes a row tappable.
 *
 * All four must agree EXACTLY or the rows silently never render — there is no error, no
 * log line, and nothing to debug. They are declared once here and referenced from Kotlin;
 * the XML copies are the only unavoidable duplication and are commented as such.
 */
object VoiidContacts {

    /** Must match `android:accountType` in authenticator.xml and contacts_sync_adapter.xml. */
    const val ACCOUNT_TYPE = "com.voiid.app"

    /**
     * The single account we create. Stable on purpose: deriving it from the signed-in user
     * would strand an orphan account (and its contact rows) on every re-login.
     */
    const val ACCOUNT_NAME = "Voiid"

    /** Must match the `<data android:mimeType>` filters in the manifest and contacts.xml. */
    const val MIME_VOICE_CALL = "vnd.android.cursor.item/vnd.com.voiid.app.call"
    const val MIME_VIDEO_CALL = "vnd.android.cursor.item/vnd.com.voiid.app.video"

    /**
     * DATA2 is the row's first line (`summaryColumn` in contacts.xml). The "(Voiid)" is
     * written into the string rather than left to the account label, because OEM contact
     * apps disagree about whether they show the account name next to a row — and a row that
     * just says "Voice call" inside a contact card is ambiguous with the dialer's own.
     */
    const val LABEL_VOICE_CALL = "Voice call (Voiid)"
    const val LABEL_VIDEO_CALL = "Video call (Voiid)"
}
