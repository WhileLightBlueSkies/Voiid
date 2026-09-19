-- 083_social_consent_notice.sql — publish the Social Profile consent notice.
--
-- WHY A SECOND NOTICE RATHER THAN A NEW VERSION OF THE FIRST
--
-- The account notice ('2026-08-01') covers being a Voiid USER: a phone number identifies you,
-- encrypted messages are delivered, abuse is blocked, crashes are triaged. Those are the
-- purposes of a messenger, and someone who only wants to message should be asked about
-- exactly those and nothing else.
--
-- The Social Profile is a different bargain: a handle and photo any stranger can see, and
-- content stored UNENCRYPTED so it can be shown publicly. DPDP s.6 requires consent to be
-- specific to a purpose, so bundling "your face is public" into the notice a person accepts
-- to send a message would be consent to publishing that nobody knowingly gave.
--
-- Both notices are therefore CURRENT AT THE SAME TIME, selected by scope. `consent_records`
-- already keys on (user_id, notice_version), so a person holds two independent records and
-- can withdraw one without touching the other.
--
-- ── content_sha256 IS NULL, DELIBERATELY ────────────────────────────────────────
-- The hash is of the document as SERVED. There is no hosted document at this URL yet, and a
-- hash of a page that does not exist is worse than no hash: it is an evidence record that
-- looks complete and attests to nothing. 030's schema permits null for exactly this case and
-- forbids it for new notices once the document is live — so the URL must be published, and
-- this row's hash backfilled, before anyone is asked to agree to it in production.
--
-- [COUNSEL] The Eighth-Schedule translation obligation applies to this notice as much as to
-- the account one. English only here; the schema takes one row per language and the policy
-- decision on which of the 22 is unresolved.

insert into consent_notices (version, language, url, content_sha256, published_at)
values (
    '2026-09-19-social',
    'en',
    'https://voiid.app/legal/social-profile-notice',
    null,
    now()
)
on conflict (version, language) do nothing;
