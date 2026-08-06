package com.voiid.app.legal

/**
 * The privacy notice and the terms, as data, bundled in the APK.
 * Twin of `apps/ios/Voiid/Voiid/Legal/LegalDocuments.swift` — the two must say the same
 * thing, word for word where the wording matters. A user on Android agreeing to
 * "version 2026-08-01" must have been shown what a user on iOS was shown.
 *
 * WHY BUNDLED AND NOT A WEB LINK
 * ------------------------------
 * DPDP s.5 requires the notice to be available at or BEFORE consent, and consent is asked
 * for on the first screen of onboarding — before a phone number, before a network
 * round-trip, sometimes before a working connection. A notice that lives only on a website
 * is unreachable at exactly the moment it is legally required to be reachable, and a link
 * that 404s is worse than no link. `database/migrations/031_consent_notice.sql` records
 * this on the registry row: its `url` is `app://voiid/legal/2026-08-01/en`, an honest
 * locator for a document that is genuinely here.
 *
 * WHAT MUST STAY TRUE
 * -------------------
 * 1. [NOTICE_VERSION] here, the `version` column of the seeded `consent_notices` row, and
 *    `NOTICE_PURPOSES` in `backend/api/src/routes/consent.ts` are ONE version string in
 *    three places. Changing the words below changes what people are agreeing to: publish a
 *    NEW version in a migration and bump all three, never edit in place. The server
 *    rejects a version it has not published, so a mismatch fails loudly at the consent call
 *    rather than quietly recording agreement to text nobody saw.
 * 2. Every factual claim below is a claim about code that exists. Where a behaviour is
 *    stated but not yet built it is listed in [LegalDocument.pendingCounselOrBuild] and
 *    rendered to the user as unfinished, not asserted in the body as though it were live.
 *
 * TODO [COUNSEL] — THIS TEXT HAS NOT BEEN REVIEWED BY A LAWYER.
 * It was written by engineering to describe accurately what the system does and does not
 * do, which is the part engineering can answer. Everything an India-qualified
 * data-protection lawyer must decide is deliberately ABSENT rather than invented, and is
 * named in the pending list so it is visible in the app instead of being a gap nobody can
 * see. Open questions tracked in docs/LEGAL_QUESTIONS.md §3/§6 and
 * docs/research/11_admin_dpdp.md §6. Do not ship to the public Play Store until that list
 * is empty.
 */

/**
 * One legal document, structured rather than one blob of markdown: the renderer needs
 * headings it can style, and a flat string cannot be diffed against the iOS copy paragraph
 * by paragraph.
 */
data class LegalDocument(
    val id: String,
    val title: String,
    /** The registry version this text belongs to. Rendered — "which version did I agree
     *  to" must be answerable from the screen, not only from the database. */
    val version: String,
    val effectiveDate: String,
    val summary: String,
    val sections: List<Section>,
    /** Rendered under a "Still being finalised" heading. Empty means the document is done. */
    val pendingCounselOrBuild: List<String>,
) {
    /** [body] entries starting with "• " render as bullets; keeping them in one list
     *  preserves author order instead of forcing every section into paragraphs-then-bullets. */
    data class Section(val id: String, val heading: String, val body: List<String>)
}

/** Display copy of the backend's `NOTICE_PURPOSES`. The server is the authority on what
 *  may be stored — it rejects a key it does not declare — this is what the person
 *  deciding actually reads. Both change together. */
data class ConsentPurpose(
    val id: String,
    val title: String,
    val detail: String,
    /** Required = Voiid cannot deliver the service without it. In this version every
     *  purpose is required, which is itself an open question — see the notice's pending
     *  list: DPDP s.6 wants consent that is specific and unconditional. */
    val required: Boolean,
)

object LegalDocuments {

    /** MUST equal the `version` of the seeded `consent_notices` row and the key in the
     *  backend's `NOTICE_PURPOSES`. */
    const val NOTICE_VERSION = "2026-08-01"

    /** BCP-47. Only English is published; whether the Eighth-Schedule translation
     *  obligation applies at Voiid's size is an open question for counsel, and shipping
     *  machine translations of a legal notice would answer it by accident. */
    const val LANGUAGE = "en"

    val purposes: List<ConsentPurpose> = listOf(
        ConsentPurpose(
            id = "identity",
            title = "Being you, and being findable",
            detail = "Your phone number is your account. It is also how someone who already has your number can find you on Voiid.",
            required = true,
        ),
        ConsentPurpose(
            id = "delivery",
            title = "Delivering what you send",
            detail = "To hand a message or a call to the right device, Voiid has to know which account it is addressed to and when it arrived. It never knows what is inside.",
            required = true,
        ),
        ConsentPurpose(
            id = "security",
            title = "Keeping accounts safe",
            detail = "Blocking automated sign-up attacks and abuse. This is the only reason your IP address is ever written down.",
            required = true,
        ),
        ConsentPurpose(
            id = "support_diagnostics",
            title = "Fixing things when they break",
            detail = "Your device type, OS version and app version, so a bug report can be reproduced instead of guessed at.",
            required = true,
        ),
    )

    val privacy = LegalDocument(
        id = "privacy",
        title = "Privacy Notice",
        version = NOTICE_VERSION,
        effectiveDate = "1 August 2026",
        summary = "Voiid cannot read your messages, hear your calls, see your live location or open your " +
            "moments. It can see who you exchange messages with and when, what kind of device you use, " +
            "and the IP address you connect from. This notice explains exactly where that line falls " +
            "and why it falls there.",
        sections = listOf(
            LegalDocument.Section(
                id = "cannot-see",
                heading = "What Voiid cannot see",
                body = listOf(
                    "Your messages, and the photos, videos, voice notes and files you send with them, are encrypted on your device and can only be decrypted on the device of the person you sent them to. Voiid's servers hold the encrypted bytes and do not hold the key.",
                    "The same is true of:",
                    "• The audio and video of your calls.",
                    "• Your live location when you share it. Position updates are encrypted before they leave your phone; no endpoint on our servers accepts or returns a coordinate.",
                    "• Your moments, and the photos and videos in them.",
                    "• Your encrypted backup. It is locked with a key derived from your recovery phrase, which never leaves your device. If you lose that phrase we cannot recover your history for you — not as a policy, but because we do not have it.",
                    "This is not a promise we could quietly stop keeping. There is no setting, no court order and no internal tool that produces content we never held. If you ever hear that Voiid handed over the contents of a conversation, it did not happen the way it was described.",
                    "One deliberate exception: Clips, and the comments on them, are public posts. They are not encrypted, because a broadcast has no fixed set of recipients to encrypt to. Voiid stores them in the clear, counts views and likes on them, and can remove them if they are reported. Everything else in this notice about encrypted content does not apply to Clips — post accordingly.",
                ),
            ),
            LegalDocument.Section(
                id = "can-see",
                heading = "What Voiid can see",
                body = listOf(
                    "A server has to know where to deliver something in order to deliver it, so some information about your account cannot be encrypted. All of it:",
                    "• Your phone number. It is your account.",
                    "• Your profile — the name, photo, bio and status you set — and the username you choose for Clips. You typed these to be seen; your contacts see them.",
                    "• Message metadata: which account and device a message is addressed to, roughly how big it is, when it arrived on the server and when it was collected. Not what it says.",
                    "• Call metadata: that a call happened, between which accounts, when, and for how long. Not the audio or the video.",
                    "• Device metadata: the device name your phone reports, the platform, the OS version, the app version, and the push token needed to wake the app. Push notifications carry no message content — they are a nudge to fetch, not the thing itself.",
                    "• Your IP address, which every internet connection reveals. Voiid writes it down only into security logs, and only when something looks like abuse: a rate limit tripped, a suspicious sign-in. It is never stored alongside a device record or a message.",
                    "• Clips and comments you post, in the clear, along with view and like counts.",
                    "• Your consent record: which version of this notice you agreed to, in which language, when, and whether you later withdrew it.",
                    "Deliberately not collected: no advertising identifier, no device fingerprint, no coarse or background location, no contact-graph analysis beyond matching the numbers you chose to sync, and no behavioural or usage telemetry of any kind.",
                ),
            ),
            LegalDocument.Section(
                id = "purposes",
                heading = "Why we hold it",
                body = listOf(
                    "Everything listed above is held for one of four reasons, and no others:",
                    "• Being you, and being findable — your phone number is your account, and it is how someone who already has your number finds you.",
                    "• Delivering what you send — to hand a message or a call to the right device we have to know which account it is addressed to, and when.",
                    "• Keeping accounts safe — blocking automated attacks and abuse. This is the only reason an IP address is ever written down.",
                    "• Fixing things when they break — your device type, OS version and app version, so a bug report can be reproduced rather than guessed at.",
                    "Voiid does not sell your data, does not share it for advertising, and does not use it to build a profile of you.",
                ),
            ),
            LegalDocument.Section(
                id = "retention",
                heading = "How long we keep it",
                body = listOf(
                    "• Your phone number, profile and device records: for as long as your account exists.",
                    "• Security logs containing IP addresses: 90 days.",
                    "• Sign-in code records: deleted shortly after the code expires.",
                    "• Encrypted messages waiting to be collected: until your device collects them.",
                    "• After you delete your account: a short grace period, currently 30 days, and then a permanent purge — including your phone number, which is the whole point of deleting.",
                    "These periods are the ones we have set. They have not yet been reviewed by a lawyer, and the background jobs that enforce two of them automatically are still being built — see the end of this notice.",
                ),
            ),
            LegalDocument.Section(
                id = "processors",
                heading = "Who else is involved",
                body = listOf(
                    "Voiid uses a small number of outside services, and what each one can see is limited by design:",
                    "• Firebase (Google) verifies your phone number by SMS during sign-in. It sees your phone number.",
                    "• Cloudflare R2 stores media. For messages, moments and backups it stores encrypted bytes it cannot read. For Clips, which are public, it stores the video itself.",
                    "• Apple and Google deliver push notifications. They see that your device should wake up, not what for.",
                    "• LiveKit carries group call media.",
                    "Where these companies physically store data, and what their contracts must say to satisfy Indian data-protection law, is still being confirmed — see the end of this notice.",
                ),
            ),
            LegalDocument.Section(
                id = "rights",
                heading = "Your choices",
                body = listOf(
                    "• Withdraw your consent at any time, from Settings → Privacy & Legal. It takes the same single tap that giving it did. Because every purpose above is one Voiid cannot run without, withdrawing consent means your account can no longer be operated — the app will tell you so plainly and take you to account deletion. Withdrawing does not delete anything by itself.",
                    "• Delete your account, from Settings → Edit Profile. This starts the purge described above.",
                    "• Correct your profile at any time from the same screen.",
                    "• Ask for a copy of what Voiid holds about you. It will be metadata only — your account record, your devices, your consent history, your Clips. There is no message content to give you, because we do not have any.",
                ),
            ),
            LegalDocument.Section(
                id = "changes",
                heading = "If this notice changes",
                body = listOf(
                    "Each version of this notice has a version number, shown at the top of this screen, and your agreement is recorded against that exact version. If we publish a new one we will ask you again rather than assume your answer carried over.",
                ),
            ),
        ),
        pendingCounselOrBuild = listOf(
            "This notice has been written by Voiid's engineering team to describe accurately what the app and its servers do. It has not yet been reviewed by a lawyer qualified in Indian data-protection law, and the following are deliberately not yet answered here rather than answered wrongly:",
            "• The name and contact details of the grievance officer you can complain to, and how quickly we must respond.",
            "• Whether the retention periods above are the right ones, and whether Indian IT Rules require us to keep some records for longer than we would choose to.",
            "• Voiid's position on accounts belonging to under-18s, and how parental consent would be verified for a phone-number-only sign-up.",
            "• Where each outside service physically stores data, and whether any transfer needs additional safeguards.",
            "• Whether this notice must be published in languages other than English.",
            "Two of the deletion schedules described above are not yet enforced automatically — the jobs that purge expired security logs and permanently erase deleted accounts are still being built. Until they run, those deletions are not happening on the schedule stated.",
        ),
    )

    val terms = LegalDocument(
        id = "terms",
        title = "Terms of Use",
        version = NOTICE_VERSION,
        effectiveDate = "1 August 2026",
        summary = "The short version: your account is yours, the content you send is yours and we cannot " +
            "read it, Clips you post are public, and if you use Voiid to harm people we will remove " +
            "what you posted and may close your account.",
        sections = listOf(
            LegalDocument.Section(
                id = "account",
                heading = "Your account",
                body = listOf(
                    "Your account is your phone number. Keep access to that number and to this device: anyone who controls both can sign in as you.",
                    "You can see every device signed into your account, and sign any of them out, from Settings → Linked Devices.",
                ),
            ),
            LegalDocument.Section(
                id = "content",
                heading = "What you send",
                body = listOf(
                    "What you write, record and send stays yours. Voiid does not read it, cannot read it, and claims no rights over it.",
                    "Because we cannot read it, we also cannot get it back for you. If you lose your device and your recovery phrase, your message history is gone. That is the cost of the encryption, and it is the deliberate trade.",
                ),
            ),
            LegalDocument.Section(
                id = "clips",
                heading = "Clips are public",
                body = listOf(
                    "A Clip is a public post. Anyone using Voiid can watch it, comment on it and report it, and Voiid's moderators can see it and remove it. Do not put anything in a Clip you would not put on a public website.",
                ),
            ),
            LegalDocument.Section(
                id = "acceptable",
                heading = "What you may not do",
                body = listOf(
                    "• Harass, threaten or impersonate people.",
                    "• Post content that sexualises children, incites violence, or that Indian law prohibits.",
                    "• Send bulk unsolicited messages, or automate sign-ups.",
                    "• Attack the service — probing for holes, scraping accounts, or trying to overwhelm it.",
                    "We can remove a public Clip and we can close an account for these. We cannot remove a message from a conversation, because we cannot see conversations; blocking the sender is the control that exists, and it is on your device.",
                ),
            ),
            LegalDocument.Section(
                id = "availability",
                heading = "Availability",
                body = listOf(
                    "Voiid is offered as it is. Features can change, and the service can be interrupted. We will not pretend otherwise in advance.",
                ),
            ),
            LegalDocument.Section(
                id = "changes-terms",
                heading = "If these terms change",
                body = listOf(
                    "These terms carry the same version number as the privacy notice and change with it. A new version means we ask you again.",
                ),
            ),
        ),
        pendingCounselOrBuild = listOf(
            "These terms describe how Voiid actually works. The clauses that a contract normally also contains have deliberately been left out rather than drafted by engineers, and are still to be written by a lawyer:",
            "• Limitation of liability, warranties and indemnities.",
            "• Governing law, jurisdiction and how disputes are resolved.",
            "• The minimum age to use Voiid, and what happens to an account below it.",
            "• Notice-and-takedown and grievance timelines under Indian IT Rules, and who the named grievance officer is.",
            "• Anything about paid features, which do not exist yet.",
        ),
    )

    val all: List<LegalDocument> = listOf(privacy, terms)

    fun byId(id: String?): LegalDocument? = all.firstOrNull { it.id == id }
}
